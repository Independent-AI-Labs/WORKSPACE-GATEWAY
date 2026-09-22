-- 000014_model_colors.up.sql
-- Deterministic, shared per-model colors for every model-colored panel.
--
-- A model's color is its ALPHABETICAL RANK in the current model set mapped
-- onto the palette, so similarly named models (claude-3-5-*, claude-opus*)
-- land on adjacent hues instead of scattering across the wheel:
--
--   color = palette[1 + (row_number() OVER (ORDER BY model) - 1) % length]
--
-- The palette is APPEND-ONLY: appending hues leaves the palette meaning
-- unchanged, while reordering/removing remaps every color. model_palette is
-- a VIEW so the literal lives in exactly one place.
--
-- model_color_map is a pure VIEW over usage_log, so there is no registry
-- table, no materialized view and no backfill to keep in sync. Models are
-- discovered from usage_log only.
--
-- Idempotent: older installs (000014 originally shipped a hash + Replacing
-- MergeTree registry) have their old objects dropped before the view is
-- (re)created.
--
-- Kept in step with the canonical copy in conf/sql/clickhouse-init.sql.

DROP TABLE IF EXISTS llm_gateway.model_colors;
DROP VIEW IF EXISTS llm_gateway.model_colors_mv;
DROP VIEW IF EXISTS llm_gateway.model_color_map;

CREATE VIEW IF NOT EXISTS llm_gateway.model_palette
AS
SELECT [
    '#d65151', '#d66251', '#d67351', '#d68351', '#d69451', '#d6a551',
    '#d6b551', '#d6c651', '#d6d651', '#c6d651', '#b5d651', '#a5d651',
    '#94d651', '#83d651', '#73d651', '#62d651', '#51d651', '#51d662',
    '#51d673', '#51d683', '#51d694', '#51d6a5', '#51d6b5', '#51d6c6',
    '#51d6d6', '#51c6d6', '#51b5d6', '#51a5d6', '#5194d6', '#5183d6',
    '#5173d6', '#5162d6', '#5151d6', '#6251d6', '#7351d6', '#8351d6',
    '#9451d6', '#a551d6', '#b551d6', '#c651d6', '#d651d6', '#d651c6',
    '#d651b5', '#d651a5', '#d65194', '#d65183', '#d65173', '#d65162'
] AS palette;

CREATE VIEW IF NOT EXISTS llm_gateway.model_color_map
AS
SELECT
    m.model AS model,
    arrayElement(p.palette, 1 + (m.rn - 1) % length(p.palette)) AS color
FROM (
    SELECT model, row_number() OVER (ORDER BY model) AS rn
    FROM (
        SELECT DISTINCT model
        FROM llm_gateway.usage_log
        WHERE model != ''
    )
) AS m
CROSS JOIN llm_gateway.model_palette AS p;
