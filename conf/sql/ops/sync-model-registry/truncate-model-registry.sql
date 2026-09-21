-- res/scripts/sync-model-registry.sh: clear before re-insert (idempotent).
TRUNCATE TABLE {{ DB }}.model_registry
