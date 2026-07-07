#!/bin/bash
set -euo pipefail

# install-deps.sh
# Checks and installs system dependencies listed in config/system-deps.yaml.
# Pure bash + awk. No Python.
#
# Usage:
#   make init          # check + print install instructions
#   make init-check    # check only (report missing, exit non-zero if any)
#   bash res/scripts/install-deps.sh --check
#   bash res/scripts/install-deps.sh --install
#
# Behavior:
#   --check   Report present/missing for each tool. Exit 0 if all present,
#             exit 1 if any missing.
#   --install Report present/missing, then print the apt-get command to
#             install missing packages. Does NOT run sudo itself.
#             Exit 0 if all present, exit 1 if any missing (so the user
#             knows to run the printed command).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DEPS_FILE="${DEPS_FILE:-$REPO_ROOT/config/system-deps.yaml}"

MODE="check"
if [ "${1:-}" = "--install" ]; then
  MODE="install"
elif [ "${1:-}" = "--check" ]; then
  MODE="check"
elif [ -n "${1:-}" ]; then
  echo "Usage: $0 [--check|--install]" >&2
  exit 2
fi

if [ ! -f "$DEPS_FILE" ]; then
  echo "ERROR: Dependencies config not found: $DEPS_FILE" >&2
  exit 1
fi

# Parse config/system-deps.yaml with awk.
# Extracts check_cmd, apt_package (or "-" if absent), description per entry.
# Output format: TSV lines of "check_cmd<TAB>apt_package<TAB>description"
parse_deps() {
  awk '
    /^requires:/ { in_requires = 1; next }
    in_requires && /^[^ ]/ { in_requires = 0; next }
    in_requires && /^  - check_cmd:/ {
      if (check_cmd != "") {
        print check_cmd "\t" apt_pkg "\t" desc
      }
      check_cmd = $3
      apt_pkg = "-"
      desc = ""
      next
    }
    in_requires && /^    apt_package:/ {
      apt_pkg = $2
      next
    }
    in_requires && /^    description:/ {
      sub(/^    description:[ ]*/, "")
      desc = $0
      next
    }
    END {
      if (check_cmd != "") {
        print check_cmd "\t" apt_pkg "\t" desc
      }
    }
  ' "$DEPS_FILE"
}

missing_pkgs=()
non_apt_missing=()
present_count=0
missing_count=0

echo "=== System Dependency Check ==="
echo ""

while IFS=$'\t' read -r check_cmd apt_pkg desc; do
  if command -v "$check_cmd" >/dev/null 2>&1; then
    echo "  [OK]      $check_cmd  -  $desc"
    present_count=$((present_count + 1))
  else
    echo "  [MISSING] $check_cmd  -  $desc"
    missing_count=$((missing_count + 1))
    if [ "$apt_pkg" != "-" ]; then
      missing_pkgs+=("$apt_pkg")
    else
      non_apt_missing+=("$check_cmd")
    fi
  fi
done < <(parse_deps)

echo ""
echo "  Present:  $present_count"
echo "  Missing:  $missing_count"

if [ "$missing_count" -eq 0 ]; then
  echo ""
  echo "All system dependencies satisfied."
  exit 0
fi

if [ "${#missing_pkgs[@]}" -gt 0 ]; then
  echo ""
  echo "Missing apt-installable packages: ${missing_pkgs[*]}"
  echo ""
  echo "Install them by running:"
  echo ""
  echo "  sudo apt-get update && sudo apt-get install -y ${missing_pkgs[*]}"
  echo ""
  if [ "$MODE" = "install" ]; then
    echo "This script does not run sudo. Run the command above manually."
  fi
fi

# Tools without apt_package (e.g. uv) need manual bootstrap
for tool in "${non_apt_missing[@]}"; do
  echo ""
  echo "  $tool is not apt-installable. Bootstrap it manually."
  case "$tool" in
    uv)
      echo "    curl -LsSf https://astral.sh/uv/install.sh | sh"
      ;;
    *)
      echo "    See documentation for $tool installation."
      ;;
  esac
done

exit 1
