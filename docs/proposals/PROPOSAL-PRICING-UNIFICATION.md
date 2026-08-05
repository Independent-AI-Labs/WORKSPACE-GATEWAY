# Pricing Unification Proposal

**Status:** Approved for implementation
**Date:** 2026-08-05
**Scope:** Provider catalog generation, model metadata, pricing resolution,
telemetry cost calculation, OpenCode output, and historical billing

## Decision Summary

All providers use `models.dev` as the default metadata and pricing source unless
the provider configuration explicitly selects another source or declares a
model-level override.

llamafile is explicitly `unknown` for pricing during this migration. Its local
inference is not assumed to be free. A future provider-specific policy may
replace `unknown` with a validated static or local-cost policy.

No pricing value is hardcoded in generated OpenCode output. Generated output is
derived from the normalized provider catalog. Checked-in examples are either
generated from a fixture or clearly marked as illustrative and non-authoritative.

## Problems Being Solved

The current implementation has separate pricing behavior in provider YAML,
models.dev enrichment, endpoint discovery, alias expansion, shared-dictionary
cache writes, and telemetry cost calculation. Pricing cache keys contain only a
canonical model, so two providers exposing the same model cannot have different
prices. Pricing fields are also dropped or defaulted to zero during conversion,
and historical usage does not record which rates were applied.

## Target Provider Contract

Every provider document will expose the following conceptual fields. The
migration may accept legacy fields temporarily, but the normalized in-memory
contract must be identical for every provider.

```yaml
schema_version: 2

catalog:
  discovery:
    type: models_dev | gateway_endpoint | llamafile
    provider: openai                 # required for models.dev
    endpoint: /v1/models             # required for endpoint discovery
  metadata:
    source: models_dev | endpoint | static | none
    provider: openai                 # required for models.dev metadata
  normalize:
    strip_prefix: null
    lowercase: true
  filter:
    include: []
    exclude: []

pricing:
  source:
    type: models_dev | static | upstream | unknown
    provider: openai                 # required for models.dev pricing
  missing_policy: unknown
  overrides:
    model-id:
      input: 0
      output: 0

aliases:
  source: model_registry
  expose: []
```

### Resolution precedence

Pricing is resolved independently for each field:

1. Explicit provider/model override.
2. Static model metadata override.
3. Explicit `pricing.source`.
4. Explicit `catalog.metadata` models.dev provider.
5. Explicit `catalog.discovery` models.dev provider.
6. `missing_policy`.

An explicit zero is valid and must remain zero. Missing fields must not be
converted to zero. Unknown pricing remains observable as `unknown`.

### Supported pricing data

The normalized rate card preserves:

- input tokens;
- output tokens;
- reasoning tokens;
- cache-read tokens;
- cache-write tokens;
- audio/image modalities when supplied;
- tiered/context-dependent rates;
- service/batch tier metadata;
- currency and source provenance.

## Provider Policies

| Provider | Discovery | Metadata | Pricing policy |
|---|---|---|---|
| OpenAI OAuth | Configured compatible model source | models.dev `openai` | models.dev `openai` unless explicitly overridden |
| Kimi API/virtual/device OAuth | models.dev `moonshotai` | models.dev `moonshotai` | models.dev `moonshotai` |
| OpenCode Go API/virtual | Gateway model endpoint | models.dev `opencode` | models.dev `opencode` |
| OpenCode Zen | Gateway model endpoint | models.dev `opencode` | models.dev `opencode` |
| llamafile | Local model endpoint | Static metadata | `unknown` until a pricing policy is defined |

## Runtime Architecture

### Reusable pricing resolver

Create one pure resolver module:

```text
resolve_price(provider_id, raw_model_id, provider_config,
              discovered_model, models_dev_snapshot)
```

It returns a normalized rate card, canonical identity, selected source,
provenance, validation warnings, and a deterministic snapshot key. Catalog
generation, OpenCode output, cache publication, and cost calculation consume
this result rather than copying pricing fields independently.

### Provider-aware pricing identity

Pricing records are keyed by:

```text
provider_id + canonical_model_id + pricing_band_id
```

The request path must carry provider and route identity through telemetry into
cost resolution. A model-only key is not a valid billing identity.

### Atomic pricing snapshots

Each sync builds a complete validated generation before publication:

```text
pricing:snapshot:<generation>:<provider>:<canonical-model>
pricing:manifest:<generation>
pricing:active-generation
```

Failed refreshes retain the last-known-good generation. Request and log phases
never perform network synchronization.

### Historical accounting

Usage records will persist:

- provider and route identity;
- requested, upstream, and canonical model IDs;
- pricing snapshot ID;
- selected rate band;
- component token counts and costs;
- source/provenance and extraction version;
- request time and ingestion time.

Historical correction uses immutable adjustment records, not destructive
replacement with current prices.

## Migration Phases

### Phase 1: Contract and validation

- Add the normalized provider pricing schema.
- Convert all eight providers.
- Set llamafile to explicit `unknown`.
- Validate aliases, sources, pricing fields, and duplicate IDs.
- Remove zero-price llamafile metadata.

### Phase 2: Resolver and catalog

- Implement the reusable resolver.
- Remove duplicated pricing serializers.
- Add models.dev defaulting and explicit override precedence.
- Preserve tier, reasoning, cache-write, and provenance fields.

### Phase 3: Cache and telemetry

- Add provider-aware snapshot keys.
- Pass provider identity into cost calculation.
- Add normalized usage dimensions and component costs.
- Publish snapshots atomically and retain last-known-good data.

### Phase 4: Generated output

- Make runtime OpenCode output consume normalized provider models.
- Add a deterministic fixture-based generator for examples.
- Remove manually maintained hardcoded pricing snapshots.
- Add drift tests.

### Phase 5: Historical migration

- Add pricing snapshot and usage provenance columns.
- Classify existing rows as exact, resolvable, ambiguous, or unrecoverable.
- Recalculate only exact/resolvable rows with an explicit adjustment record.
- Keep llamafile historical pricing unknown.

## Acceptance Criteria

- Every provider has one normalized pricing policy.
- models.dev is the default unless a provider explicitly overrides it.
- llamafile resolves to `unknown`, never implicit zero pricing.
- Same model through two providers uses provider-specific prices.
- Explicit zero pricing remains distinguishable from missing pricing.
- Tiered, reasoning, cache-read, and cache-write rates survive normalization.
- No generated OpenCode file contains manually authored runtime pricing.
- Pricing snapshots are atomic, provider-aware, and historically identifiable.
- No request/log phase performs catalog or pricing network fetches.
- Cost tests cover source precedence, collisions, aliases, missing values,
  tiers, and explicit overrides.
- Full repository verification passes twice consecutively.

## Non-Goals

- Automatically assigning a cost to llamafile before a policy is defined.
- Inferring provider prices from the cheapest available source.
- Treating current catalog prices as historical truth.
- Adding xAI/Grok before its provider contract is implemented.
