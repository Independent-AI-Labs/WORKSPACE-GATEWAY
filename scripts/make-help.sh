#!/bin/bash
# Format `make help` output from "##"-annotated targets.
# Lives in a script body because the shell guard's alt-interp rule
# (REQ-SHG-313) blocks interpreters at command position in recipe -c
# text; script bodies are scanned under the script scope instead.
set -euo pipefail

grep -hE '^[a-zA-Z_-]+:.*?## .*$' "$@" | \
    awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $1, $2}'
