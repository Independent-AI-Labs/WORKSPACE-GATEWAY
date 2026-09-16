#!/bin/bash
set -euo pipefail

# Refresh vendored rejection-language dictionaries (REQ-USEFULNESS-TELEMETRY FR-3.3).
#
# Sources (all MIT):
#   - coffee-and-fun/google-profanity-words data/en.txt  -> conf/profanity/en.txt
#   - cjhutto/vaderSentiment vader_lexicon.txt            -> conf/profanity/vader-negative.txt
#     (valence <= -2.0 subset, single-word entries, profanity overlap removed)
#   - first20hours/google-10000-english                   -> conf/profanity/fuzzy-blocklist.txt
#     (+ every VADER lexicon word + a tech supplement). Tokens in this list
#     are common English and never fuzzy-match: distance-1 collisions like
#     where~whore, parsing~pissing, batch~bitch, fetch~felch, parse~arse,
#     chunk~chink are the dominant false-positive source.
#
# conf/profanity/frustration-phrases.txt is gateway-owned and is NEVER
# modified by this script (FR-3.5).
#
# Usage: res/scripts/update-dictionaries.sh [--dry-run]

_SELF="${BASH_SOURCE[0]}"
case "$_SELF" in
    /proc/*) _SELF="${SHG_SCRIPT_PATH:-$_SELF}" ;;
esac
SCRIPT_DIR="$(cd "$(dirname "$_SELF")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
#When invoked through a /proc file descriptor the derived root is bogus
#(/proc); make always runs recipes from the repo root, so use cwd instead.
if [ ! -f "$REPO_ROOT/conf/clickhouse-init.sql" ]; then
    REPO_ROOT="$(pwd)"
fi
if [ ! -f "$REPO_ROOT/conf/clickhouse-init.sql" ]; then
    echo "ERROR: cannot locate repo root (invoked as $_SELF, cwd $(pwd))" >&2
    exit 1
fi
OUT_DIR="$REPO_ROOT/conf/profanity"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

PROFANITY_URL="${PROFANITY_URL:-https://raw.githubusercontent.com/coffee-and-fun/google-profanity-words/main/data/en.txt}"
VADER_URL="${VADER_URL:-https://raw.githubusercontent.com/cjhutto/vaderSentiment/master/vaderSentiment/vader_lexicon.txt}"
COMMON_URL="${COMMON_URL:-https://raw.githubusercontent.com/first20hours/google-10000-english/master/google-10000-english.txt}"

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

mkdir -p "$OUT_DIR"

echo "[dicts] fetching $PROFANITY_URL"
curl -sSfL --max-time 30 "$PROFANITY_URL" -o "$TMP_DIR/en-raw.txt"
echo "[dicts] fetching $VADER_URL"
curl -sSfL --max-time 30 "$VADER_URL" -o "$TMP_DIR/vader-raw.txt"
echo "[dicts] fetching $COMMON_URL"
curl -sSfL --max-time 30 "$COMMON_URL" -o "$TMP_DIR/common-raw.txt"

# Profanity: lowercase, trim, drop empties, dedupe, sort.
tr '[:upper:]' '[:lower:]' < "$TMP_DIR/en-raw.txt" \
  | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
  | grep -v '^$' | LC_ALL=C sort -u > "$TMP_DIR/en.txt"

# VADER negative subset: valence <= -2.0, single alphabetic words (with
# apostrophes), profanity entries excluded (dedup precedence, FR-3.3).
# STOPWORDS: emotionally-negative words that are routine benign vocabulary
# in coding-assistant traffic ("kill the process", "failed test", "wrong
# import") and would swamp the rejection signal; excluded deterministically,
# with plural/verb forms so fuzzy neighbors of the singulars cannot rematerialize.
STOPWORDS='^(wrong|wrongs|broken|dead|fail|fails|failed|failing|failure|failures|kill|kills|killed|killing|attack|attacks|attacked|war|wars|lost|missing|crash|crashes|crashed|crashing|exception|exceptions|error|errors|timeout|timeouts|bug|bugs|fatal|fatally|panic|panics|panicked)$'
awk -F'\t' '$2 <= -2.0 {print $1"\t"$2}' "$TMP_DIR/vader-raw.txt" \
  | tr '[:upper:]' '[:lower:]' \
  | awk -F'\t' -v stop="$STOPWORDS" \
      '$1 ~ /^[a-z][a-z'"'"']*$/ && $1 !~ / / && $1 !~ stop {print $1"\t"$2}' \
  | LC_ALL=C sort -u > "$TMP_DIR/vader-all.txt"
awk -F'\t' 'NR==FNR {p[$1]=1; next} !($1 in p) {print}' \
  "$TMP_DIR/en.txt" "$TMP_DIR/vader-all.txt" > "$TMP_DIR/vader-negative.txt"

PROF_N=$(wc -l < "$TMP_DIR/en.txt")
VADER_N=$(wc -l < "$TMP_DIR/vader-negative.txt")
EXCLUDED=$(( $(wc -l < "$TMP_DIR/vader-all.txt") - VADER_N ))
echo "[dicts] profanity: $PROF_N entries; vader-negative: $VADER_N entries ($EXCLUDED profanity overlaps excluded)"

# Fuzzy blocklist: common-English tokens (google-10000 + every VADER lexicon
# word + a coding-context supplement). Such tokens never fuzzy-match; exact
# dictionary hits are unaffected. Sorted, deduped, committed for reproducible
# deploys.
{
  tr '[:upper:]' '[:lower:]' < "$TMP_DIR/common-raw.txt"
  awk -F'\t' '{print tolower($1)}' "$TMP_DIR/vader-raw.txt"
  cat <<'EOF'
parsing
parsed
parse
parses
batch
batches
batching
fetch
fetched
fetches
fetching
chunk
chunks
chunking
chunked
assess
assessed
asses
assessing
test
tests
tested
testing
chose
choose
choosing
shoes
hello
shell
spelled
spelling
smell
smelled
dwell
dwelling
swell
where
were
nodejs
nginx
opcode
opcodes
EOF
} | grep -E '^[a-z][a-z'"'"'-]*$' | LC_ALL=C sort -u > "$TMP_DIR/fuzzy-blocklist.txt"
BLOCK_N=$(wc -l < "$TMP_DIR/fuzzy-blocklist.txt")
echo "[dicts] fuzzy-blocklist: $BLOCK_N common-English tokens"

if $DRY_RUN; then
  echo "[dicts] DRY RUN -- snapshots not written."
  exit 0
fi

install -m 0644 "$TMP_DIR/en.txt" "$OUT_DIR/en.txt"
install -m 0644 "$TMP_DIR/vader-negative.txt" "$OUT_DIR/vader-negative.txt"
install -m 0644 "$TMP_DIR/fuzzy-blocklist.txt" "$OUT_DIR/fuzzy-blocklist.txt"

DICT_VERSION="$(cat "$OUT_DIR/en.txt" "$OUT_DIR/vader-negative.txt" \
  "$OUT_DIR/fuzzy-blocklist.txt" "$OUT_DIR/frustration-phrases.txt" | sha256sum | cut -c1-12)"echo "[dicts] dict_version=$DICT_VERSION"
echo "[dicts] done."
