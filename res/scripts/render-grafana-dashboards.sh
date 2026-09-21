#!/bin/bash
# render-grafana-dashboards.sh - Expand {{sql:<path>}} references in Grafana
# sources into the committed rendered tree Grafana actually mounts.
#
#   res/scripts/render-grafana-dashboards.sh          # write conf/grafana/rendered/
#   res/scripts/render-grafana-dashboards.sh --check  # fail if the tree is stale
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"

uv run python "$REPO_ROOT/res/scripts/render_grafana_dashboards.py" "${1:-render}"
