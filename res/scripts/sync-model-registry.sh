#!/bin/bash
set -euo pipefail

# sync-model-registry.sh - materialize model metadata into
# llm_gateway.model_registry so dashboards can filter without parsing
# YAML at query time (Grafana include/exclude-local toggle).
#
# Source of truth: conf/model-registry.yaml (canonical ids) +
# conf/providers/*.yaml (`local: true` flags). This script only copies;
# idempotent (TRUNCATE + INSERT).
#
# Usage: sync-model-registry.sh [--dry-run]
#   --dry-run  print the planned rows, write nothing
# Env: CLICKHOUSE_HOST (default localhost), CLICKHOUSE_PORT (default 8123),
#      DATABASE (default llm_gateway)

CLICKHOUSE_HOST="${CLICKHOUSE_HOST:-localhost}"
CLICKHOUSE_PORT="${CLICKHOUSE_PORT:-8123}"
DATABASE="${DATABASE:-llm_gateway}"
CH_URL="http://${CLICKHOUSE_HOST}:${CLICKHOUSE_PORT}"

# Authenticated ops access (REQ-SECURITY-HARDENING FR-1.3): no
# unauthenticated access. Enforced at first query so --dry-run works
# without credentials.
CH_OPS_USER="${CH_OPS_USER:-ops_admin}"
need_ch_creds() {
    : "${CH_OPS_PASSWORD:?CH_OPS_PASSWORD not set (source repo .env)}"
}

DRY_RUN=false
[ "${1:-}" = "--dry-run" ] && DRY_RUN=true

_SELF="${BASH_SOURCE[0]}"
case "$_SELF" in
    /proc/*) _SELF="${SHG_SCRIPT_PATH:-$_SELF}" ;;
esac
SCRIPT_DIR="$(cd "$(dirname "$_SELF")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
if [ ! -f "$REPO_ROOT/conf/model-registry.yaml" ]; then
    REPO_ROOT="$(pwd)"
fi
if [ ! -f "$REPO_ROOT/conf/model-registry.yaml" ]; then
    echo "ERROR: cannot locate repo root (invoked as $_SELF, cwd $(pwd))" >&2
    exit 1
fi

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

# YAML parsing reuses the repo's containerized helper (host has no YAML
# tooling; same pattern as gen-model-registry.sh).
# shellcheck source=../../tests/config/yaml_helpers.sh
source "$REPO_ROOT/tests/config/yaml_helpers.sh" || exit 1

REG_JSON="$(yaml_to_json "$REPO_ROOT/conf/model-registry.yaml")"
[ -n "$REG_JSON" ] || { echo "ERROR: cannot parse conf/model-registry.yaml" >&2; exit 1; }

# Alias map (lowercased alias -> canonical), mirroring
# gen-model-registry.sh: canonical maps to itself.
echo "$REG_JSON" | jq -r '.models | to_entries[] | .key as $c
       | ([$c] + [(.value.aliases // [])[] | ascii_downcase])[]
       | "\(.)\t\($c)"' | LC_ALL=C sort > "$TMPD/aliases.tsv"

# Provider yaml -> model ids for local-flagged providers.
: > "$TMPD/local_models.tsv"
for pv in "$REPO_ROOT"/conf/providers/*.yaml; do
    [ -f "$pv" ] || continue
    PV_JSON="$(yaml_to_json "$pv")"
    [ -n "$PV_JSON" ] || { echo "ERROR: cannot parse $pv" >&2; exit 1; }
    echo "$PV_JSON" | jq -r 'select(.local == true)
           | .provider.id as $p
           | .model_source.model_metadata[]?.id
           | "\($p)\t\(.)"' >> "$TMPD/local_models.tsv"
done

# Canonicalize each local provider model id through the alias map
# (exact lowercase hit, else last "/" segment hit, else last segment).
awk -F'\t' -v OFS='\t' '
    NR==FNR { alias[$1]=$2; next }
    {
        m = tolower($2)
        c = m in alias ? alias[m] : ""
        if (c == "") {
            seg = m; sub(/.*\//, "", seg)
            c = (seg in alias) ? alias[seg] : seg
        }
        print c, 1, $1
    }
' "$TMPD/aliases.tsv" "$TMPD/local_models.tsv" | LC_ALL=C sort -u > "$TMPD/local_rows.tsv"

# All registry canonicals, local flag joined; models not under any local
# provider land with is_local = 0.
cut -f2 "$TMPD/aliases.tsv" | LC_ALL=C sort -u > "$TMPD/canonicals.tsv"
awk -F'\t' -v OFS='\t' '
    NR==FNR { loc[$1]=1; prov[$1]=$3; next }
    { print $1, ($1 in loc) ? 1 : 0, ($1 in prov) ? prov[$1] : "" }
' "$TMPD/local_rows.tsv" "$TMPD/canonicals.tsv" > "$TMPD/rows.tsv"

N_ROWS=$(wc -l < "$TMPD/rows.tsv")
if [ "$N_ROWS" -eq 0 ]; then
    echo "ERROR: model_registry would be empty (conf/model-registry.yaml has no models?)" >&2
    exit 1
fi

if $DRY_RUN; then
    echo "[DRY-RUN] model_registry rows: $N_ROWS"
    cat "$TMPD/rows.tsv"
    exit 0
fi
need_ch_creds

jq -cRn 'inputs | split("\t") as $f |
    { model: $f[0], is_local: ($f[1]|tonumber), provider: $f[2] }' \
    "$TMPD/rows.tsv" > "$TMPD/rows.jsonl"

curl -sSf --max-time 30 --user "$CH_OPS_USER:$CH_OPS_PASSWORD" "$CH_URL/" \
    --data-binary "TRUNCATE TABLE ${DATABASE}.model_registry"
{ printf 'INSERT INTO %s.model_registry (model, is_local, provider) FORMAT JSONEachRow\n' "$DATABASE"
  cat "$TMPD/rows.jsonl"; } > "$TMPD/insert.payload"
curl -sSf --max-time 30 --user "$CH_OPS_USER:$CH_OPS_PASSWORD" "$CH_URL/" --data-binary @"$TMPD/insert.payload"
echo "[OK] model_registry synced: $N_ROWS models ($(awk -F'\t' '$2==1' "$TMPD/rows.tsv" | wc -l) local)"
