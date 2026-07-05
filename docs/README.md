# LLM Gateway Documentation

**Project:** WORKSPACE-GATEWAY, High-Performance Enterprise Multi-Tenant LLM Gateway
**Platform:** Apache APISIX 3.17.0 (standalone YAML mode)
**Status:** Draft specs (research-validated)
**Date:** 2026-07-05

## Index

| Document | Scope |
|----------|-------|
| [`PROPOSAL-LLM-GATEWAY-v3.md`](PROPOSAL-LLM-GATEWAY-v3.md) | Umbrella architecture: APISIX pivot rationale, plugin mapping, billing-grade contract, ClickHouse schema. Supersedes v2.0 (Kong, archived). |
| [`PLUGIN-FOUNDATION.md`](PLUGIN-FOUNDATION.md) | APISIX custom Lua plugin development foundation: file layout, manifest, schema, phase mapping, context/state, cosockets, custom Docker image, error discipline. |
| [`BUILTIN-PLUGINS.md`](BUILTIN-PLUGINS.md) | Configuration guide for APISIX built-in plugins: `openid-connect`, `ldap-auth`, `ai-proxy`, `ai-proxy-multi`, `ai-rate-limiting`, `http-logger`, `prometheus`, `proxy-buffering`, `proxy-rewrite`. Zero custom code. |
| [`PLUGIN-REDACT-LUA.md`](PLUGIN-REDACT-LUA.md) | Custom Lua plugin (v1): PII redaction via `ngx.re` PCRE + file-based dictionary. PII Map in `ctx`. `body_filter` re-hydration with sliding window. Zero sidecars. |
| [`PLUGIN-REDACT-ENGINE.md`](PLUGIN-REDACT-ENGINE.md) | Optional NER sidecar (v2): Rust binary, ONNX BERT-tiny, `POST /ner`. Off-thread via `ngx.timer.at`. Best-effort enrichment. |
| [`PLUGIN-SEMANTIC-CACHE.md`](PLUGIN-SEMANTIC-CACHE.md) | Custom Lua plugin (v2): Redis VSS semantic cache via `lua-resty-redis` cosocket. Embedding via Rust sidecar (torch/llama.cpp). Canonical JSON storage + SSE synthesis on HIT. |
| [`DEPLOYMENT.md`](DEPLOYMENT.md) | Deployment infrastructure: docker-compose stack, `config.yaml`, `apisix.yaml`, custom Docker image, ClickHouse schema, Vector pipeline, reconciler job, health checks. |

## Reading Order

1. `PROPOSAL-LLM-GATEWAY-v3.md`, the umbrella architecture & rationale.
2. `PLUGIN-FOUNDATION.md`, shared plugin development contracts.
3. `BUILTIN-PLUGINS.md`, built-in plugin configuration (auth, proxy, failover, telemetry).
4. `PLUGIN-REDACT-LUA.md`, the v1 custom plugin (redaction).
5. `DEPLOYMENT.md`, how to deploy and operate.
6. v2 specs: `PLUGIN-SEMANTIC-CACHE.md`, `PLUGIN-REDACT-ENGINE.md`.

## License Posture

- **Apache APISIX 3.17.0**, Apache 2.0. ALL plugins OSS, no license enforcement,
  no tier split, no "free mode" cliff. Source code public. Docker images for every
  version.
- **Custom Lua plugins** are bespoke, written for this project.
- **Rust sidecars** (v2): `ort` (ONNX Runtime, MIT), `axum` (MIT), `tokenizers`
  (Apache 2.0). All dependencies MIT or Apache-2.0.
- No Kong, no Wasm, no Proxy-Wasm, no Enterprise licensing concerns.
