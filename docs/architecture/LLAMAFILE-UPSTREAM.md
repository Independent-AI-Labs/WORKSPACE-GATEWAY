# VM-hosted llamafile Upstream

Local zero-cost LLM so the full request -> log -> ledger pipeline runs
without paid upstream credits. Used by integration tests when the VM
llamafile server is reachable.

## Lifecycle split

- **VM owns the server:** llamafile binary per model, systemd unit
  `llamafile-<model>.service`, port 8765. Operate via `make install-llamafile`,
  `make restart-llamafile`, etc. (`ansible/roles/llamafile/`).
- **Gateway declares the route:** `relay-llamafile` proxies `/llamafile/*`
  to `host.docker.internal:8765` (templated via
  `LLAMAFILE_UPSTREAM_HOST` / `PORT` in [`conf/apisix.yaml.j2`](../../conf/apisix.yaml.j2)).

No `key-resolver` or `key-meta`. Same telemetry plugins as cloud routes
(`request-id`, `http-logger`, `sse-usage`, `prometheus`, etc.).

## APE binary / systemd

Cosmopolitan APE binaries need `ExecStart=/bin/sh {{ llamafile_path }}`.
Run bare (no CLI args) so embedded `.args` supplies server flags.

## Model normalization

Server ids like `/zip/MiniCPM5-1B-Q8_0.gguf` normalize via
`cost_calc.normalize_key()` to `minicpm5-1b-q8_0.gguf` in both log tables.
No models.dev entry: `cost_source = unknown`, `cost = 0`.

## Integration tests

`test_llamafile_e2e.sh`, `test_event_id_alignment.sh`, `test_data_flow.sh`,
`test_cost_e2e.sh` use `/llamafile/*` exclusively via
`tests/integration/lib_event_align.sh`. Skip cleanly (exit 0) if server or
stack unreachable.

## opencode provider

`workspace-gw-llamafile` synced by `make sync-models`. See
[`OPENCODE-INTEGRATION.md`](../OPENCODE-INTEGRATION.md).