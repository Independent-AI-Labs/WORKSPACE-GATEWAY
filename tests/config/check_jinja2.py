#!/usr/bin/env python3
"""Exit 0 if jinja2 is importable (used by test_apisix_yaml_render.sh)."""
import sys

try:
    import jinja2
    del jinja2
except ImportError:
    sys.exit(1)
