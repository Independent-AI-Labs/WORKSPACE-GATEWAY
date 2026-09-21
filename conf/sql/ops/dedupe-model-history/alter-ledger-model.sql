-- dedupe-model-history.sh: rewrite billing_ledger aliases to canonical ids.
ALTER TABLE {{ DB }}.billing_ledger
UPDATE model_raw = model_name, model_name = {{ MODEL_NAME_MULTIIF }}
WHERE {{ MODEL_NAME_WHERE }}
SETTINGS mutations_sync = 1
