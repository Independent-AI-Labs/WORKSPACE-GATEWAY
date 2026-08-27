# Makefile for WORKSPACE-GATEWAY
#
# Quality gates: lint, type-check, test, check, check-push.
# Dev lifecycle: compose ops run directly from Makefile (INCIDENT-2026-07-07:
#   nesting podman-compose build/up inside ansible.builtin.command swallowed
#   all stdout, making builds + health-probe loops look like an indefinite
#   freeze). Ansible handles health checks, init SQL, and model sync only.
# Pattern follows WORKSPACE-PORTAL (INCIDENT-2026-05-08).

SHELL := /bin/bash
SCRIPT_BASH := bash
.DEFAULT_GOAL := help

# Repo root from this Makefile's own path, not `git rev-parse`: root/sudo
# hits safe.directory, and a $(shell) probe runs through SHELL, which
# fails closed for root under the guard and yields an empty root.
_CONSUMER_MK := $(abspath $(lastword $(MAKEFILE_LIST)))
REPO_ROOT := $(patsubst %/,%,$(dir $(_CONSUMER_MK)))
CI_DIR := /opt/workspace-ci
CI_BOOT_BIN := $(CI_DIR)/.boot-linux/bin
COMPOSE_FILE := $(REPO_ROOT)/res/docker/docker-compose.yml
VENV_BIN := $(REPO_ROOT)/.venv/bin
COMPOSE_CMD := $(VENV_BIN)/podman-compose -f $(COMPOSE_FILE)
# Fail fast: cap podman-compose's internal HTTP timeout at 10s (default 60s
# causes indefinite hangs when containers fail to start - see podman #10922).
export COMPOSE_HTTP_TIMEOUT := 10
# User-configurable (env or CLI override); CI's boot bin is the single source when unset
ANSIBLE_PLAYBOOK ?= $(CI_DIR)/.boot-linux/bin/ansible-playbook
# Containment: uv-managed interpreters live inside CI's boot dir, never in
# $HOME/.local/share/uv/python (no unsanctioned HOME/system resources)
export UV_PYTHON_INSTALL_DIR := $(CI_DIR)/.boot-linux/python
ANSIBLE_DEV := $(ANSIBLE_PLAYBOOK) $(REPO_ROOT)/res/ansible/dev.yml
ANSIBLE_COMPOSE := $(ANSIBLE_PLAYBOOK) $(REPO_ROOT)/res/ansible/compose.yml

# Node.js / Playwright for browser-based Grafana panel rendering tests.
# Force-set (not ?=) so git hooks / CI get correct paths even when the
# calling environment has different values (e.g. Tabby's NODE_PATH).
WORKSPACE_ROOT := $(abspath $(REPO_ROOT)/../..)
NODE_BIN := $(WORKSPACE_ROOT)/.boot-linux/bin/node
NODE_PATH := $(WORKSPACE_ROOT)/node_modules
PLAYWRIGHT_BROWSERS_PATH := $(WORKSPACE_ROOT)/.boot-linux/playwright-browsers
BUN ?= $(HOME)/.bun/bin/bun
BUN_PLUGIN_DIR := $(REPO_ROOT)/res/opencode-plugin
# CI should override BUN with the workspace-booted Bun path. The local default
# matches the existing OpenCode Bun installation on the development VM.
export NODE_BIN
export NODE_PATH
export PLAYWRIGHT_BROWSERS_PATH

export PATH := $(CI_BOOT_BIN):$(VENV_BIN):$(PATH)
export PODMAN_PATH := $(CI_BOOT_BIN)/podman

-include $(CI_DIR)/lib/makefile_contract.mk

# =============================================================================
# Help
# =============================================================================
.PHONY: help
help: ## Show this help
	$(SCRIPT_BASH) scripts/make-help.sh $(MAKEFILE_LIST)

# =============================================================================
# Setup / Install
# =============================================================================
.PHONY: preflight bootstrap-podman setup install install-ci install-deps plugin-install install-hooks sync init init-check

preflight: ## Verify environment
	test -d "$(CI_DIR)" || { echo "ERROR: CI directory not found at $(CI_DIR)" >&2; exit 1; }
	test -f "$(CI_DIR)/scripts/reinstall-hooks" || { echo "ERROR: reinstall-hooks missing" >&2; exit 1; }
	command -v podman 1>&2 || { echo "ERROR: podman not on PATH" >&2; exit 1; }
	test -x "$(ANSIBLE_PLAYBOOK)" || { echo "ERROR: ansible-playbook not found at $(ANSIBLE_PLAYBOOK)" >&2; echo "Provision (operator, elevated): sudo make -C $(CI_DIR) install-ansible, or set ANSIBLE_PLAYBOOK=/path/to/ansible-playbook" >&2; exit 1; }
	test -f "$(VENV_BIN)/podman-compose" || { echo "ERROR: run 'make install' first" >&2; exit 1; }
	echo "Preflight OK"

bootstrap-podman: ## Install podman binaries if not on PATH
	command -v podman 1>&2 || { \
		echo "=== Bootstrapping podman ==="; \
		bash $(CI_DIR)/scripts/bootstrap-podman; \
	}

setup: bootstrap-podman ## Create .venv with podman-compose
	echo "=== Creating .venv ==="
	if [ ! -d .venv ]; then uv venv .venv; else echo "  .venv already exists"; fi
	uv pip install --python .venv podman-compose jinja2
	echo "=== Setup complete ==="
	_podman="$$(command -v podman)" || _podman="NOT FOUND"; echo "  podman: $$_podman"
	echo "  podman-compose: $(VENV_BIN)/podman-compose"
	echo "  ansible: $(ANSIBLE_PLAYBOOK)"

install: setup install-hooks ## Full install: podman + .venv + hooks + images
	$(MAKE) _compose-build
	echo "=== Install complete ==="
	echo "Run 'make gw-start' to start the gateway stack."

install-ci: install-deps ## CI install: deps only, no hooks
install-deps: setup plugin-install ## Install project dependencies

plugin-install: ## Install the gateway-owned Bun plugin dependencies from the frozen lockfile
	test -x "$(BUN)" || { echo "ERROR: Bun not found at $(BUN); install the pinned workspace Bun runtime or set BUN=/path/to/bun" >&2; exit 1; }
	$(BUN) install --cwd "$(BUN_PLUGIN_DIR)" --frozen-lockfile

install-hooks: ## (Re)generate native git hooks (root on locked repos; preserves the +i invariant)
	$(SCRIPT_BASH) $(CI_DIR)/scripts/reinstall-hooks

sync: install-deps install-hooks ## Sync deps + reinstall hooks

init: ## Check system dependencies and print install instructions if missing
	bash $(CI_DIR)/scripts/install-system-deps --print

init-check: ## Check system dependencies (report only, fail if any missing)
	bash $(CI_DIR)/scripts/install-system-deps --check

# =============================================================================
# Gateway Lifecycle
# =============================================================================
# Compose operations (build/up/down) run directly from Makefile targets so
# output streams live to the terminal. The stack is owned by the systemd user
# unit gateway-compose (Boot Persistence below): start/stop/restart go through
# systemctl so an unmanaged compose stack never fights the unit's
# restart ownership. Ansible handles health checks, ClickHouse init SQL, and
# model sync.
# =============================================================================

.PHONY: _compose-build _compose-down

_compose-build:
	echo "=== Building container images ==="
	$(SCRIPT_BASH) res/scripts/gateway-compose.sh build

_compose-down:
	echo "=== Stopping gateway stack ==="
	-$(SCRIPT_BASH) res/scripts/gateway-compose.sh down

.PHONY: gw-build gw-start gw-stop gw-restart gw-update gw-reconcile gw-verify gw-status gw-logs gw-shell gw-test \
        gw-restart-service gw-restart-grafana

gw-build: _compose-build ## Build container images

gw-start: ## Start the gateway stack via systemd, then health checks + init + sync
	$(ANSIBLE_COMPOSE) --tags deploy,start
	if [ -f .env ]; then set -a; source .env; set +a; fi; \
	$(ANSIBLE_DEV) --tags start

gw-stop: ## Stop the gateway stack via systemd (keep volumes)
	$(ANSIBLE_COMPOSE) --tags stop

gw-restart: ## Restart existing containers via systemd; does not build or recreate
	$(ANSIBLE_COMPOSE) --tags restart
	if [ -f .env ]; then set -a; source .env; set +a; fi; \
	$(ANSIBLE_DEV) --tags start

gw-update: ## Build images, redeploy changed services via systemd, then reconcile
	$(MAKE) gw-build
	$(ANSIBLE_COMPOSE) --tags deploy,restart
	if [ -f .env ]; then set -a; source .env; set +a; fi; \
	$(ANSIBLE_DEV) --tags start

gw-reconcile: ## Reconcile routes, schema, and provider catalog without restarting containers
	if [ -f .env ]; then set -a; source .env; set +a; fi; \
	$(ANSIBLE_DEV) --tags start

gw-restart-service: ## Restart one existing service without recreating it
	test -n "$(SVC)" || { echo "ERROR: SVC required. Usage: make gw-restart-service SVC=grafana" >&2; exit 1; }
	echo "=== Restarting existing service: $(SVC) ==="
	$(SCRIPT_BASH) res/scripts/gateway-compose.sh restart-service "$(SVC)"
	echo "=== $(SVC) restarted ==="

gw-restart-grafana: ## Restart Grafana, wait healthy, reload provisioning
	$(MAKE) gw-restart-service SVC=grafana
	echo "=== Waiting for Grafana health ==="
	for i in 1 2 3 4 5 6 7 8 9 10 15 20; do \
		if curl -sS -f --max-time 2 http://admin:$${GRAFANA_ADMIN_PASSWORD:-admin}@localhost:3030/api/health; then \
			curl -sS http://admin:$${GRAFANA_ADMIN_PASSWORD:-admin}@localhost:3030/api/health | python3 -c "import json,sys; print('Grafana version:', json.load(sys.stdin)['version'])"; break; \
		fi; \
		echo "  waiting... (attempt $$i/20)"; sleep 2; \
	done
	echo "=== Reloading provisioning (drops orphan dashboards) ==="
	curl -sS -f -X POST http://admin:$${GRAFANA_ADMIN_PASSWORD:-admin}@localhost:3030/api/admin/provisioning/dashboards/reload
	echo "=== Syncing dashboard defaults from JSON (7d / 5s) ==="
	bash res/scripts/sync-grafana-dashboards.sh
	echo "=== Canonical dashboard URLs (use these; stale bookmarks may keep now-24h) ==="
	echo "  http://localhost:3030/d/gateway-cost-usage?from=now-7d&to=now&refresh=5s"
	echo "  http://localhost:3030/d/gateway-ops-health?from=now-7d&to=now&refresh=5s"
	echo "  http://localhost:3030/d/gateway-cost-leaderboard?from=now-7d&to=now&refresh=5s"
	echo "=== Grafana upgrade complete ==="

gw-verify: ## Health report: container/endpoint status + one request through the gateway
	if [ -f .env ]; then set -a; source .env; set +a; fi; \
	$(ANSIBLE_DEV) --tags status,sanity

gw-status: ## Show gateway systemd + container status
	$(ANSIBLE_COMPOSE) --tags status

gw-logs: ## Show the latest 200 gateway log lines (optional SVC=grafana)
	$(SCRIPT_BASH) res/scripts/gateway-compose.sh logs $(SVC)

gw-shell: ## Exec into APISIX container shell
	podman exec -it docker_apisix_1 /bin/bash

gw-test: ## Run full test suite against running stack
	if [ -f .env ]; then set -a; source .env; set +a; fi; \
	bash tests/run_all.sh

# =============================================================================
# ClickHouse Migrations
# =============================================================================

.PHONY: ch-migrate ch-migrate-status
ch-migrate: ## Apply pending ClickHouse schema migrations (golang-migrate via compose)
	$(SCRIPT_BASH) res/scripts/gateway-compose.sh migrate-up

ch-migrate-status: ## Show ClickHouse schema migration status (golang-migrate version)
	$(SCRIPT_BASH) res/scripts/gateway-compose.sh migrate-status

# =============================================================================
# Model Sync
# =============================================================================

sync-models: ## Trigger provider model sync on the gateway
	curl -sS -f --max-time 30 -X POST http://localhost:9080/gateway/providers/sync

# OpenBao-backed virtual key management
# =============================================================================
# Key Management
# =============================================================================
.PHONY: issue-key list-keys revoke-key pool-key

issue-key: ## Issue a new virtual gateway key (use KEY_ID=, TENANT_ID=, USER_ID=, POOL=)
	bash $(REPO_ROOT)/res/scripts/issue-key.sh $(if $(KEY_ID),--key-id $(KEY_ID)) $(if $(TENANT_ID),--tenant $(TENANT_ID)) $(if $(USER_ID),--user $(USER_ID)) $(if $(UPSTREAM_KEY),--upstream-key $(UPSTREAM_KEY)) $(if $(POOL),--pool $(POOL))

pool-key: ## Manage upstream key pools (ARGS='create kimi', 'add kimi k1 sk-...', 'list', 'reset kimi')
	if [ -z "$(ARGS)" ]; then echo "ERROR: ARGS required. Usage: make pool-key ARGS='list'" >&2; exit 1; fi
	bash $(REPO_ROOT)/res/scripts/pool-key.sh $(ARGS)

list-keys: ## List all virtual gateway keys
	bash $(REPO_ROOT)/res/scripts/list-keys.sh

revoke-key: ## Revoke a virtual gateway key (KEY_ID=vgw-xxx required)
	if [ -z "$(KEY_ID)" ]; then echo "ERROR: KEY_ID required. Usage: make revoke-key KEY_ID=vgw-xxx" >&2; exit 1; fi
	bash $(REPO_ROOT)/res/scripts/revoke-key.sh $(KEY_ID)

# =============================================================================
# Quality Gates
# =============================================================================
.PHONY: check lint type-check plugin-type-check plugin-test test test-live check-push

lint: ## Lint shell scripts and validate YAML
	echo "=== Linting shell scripts ==="
	for f in $$(find . -name '*.sh' -not -path './.git/*'); do \
		echo "  checking $$f"; \
		bash -n "$$f" || { echo "FAIL: $$f"; exit 1; }; \
	done
	echo "=== Validating YAML ==="
	bash $(REPO_ROOT)/res/scripts/validate-yaml.sh

type-check: ## Lua syntax check and TypeScript plugin contract check
	echo "=== Lua syntax check ==="
	$(SCRIPT_BASH) tests/lua/check_syntax.sh
	$(MAKE) plugin-type-check

plugin-type-check: ## Type-check the gateway-owned OpenCode plugin with Bun
	test -x "$(BUN)" || { echo "ERROR: Bun not found at $(BUN); install the pinned workspace Bun runtime or set BUN=/path/to/bun" >&2; exit 1; }
	$(BUN) --cwd "$(BUN_PLUGIN_DIR)" ./node_modules/typescript/bin/tsc --noEmit

plugin-test: ## Run gateway-owned OpenCode plugin Bun tests
	test -x "$(BUN)" || { echo "ERROR: Bun not found at $(BUN); install the pinned workspace Bun runtime or set BUN=/path/to/bun" >&2; exit 1; }
	$(BUN) test "$(BUN_PLUGIN_DIR)/workspace-gateway-auth.test.ts"

test: ## Run all test stages (excludes live upstream API tests)
	if [ -f .env ]; then set -a; source .env; set +a; fi; \
	$(MAKE) plugin-test; \
	bash tests/run_all.sh

test-live: ## Run all tests including live upstream API tests (RUN_LIVE_API_TESTS=1)
	if [ -f .env ]; then set -a; source .env; set +a; fi; \
	RUN_LIVE_API_TESTS=1 bash tests/run_all.sh

check: lint type-check test ## Run all quality gates
	echo "=== All checks passed ==="

check-push: check ## Pre-push gate: check + E2E if API key available
	if [ -n "$$OPENCODE_API_KEY" ]; then \
		echo "=== Running E2E tests ==="; \
		bash tests/e2e/run.sh; \
	else \
		echo "=== OPENCODE_API_KEY not set, skipping E2E ==="; \
	fi

# Boot persistence via systemd user unit + Ansible
# =============================================================================
# Boot Persistence
# =============================================================================
.PHONY: gw-deploy gw-undeploy gw-systemd-logs

gw-deploy: ## Install + enable gateway compose on boot (systemd user + linger), then health checks + init + sync
	$(ANSIBLE_COMPOSE) --tags deploy
	if [ -f .env ]; then set -a; source .env; set +a; fi; \
	$(ANSIBLE_DEV) --tags start

gw-undeploy: ## Disable + remove gateway compose systemd unit
	$(ANSIBLE_COMPOSE) --tags undeploy

gw-systemd-logs: ## Tail gateway systemd unit logs
	journalctl --user -u gateway-compose -f

# =============================================================================
# Cleanup
# =============================================================================
.PHONY: clean
clean: ## Remove build artifacts
	echo "No build artifacts to remove"
