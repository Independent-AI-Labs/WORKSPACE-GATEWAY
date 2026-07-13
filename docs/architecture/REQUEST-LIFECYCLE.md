# Request Lifecycle

Sequence for one **federated** cloud request (`/opencode_federated/*`).
Passthrough and llamafile routes skip `key-resolver`; llamafile skips
`key-meta`.

```mermaid
sequenceDiagram
    participant C as Client
    participant A as APISIX
    participant KR as key-resolver
    participant KM as key-meta
    participant RD as redact
    participant LC as limit-count
    participant PRW as proxy-rewrite
    participant U as CloudUpstream
    participant V as Vector
    participant CH as ClickHouse
    participant SU as sse-usage

    C->>A: POST /opencode_federated/v1/chat/completions

    Note over A,KR: access phase
    KR->>KR: Resolve vgw-* via OpenBao or passthrough
    KM->>KM: Set X-Key-Hash
    RD->>RD: Redact PII in request body
    LC->>LC: Check RPM limit

    Note over A,U: rewrite + proxy
    PRW->>PRW: Strip prefix -> /zen/go/...
    A->>U: HTTPS upstream request
    U-->>A: SSE or JSON response

    Note over A,SU: response phases
    SU->>SU: Buffer SSE, extract usage
    RD->>RD: Re-hydrate response tokens

    Note over A,CH: log phase
    A->>V: http-logger POST /ingest
    V->>CH: INSERT request_log
    SU->>CH: timer INSERT usage_log
```

## Phase summary

| Phase | Plugins | Action |
|-------|---------|--------|
| access | key-resolver, key-meta, redact, limit-count | Auth, hash, PII, RPM |
| rewrite | proxy-rewrite | Prefix strip |
| filter | proxy-buffering | SSE-friendly buffering off |
| header_filter / body_filter | sse-usage, redact | Track stream, re-hydrate |
| log | http-logger, sse-usage, prometheus, request-id | Vector ingest, usage INSERT, metrics |

## Error responses (key-resolver)

| Condition | Status |
|-----------|--------|
| Missing Authorization | 401 |
| Invalid / revoked key | 401 |
| OpenBao unreachable | 503 |
| Upstream key not configured | 500 |

Full table: [`CUSTOM-PLUGINS.md`](CUSTOM-PLUGINS.md#key-resolver).