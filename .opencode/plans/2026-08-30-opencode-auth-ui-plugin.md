# Plan record: opencode auth UI wiring (2026-08-30)

Superseded scratch plan; the shipped design differs. Final requirements and
implementation details live in:

- docs/requirements/REQ-PROVIDER-SYNC.md (FR-4.5, FR-5.7)
- docs/specifications/SPEC-PROVIDER-SYNC.md (section 9)
- res/scripts/opencode-client-lib.sh (register_auth_plugin)

Outcome: the existing gateway auth plugin is registered per OAuth provider
via generated wrappers; opencode /connect shows device and browser flows.
Context caps are uniform across providers (FR-2.7), and a production image
build with staged rollout landed as make gw-prod-* (REQ-GATEWAY-CORE FR-5).
