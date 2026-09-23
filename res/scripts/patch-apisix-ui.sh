#!/usr/bin/env bash
# patch-apisix-ui.sh: rebrand the APISIX Dashboard bundled in the APISIX image.
#
# The Dashboard is a prebuilt static bundle (index.html plus content-hashed
# assets under <ui>/assets/) baked into the base image. APISIX exposes no
# config knob for branding, so the image build patches the bundle in place:
#   * every apisix-logo-*.svg asset is overwritten with our mark
#   * the title text "APISIX Dashboard" becomes "Workspace Gateway APISIX
#     Dashboard" in index.html and in the JS bundle (the document.title
#     constant and the i18n labels). A leading upstream "Apache " is collapsed
#     so the tab reads cleanly.
# Asset filenames are content-hashed but referenced by name, so replacing a
# file's *contents* (never its name) keeps every reference valid.
#
# Fails the build (non-zero) if the expected assets/text are absent, so an
# un-rebranded image cannot ship unverified after an upstream bundle change.
#
# Usage: patch-apisix-ui.sh [UI_DIR] [LOGO_SVG]
set -euo pipefail

UI_DIR="${1:-/usr/local/apisix/ui}"
LOGO_SVG="${2:-/opt/apisix-ui/workspace-ci-logo.svg}"
OLD_TEXT="APISIX Dashboard"
NEW_TEXT="Workspace Gateway APISIX Dashboard"

die() { printf 'patch-apisix-ui: %s\n' "$1" >&2; exit 1; }

[ -d "$UI_DIR" ] || die "UI dir not found: $UI_DIR"
[ -f "$LOGO_SVG" ] || die "logo not found: $LOGO_SVG"

# 1. Logo: overwrite each content-hashed apisix-logo asset in place.
logo_hits=0
for f in "$UI_DIR"/assets/apisix-logo-*.svg; do
    [ -e "$f" ] || continue
    cp "$LOGO_SVG" "$f"
    logo_hits=$((logo_hits + 1))
done
[ "$logo_hits" -gt 0 ] || die "no apisix-logo-*.svg asset under $UI_DIR/assets"

# 2. Text: rewrite the HTML shell and the JS bundle(s). The optional "Apache "
#    group collapses the upstream prefix; sed does not rescan its replacement,
#    so the "APISIX Dashboard" inside NEW_TEXT cannot double-expand.
text_hits=0
for f in "$UI_DIR"/index.html "$UI_DIR"/assets/index-*.js; do
    [ -e "$f" ] || continue
    content="$(<"$f")"
    [[ "$content" == *"$OLD_TEXT"* ]] || continue
    sed -E -i "s/(Apache )?${OLD_TEXT}/${NEW_TEXT}/g" "$f"
    text_hits=$((text_hits + 1))
done
[ "$text_hits" -gt 0 ] || die "title text '$OLD_TEXT' not found under $UI_DIR"

printf 'patch-apisix-ui: replaced logo in %d asset(s); retitled %d file(s)\n' \
    "$logo_hits" "$text_hits"
