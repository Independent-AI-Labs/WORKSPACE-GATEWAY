-- dedupe-model-history.sh: rewrite usage_log aliases to canonical ids.
ALTER TABLE {{ DB }}.usage_log
UPDATE model_raw = model, model = {{ MODEL_MULTIIF }}
WHERE {{ MODEL_WHERE }}
SETTINGS mutations_sync = 1
