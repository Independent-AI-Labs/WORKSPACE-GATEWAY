# RES-PROVIDER-ALIBABA-TOKEN-PLAN: Alibaba Cloud Token Plan Endpoints

**Date:** 2026-09-20
**Status:** Research complete
**Related:** [REQ-PROVIDER-ALIBABA-TOKEN-PLAN](../requirements/REQ-PROVIDER-ALIBABA-TOKEN-PLAN.md), [SPEC-PROVIDER-ALIBABA-TOKEN-PLAN](../specifications/SPEC-PROVIDER-ALIBABA-TOKEN-PLAN.md)

> Answers one question: which Alibaba Cloud Model Studio (Bailian) endpoint
> serves the Token Plan, what credential it takes, and can WORKSPACE-GATEWAY
> proxy it with the client's own plan key passed through untouched? Short
> answer: the Token Plan is served by the dedicated
> `token-plan.{region}.maas.aliyuncs.com` host (Singapore
> `token-plan.ap-southeast-1.maas.aliyuncs.com` for the International site,
> Beijing `token-plan.cn-beijing.maas.aliyuncs.com` for the China site), on
> the OpenAI-compatible `/compatible-mode/v1` and Anthropic-compatible
> `/apps/anthropic` paths. The credential is a plan-specific `sk-sp-…` key
> (the same prefix the separate Coding Plan uses) and it proxies cleanly
> through a bare relay. The plan key is bound to its endpoint family: the
> same key returns 401 on the Coding Plan and pay-as-you-go hosts.

## 1. Product and endpoint families

Model Studio sells four isolated billing modes. Keys and base URLs must be
used in matching pairs; mixing them fails with 401/403 and can bill
pay-as-you-go unexpectedly.

| Family | Billing | Key prefix | Endpoint host |
|--------|---------|------------|---------------|
| **Token Plan** (this document) | Monthly Credits, per token | `sk-sp-…` | `token-plan.{region}.maas.aliyuncs.com` |
| Coding Plan | Monthly, per-request quota | `sk-sp-…` | `coding.dashscope.aliyuncs.com` (CN) / `coding-intl.dashscope.aliyuncs.com` (Intl) |
| Pay-as-you-go | Per token | `sk-…` | `dashscope*.aliyuncs.com`, `{WorkspaceId}.{region}.maas.aliyuncs.com`, `trial.{region}.maas.aliyuncs.com` |
| AI General-purpose Savings Plan | Prepaid credit offset | `sk-…` | `dashscope*.aliyuncs.com` |

**The `sk-sp-` prefix is shared by Token Plan and Coding Plan**  -  it only
separates "plan" keys from pay-as-you-go `sk-` keys. It does **not**
identify which plan. The endpoint host is what disambiguates.

## 2. Token Plan endpoints (verified 2026-09-20)

| Region | OpenAI-compatible | Anthropic-compatible |
|--------|-------------------|----------------------|
| Singapore (International) | `https://token-plan.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1` | `https://token-plan.ap-southeast-1.maas.aliyuncs.com/apps/anthropic` |
| China North 2 (Beijing) | `https://token-plan.cn-beijing.maas.aliyuncs.com/compatible-mode/v1` | `https://token-plan.cn-beijing.maas.aliyuncs.com/apps/anthropic` |

The console "My Subscriptions" page prints the exact base URL for the
subscription as **PLAN EXCLUSIVE BASE URL**. Treat that string as
authoritative over the documentation tables when they differ.

Anthropic-protocol model discovery is unsupported on this host (`GET
/apps/anthropic/v1/models` returns `404 {"code":"InvalidParameter","message":"Not support"}`),
which is normal for Anthropic-compatible endpoints.

## 3. Model catalog (live `GET /compatible-mode/v1/models`, 2026-09-20)

```
qwen3.8-max              qwen3.8-flash
qwen3.7-max              qwen3.7-plus
qwen3.6-flash
glm-5.3                  glm-5.2
deepseek-v4-pro          deepseek-v4.1-flash        deepseek-v4-flash-0731
wan2.7-image             wan2.7-image-pro
qwen-audio-3.0-tts-plus  qwen-audio-3.0-realtime-plus
```

Guidance:
- Coding/text-capable: `qwen3.8-max`, `qwen3.8-flash`, `qwen3.7-max`,
  `qwen3.7-plus`, `qwen3.6-flash`, `glm-5.3`, `glm-5.2`, `deepseek-v4-pro`,
  `deepseek-v4.1-flash`, `deepseek-v4-flash-0731`.
- `wan2.7-image*` and `qwen-audio-*` are image/audio models that use
  dedicated APIs and are not callable through the text
  `/chat/completions` route.
- The list is console-defined and changes over time; it is not a stable
  contract. The gateway should not fail hard when a model is unknown.

`qwen3.8-max` is the Token Plan flagship and is not in the Coding Plan
list. It was confirmed working on both protocols (see section 6).

## 4. Credential model

- **Plan key:** `sk-sp-…`, generated/shown on the subscription page,
  displayed in full only at creation (later masked as `sk-sp-****`).
- **Bearer semantics:** clients send it as `Authorization: Bearer` and/or
  `x-api-key`; there is no OAuth or refresh flow.
- **Console-encoded form:** the web console can emit an **obfuscated** token
  `o1_<salt6><payload><crc32-6>` (Feistel obfuscation + crc32 over a
  65-char alphabet). The official `bl` CLI decodes it locally into the plain
  `sk-sp-…` key with `bl config agent --key <encoded>` or
  `bl auth login --config token-plan`. A faithful decoder was ported and
  round-trip-validated against the upstream reference during this research.
  The gateway does not need this decoder: clients pass the already-decoded
  `sk-sp-` key.

## 5. Console vs. documentation discrepancy

Alibaba's documentation tables list Coding Plan on
`coding-intl.dashscope.aliyuncs.com` and Token Plan on
`token-plan.ap-southeast-1.maas.aliyuncs.com`. The International console's
subscription page for the plan observed here prints the **token-plan** URL
as the plan-exclusive base URL even though the storefront labels the
subscription as a coding plan. Observed behavior resolves the conflict in
favor of the console:

| Key | `token-plan.ap-southeast-1...` | `coding-intl.dashscope.aliyuncs.com` |
|-----|-------------------------------|--------------------------------------|
| `sk-sp-…` from the console page | 200 OK | 401 `invalid access token or token expired` |

The Token Plan FAQ documents this exact 401 as "used the Coding Plan or
another billing mode's Base URL by mistake." Conclusion: for the
subscription observed here the operative endpoint family is **token-plan**,
and the console URL is the source of truth.

## 6. Protocol verification (2026-09-20)

| Request | Result |
|---------|--------|
| `POST /compatible-mode/v1/chat/completions` model `qwen3.8-max` | 200, `content: "Hi!"`, usage 63/18 |
| `POST /apps/anthropic/v1/messages` model `qwen3.8-max` | 200, thinking block, usage 63/15 |
| `GET /compatible-mode/v1/models` | 200, list in section 3 |
| Same key on `coding-intl` / `coding.dashscope` hosts | 401 |

Both protocols relay the plan key verbatim with no gateway-side credential
handling.

## 7. Risks

- **Key/endpoint mismatch:** a Token Plan key on the Coding Plan host (or
  vice versa) returns 401; a `sk-` key on either plan host is billed
  pay-as-you-go. The gateway must not rewrite or re-map credentials.
- **Interactive-use licence:** both plans are licensed for interactive
  coding tools, not automated backends. The gateway is transparent
  transport; operator policy governs acceptable use.
- **SSE compression:** force `accept-encoding: identity` upstream so usage
  telemetry can read the stream, as on the other relay routes.
- **Unstable model list:** model ids are console-defined; unknown models
  must pass through in telemetry/pricing.
- **Pricing:** Token Plan is Credits-based, not covered by a models.dev namespace;
  token pricing on this route is indicative. `missing_policy: unknown`.

## 8. Conclusion

| Plane | Proxiable through GW | Mode |
|-------|----------------------|------|
| Token Plan inference, OpenAI + Anthropic protocols | Yes, fully | Bare passthrough, zero auth logic |
| Plan key validation / Credits | N/A | Upstream; gateway forwards and reports status |
| OAuth / device login | N/A | No upstream flow exists |
| Coding Plan | Separate provider | Its own key + `coding*` host; not this provider |

Basis for REQ/SPEC-PROVIDER-ALIBABA-TOKEN-PLAN: two bare-relay routes
(`token-plan` Intl default, `token-plan-cn` China), one OpenCode provider
definition each, and the standard relay plugin stack.

## References

- [Model Studio Base URL overview](https://www.alibabacloud.com/help/en/model-studio/base-url)
- [Token Plan quick start (personal)](https://www.alibabacloud.com/help/en/model-studio/token-plan-personal-quick-start)
- [Token Plan quick start (team)](https://www.alibabacloud.com/help/en/model-studio/token-plan-team-quickstart)
- [Token Plan FAQ](https://www.alibabacloud.com/help/zh/model-studio/token-plan-faq)
- [Coding Plan overview](https://www.alibabacloud.com/help/en/model-studio/coding-plan)
- [Coding Plan FAQ](https://www.alibabacloud.com/help/en/model-studio/coding-plan-faq)
- [Connect third-party programming tools](https://www.alibabacloud.com/help/en/model-studio/more-tools)
- [Model Studio CLI (`bl`)](https://github.com/modelstudioai/cli)
