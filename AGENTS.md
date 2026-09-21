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
