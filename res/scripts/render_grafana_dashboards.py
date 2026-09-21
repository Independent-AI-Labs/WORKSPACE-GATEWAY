#!/usr/bin/env python3
"""Expand {{sql:<path>}} references in Grafana sources.

Sources:   conf/grafana/dashboards/*.json, conf/grafana/provisioning/**
Rendered:  conf/grafana/rendered/{dashboards,provisioning}/

Usage: render_grafana_dashboards.py [render|--check]
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
SRC = os.path.join(ROOT, "conf/grafana")
RENDERED = os.path.join(SRC, "rendered")
PLACEHOLDER = re.compile(r'"\{\{sql:([^}]+)\}\}"')

_cache = {}


def render_sql(rel):
    if rel in _cache:
        return _cache[rel]
    env = dict(os.environ)
    env["REPO_ROOT"] = ROOT
    env["SQL_RENDER_MODE"] = "grafana"
    proc = subprocess.run(
        ["bash", "-c", 'source "$REPO_ROOT/res/scripts/lib-sql.sh"; sql_render "$1"', "x", rel],
        env=env, cwd=ROOT, capture_output=True, text=True,
    )
    if proc.returncode != 0:
        sys.exit("sql_render failed for %s: %s" % (rel, proc.stderr.strip()))
    _cache[rel] = proc.stdout.rstrip("\n")
    return _cache[rel]


def expand(text):
    def repl(m):
        return json.dumps(render_sql(m.group(1)))
    return PLACEHOLDER.sub(repl, text)


def render_dir(src, dst):
    for dirpath, _dirs, files in os.walk(src):
        for fn in sorted(files):
            s = os.path.join(dirpath, fn)
            d = os.path.join(dst, os.path.relpath(s, src))
            os.makedirs(os.path.dirname(d), exist_ok=True)
            if fn.endswith((".json", ".yaml", ".yml")):
                with open(s) as f:
                    open(d, "w").write(expand(f.read()))
            else:
                shutil.copy2(s, d)


def build(dst):
    shutil.rmtree(dst, ignore_errors=True)
    os.makedirs(dst, exist_ok=True)
    render_dir(os.path.join(SRC, "dashboards"), os.path.join(dst, "dashboards"))
    render_dir(os.path.join(SRC, "provisioning"), os.path.join(dst, "provisioning"))


def tree_files(root):
    out = {}
    for dirpath, _dirs, files in os.walk(root):
        for fn in files:
            p = os.path.join(dirpath, fn)
            out[os.path.relpath(p, root)] = open(p, "rb").read()
    return out


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "render"
    if mode == "render":
        build(RENDERED)
        print("[render-grafana] wrote %s" % os.path.relpath(RENDERED, ROOT))
        return
    if mode == "--check":
        tmp = tempfile.mkdtemp(prefix="gw-grafana-render-")
        try:
            build(tmp)
            got, exp = tree_files(tmp), tree_files(RENDERED)
            stale = sorted(k for k in set(got) | set(exp) if got.get(k) != exp.get(k))
            if stale:
                sys.exit("rendered Grafana tree is stale (%s); run res/scripts/render-grafana-dashboards.sh"
                         % ", ".join(stale))
            print("[render-grafana] rendered tree is current")
        finally:
            shutil.rmtree(tmp, ignore_errors=True)
        return
    sys.exit("usage: render_grafana_dashboards.py [render|--check]")


if __name__ == "__main__":
    main()
