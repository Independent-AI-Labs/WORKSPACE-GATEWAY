#!/usr/bin/env python3
"""Render conf/apisix.yaml.j2 the same way the stack does (tests/config)."""
import os
import sys

import jinja2

path = sys.argv[1]
env = jinja2.Environment(
    loader=jinja2.FileSystemLoader(os.path.dirname(path)),
    undefined=jinja2.Undefined,
)
template = env.get_template(os.path.basename(path))
# jinja2 default() with boolean=true handles empty AND undefined; pass vars
# explicitly so local env does not leak across renders.
print(
    template.render(
        LLAMAFILE_UPSTREAM_HOST=os.environ.get("LLAMAFILE_UPSTREAM_HOST", ""),
        LLAMAFILE_UPSTREAM_PORT=os.environ.get("LLAMAFILE_UPSTREAM_PORT", ""),
    )
)
