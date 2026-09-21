# SPEC-SQL-STRUCTURE: Externalized SQL Tree, Templating, and Linting

**Date:** 2026-09-21
**Status:** Active
**Type:** Specification

> Every SQL statement in the repository lives under `conf/sql/`. Nothing is
> written inline in shell, Lua, tests, or Grafana JSON. The tree is rendered
> at runtime (shell, Grafana) or read directly (Lua, ClickHouse initdb,
> golang-migrate), and is linted by `sqlfluff` from the root-guarded
> `.sqlfluff`. Enforced by `tests/config/test_no_inline_sql.sh`; the render
> contract is covered by `tests/config/test_sql_render.sh`.

---

**Cross-references:**
- [SPEC-BILLING-TELEMETRY](SPEC-BILLING-TELEMETRY.md): ClickHouse schema + migrations
- [SPEC-DASHBOARD](SPEC-DASHBOARD.md): Grafana panels whose `rawSql` comes from this tree
- [architecture/TELEMETRY-AND-SCHEMA.md](../architecture/TELEMETRY-AND-SCHEMA.md): schema reference
- [`res/scripts/lib-sql.sh`](../../res/scripts/lib-sql.sh): shell renderer

---

## 1. Tree layout

```
conf/sql/
├── VARS                         runtime defaults + lint context values (KEY=VALUE)
├── clickhouse-init.sql          ClickHouse initdb baseline (was conf/clickhouse-init.sql)
├── migrations/                  golang-migrate NNNNNN_*.{up,down}.sql
├── ops/<tool>/                  ClickHouse SQL extracted from res/scripts/<tool>.sh
├── ingest/                      SQL the APISIX Lua plugins execute
├── grafana/queries/             dashboard rawSql bodies (Grafana macros)
├── sqlite/                      SQLite dialect
│   ├── .sqlfluff                dialect override (sqlite)
│   ├── opencode-stats/          opencode.db extraction queries
│   ├── opencode-fix/            opencode.db repair queries
│   └── tests/                   SQLite test fixtures (dialect override applies)
└── tests/                       SQL used by test harnesses
```

Rendered Grafana JSON is committed outside this tree at
`conf/grafana/rendered/{dashboards,provisioning}/` (see §3).

The repo-root `.sqlfluff` sets the ClickHouse dialect for the whole tree;
`conf/sql/sqlite/.sqlfluff` overrides the dialect for SQLite templates.

## 2. Templating

Templates are plain SQL plus `{{ … }}` template variables. The syntax is shared by
the runtime renderer ([`res/scripts/lib-sql.sh`](../../res/scripts/lib-sql.sh),
POSIX `awk`) and by `sqlfluff`'s Jinja templater, so a template that lints is
the same template that renders.

| Template variable | Runtime `raw` mode | Runtime `grafana` mode | Purpose |
|-------------|--------------------|------------------------|---------|
| `{{ NAME }}` | value | value | Scalar substitution |
| `{{ time_filter('col') }}` | `col >= now() - INTERVAL 1 DAY` | `$__timeFilter(col)` | Grafana time range |
| `{{ gf_num('v') }}` | `10` | `${v}` | Numeric Grafana variable |
| `{{ gf_str('v') }}` | `'sample'` | `${v:singlequote}` | String Grafana variable |
| `{{ gf_str_multi('v') }}` | `'sample'` | `${v:singlequote}` | Multi-value Grafana variable |

`{{ NAME }}` resolution precedence: `NAME=VALUE` render arguments, then
`SQL_<NAME>` in the environment, then `conf/sql/VARS`. Rendering fails closed:
a template variable that cannot be resolved is left in place and `sql_render`
returns non-zero.

`conf/sql/VARS` is the single source of truth for defaults. `test_sql_render.sh`
asserts that the values under `[sqlfluff:templater:jinja:context]` in
`.sqlfluff` hold exactly the same keys; the linter therefore renders the same
values the runtime uses.

## 3. Loaders

| Consumer | How SQL reaches it |
|----------|--------------------|
| Shell scripts | `source res/scripts/lib-sql.sh` then `sql_render <path> [K=V …]`; `SQL_RENDER_MODE=grafana` emits Grafana macros |
| Lua (`plugins/custom/sse-usage.lua`) | `io.open` the file mounted read-only at `/etc/apisix/sql/…` |
| ClickHouse initdb | `conf/sql/clickhouse-init.sql` bind-mounted to `/docker-entrypoint-initdb.d/init.sql` |
| golang-migrate | `conf/sql/migrations` bind-mounted to `/migrations` |
| Grafana | dashboard `rawSql`/variable `query` is `{{sql:<path>}}` in `conf/grafana/dashboards/*.json`; `res/scripts/render_grafana_dashboards.py` expands it to the committed `conf/grafana/rendered/` tree Grafana mounts; `tests/config/test_grafana_dashboards_render.sh` fails on drift |
| Tests | probe SQL under `conf/sql/tests/` (ClickHouse) and `conf/sql/sqlite/tests/` (SQLite), rendered with `sql_render` or read by the harness |

## 4. Linting

`sqlfluff` 4.3.0, driven by the root `.sqlfluff`:

- `dialect = clickhouse`, `templater = jinja`.
- `ignore = parsing`: ClickHouse DDL (`SETTINGS`, `TTL`,
  `parts_to_throw_insert`, …) is not fully modelled by the dialect; the
  parseable parts are still linted.
- `exclude_rules = layout, capitalisation, aliasing, structure, RF04, RF05,
  RF06, RF02, CV02, CV07, AM05, AM09`: the existing corpus is column-aligned,
  mixed-case, implicitly aliased, and uses subqueries/joins the formatter
  would rewrite. Grafana panel queries additionally select quoted display
  aliases (`"Total"`), unqualified columns across CTEs, and `LIMIT` without
  `ORDER BY` on ranked tiles. `CV07` is off because a few templates are
  subquery fragments substituted inline (Grafana "All" expansions) rather
  than top-level statements. Reformatting is out of scope, so those cosmetic
  and display-oriented rules are off; the rest stay on.
- Dummy Jinja macros in `.sqlfluff` mirror the `lib-sql.sh` macro names so a
  Grafana template renders to valid SQL for linting.

## 5. Guard and provenance

- `tests/config/test_no_inline_sql.sh` scans shell/Lua/YAML/JSON for SQL
  statement starters outside `conf/sql/`, and requires Grafana `rawSql` to be
  `{{sql:<path>}}`. It fails with the offending file:line list. Test probe SQL
  now lives in `conf/sql/tests/` (ClickHouse) and `conf/sql/sqlite/tests/`
  (SQLite), so the scan is clean rather than exempted.
- The guard skips matches that are not executed SQL: `grep`/`awk`/`sed`
  pattern strings and `assert_contains`/`assert_not_contains` schema
  assertions (e.g. DDL extracted from a `conf/sql/` file, or test assertions
  about column text). Real query execution (`ch`, `curl`,
  `clickhouse-client`) still trips the pattern.
- `res/docker/clickhouse-provision.sh` is an explicit, documented exception:
  it runs as ClickHouse initdb before any repo/`conf` mount exists, and its
  user DDL embeds secrets, so it stays inline and fail-closed.
- `.sqlfluff` is a root-guarded file: WORKSPACE-GUARD locks every file named
  `.sqlfluff` (see WORKSPACE-GUARD `config/shared_locked_paths.yaml` →
  `glob_patterns`), and WORKSPACE-CI validates its provenance fail-closed via
  `config/exemption_files.yaml`.

## 6. Implementation status

| Area | Status | Evidence |
|------|--------|----------|
| Tree, renderer, VARS, lint config | Implemented | `conf/sql/`; `res/scripts/lib-sql.sh`; `.sqlfluff`; `tests/config/test_sql_render.sh` (15/15) |
| Initdb + migrations relocated | Implemented | `conf/sql/clickhouse-init.sql`; `conf/sql/migrations/`; compose/ansible/tests updated |
| No-inline-SQL guard | Implemented (green) | `tests/config/test_no_inline_sql.sh` (2/2); no inline SQL outside `conf/sql/` |
| SQLite `opencode-stats` / `opencode-fix` extraction | Implemented | `conf/sql/sqlite/opencode-stats/`; `conf/sql/sqlite/opencode-fix/` |
| Shell ClickHouse extraction | Implemented | `ops/<tool>/`; guard reports no production shell files |
| Lua `ingest/` extraction | Implemented | `conf/sql/ingest/usage-log.insert.sql`; `sse-usage.lua` reads it via `io.open`; `conf/sql` mounted at `/etc/apisix/sql` |
| Grafana rendered-tree templating | Implemented | `conf/sql/grafana/queries/` (42); `conf/grafana/rendered/`; `res/scripts/render_grafana_dashboards.py`; `tests/config/test_grafana_dashboards_render.sh` (7/7) |
| Test-embedded SQL extraction | Implemented | `conf/sql/tests/`; `conf/sql/sqlite/tests/migrate-opencode-stats/fixture.sql`; e2e/integration harnesses render via `sql_render` |
| Root-guard + CI hook wiring | Pending | WORKSPACE-GUARD / WORKSPACE-CI |
