# Gateway Treemap

A dependency-free Grafana panel plugin: an area treemap with a built-in
measured tile face (percent share / name / value), a **Handlebars-style
tooltip**, and **minimum and maximum tile-area constraints** so small tiles
never collapse into an unreadable sliver and a single dominant tile never eats
the whole panel.

## Why this exists

The stock community treemap (`marcusolsson-treemap-panel`) hard-codes its font
size, only ever draws the label (the numeric value is tooltip-only), and has no
notion of minimum tile area. This plugin keeps the treemap layout but adds:

- **Built-in measured tile face**: percent share (largest, thin), name, value.
  A hidden probe copy of the three lines is measured after layout and lines
  that do not fit are dropped (percent first, then the name; the name is also
  dropped when it is wider than the tile). The value always shows, and the
  spacing between the percent and name lines scales with the tile font.
- **Templated tooltips**: `{{label}}`, `{{value}}`, `{{percent}}`,
  `{{fields.<column>}}`, `{{raw.<column>}}`, `{{area}}`, `{{fontSize}}`, and so
  on.
- **Auto font size**: scaled to the tile on a cube root of its area and
  clamped, so a big tile gets a big label and a small tile a small one instead
  of disappearing.
- **Colour ramp**: tile fill blends from neutral grey to the tile colour with
  size, so saturation encodes magnitude.
- **`minTileArea`**: tiles below this pixel area are merged into a single
  labelled overflow tile. `0` disables.
- **`maxTileArea`**: tiles above this pixel area are capped and the freed area
  redistributed. `0` disables.

## Build

```sh
bash res/grafana-plugins/gateway-treemap/build.sh        # -> dist/
```

The build is a plain concatenation (`src/constraints.js` + `src/face.js` +
`src/panel.js`) plus a copy of `plugin.json` / `README.md` / `img/`. No npm
toolchain: the panel runs against Grafana's own AMD modules (`react`,
`@grafana/data`).

## Test

```sh
node --test res/grafana-plugins/gateway-treemap/test/
```

## Install

`dist/` is bind-mounted into the Grafana container at
`/var/lib/grafana/plugins/gateway-treemap` and loaded as unsigned via
`GF_PLUGINS_ALLOW_LOADING_UNSIGNED_PLUGINS`. See `res/docker/docker-compose.yml`.

## Tooltip context

The tooltip is a `tooltipTemplate` with these keys:

| Key | Meaning |
|-----|---------|
| `label` | The label field value (or the overflow-tile label). |
| `value` | Formatted size value (Grafana display text of the size field). |
| `valueRaw` | Raw numeric size value. |
| `percent` | Share of the total size, one decimal (`"12.4"`). |
| `area` | Rendered tile area in px². |
| `width`, `height` | Rendered tile size in px. |
| `color` | Tile fill colour (`#rrggbb`). |
| `fontSize` | The computed card font size in px. |
| `isOther` | `true` for the merged overflow tile. |
| `count` | Number of source rows in the tile (`1` unless overflow). |
| `fields.<name>` | Any column of the row, formatted by its Grafana display processor. |
| `raw.<name>` | Any column of the row, raw value. |

Substituted values are HTML-escaped; `{{ }}` only (no triple-stache).
