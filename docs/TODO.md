# WORKSPACE-GATEWAY OAuth TODO

**Date:** 2026-08-06
**Status:** Active
**Type:** Implementation TODO
**Owner:** WORKSPACE-GATEWAY

This is the execution checklist for the gateway-owned OpenCode OAuth plugin.
The authoritative behavior contracts remain in
[REQ-PROVIDER-OPENAI](requirements/REQ-PROVIDER-OPENAI.md),
[SPEC-PROVIDER-OPENAI](specifications/SPEC-PROVIDER-OPENAI.md), and
[RUNBOOK-CLIENT-LOGIN](runbooks/RUNBOOK-CLIENT-LOGIN.md).

## Non-Negotiable Boundaries

- Keep all changes in `WORKSPACE-GATEWAY`.
- Do not modify `projects/opencode`.
- Use the published `@opencode-ai/plugin` package through Bun.
- Do not replace upstream plugin types with local copies or structural aliases.
- Keep plugin tests on Bun and `bun:test`.
- Do not add an inline interpreter callback server to the shell installer.
- Do not store upstream access or refresh tokens in repository files, logs, or
  test fixtures.

## Established CI Conventions To Follow

The implementation MUST learn from, and integrate with, the existing workspace
tooling rather than inventing a parallel dependency system:

- `WORKSPACE-VM/workspace/config/bootstrap-components.yaml` is the source for
  hermetic tool components and version detection.
- `WORKSPACE-VM/workspace/config/install-defaults.yaml` controls default tool
  installation.
- `WORKSPACE-CI/scripts/bootstrap-npm` and the `node-env` boot layout define
  how JavaScript runtimes are installed without relying on global binaries.
- `WORKSPACE-CI` package projects use package manifests, committed lockfiles,
  explicit scripts, and `npm ci` for their normal JavaScript dependency path.
- Generated `.pre-commit-config.yaml` files come from `WORKSPACE-CI`; they MUST
  be regenerated, never hand-edited.
- The gateway's existing `languages: [lua, shell]` profile and Lua/shell quality
  gates remain in place. Bun is the required runtime for this plugin, not a
  reason to invent a Node/npm hook profile.

## P0: Package And Runtime Setup

- [x] Decide and document the package root as `res/opencode-plugin/` using the
  same package-root convention as sibling repositories; do not scatter
  manifests across both locations.
- [x] Add a gateway-local Bun `package.json` at that package root, following
  the established workspace package conventions.
- [x] Pin the published `@opencode-ai/plugin` version in the manifest. The
  package observed on 2026-08-06 is `1.18.14`; verify the intended pin before
  writing it.
- [x] Add `res/opencode-plugin/bun.lock` with the manifest in the same change.
- [x] Declare the Bun runtime/package-manager version used by the plugin.
- [x] Add a type-check script that resolves the public package directly.
- [x] Add a test script that runs
  `bun test res/opencode-plugin/workspace-gateway-auth.test.ts`.
- [x] Ensure `bun install --frozen-lockfile` works without a dependency on
  `projects/opencode` or any `workspace:*` package.
- [ ] Add or reuse the hermetic Bun bootstrap component in the workspace boot
  layout, with a pinned version, platform/architecture detection, checksum
  verification, and an installed-path check.
- [ ] Add Bun to the appropriate CI/default installation path only after
  comparing the corresponding `WORKSPACE-CI` and `WORKSPACE-VM` component
  patterns.
- [ ] Decide whether `WORKSPACE-CI` needs a `check-bun-lock-sync` hook; if the
  existing CI library has no Bun lockfile validator, add one through the
  established required-hook/scaffold mechanism rather than silently omitting
  lockfile validation.

## P0: Plugin Behavior

- [x] Preserve the existing `@opencode-ai/plugin` type import and public
  `Hooks.auth` contract.
- [x] Preserve both OpenAI methods: browser authorization-code/PKCE and
  headless device authorization.
- [x] Preserve Kimi as device-only until an official browser authorization-code
  contract exists.
- [x] Ensure device polling treats HTTP 202 with
  `authorization_pending` as an intermediate response.
- [x] Ensure `slow_down` increases the wait interval without ending the flow.
- [x] Ensure terminal device errors fail cleanly and never leak response bodies.
- [x] Ensure browser callback state is checked before any gateway callback
  exchange.
- [x] Ensure the callback server closes on success, failure, timeout, and
  startup error.
- [x] Ensure the plugin never calls provider OAuth endpoints directly; all
  OAuth exchanges remain gateway-owned.

## P1: Tests And Quality Gates

- [x] Test OpenAI method registration and labels.
- [x] Test Kimi device-only registration.
- [x] Test device authorization URL handling.
- [x] Test one pending poll followed by successful token issuance.
- [x] Test `slow_down` and terminal denial behavior.
- [x] Test browser callback state mismatch with zero gateway exchange calls.
- [x] Test browser callback success and callback-server cleanup.
- [x] Test HTTP failures and malformed gateway responses.
- [x] Add Bun typecheck and plugin test commands to the gateway Makefile.
- [x] Include the commands in the node CI profile without replacing Lua and
  shell gates.
- [ ] Ensure CI invokes the hermetic Bun binary explicitly or through the
  workspace boot PATH; never depend on a developer's global `bun`.
- [x] Regenerate `.pre-commit-config.yaml` from `WORKSPACE-CI` after the
  profile change.
- [ ] Run lockfile synchronization, secret scanning, lint, typecheck, plugin
  tests, Lua tests, config tests, and the full gateway test suite.

## P1: Documentation And Release Readiness

- [ ] Keep provider YAML method identifiers, flows, and routes synchronized with
  the plugin configuration examples.
- [x] Keep the runbook explicit that the shell installer is legacy device/API
  key setup and does not host browser callbacks.
- [x] Document the published package version and update it deliberately when
  upstream changes.
- [x] Record any OpenCode compatibility changes against the upstream source
  references in the OpenAI specification.
- [x] Confirm no documentation claims browser support for Kimi.
- [ ] Update the audit status and findings after all verification commands pass.

## P2: Documentation Maintenance

- [ ] Document the exact published `@opencode-ai/plugin` version, Bun version,
  package root, lockfile location, and bootstrap target.
- [x] Document the exact commands for a clean install, frozen install,
  typecheck, focused plugin tests, and aggregate gateway checks.
- [x] Document failure recovery for missing Bun, lockfile drift, package
  resolution from `projects/opencode`, and failed generated-hook checks.
- [x] Link the package README, requirements, specification, runbook, audit, and
  this TODO from the documentation hub where appropriate.

## Current Verification

**Verified 2026-08-06:**

- `bun install --frozen-lockfile` passed.
- Bun TypeScript check passed.
- Plugin Bun tests passed: 7 tests, 20 expectations.
- `make type-check BUN="$BUN"` passed with the workspace Bun runtime.
- OpenCode gateway config test passed: 7 checks.
- Legacy provider-login test passed: 13 checks.
- YAML config test passed: 33 checks.
- APISIX route test passed: 150 checks.
- Lua suite passed across all suites.
- Grafana panel integration passed: 22 checks.

**Still pending:**

- Hermetic Bun bootstrap/component registration in the workspace boot layout.
- Bun lockfile-specific CI validation, if `WORKSPACE-CI` does not already
  provide it.
- Full `make test` is not green because existing integration scripts are
  blocked by the shell audit's inline-Python policy; those scripts predate this
  plugin change and remain separate remediation work.

## P3: Hook Lifecycle And CI Provenance (added 2026-08-23)

Root cause of the failed hook regeneration: GATEWAY's `install-hooks` calls
`generate-hooks` directly, bypassing `reinstall-hooks`, the only script that
preserves the `.git/hooks/*` `chattr +i` invariant (REQ-GGUARD-178) via a
per-inode transient clear/restore inside `ci_acquire_deploy_lock` with
fail-closed `lsattr` verification. Root `make install-hooks` therefore failed
with `mv: Operation not permitted`.

### P3.1: GATEWAY hook flow repair (this change set)

- [x] Change `Makefile` `install-hooks` to invoke
  `$(CI_DIR)/scripts/reinstall-hooks` instead of `generate-hooks`.
- [x] Update `preflight` to check for `reinstall-hooks`, not `generate-hooks`.
- [x] Document in README that `install-hooks` is a root operation on locked
  repos and that hook immutability is maintained by the tool, never by hand.
- [x] Regenerate `.pre-commit-config.yaml` from the redeployed
  `/opt/workspace-ci` (after the P3.2 `REL_CI` fix reaches `/opt`) so
  generated entries and the Makefile agree on one CI root.
- [ ] Root: run `make install-hooks` (now the sanctioned path), then verify
  `lsattr -d .git/hooks/*` shows `+i` restored on exactly the three hooks.

### P3.2: CI provenance rule (single generation source)

Resolved by the 2026-08-24/25 WORKSPACE-CI remediation and redeployment:
`scaffold-ci` was restored to the deployed artifact (`a0efdec`), and
hook-entry integrity gates (`80089d2`) abort generation when a catalog
entry has no implementation (the generator/checker skew class that
produced 22 phantom violations on 2026-08-22).

- [x] WORKSPACE-CI: restore consumer-config generation (`scaffold-ci`)
  into the deployed artifact. Done: `a0efdec` + redeploy.
- [x] WORKSPACE-CI: reconcile the deployed `generate-hooks` with
  `check_required_hooks_present` (marker skew). Done: integrity gates.
- [x] Fix scaffold-ci `REL_CI` computation: the pre-migration
  `realpath --relative-to` logic emitted `../../../../../opt/workspace-ci`
  for the deployed tree; it now uses the absolute `/opt/workspace-ci` per
  SPEC-DEPLOYMENT section 7, Hook Installation (relative paths remain for
  sibling source checkouts). Committed in WORKSPACE-CI `06b5511`
  (2026-08-25 TODO cross-check found the fix had been authored but left
  uncommitted; the 2026-08-25 GATEWAY regeneration therefore still
  emitted relative paths). Needs redeploy to reach `/opt`.
- [x] After WORKSPACE-CI redeploys `06b5511`: regenerate
  `.pre-commit-config.yaml` once more from `/opt/workspace-ci` so entries
  embed the ABSOLUTE path (the 2026-08-25 regeneration embedded relative
  `../../../../../opt/workspace-ci` paths; functional but a provenance
  violation per SPEC-DEPLOYMENT section 7), then delete the stale
  `.pre-commit-config.yaml.scaffold-bak.*` backups. Done 2026-08-27: the
  deployed `scaffold-ci` (via the restored `7d42315` Makefile entrypoint)
  regenerated the config with 20 absolute `/opt/workspace-ci` refs and zero
  `../CI` refs; backups removed.
- [ ] Reconcile or remove the stale `../CI` tree (operator decision; it
  predates the migration and is now unreferenced by anything live).
- [ ] Extend the deployed hook-drift check to reject consumer configs whose
  embedded CI path differs from the deployed root.

### P3.3: Transient-mutability audit follow-up

Confirmed model (evidence: REQ-GGUARD-174..178, REQ-YE-402/500/800/801,
REQ-DEPLOYMENT 16-17, `reinstall-hooks`, `lock-repo`):

- Tracked policy files: no `+i`; ownership+dir-control invariant, guard
  reconcile, no unseal cycle.
- `.git/hooks/*` + tier registries: `+i` retained; edits go through
  root-run tools that clear per-inode inside an exclusive lock and verify
  restore. `lock-repo --unseal` (recursive strip) is deployment-mirror-only.

- [ ] Verify no GATEWAY or CI consumer flow still performs a hand-run
  `chattr` cycle; all must go through `reinstall-hooks`/`workspace-yaml-edit`.
- [ ] WORKSPACE-CI: RUNBOOK-HOOKS gains a consumer-side section documenting
  `reinstall-hooks`, the S1 drift class (install-hooks must not call
  generate-hooks directly), and the provenance rule.
- [ ] WORKSPACE-CI: deployment gate scratch-runs `generate-hooks` +
  `check_required_hooks_present` against its own output before publication,
  killing generator/checker skew (the deployed 2.7KB generator vs 22KB
  source mismatch that produced 22 phantom violations).

### P3.4: Open investigation: `.gitleaksignore`

- [ ] Determine why the deployed gitleaks wrapper reports findings in the
  gitignored `.env` while the source-tree wrapper does not; compare
  `checks_secrets.sh` generations across the three CI trees.
  2026-08-25 finding: the deployed `checks_secrets.sh` builds its own
  gitleaks allowlist from git-ignored paths and never reads
  `.gitleaksignore`; the file is therefore likely INERT under the
  deployed wrapper, which makes the observed discrepancy stranger, not
  explained. The generation comparison is still the next step.
- [ ] If the deployed wrapper has an ignore-propagation defect, fix it in
  WORKSPACE-CI and REMOVE `.gitleaksignore` from this repository.
- [ ] Until resolved, `.gitleaksignore` is documented as a scoped,
  fingerprint-limited exception for the gitignored local `.env` only; it
  must never cover tracked files.

### P3.6: Documentation truth pass (added 2026-08-25)

- [ ] README provenance table (lines ~627-634): "`../CI` is the only
  working generator" is FALSE since the 2026-08-24/25 restoration;
  `/opt/workspace-ci` ships `scaffold-ci` and is the single generation
  source. Update the table and the two `../CI/workflows/` doc links
  (point at `../WORKSPACE-CI/workflows/` or remove).
- [ ] This TODO's P3.2 preamble and README both need the post-fix state:
  restoration landed (`a0efdec`), integrity gates live (`80089d2`),
  REL_CI fix committed (`06b5511`), absolute-path regeneration pending
  deploy.
- [ ] WORKSPACE-CI-side ledger: record the guard yaml-edit splice defect
  (cannot append to indentless block sequences; discovered 2026-08-25
  against `policy_integrity_baseline.yaml`) as a WORKSPACE-GUARD issue.

### P3.7: Pre-commit hygiene for the landing commit (added 2026-08-25)

- [ ] The staged `.pre-commit-config.yaml` regeneration (2026-08-25) wrote
  `.pre-commit-config.yaml.scaffold-bak.*` into the tree; ensure the
  landing commit deletes it (or it rides the commit as a stray artifact).
- [ ] Root `make install-hooks` MUST complete before the landing commit:
  `.git/hooks/*` still source `../CI` from the 2026-08-22 install, so
  committing before reinstall runs the stale-clone hooks and defeats the
  remediation.
- [ ] After install-hooks: verify `lsattr -d .git/hooks/*` shows `+i` on
  exactly the three hooks AND `grep -c '\.\./CI' .git/hooks/*` is 0.

### P3.5: Landing bookkeeping

- [ ] Commit the complete staged change set through the repaired hooks.
- [ ] After the commit lands, flip OAUTH-022/023 and the REQ-PROVIDER-OPENAI
  implementation-status lines from "landing pending" to their final state.
- [ ] WORKSPACE-CI `TODO-REMEDIATION.md` items 256/260 (review Gateway OAuth
  changes; commit Gateway through repaired hooks) reference this commit.

## Definition Of Done

This TODO is complete only when:

1. The gateway plugin installs from the public package registry using Bun and
   frozen-lockfile mode.
2. The plugin type-checks without importing any file from `projects/opencode`.
3. Bun tests cover success, pending, slow-down, denial, expiry, and callback
   state validation.
4. Existing gateway Lua, shell, YAML, and integration gates still pass.
5. Documentation, provider metadata, examples, and generated hooks describe
   the same OpenAI/Kimi OAuth behavior.
6. Hook regeneration uses `reinstall-hooks` end-to-end; the `+i` invariant
   holds after every regeneration without manual `chattr`.
7. Exactly one CI tree (the deployed `/opt/workspace-ci`) generates GATEWAY
   hook configuration, enforced by drift checks.
8. The `.gitleaksignore` question is resolved: wrapper fixed and the ignore
   file removed, or the wrapper behavior is confirmed correct and the file is
   the documented policy.
