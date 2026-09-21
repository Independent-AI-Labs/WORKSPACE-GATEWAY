# AGENTS.md

## Dashboard number formatting

Every dashboard renders numbers with the same abbreviation rule, so a value
reads identically wherever it appears.

- **Stat tiles (exact values).** Format in SQL, never with Grafana's `short`
  unit. Costs are exact `$x.yy` via the rollover-safe integer-cents pattern
  (`floor(round(x * 100) / 100)` + 2-digit `leftPad(round(x * 100) % 100, ...)`),
  never SI-abbreviated. Token volumes and other large counts are compact
  uppercase `B`/`M`/`K` via `multiIf` (`>= 1e9 -> B`, `>= 1e6 -> M`,
  `>= 1e3 -> K`, 2 decimals, rounded not floored).
- **Graphs, bargauges, axes and tables (rendered values).** Set the Grafana
  `unit` field and let Grafana abbreviate: `short` for large counts
  (K / Mil / Bil), the domain unit otherwise (`bytes`, `s`, `ms`, `Bps`,
  `percent`, ...).
- Round measured values to 2 decimals (`decimals: 2`); raw integer counts stay
  integers.

Canonical rules: [docs/specifications/SPEC-DASHBOARD.md](docs/specifications/SPEC-DASHBOARD.md)
section 2.4. Enforced by `tests/config/dashboard_assert.sh` (check S18).

## SQL

All SQL lives in `conf/sql/`; never write SQL inline in shell, Lua, tests, or
Grafana JSON. Template with `{{ NAME }}` / `{{ time_filter('col') }}` /
`{{ gf_num|gf_str|gf_str_multi('v') }}`; render in shell via
`res/scripts/lib-sql.sh` (`sql_render <path> [K=V ...]`), and point Grafana
`rawSql` at `{{sql:<path>}}` so the JSON stays a thin reference. Lint with
`uvx --from sqlfluff sqlfluff lint conf/sql` (root `.sqlfluff`, Jinja
templater; SQLite overrides under `conf/sql/sqlite/`).

Canonical rules: [docs/specifications/SPEC-SQL-STRUCTURE.md](docs/specifications/SPEC-SQL-STRUCTURE.md).
Enforced by `tests/config/test_no_inline_sql.sh`; render contract by
`tests/config/test_sql_render.sh`.
