-- 000015_drop_model_colors.up.sql
-- Retire the per-model color system: every per-model panel now renders
-- colorless, so the model_palette and model_color_map VIEWs are dropped.
-- One-way retirement - the feature is removed, not merely disabled.

DROP VIEW IF EXISTS llm_gateway.model_color_map;
DROP VIEW IF EXISTS llm_gateway.model_palette;
