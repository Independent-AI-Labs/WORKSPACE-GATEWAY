#!/usr/bin/env python3
"""Print the Grafana version from a /api/health JSON payload on stdin.

Extracted from the gw-restart-grafana make recipe: an inline interpreter
one-liner is blocked by the CI inline-code guard; an extension-qualified
isolated script is the approved form.
"""
import json
import sys


def main() -> None:
    print("Grafana version:", json.load(sys.stdin)["version"])


if __name__ == "__main__":
    main()
