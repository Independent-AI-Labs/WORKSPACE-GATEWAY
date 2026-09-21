-- recalc-costs.sh: audit table for old->new cost pairs.
CREATE TABLE IF NOT EXISTS {{ DB }}.cost_recalc_audit (
      event_id String,
      provider_id LowCardinality(String) DEFAULT '',
      new_provider_id LowCardinality(String) DEFAULT '',
      model LowCardinality(String) DEFAULT '',
      old_cost Float64,
      new_cost Float64,
      old_source LowCardinality(String) DEFAULT '',
      run_id String,
      timestamp DateTime64(3) DEFAULT now()
    )
    ENGINE = MergeTree()
    PARTITION BY toYYYYMM(timestamp)
    ORDER BY (event_id, run_id, timestamp)
    TTL toDateTime(timestamp) + INTERVAL 13 MONTH
