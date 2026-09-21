#!/usr/bin/env bash
# test_migrate_opencode_stats.sh - Fixture test + optional full-database
# rehearsal for res/scripts/migrate-opencode-stats.sh.
# Isolation invariants (REQ-STATS-MIGRATION FR-5):
#   - SQLite source is always a .backup COPY, never the live database.
#   - ClickHouse target is always a brand-new ephemeral podman container
#     (fresh volume, init.sql applied, ephemeral loopback port - never
#     the dev stack's 8123), asserted empty before any run.
# Usage: test_migrate_opencode_stats.sh [--full]
#   --full  also rehearses against a .backup of the real opencode.db
#           (skipped when OPENCODE_LIVE_DB is absent).
set -euo pipefail

_SELF="${BASH_SOURCE[0]}"
if [ -n "${SHG_SCRIPT_PATH:-}" ]; then
    _SELF="$SHG_SCRIPT_PATH"
fi
SCRIPT_DIR="$(cd "$(dirname "$_SELF")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
export REPO_ROOT
# shellcheck source=../res/scripts/lib-sql.sh
source "$REPO_ROOT/res/scripts/lib-sql.sh" || exit 1
MIGRATOR="$REPO_ROOT/res/scripts/migrate-opencode-stats.sh"
INIT_SQL="$REPO_ROOT/conf/sql/clickhouse-init.sql"
CH_IMAGE="clickhouse/clickhouse-server:24.8-alpine"
OPENCODE_LIVE_DB="${OPENCODE_LIVE_DB:-$HOME/.local/share/opencode/opencode.db}"
TEST_OPS_ADMIN="$SCRIPT_DIR/test-ops-admin.xml"

# The migrator authenticates as ops_admin; source repo .env first.
: "${CH_OPS_PASSWORD:?CH_OPS_PASSWORD not set (source repo .env)}"

FULL=false
[ "${1:-}" = "--full" ] && FULL=true

pass=0
fail=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        echo "[PASS] $desc"
        pass=$((pass + 1))
    else
        echo "[FAIL] $desc -- expected: $expected, actual: $actual"
        fail=$((fail + 1))
    fi
}

summary() {
    echo ""
    echo "test_migrate_opencode_stats.sh: $pass passed, $fail failed"
    [ "$fail" -gt 0 ] && exit 1
    exit 0
}

PODMAN_BIN="${PODMAN_BIN:-}"
if [ -z "$PODMAN_BIN" ]; then
    if [ -x /opt/workspace-ci/.boot-linux/bin/real-podman ]; then
        PODMAN_BIN="/opt/workspace-ci/.boot-linux/bin/real-podman"
    elif command -v real-podman 2>&1; then
        PODMAN_BIN="real-podman"
    else
        PODMAN_BIN="podman"
    fi
fi
echo "[INFO] container runtime: $PODMAN_BIN"

TMPD="$(mktemp -d)"
CONTAINERS=()
CLEANED=false

# cleanup runs exactly once, on EVERY exit path: normal end, set -e abort,
# assert failure, signals INT/TERM/HUP. Only SIGKILL bypasses it; that case
# is covered by --rm on the container and the stale sweep on the next run.
cleanup() {
    [ "$CLEANED" = true ] && return 0
    CLEANED=true
    # Never re-trigger: clear traps first. Every fallible command below is
    # guarded individually so cleanup always runs to completion.
    trap - EXIT INT TERM HUP
    local c stale_all
    for c in "${CONTAINERS[@]:-}"; do
        if [ -n "$c" ]; then
            # -v: also removes the anonymous /var/lib/clickhouse volume
            # (~400k inodes per container; leaving them once exhausted the
            # host inode table -- 57M inodes, 2026-08-29).
            if ! "$PODMAN_BIN" rm -f -v "$c" 2>&1; then
                echo "[WARN] failed to remove container $c" >&2
            fi
        fi
    done
    # Backstop: catch any migtest container this run failed to register
    # (e.g. killed between podman run and CONTAINERS+=).
    while IFS= read -r stale_all; do
        [ -z "$stale_all" ] && continue
        echo "[WARN] cleanup backstop removing unregistered container: $stale_all" >&2
        if ! "$PODMAN_BIN" rm -f -v "$stale_all" >&2; then
            echo "[WARN] failed to remove backstop container $stale_all" >&2
        fi
    done < <("$PODMAN_BIN" ps -a --format '{{.Names}}' | awk '$1 ~ /^migtest-ch-/')
    if ! rm -rf "$TMPD"; then
        echo "[WARN] failed to remove temp dir $TMPD" >&2
    fi
    return 0
}
trap cleanup EXIT
trap 'cleanup; trap - INT; kill -INT $$' INT
trap 'cleanup; trap - TERM; kill -TERM $$' TERM
trap 'cleanup; trap - HUP; kill -HUP $$' HUP

# Sweep containers leaked by earlier killed runs (trap cannot catch SIGKILL).
mapfile -t STALE < <("$PODMAN_BIN" ps -a --format '{{.Names}}' | awk '$1 ~ /^migtest-ch-/')
if (( ${#STALE[@]} )); then
    echo "[WARN] removing ${#STALE[@]} stale migtest container(s) from prior runs" >&2
    "$PODMAN_BIN" rm -f -v "${STALE[@]}" >&2
fi

# ---------------------------------------------------------- fresh CH (FR-5.2)
# Sets global CH_URL. MUST NOT be called in a command substitution:
# a subshell would drop the CONTAINERS+= registration and leak the
# container + its anonymous volume on cleanup.
start_clickhouse() {
    local name="migtest-ch-$(date +%s)-$RANDOM" port="" out=""
    CH_URL=""
    if ! out=$("$PODMAN_BIN" run -d --rm --name "$name" \
        -p 127.0.0.1::8123 \
        -e "CH_OPS_PASSWORD=$CH_OPS_PASSWORD" \
        -v "$INIT_SQL:/docker-entrypoint-initdb.d/init.sql:ro" \
        -v "$TEST_OPS_ADMIN:/etc/clickhouse-server/users.d/ops-admin.xml:ro" \
        "$CH_IMAGE" 2>&1); then
        echo "[FAIL] podman run: $out" >&2
        return 1
    fi
    CONTAINERS+=("$name")
    port=$("$PODMAN_BIN" port "$name" 8123 | awk -F: '{print $NF}')
    local i
    for i in $(seq 1 60); do
        if curl -sSf --max-time 2 "http://127.0.0.1:$port/ping" 2>&1 | grep -q 'Ok.'; then
            CH_URL="http://127.0.0.1:$port"
            return 0
        fi
        sleep 2
    done
    return 1
}

assert_fresh() {
    local url="$1" t
    for t in usage_log request_log billing_ledger; do
        local n
        n=$(curl -sSf "$url/" --data-binary "$(sql_render ops/migrate-opencode-stats/table-count.sql "DB=llm_gateway" "TABLE=$t")")
        assert_eq "fresh instance: $t empty (FR-5.3)" "0" "$n"
    done
}

# ---------------------------------------------------------- fixture (FR-5.1)
FIXTURE="$TMPD/fixture-src.db"
sql_render sqlite/tests/migrate-opencode-stats/fixture.sql | sqlite3 "$FIXTURE"

# models.dev-format fixture. Direct providers (amazon-bedrock) are their
# own models.dev provider; zai-coding-plan is flat-fee (zero rates) and is
# explicitly priced at zai; gateway routes and models.dev provider ids come
# from conf/providers/*.yaml, not from here.
PRICING_FIXTURE="$TMPD/pricing.json"
cat > "$PRICING_FIXTURE" <<'JSON'
{
  "zai-coding-plan": {"models": {"glm-5.3": {"cost": {"input": 0, "output": 0}}}},
  "zai": {"models": {"glm-5.3": {"cost": {"input": 1.4, "output": 4.4}}}},
  "amazon-bedrock": {"models": {"glm-5": {"cost": {"input": 2, "output": 8}}}},
  "moonshotai": {"models": {"kimi-k3": {"cost": {"input": 3, "output": 15}}}}
}
JSON

SRC_COPY="$TMPD/fixture-copy.db"
sqlite3 "$FIXTURE" ".backup '$SRC_COPY'"
file_exists() { if [ -e "$1" ]; then printf 'true'; else printf 'false'; fi; }
text_matches() { if echo "$1" | grep -q "$2"; then printf 'true'; else printf 'false'; fi; }
assert_eq "copy has no WAL sidecar (FR-5.1)" "false" "$(file_exists "$SRC_COPY-wal")"
assert_eq "copy has no SHM sidecar (FR-5.1)" "false" "$(file_exists "$SRC_COPY-shm")"

if ! start_clickhouse; then echo "[FAIL] ephemeral ClickHouse failed to start"; fail=$((fail+1)); summary; fi
echo "[INFO] fresh ClickHouse at $CH_URL"
assert_fresh "$CH_URL"

# ---------------------------------------------------------- dry-run
DRY_OUT=$(OPENCODE_DBS="$SRC_COPY" bash "$MIGRATOR" --dry-run --clickhouse-url "$CH_URL" --pricing-file "$PRICING_FIXTURE")
echo "$DRY_OUT"
assert_eq "dry-run rows to insert (usage)" \
    "[DRY-RUN] rows to insert: usage_log=5 request_log=5" \
    "$(echo "$DRY_OUT" | grep 'rows to insert')"
assert_eq "dry-run dup count" \
    "[DRY-RUN] source duplicates collapsed: 1" \
    "$(echo "$DRY_OUT" | grep 'duplicates collapsed:')"
assert_eq "dry-run pricing coverage" \
    "[DRY-RUN] rows priced via models.dev: 3; unknown: 2" \
    "$(echo "$DRY_OUT" | grep 'priced via models.dev')"

# ---------------------------------------------------------- run 1
BACKUP_DIR="$TMPD/backup"
RUN1=$(OPENCODE_DBS="$SRC_COPY" bash "$MIGRATOR" --clickhouse-url "$CH_URL" --backup-dir "$BACKUP_DIR" --pricing-file "$PRICING_FIXTURE")
echo "$RUN1"
assert_eq "run1 usage_log inserted" \
    "[OK] usage_log: inserted=5 skipped_existing=0 of 5" \
    "$(echo "$RUN1" | grep 'usage_log:')"
assert_eq "run1 request_log inserted" \
    "[OK] request_log: inserted=5 skipped_existing=0 of 5" \
    "$(echo "$RUN1" | grep 'request_log:')"
assert_eq "backup manifest rows (3 tables)" "3" "$(wc -l < "$BACKUP_DIR/manifest.txt")"
assert_eq "backup usage_log native dump exists" "true" \
    "$(file_exists "$BACKUP_DIR/usage_log.native")"
assert_eq "backup request_log native dump exists" "true" \
    "$(file_exists "$BACKUP_DIR/request_log.native")"
assert_eq "backup billing_ledger native dump exists" "true" \
    "$(file_exists "$BACKUP_DIR/billing_ledger.native")"
assert_eq "backup manifest pre-insert counts are 0" "3" \
    "$(grep -c 'rows=0' "$BACKUP_DIR/manifest.txt")"

# ---------------------------------------------------------- field checks
chq() { curl -sSf "$CH_URL/" --data-binary "$1"; }
chq_t() { local tmpl="$1"; shift; chq "$(sql_render "tests/migrate-opencode-stats/$tmpl.sql" "$@")"; }
chq_count() { chq "$(sql_render ops/migrate-opencode-stats/table-count.sql "DB=llm_gateway" "TABLE=$1")"; }

U1=$(chq_t select-by-event "COLS=model, model_raw, provider_id, prompt_tokens, completion_tokens, total_tokens, reasoning_tokens, cached_tokens, cost, cost_source, reported_cost, is_stream, request_id" "TABLE=usage_log" "EID=ocm_msg_a01" "FORMAT= FORMAT JSONEachRow")
assert_eq "canonical model k3->kimi-k3" "kimi-k3" "$(echo "$U1" | jq -r .model)"
assert_eq "model_raw verbatim" "k3" "$(echo "$U1" | jq -r .model_raw)"
assert_eq "provider_id aliased" "workspace-gw-kimi-device-oauth" "$(echo "$U1" | jq -r .provider_id)"
assert_eq "prompt_tokens=input+cache.read+cache.write" "110" "$(echo "$U1" | jq -r .prompt_tokens)"
assert_eq "completion_tokens=output+reasoning" "60" "$(echo "$U1" | jq -r .completion_tokens)"
assert_eq "total_tokens=prompt+completion" "170" "$(echo "$U1" | jq -r .total_tokens)"
assert_eq "reasoning_tokens" "10" "$(echo "$U1" | jq -r .reasoning_tokens)"
assert_eq "cached_tokens=cache.read" "7" "$(echo "$U1" | jq -r .cached_tokens)"
assert_eq "billed cost from provider-scoped models.dev price" "0.0012" "$(echo "$U1" | jq -r .cost)"
assert_eq "cost_source models_dev (priced)" "models_dev" "$(echo "$U1" | jq -r .cost_source)"
assert_eq "opencode-recorded cost kept as reported_cost" "0.5" "$(echo "$U1" | jq -r .reported_cost)"
assert_eq "is_stream=1" "1" "$(echo "$U1" | jq -r .is_stream)"
assert_eq "request_id=message.id" "msg_a01" "$(echo "$U1" | jq -r .request_id)"

U2=$(chq_t select-by-event "COLS=model, cost, cost_source, reported_cost" "TABLE=usage_log" "EID=ocm_msg_a02" "FORMAT= FORMAT JSONEachRow")
assert_eq "canonical /zip model" "minicpm5-1b-q8_0.gguf" "$(echo "$U2" | jq -r .model)"
assert_eq "cost_source unknown (cost=0, no pricing)" "unknown" "$(echo "$U2" | jq -r .cost_source)"
assert_eq "unpriced row reported_cost stays 0" "0" "$(echo "$U2" | jq -r .reported_cost)"

# ---------------------------------------------------------- pricing checks
B1=$(chq_t select-by-event "COLS=model, model_raw, provider_id, cost, cost_source" "TABLE=usage_log" "EID=ocm_msg_b01" "FORMAT= FORMAT JSONEachRow")
assert_eq "b01 canonical model glm-5.3" "glm-5.3" "$(echo "$B1" | jq -r .model)"
assert_eq "b01 flat-fee zai-coding-plan priced at zai, reasoning falls back to output" "3.6" "$(echo "$B1" | jq -r .cost)"
assert_eq "b01 cost_source models_dev" "models_dev" "$(echo "$B1" | jq -r .cost_source)"
assert_eq "b01 provider_id unchanged" "zai-coding-plan" "$(echo "$B1" | jq -r .provider_id)"

B2=$(chq_t select-by-event "COLS=model, model_raw, cost, cost_source" "TABLE=usage_log" "EID=ocm_msg_b02" "FORMAT= FORMAT JSONEachRow")
assert_eq "b02 dot-form raw id canonicalizes (zai.glm-5 -> glm-5)" "glm-5" "$(echo "$B2" | jq -r .model)"
assert_eq "b02 model_raw verbatim" "zai.glm-5" "$(echo "$B2" | jq -r .model_raw)"
assert_eq "b02 priced via models.dev amazon-bedrock (1e6*2 + 1e6*8)/1e6" "10" "$(echo "$B2" | jq -r .cost)"
assert_eq "b02 cost_source models_dev" "models_dev" "$(echo "$B2" | jq -r .cost_source)"

B3=$(chq_t select-by-event "COLS=cost, cost_source, aborted" "TABLE=usage_log" "EID=ocm_msg_b03" "FORMAT= FORMAT JSONEachRow")
assert_eq "b03 unpriced model stays 0" "0" "$(echo "$B3" | jq -r .cost)"
assert_eq "b03 cost_source unknown" "unknown" "$(echo "$B3" | jq -r .cost_source)"

# ------------------------------------------------- aborted mapping (opencode error.name)
A2=$(chq_t select-by-event "COLS=aborted" "TABLE=usage_log" "EID=ocm_msg_a02")
assert_eq "user abort maps to aborted=1 (client cancel)" "1" "$A2"
B3AB=$(chq_t select-by-event "COLS=aborted" "TABLE=usage_log" "EID=ocm_msg_b03")
assert_eq "provider APIError maps to aborted=2" "2" "$B3AB"
assert_eq "no error maps to aborted=0 (completed)" "0" \
    "$(chq_t select-by-event "COLS=aborted" "TABLE=usage_log" "EID=ocm_msg_a01")"
assert_eq "migrated abort values are only 0/1/2" "0" \
    "$(chq_t count-invalid-aborts "PREFIX=ocm_")"

# --------------------------------------- timing migration (message times)
assert_eq "duration_ms = completed - created" "1500" \
    "$(chq_t select-by-event "COLS=duration_ms" "TABLE=usage_log" "EID=ocm_msg_a01")"
assert_eq "ttft_content_ms = first non-reasoning part - created" "2" \
    "$(chq_t select-by-event "COLS=ttft_content_ms" "TABLE=usage_log" "EID=ocm_msg_a01")"
assert_eq "aborted message keeps its timing" "200" \
    "$(chq_t select-by-event "COLS=duration_ms" "TABLE=usage_log" "EID=ocm_msg_a02")"
assert_eq "message without parts has ttft 0" "0" \
    "$(chq_t select-by-event "COLS=ttft_content_ms" "TABLE=usage_log" "EID=ocm_msg_a02")"
assert_eq "no time.completed means duration 0" "0" \
    "$(chq_t select-by-event "COLS=duration_ms" "TABLE=usage_log" "EID=ocm_msg_b03")"
assert_eq "request_log upstream_response_time_s = duration_ms/1000" "1.5" \
    "$(chq_t select-by-event "COLS=upstream_response_time_s" "TABLE=request_log" "EID=ocr_msg_a01")"
assert_eq "request_log upstream_response_time_s b02" "0.1" \
    "$(chq_t select-by-event "COLS=upstream_response_time_s" "TABLE=request_log" "EID=ocr_msg_b02")"

R1=$(chq_t select-by-event "COLS=session_id, project_id, parent_session_id, agent_name, opencode_version, user_agent, method, uri, status, stream, request_size, response_size, client_type" "TABLE=request_log" "EID=ocr_msg_a01" "FORMAT= FORMAT JSONEachRow")
assert_eq "request session_id" "s1" "$(echo "$R1" | jq -r .session_id)"
assert_eq "request project_id" "p1" "$(echo "$R1" | jq -r .project_id)"
assert_eq "request parent_session_id empty" "" "$(echo "$R1" | jq -r .parent_session_id)"
assert_eq "request agent_name" "build" "$(echo "$R1" | jq -r .agent_name)"
assert_eq "request opencode_version" "1.17.11" "$(echo "$R1" | jq -r .opencode_version)"
assert_eq "request user_agent derived" "opencode/1.17.11" "$(echo "$R1" | jq -r .user_agent)"
assert_eq "request synthetic method" "POST" "$(echo "$R1" | jq -r .method)"
assert_eq "request synthetic uri (catalog route)" "/kimi/chat/completions" "$(echo "$R1" | jq -r .uri)"
assert_eq "request synthetic status" "200" "$(echo "$R1" | jq -r .status)"
assert_eq "request stream true" "true" "$(echo "$R1" | jq -r .stream)"
assert_eq "request_size=prior context bytes" "5" "$(echo "$R1" | jq -r .request_size)"
assert_eq "response_size=own part bytes" "11" "$(echo "$R1" | jq -r .response_size)"
assert_eq "client_type=migrated" "migrated" "$(echo "$R1" | jq -r .client_type)"

R2=$(chq_t select-by-event "COLS=request_size, response_size, client_type" "TABLE=request_log" "EID=ocr_msg_a02" "FORMAT= FORMAT JSONEachRow")
assert_eq "msg_a02 request_size=cumulative context" "16" "$(echo "$R2" | jq -r .request_size)"
assert_eq "msg_a02 response_size=0 (no parts)" "0" "$(echo "$R2" | jq -r .response_size)"
assert_eq "msg_a02 client_type=migrated" "migrated" "$(echo "$R2" | jq -r .client_type)"

# ---------------------------------------------------------- req_body synthesis
# msg_a01 is the first assistant turn: body = last user prompt only
# (no prior assistant turns, no markers yet at its timestamp).
RB1=$(chq_t select-by-event "COLS=req_body" "TABLE=request_log" "EID=ocr_msg_a01" "FORMAT= FORMAT TSVRaw")
assert_eq "msg_a01 body is valid JSON with messages array" "array" \
    "$(echo "$RB1" | jq -r '.messages | type')"
assert_eq "msg_a01 body has no prior assistant turn" "0" \
    "$(echo "$RB1" | jq -r '[.messages[] | select(.role == "assistant")] | length')"
assert_eq "msg_a01 body carries last user prompt" "hello" \
    "$(echo "$RB1" | jq -r '[.messages[] | select(.role == "user") | .content] | last')"

# msg_a02 follows msg_a01: one prior assistant turn, same user prompt,
# and both marker texts (rejection + guard block) land in the body.
RB2=$(chq_t select-by-event "COLS=req_body" "TABLE=request_log" "EID=ocr_msg_a02" "FORMAT= FORMAT TSVRaw")
assert_eq "msg_a02 body has 1 prior assistant turn" "1" \
    "$(echo "$RB2" | jq -r '[.messages[] | select(.role == "assistant" and .content == "")] | length')"
assert_eq "msg_a02 body carries last user prompt" "hello" \
    "$(echo "$RB2" | jq -r '[.messages[] | select(.role == "user") | .content] | last')"
assert_eq "msg_a02 body carries rejection marker" "1" \
    "$(echo "$RB2" | jq -r '[.messages[].content | select(test("The user rejected permission to use this specific tool call"))] | length')"
assert_eq "msg_a02 body carries guard-block marker" "1" \
    "$(echo "$RB2" | jq -r '[.messages[].content | select(test("BLOCKED: bash "))] | length')"

# Every migrated request row carries a parseable body with a messages array
assert_eq "all migrated rows have parseable req_body" "5" \
    "$(chq_t count-parseable-bodies "PREFIX=ocr_")"

# Lua-convention invariants (panel math assumes prompt>=cached, completion>=reasoning)
assert_eq "no row with cached>prompt" "0" \
    "$(chq_t count-cached-over-prompt)"
assert_eq "no row with reasoning>completion" "0" \
    "$(chq_t count-reasoning-over-completion)"

# ---------------------------------------------------------- billing MV
BL=$(chq_t select-by-event "COLS=model_name, cost, provider" "TABLE=billing_ledger" "EID=ocm_msg_a01" "FORMAT= FORMAT JSONEachRow")
assert_eq "billing_ledger MV row model" "kimi-k3" "$(echo "$BL" | jq -r .model_name)"
assert_eq "billing_ledger MV row cost" "0.0012" "$(echo "$BL" | jq -r .cost)"

# ---------------------------------------------------------- rerun gate
GUARD_RC=0
GUARD_OUT=$(OPENCODE_DBS="$SRC_COPY" bash "$MIGRATOR" --clickhouse-url "$CH_URL" --pricing-file "$PRICING_FIXTURE" 2>&1) || GUARD_RC=$?
echo "$GUARD_OUT"
assert_eq "rerun without --force aborts" "1" "$GUARD_RC"
assert_eq "rerun gate message" "true" \
    "$(text_matches "$GUARD_OUT" 'already present in llm_gateway.usage_log')"

# ---------------------------------------------------------- idempotency (--force)
RUN2=$(OPENCODE_DBS="$SRC_COPY" bash "$MIGRATOR" --clickhouse-url "$CH_URL" --force --pricing-file "$PRICING_FIXTURE")
echo "$RUN2"
assert_eq "run2 usage_log idempotent" \
    "[OK] usage_log: inserted=0 skipped_existing=5 of 5" \
    "$(echo "$RUN2" | grep 'usage_log:')"
assert_eq "run2 request_log idempotent" \
    "[OK] request_log: inserted=0 skipped_existing=5 of 5" \
    "$(echo "$RUN2" | grep 'request_log:')"
assert_eq "usage_log total unchanged" "5" \
    "$(chq_count usage_log)"
assert_eq "request_log total unchanged" "5" \
    "$(chq_count request_log)"

# ---------------------------------------------------------- reset + --force rerun
chq_t delete-event-prefix "TABLE=usage_log" "PREFIX=ocm_"
chq_t delete-event-prefix "TABLE=request_log" "PREFIX=ocr_"
assert_eq "reset: usage_log empty" "0" "$(chq_count usage_log)"
assert_eq "reset: request_log empty" "0" "$(chq_count request_log)"
RUN3=$(OPENCODE_DBS="$SRC_COPY" bash "$MIGRATOR" --clickhouse-url "$CH_URL" --force --backup-dir "$TMPD/backup2" --pricing-file "$PRICING_FIXTURE")
echo "$RUN3"
assert_eq "post-reset --force rerun reinserts all" \
    "[OK] usage_log: inserted=5 skipped_existing=0 of 5" \
    "$(echo "$RUN3" | grep 'usage_log:')"
assert_eq "post-reset rerun keeps priced cost" "3.6" \
    "$(chq_t select-by-event "COLS=cost" "TABLE=usage_log" "EID=ocm_msg_b01")"

# ---------------------------------------------------------- full rehearsal (AC-5)
if [ "$FULL" = true ]; then
    if [ ! -f "$OPENCODE_LIVE_DB" ]; then
        echo "[SKIP] --full: $OPENCODE_LIVE_DB not found"
    else
        LIVE_COPY="$TMPD/live-copy.db"
        echo "[INFO] --full: taking WAL-safe .backup of live db (may take a while)"
        sqlite3 "$OPENCODE_LIVE_DB" ".backup '$LIVE_COPY'"
        CH2_URL=""
        if ! start_clickhouse; then echo "[FAIL] rehearsal ClickHouse failed"; fail=$((fail+1)); summary; fi
        CH2_URL="$CH_URL"
        echo "[INFO] rehearsal ClickHouse at $CH2_URL"
        assert_fresh "$CH2_URL"

        DRY2=$(OPENCODE_DBS="$LIVE_COPY" bash "$MIGRATOR" --dry-run --clickhouse-url "$CH2_URL" --pricing-file "$PRICING_FIXTURE")
        echo "$DRY2"
        EXPECT=$(echo "$DRY2" | grep 'rows to insert' | sed -E 's/.*usage_log=([0-9]+).*/\1/')

        RUN4=$(OPENCODE_DBS="$LIVE_COPY" bash "$MIGRATOR" --clickhouse-url "$CH2_URL" --backup-dir "$TMPD/live-backup" --pricing-file "$PRICING_FIXTURE")
        echo "$RUN4"
        GOT=$(echo "$RUN4" | grep 'usage_log:' | sed -E 's/.*inserted=([0-9]+).*/\1/')
        assert_eq "rehearsal dry-run count == inserted count (AC-5)" "$EXPECT" "$GOT"
        assert_eq "rehearsal usage_log row count" "$EXPECT" \
            "$(curl -sSf "$CH2_URL/" --data-binary "$(sql_render ops/migrate-opencode-stats/table-count.sql "DB=llm_gateway" "TABLE=usage_log")")"
        assert_eq "rehearsal no cached>prompt rows" "0" \
            "$(curl -sSf "$CH2_URL/" --data-binary "$(sql_render tests/migrate-opencode-stats/count-cached-over-prompt.sql)")"
        assert_eq "rehearsal no reasoning>completion rows" "0" \
            "$(curl -sSf "$CH2_URL/" --data-binary "$(sql_render tests/migrate-opencode-stats/count-reasoning-over-completion.sql)")"

        RUN5=$(OPENCODE_DBS="$LIVE_COPY" bash "$MIGRATOR" --clickhouse-url "$CH2_URL" --force --pricing-file "$PRICING_FIXTURE")
        assert_eq "rehearsal second pass inserts 0 (AC-5)" \
            "[OK] usage_log: inserted=0 skipped_existing=$EXPECT of $EXPECT" \
            "$(echo "$RUN5" | grep 'usage_log:')"
    fi
fi

summary
