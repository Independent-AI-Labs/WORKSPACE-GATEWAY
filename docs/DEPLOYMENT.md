# Deployment Guide - APISIX LLM Gateway

> **AUTHORITATIVE ARCHITECTURE:** Runtime topology, plugin matrix, routes, and
> telemetry are documented in [`docs/architecture/README.md`](architecture/README.md).
> This file covers compose, image build, and operational commands. Sections marked
> *enterprise (future)* describe aspirational OIDC/ai-proxy-multi config, not the
> current etcd relay deployment.

**Document ID:** AMI-PROP-LLMGW-DEPLOYMENT-v1.0
**Status:** Draft
**Date:** 2026-07-13 (revised)
**Parent:** `PROPOSAL-LLM-GATEWAY-v3.md`

This document specifies the deployment infrastructure for the APISIX LLM Gateway:
Docker compose stack, APISIX configuration, custom Docker image, ClickHouse billing
schema, and the daily reconciler job.

---

## 1. Docker Compose Stack

The gateway runs as its own compose stack, separate from DATAOPS. Shared services
(Redis, Keycloak, Prometheus) are consumed from the DATAOPS stack via network.

```yaml
# res/docker/docker-compose.yml
services:
  apisix:
    build:
      context: ../..
      dockerfile: res/docker/Dockerfile.apisix
    ports:
      - "9080:9080"    # HTTP (clients)
      - "9443:9443"    # HTTPS (clients)
    volumes:
      - ../../conf/apisix.yaml:/usr/local/apisix/conf/apisix.yaml:ro
      - ../../conf/redact-patterns.json:/etc/apisix/redact-patterns.json:ro
    depends_on:
      - vector
    restart: unless-stopped
    networks:
      - gateway
      - dataops

  clickhouse:
    image: clickhouse/clickhouse-server:24.8-alpine
    ports:
      - "8123:8123"    # HTTP interface
      - "9000:9000"    # native protocol
    volumes:
      - clickhouse-data:/var/lib/clickhouse
      - ../../conf/clickhouse-init.sql:/docker-entrypoint-initdb.d/init.sql:ro
    environment:
      - CLICKHOUSE_USER=default
      - CLICKHOUSE_PASSWORD=${CLICKHOUSE_PASSWORD:-}
    restart: unless-stopped
    networks:
      - gateway

  vector:
    image: timberio/vector:0.40.0-debian
    volumes:
      - ../../conf/vector.toml:/etc/vector/vector.toml:ro
    ports:
      - "8080:8080"    # http-logger ingest endpoint
    depends_on:
      - clickhouse
    restart: unless-stopped
    networks:
      - gateway

volumes:
  clickhouse-data:

networks:
  gateway:
    driver: bridge
  dataops:
    external: true
    name: dataops_default
```

### 1.1 Shared DATAOPS services consumed

| Service | Address (from gateway network) | Purpose |
|---------|-------------------------------|---------|
| Redis 8 | `ami-redis:6379` | VSS for semantic cache (v2), optional PII map durability |
| Keycloak 26.2 | `ami-keycloak:8082` | OIDC IdP |
| Prometheus | `ami-prometheus:9091` | Metrics scrape |
| OpenBao | `ami-openbao:8200` | Secrets (API keys, LDAP creds) |

Redis must have RediSearch (FT.* commands) enabled. Redis 8 includes RediSearch
by default. Verify with `FT._LIST` after startup.

---

## 2. Custom APISIX Docker Image

```dockerfile
# res/docker/Dockerfile.apisix
FROM apache/apisix:3.17.0-debian

# Copy custom Lua plugins (flat - NO custom/ subdir in deployed tree)
COPY plugins/custom/key-resolver.lua /usr/local/apisix/apisix/plugins/key-resolver.lua
COPY plugins/custom/key-meta.lua /usr/local/apisix/apisix/plugins/key-meta.lua
COPY plugins/custom/sse-usage.lua /usr/local/apisix/apisix/plugins/sse-usage.lua
COPY plugins/custom/sse_usage_lib.lua /usr/local/apisix/apisix/plugins/sse_usage_lib.lua
COPY plugins/custom/cost_calc.lua /usr/local/apisix/apisix/plugins/cost_calc.lua
COPY plugins/custom/redact.lua /usr/local/apisix/apisix/plugins/redact.lua
COPY plugins/custom/redact_lib.lua /usr/local/apisix/apisix/plugins/redact_lib.lua

# Copy APISIX configuration
COPY conf/config.yaml /usr/local/apisix/conf/config.yaml

# Copy patterns file for redaction plugin
COPY conf/redact-patterns.json /etc/apisix/redact-patterns.json

# Expose ports
EXPOSE 9080 9443 9100

# APISIX default entrypoint works; no override needed
```

**NOTE:** Plugin files are copied directly to
`/usr/local/apisix/apisix/plugins/` (not a `custom/` subdirectory) so
`require("apisix.plugins.cost_calc")` resolves correctly. The
`plugins/custom/` path in the repo is source organization only.

**Volume mounts** (docker-compose.yml): All 7 plugin files are also
volume-mounted `:ro` for live development without image rebuilds.

---

## 3. APISIX Configuration (`config.yaml`)

The live stack uses **traditional/etcd mode** (`deployment.role: traditional`,
`config_provider: etcd`). Routes are loaded from etcd at startup via
`res/scripts/apisix-entrypoint.sh`; `conf/apisix.yaml` is the source template
synced into etcd on container start.

```yaml
# conf/config.yaml (current relay deployment)
deployment:
  role: traditional
  role_traditional:
    config_provider: etcd
  admin:
    admin_key:
      - name: admin
        key: ${{ADMIN_KEY}}
        role: admin
    enable_admin_ui: true
  etcd:
    host:
      - "http://etcd:2379"
    prefix: "/apisix"

plugins:
  - key-resolver
  - key-meta
  - limit-count
  - proxy-buffering
  - proxy-rewrite
  - http-logger
  - prometheus
  - request-id
  - redact
  - sse-usage

nginx_config:
  envs:
    - OPENCODE_API_KEY
    - OPENBAO_TOKEN
  http:
    custom_lua_shared_dict:
      redact_state: 1m
      key_cache: 5m
      gateway-cache: 2m
      quota_counters: 5m
```

### 3.1 etcd mode notes

- `config_provider: etcd`: APISIX reads routes/upstreams from etcd (`etcd:2379`).
- Admin API and Admin UI are enabled; `ADMIN_KEY` is injected at runtime.
- `conf/apisix.yaml` is not polled in etcd mode; changes require re-sync
  (entrypoint or `adc sync`). See [`architecture/OVERVIEW.md`](architecture/OVERVIEW.md).
- Standalone YAML (`config_provider: yaml`) is documented in §3.2 for reference only.

---

## 4. Route Configuration (`apisix.yaml`)

**Current deployment (3 relay routes):**

| Route id | URI prefix | Upstream | Auth |
|----------|------------|----------|------|
| `relay-opencode` | `/opencode/*` | `opencode.ai:443` | Passthrough (shared key) |
| `relay-opencode-federated` | `/opencode_federated/*` | `opencode.ai:443` | Virtual key via `key-resolver` + OpenBao |
| `relay-llamafile` | `/llamafile/*` | `host.docker.internal:8765` | None (local e2e LLM) |

Per-route plugin matrix and request lifecycle:
[`architecture/PLUGIN-PIPELINE.md`](architecture/PLUGIN-PIPELINE.md),
[`architecture/REQUEST-LIFECYCLE.md`](architecture/REQUEST-LIFECYCLE.md).

### 4.1 Enterprise example (future, not deployed)

The block below is the original OIDC + `ai-proxy-multi` design. It is **not**
what runs today.

```yaml
# aspirational (NOT conf/apisix.yaml)
routes:
  - id: llm-chat-completions
    uri: /v1/chat/completions
    methods: [POST]
    plugins:
      # Phase 1: Auth (built-in)
      openid-connect:
        client_id: "llm-gateway"
        client_secret: "{{vault:secret/oidc/client_secret}}"
        discovery: "http://ami-keycloak:8082/realms/enterprise/.well-known/openid-configuration"
        scope: "openid profile email"
        bearer_only: true
        realm: "enterprise"
        claims_to_header:
          - claim: "tenant_id"
            header: "X-Tenant-ID"
          - claim: "sub"
            header: "X-User-ID"
          - claim: "groups"
            header: "X-Routing-Tier"

      # SSE streaming: disable proxy buffering
      proxy-buffering:
        disabled: true

      # Phase 2: PII Redaction (custom Lua, v1)
      redact:
        patterns_file: "/etc/apisix/redact-patterns.json"
        stream_mode: buffer
        on_error: closed

      # Phase 3: AI Proxy + Multi-Provider Failover (built-in)
      ai-proxy-multi:
        provider: openai
        targets:
          - provider: openai
            model: gpt-4o
            api_key: "{{vault:secret/ai/openai_key}}"
            weight: 70
            priority: 1
          - provider: azure
            model: prod-deployment
            api_key: "{{vault:secret/ai/azure_key}}"
            override_endpoint: "https://azure-us-east.openai.azure.com/openai/deployments/prod-deployment/chat/completions?api-version=2024-06-01"
            weight: 30
            priority: 1
        fallback_strategy: "http_429"
        max_retries: 3
        retry_on_failure_within_ms: 10000
        max_stream_duration_ms: 120000

      # Phase 4: Rate Limiting (built-in)
      limit-count:
        count: 100
        time_window: 60
        rejected_code: 429
        key_type: var
        key: http_x_key_hash
        policy: local

      # Phase 5: Strip context headers before egress (built-in)
      proxy-rewrite:
        headers:
          remove:
            - "X-Tenant-ID"
            - "X-User-ID"
            - "X-Routing-Tier"
            - "X-Token-Scopes"
            - "X-Redact-Active"

      # Phase 6: Telemetry (built-in)
      http-logger:
        uri: "http://vector:8080/ingest"
        method: POST
        content_type: "application/json"
        batch_max_size: 1
        include_req_body: true
        include_resp_body: false

      prometheus:
        prefer_name: true

# v2: Add semantic-cache plugin between auth and redact
# - id: llm-chat-completions-v2
#   ...
#   plugins:
#     semantic-cache:
#       embedding_url: "http://127.0.0.1:8090/v1/embeddings"
#       embedding_model: "bge-large-en-v1.5"
#       embedding_dim: 1024
#       redis_host: "ami-redis"
#       redis_port: 6379
#       distance_threshold: 0.10
#       cache_ttl_seconds: 300
```

---

## 5. Redaction Patterns File

```json
// conf/redact-patterns.json
{
  "regex": [
    { "kind": "email",       "pattern": "(?i)\\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}\\b" },
    { "kind": "ssn",         "pattern": "\\b\\d{3}-\\d{2}-\\d{4}\\b" },
    { "kind": "credit_card", "pattern": "\\b(?:\\d[ -]*?){13,16}\\b", "luhn_check": true },
    { "kind": "api_key",     "pattern": "(?i)\\b(?:sk|pk|key)-[A-Za-z0-9]{20,}\\b" },
    { "kind": "phone",       "pattern": "\\b\\+?\\d{1,3}?[-.\\s]?\\(?\\d{3}\\)?[-.\\s]?\\d{3,4}[-.\\s]?\\d{4}\\b" },
    { "kind": "jwt",         "pattern": "\\beyJ[A-Za-z0-9_-]+\\.eyJ[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\b" }
  ],
  "dictionary": [
    { "kind": "organization", "entries": [
      "Acme Corporation",
      "Project Phoenix",
      "Internal System X"
    ]},
    { "kind": "person_name", "entries": [
      "John Smith",
      "Jane Doe"
    ]}
  ]
}
```

---

## 6. Vector Configuration

```toml
# conf/vector.toml
[sources.apisix_http_logger]
type = "http_server"
address = "0.0.0.0:8080"
path = "/ingest"
encoding = "json"

[transforms.parse_log]
type = "remap"
inputs = ["apisix_http_logger"]
source = """
. = parse_json!(.message)
.tenant_id = .X-Tenant-ID ?? "unknown"
.user_id = .X-User-ID ?? "unknown"
.timestamp = now()
"""

[sinks.clickhouse]
type = "clickhouse"
inputs = ["parse_log"]
endpoint = "http://clickhouse:8123"
database = "default"
table = "llm_billing_ledger"
skip_unknown_fields = true
```

---

## 7. ClickHouse Schema

```sql
-- conf/clickhouse-init.sql
CREATE TABLE IF NOT EXISTS llm_billing_ledger (
    event_id         String,
    tenant_id        LowCardinality(String),
    user_id          String,
    provider         LowCardinality(String),
    model_name       LowCardinality(String),
    route_name       LowCardinality(String),
    consumer_group   LowCardinality(String),
    request_mode     LowCardinality(String),
    cache_status     LowCardinality(String),
    prompt_tokens    UInt32,
    completion_tokens UInt32,
    reasoning_tokens UInt32,
    cached_tokens    UInt32,
    total_tokens     UInt32,
    rate_input       Decimal64(8),
    rate_output      Decimal64(8),
    currency         LowCardinality(String),
    cost             Decimal64(6),
    success          Bool,
    error_type       LowCardinality(String),
    llm_latency_ms   UInt32,
    ttft_ms          UInt32,
    upstream_resp_id LowCardinality(String),
    redact_active    Bool DEFAULT false,
    redact_placeholder_count UInt32 DEFAULT 0,
    timestamp        DateTime64(3) DEFAULT now()
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(timestamp)
ORDER BY (tenant_id, user_id, timestamp)
TTL timestamp + INTERVAL 13 MONTH
SETTINGS index_granularity = 8192;

CREATE TABLE IF NOT EXISTS billing_discrepancies (
    date         Date,
    tenant_id    LowCardinality(String),
    provider     LowCardinality(String),
    model_name   LowCardinality(String),
    gateway_tokens  UInt32,
    provider_tokens UInt32,
    divergence   Decimal64(6),
    tolerance    Decimal64(6),
    flagged_at   DateTime64(3) DEFAULT now()
)
ENGINE = MergeTree()
PARTITION BY toYYYYMM(date)
ORDER BY (date, tenant_id, provider, model_name);
```

---

## 8. Reconciler Job

Daily job cross-checks ClickHouse ledger against upstream provider billing APIs.

```bash
#!/bin/bash
# res/scripts/reconciler.sh
set -euo pipefail

YESTERDAY=$(date -d "yesterday" +%Y-%m-%d)

# Query ClickHouse for yesterday's totals per (tenant, provider, model)
GATEWAY_TOTALS=$(clickhouse-client --query "
  SELECT tenant_id, provider, model_name,
         sum(prompt_tokens), sum(completion_tokens), sum(total_tokens)
  FROM llm_billing_ledger
  WHERE toDate(timestamp) = '$YESTERDAY' AND success = 1
  GROUP BY tenant_id, provider, model_name
  FORMAT TabSeparated
")

# Query OpenAI usage API for yesterday
# (OpenAI usage endpoint: GET /v1/usage?date=$YESTERDAY)
# Compare per-model token counts; flag divergence > tolerance

# Insert discrepancies into billing_discrepancies table
# Never silently drop a divergence (Rule 13)

echo "[reconciler] completed for $YESTERDAY"
```

Run via cron at 02:00 daily. Tolerance: 1% (configurable). Divergence beyond
tolerance is inserted into `billing_discrepancies` and alerts are fired.

---

## 9. Health Checks & Monitoring

### 9.1 APISIX health

```bash
# APISIX status endpoint
curl http://apisix:9080/apisix/status

# Prometheus metrics
curl http://apisix:9080/apisix/prometheus/metrics
```

### 9.2 Prometheus scrape config (DATAOPS)

Add to `ami-prometheus` scrape config:

```yaml
scrape_configs:
  - job_name: "apisix"
    static_configs:
      - targets: ["apisix:9080"]
    metrics_path: "/apisix/prometheus/metrics"
    scrape_interval: 15s
```

### 9.3 Key metrics to alert on

- `ai_llm_tokens_total`, token usage by model/consumer
- `apisix_http_request_duration_seconds`, gateway latency
- `apisix_http_status{status=~"5.."}`, upstream errors
- `ai_rate_limiting_rejected_total`, rate limit hits
- `redact_placeholder_count` (custom), PII redaction activity

---

## 10. ADC (GitOps, optional)

For traditional mode (etcd) or GitOps config management:

```bash
# Install ADC
go install github.com/api7/adc@latest

# Sync apisix.yaml to running APISIX (traditional mode)
adc sync --server http://apisix:9180/apisix/admin \
  --key "$APISIX_ADMIN_KEY" \
  -f conf/apisix.yaml

# Dump current state for drift detection
adc dump --server http://apisix:9180/apisix/admin \
  --key "$APISIX_ADMIN_KEY"
```

In standalone YAML mode, ADC is not needed, `apisix.yaml` is the source of truth
and is hot-reloaded automatically.

---

## 11. v2 Sidecar Deployment

When semantic cache and NER sidecars are added (v2):

```yaml
# Add to docker-compose.yml:
  ner-engine:
    build:
      context: ../../sidecars/ner-engine
      dockerfile: Dockerfile
    ports:
      - "127.0.0.1:8081:8081"
    volumes:
      - ../../sidecars/ner-engine/models:/models:ro
    environment:
      - NER_MODEL_PATH=/models/bert-tiny-ner-int8.onnx
      - RUST_LOG=info
    restart: unless-stopped
    networks:
      - gateway

  embedding-service:
    build:
      context: ../../sidecars/embedding-service
      dockerfile: Dockerfile
    ports:
      - "127.0.0.1:8090:8090"
    environment:
      - EMBEDDING_MODEL_PATH=/models/bge-large-en-v1.5.onnx
      - RUST_LOG=info
    volumes:
      - ../../sidecars/embedding-service/models:/models:ro
    restart: unless-stopped
    networks:
      - gateway
```

---

## 12. Repository Layout (Target)

```
WORKSPACE-GATEWAY/
├── README.md
├── docs/                           # specifications (this doc set)
│   ├── README.md
│   ├── PROPOSAL-LLM-GATEWAY-v3.md
│   ├── PLUGIN-FOUNDATION.md
│   ├── BUILTIN-PLUGINS.md
│   ├── PLUGIN-REDACT-LUA.md
│   ├── PLUGIN-REDACT-ENGINE.md
│   ├── PLUGIN-SEMANTIC-CACHE.md
│   └── DEPLOYMENT.md
├── plugins/
│   └── custom/
│       ├── redact.lua              # v1 custom plugin
│       └── semantic-cache.lua      # v2 custom plugin
├── conf/
│   ├── config.yaml                 # APISIX config
│   ├── apisix.yaml                 # routes + plugin configs
│   ├── redact-patterns.json        # PII regex + dictionary
│   ├── clickhouse-init.sql         # billing ledger schema
│   └── vector.toml                 # telemetry pipeline
├── res/
│   ├── docker/
│   │   ├── docker-compose.yml
│   │   └── Dockerfile.apisix
│   ├── scripts/
│   │   └── reconciler.sh
│   ├── LOGO.png
│   └── LOGO.svg
└── sidecars/                       # v2
    ├── ner-engine/
    │   ├── Cargo.toml
    │   ├── src/
    │   └── models/
    └── embedding-service/
        ├── Cargo.toml
        ├── src/
        └── models/
```

---

**End of document.**
