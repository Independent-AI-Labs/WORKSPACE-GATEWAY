# RUNBOOK-EDGE-PROXY: Edge Trust Contract

**Date:** 2026-09-20
**Status:** Active
**Type:** Runbook

---

## Purpose

The edge proxy ("wiki nginx") terminating `https://workspaceguardrails.com`
is the **only** component allowed to assert a Grafana identity. It is a
container attached to the dedicated `gw-edge` bridge, pinned at
**`10.99.60.2`**, and forwards `/grafana/` to `gw-grafana:3000` over that
network (it cannot use host loopback: rootless podman runs
`slirp4netns --disable-host-loopback`). Grafana trusts `X-WEBAUTH-USER`
**only** from the allowlisted source address (`GF_AUTH_PROXY_WHITELIST`:
`10.99.60.2/32` + `127.0.0.1/32`  -  see REQ-SECURITY-HARDENING FR-5.1/FR-6.1).

The proxy's configuration is **outside this repository**. This runbook is
the binding contract; the edge operator must apply it and keep it applied.

## Required edge behavior

```nginx
# 1. Strip any client-supplied trust header BEFORE anything else.
proxy_set_header X-WEBAUTH-USER "";

# 2. Authenticate (your SSO/wiki auth) and only then set the header.
#    The proxy container MUST be pinned to 10.99.60.2 on gw-edge;
#    Grafana is pinned at 10.99.60.3 on the same bridge.
location /grafana/ {
    auth_request /_auth;                 # your authentication mechanism
    proxy_set_header X-WEBAUTH-USER $authenticated_user;  # from auth, never from client
    proxy_pass http://10.99.60.3:3000/;  # gw-edge bridge (Grafana pinned address)
    proxy_set_header Host $host;
    add_header Strict-Transport-Security "max-age=31536000; includeSubScripts" always;
    limit_req zone=grafana burst=20 nodelay;
}

# 3. Never proxy anything except /grafana/ to Grafana; never expose
#    8123/8124 (ClickHouse) or any other gateway service.
```

Hard rules:

| # | Rule |
|---|------|
| 1 | Inbound client-supplied `X-WEBAUTH-USER` MUST be discarded unconditionally (both header spellings, all casings). |
| 2 | The header value MUST come exclusively from the edge's own authentication result. |
| 3 | TLS 1.3 (min 1.2), HSTS enabled, no plain-HTTP listener on 443-facing vhosts. |
| 4 | Rate limiting on `/grafana/`; no websocket-free infinite buffering of SSE panel refreshes. |
| 5 | No other gateway port (8123, 8124, 2379, 2380, 8201, 9092, 9100, 9101, 9180, 9181, 18080) may be forwarded anywhere. |

## Verification matrix (run from the gateway host)

```bash
# 1. Spoofed trust header MUST NOT authenticate:
curl -s -o /dev/null -w '%{http_code}\n' \
  -H 'X-WEBAUTH-USER: admin' https://workspaceguardrails.com/grafana/api/user
# expect 401/302-to-login, NOT 200

# 2. Unauthenticated dashboard API MUST reject:
curl -s -o /dev/null -w '%{http_code}\n' \
  https://workspaceguardrails.com/grafana/api/dashboards/uid/gateway-ops-health
# expect 401/302

# 3. Other services MUST NOT be reachable through the edge:
for p in 8123 8124 9092 9180; do
  curl -s -o /dev/null -m 5 -w "$p %{http_code}\n" \
    "https://workspaceguardrails.com:$p/" ; done
# expect connection failures (no listener on the edge)

# 4. Direct-to-Grafana spoof bypass MUST fail (allowlist):
#    (from a container NOT on gw-edge; the pinned proxy is the only trusted source)
podman run --rm --network docker_gw-ch docker.io/curlimages/curl \
  -s -o /dev/null -w '%{http_code}\n' \
  -H 'X-WEBAUTH-USER: admin' http://gw-grafana:3000/api/user
# expect 401  -  Grafana only trusts the header from the pinned gw-edge source
```

Run the matrix after any edge change and after every Grafana upgrade.
Record results in the deploy log.

## Failure modes

| Symptom | Cause | Fix |
|---------|-------|-----|
| All Grafana logins rejected at edge | Header stripped but never re-set | Verify `proxy_set_header X-WEBAUTH-USER $authenticated_user` runs post-auth |
| Spoofed header logs in as arbitrary user | Edge forwards client header | Apply rule 1 immediately; rotate Grafana admin secret |
| Grafana 401 despite valid edge auth | Source IP not in `GF_AUTH_PROXY_WHITELIST` | Whitelist carries `10.99.60.2` (pinned edge proxy) + 127.0.0.1; confirm the proxy is pinned to that address on `gw-edge` (`docker_gw-edge`) |
