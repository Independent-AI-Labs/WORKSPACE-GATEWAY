# Makefile for WORKSPACE-GATEWAY
#
# Quality gates: lint, type-check, test, check, check-push.
# Dev lifecycle: compose ops run directly from Makefile (INCIDENT-2026-07-07:
#   nesting podman-compose build/up inside ansible.builtin.command swallowed
#   all stdout, making builds + health-probe loops look like an indefinite
#   freeze). Ansible handles health checks, init SQL, and model sync only.
# Pattern follows WORKSPACE-PORTAL (INCIDENT-2026-05-08).

SHELL := /bin/bash
.DEFAULT_GOAL := help

REPO_ROOT := $(shell git rev-parse --show-toplevel || pwd)
CI_DIR := $(abspath $(REPO_ROOT)/../CI)
COMPOSE_FILE := $(REPO_ROOT)/res/docker/docker-compose.yml
VENV_BIN := $(REPO_ROOT)/.venv/bin
COMPOSE_CMD := $(VENV_BIN)/podman-compose -f $(COMPOSE_FILE)
# Fail fast: cap podman-compose's internal HTTP timeout at 10s (default 60s
# causes indefinite hangs when containers fail to start - see podman #10922).
export COMPOSE_HTTP_TIMEOUT := 10
ANSIBLE_PLAYBOOK := ansible-playbook
ANSIBLE_DEV := $(ANSIBLE_PLAYBOOK) $(REPO_ROOT)/res/ansible/dev.yml
ANSIBLE_COMPOSE := $(ANSIBLE_PLAYBOOK) $(REPO_ROOT)/res/ansible/compose.yml

# Node.js / Playwright for browser-based Grafana panel rendering tests.
# Force-set (not ?=) so git hooks / CI get correct paths even when the
# calling environment has different values (e.g. Tabby's NODE_PATH).
WORKSPACE_ROOT := $(abspath $(REPO_ROOT)/../..)
NODE_BIN := $(WORKSPACE_ROOT)/.boot-linux/bin/node
NODE_PATH := $(WORKSPACE_ROOT)/node_modules
PLAYWRIGHT_BROWSERS_PATH := $(WORKSPACE_ROOT)/.boot-linux/playwright-browsers
export NODE_BIN
export NODE_PATH
export PLAYWRIGHT_BROWSERS_PATH

export PATH := $(PATH):$(VENV_BIN)

-include $(CI_DIR)/lib/makefile_contract.mk

# =============================================================================
# Help
# =============================================================================
.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

# =============================================================================
# Setup / Install
# =============================================================================
.PHONY: preflight bootstrap-podman setup install install-ci install-deps install-hooks sync init init-check

preflight: ## Verify environment
	@test -d "$(CI_DIR)" || { echo "ERROR: CI directory not found at $(CI_DIR)" >&2; exit 1; }
	@test -f "$(CI_DIR)/scripts/generate-hooks" || { echo "ERROR: generate-hooks missing" >&2; exit 1; }
	@command -v podman >/dev/null 2>&1 || { echo "ERROR: podman not on PATH" >&2; exit 1; }
	@command -v ansible-playbook >/dev/null 2>&1 || { echo "ERROR: ansible-playbook not on PATH" >&2; exit 1; }
	@test -f "$(VENV_BIN)/podman-compose" || { echo "ERROR: run 'make install' first" >&2; exit 1; }
	@echo "Preflight OK"

bootstrap-podman: ## Install podman binaries if not on PATH
	@command -v podman >/dev/null 2>&1 || { \
		echo "=== Bootstrapping podman ==="; \
		bash $(CI_DIR)/scripts/bootstrap-podman; \
	}

setup: bootstrap-podman ## Create .venv with podman-compose
	@echo "=== Creating .venv ==="
	@if [ ! -d .venv ]; then uv venv .venv; else echo "  .venv already exists"; fi
	@uv pip install --python .venv podman-compose
	@echo "=== Setup complete ==="
	@_podman="$$(command -v podman)" || _podman="NOT FOUND"; echo "  podman: $$_podman"
	@echo "  podman-compose: $(VENV_BIN)/podman-compose"
	@_ansible="$$(command -v ansible-playbook)" || _ansible="NOT FOUND"; echo "  ansible: $$_ansible"

install: setup install-hooks ## Full install: podman + .venv + hooks + images
	@$(MAKE) _compose-build
	@echo "=== Install complete ==="
	@echo "Run 'make dev-start' to start the gateway stack."

install-ci: install-deps ## CI install: deps only, no hooks
install-deps: setup ## Install project dependencies

install-hooks: ## (Re)generate native git hooks
	bash $(CI_DIR)/scripts/generate-hooks

sync: install-deps install-hooks ## Sync deps + reinstall hooks

init: ## Check system dependencies and print install instructions if missing
	@bash $(CI_DIR)/scripts/install-system-deps --print

init-check: ## Check system dependencies (report only, fail if any missing)
	@bash $(CI_DIR)/scripts/install-system-deps --check

# =============================================================================
# Dev Lifecycle
# =============================================================================
# Compose operations (build/up/down) run directly from Makefile targets so
# output streams live to the terminal. Ansible handles only health checks,
# ClickHouse init SQL, and model sync.
# =============================================================================

.PHONY: _compose-build _compose-up _compose-down _compose-clean

_compose-build:
	@echo "=== Building container images ==="
	$(COMPOSE_CMD) build

_compose-up:
	@echo "=== Starting gateway stack ==="
	@timeout 120 $(COMPOSE_CMD) up -d; \
	rc=$$?; \
	if [ $$rc -ne 0 ]; then \
		echo "=== ERROR: podman-compose up failed (rc=$$rc) ===" >&2; \
		podman ps -a --format "table {{.Names}}\t{{.Status}}" | grep -E "docker_|gw-"; \
		exit 1; \
	fi
	@echo "=== Verifying containers started ==="
	@expected="docker_apisix_1 docker_clickhouse_1 docker_vector_1 gw-etcd gw-grafana gw-prometheus gw-openbao"; \
	missing=""; \
	for c in $$expected; do \
		if ! podman inspect -f '{{.State.Running}}' $$c | grep -q true; then \
			missing="$$missing $$c"; \
		fi; \
	done; \
	if [ -n "$$missing" ]; then \
		echo "=== ERROR: containers not running:$$missing ===" >&2; \
		podman ps -a --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}" | grep -E "docker_|gw-"; \
		exit 1; \
	fi
	@echo "=== All containers running ==="

_compose-down:
	@echo "=== Stopping gateway stack ==="
	-$(COMPOSE_CMD) down

_compose-clean:
	@echo "=== Destroying volumes (data loss!) ==="
	-$(COMPOSE_CMD) down -v

.PHONY: dev-start dev-stop dev-restart dev-rebuild dev-restart-service dev-restart-grafana dev-logs dev-status \
        dev-clean dev-shell dev-test dev-sanity

dev-start: _compose-build _compose-up ## Start the gateway stack (build + up + health checks)
	@echo "=== Waiting for services to become healthy ==="
	@if [ -f .env ]; then set -a; source .env; set +a; fi; \
	$(ANSIBLE_DEV) --tags start

dev-stop: _compose-down ## Stop the gateway stack (keep volumes)

dev-restart: dev-stop dev-start ## Restart the gateway stack (stop + start)

dev-rebuild: dev-stop _compose-build _compose-up ## Rebuild images and restart
	@echo "=== Waiting for services to become healthy ==="
	@if [ -f .env ]; then set -a; source .env; set +a; fi; \
	$(ANSIBLE_DEV) --tags start

dev-restart-service: ## Restart a single service (SVC=grafana|clickhouse|apisix|vector|openbao|prometheus)
	@test -n "$(SVC)" || { echo "ERROR: SVC required. Usage: make dev-restart-service SVC=grafana" >&2; exit 1; }
	@echo "=== Recreating service: $(SVC) ==="
	@timeout 120 $(COMPOSE_CMD) up -d --force-recreate --no-deps $(SVC); \
	rc=$$?; \
	if [ $$rc -ne 0 ]; then echo "=== ERROR: recreate $(SVC) failed (rc=$$rc) ===" >&2; exit 1; fi
	@echo "=== $(SVC) recreated ==="

dev-restart-grafana: ## Recreate Grafana (pulls new image from compose), wait healthy, reload provisioning
	@$(MAKE) dev-restart-service SVC=grafana
	@echo "=== Waiting for Grafana health ==="
	@for i in 1 2 3 4 5 6 7 8 9 10 15 20; do \
		if curl -sf --max-time 2 http://admin:$${GRAFANA_ADMIN_PASSWORD:-admin}@localhost:3030/api/health >/dev/null 2>&1; then \
			curl -s http://admin:$${GRAFANA_ADMIN_PASSWORD:-admin}@localhost:3030/api/health | python3 -c "import json,sys; print('Grafana version:', json.load(sys.stdin)['version'])"; break; \
		fi; \
		echo "  waiting... (attempt $$i/20)"; sleep 2; \
	done
	@echo "=== Reloading provisioning (drops orphan dashboards) ==="
	@curl -s -X POST http://admin:$${GRAFANA_ADMIN_PASSWORD:-admin}@localhost:3030/api/admin/provisioning/dashboards/reload >/dev/null
	@echo "=== Syncing dashboard defaults from JSON (7d / 5s) ==="
	@bash res/scripts/sync-grafana-dashboards.sh
	@echo "=== Canonical dashboard URLs (use these; stale bookmarks may keep now-24h) ==="
	@echo "  http://localhost:3030/d/gateway-cost-usage?from=now-7d&to=now&refresh=5s"
	@echo "  http://localhost:3030/d/gateway-ops-health?from=now-7d&to=now&refresh=5s"
	@echo "  http://localhost:3030/d/gateway-cost-leaderboard?from=now-7d&to=now&refresh=5s"
	@echo "=== Grafana upgrade complete ==="

dev-logs: ## Tail container logs (Ctrl-C to stop)
	$(COMPOSE_CMD) logs -f

dev-status: ## Show running containers and health status
	$(ANSIBLE_DEV) --tags status

dev-clean: _compose-clean ## Stop stack and remove all volumes (data loss!)

dev-shell: ## Exec into APISIX container shell
	@podman exec -it docker_apisix_1 /bin/bash

dev-test: ## Run full test suite against running stack
	@if [ -f .env ]; then set -a; source .env; set +a; fi; \
	bash tests/run_all.sh

dev-sanity: ## Quick sanity check: one request through the gateway
	$(ANSIBLE_DEV) --tags sanity

# =============================================================================
# ClickHouse Migrations
# =============================================================================

.PHONY: ch-migrate ch-migrate-status
ch-migrate: ## Apply pending ClickHouse schema migrations (golang-migrate via compose)
	@$(COMPOSE_CMD) run --rm migrate up

ch-migrate-status: ## Show ClickHouse schema migration status (golang-migrate version)
	@$(COMPOSE_CMD) run --rm migrate version

# =============================================================================
# Model Sync
# =============================================================================

sync-models: ## Sync models from gateway into opencode config
	bash $(REPO_ROOT)/res/scripts/sync-opencode-models.sh

# OpenBao-backed virtual key management
# =============================================================================
# Key Management
# =============================================================================
.PHONY: issue-key list-keys revoke-key

issue-key: ## Issue a new virtual gateway key (use KEY_ID=, TENANT_ID=, USER_ID=)
	@bash $(REPO_ROOT)/res/scripts/issue-key.sh $(if $(KEY_ID),--key-id $(KEY_ID)) $(if $(TENANT_ID),--tenant $(TENANT_ID)) $(if $(USER_ID),--user $(USER_ID)) $(if $(UPSTREAM_KEY),--upstream-key $(UPSTREAM_KEY))

list-keys: ## List all virtual gateway keys
	@bash $(REPO_ROOT)/res/scripts/list-keys.sh

revoke-key: ## Revoke a virtual gateway key (KEY_ID=vgw-xxx required)
	@if [ -z "$(KEY_ID)" ]; then echo "ERROR: KEY_ID required. Usage: make revoke-key KEY_ID=vgw-xxx" >&2; exit 1; fi
	@bash $(REPO_ROOT)/res/scripts/revoke-key.sh $(KEY_ID)

# =============================================================================
# Quality Gates
# =============================================================================
.PHONY: check lint type-check test test-live check-push

lint: ## Lint shell scripts and validate YAML
	@echo "=== Linting shell scripts ==="
	@for f in $$(find . -name '*.sh' -not -path './.git/*'); do \
		echo "  checking $$f"; \
		bash -n "$$f" || { echo "FAIL: $$f"; exit 1; }; \
	done
	@echo "=== Validating YAML ==="
	@tmpfile=$$(mktemp); trap 'rm -f $$tmpfile' EXIT; \
	for f in conf/*.yaml res/docker/*.yml res/ansible/*.yml; do \
		[ -f "$$f" ] || continue; \
		echo "  checking $$f"; \
		podman run --rm \
			-e 'LUA_PATH=/usr/local/apisix/deps/share/lua/5.1/?.lua;/usr/local/apisix/deps/share/lua/5.1/?/init.lua;;' \
			-e 'LUA_CPATH=/usr/local/apisix/deps/lib/lua/5.1/?.so;;' \
			-v "$(PWD)/$$f:/check.yaml:ro" \
			--entrypoint /usr/local/openresty/luajit/bin/luajit \
			apache/apisix:3.17.0-debian \
			-e 'local y=require("lyaml"); local f=io.open("/check.yaml"); if not f then io.stderr:write("cannot open\n"); os.exit(1) end; y.load(f:read("*a")); f:close()' \
			2>$$tmpfile || { echo "FAIL: $$f"; cat $$tmpfile 1>&2; exit 1; }; \
	done; \
	rm -f $$tmpfile

type-check: ## Lua syntax check via resty in Podman
	@echo "=== Lua syntax check ==="
	@for f in plugins/custom/*.lua; do \
		[ -f "$$f" ] || continue; \
		echo "  checking $$f"; \
		podman run --rm \
			-v "$(PWD)/plugins/custom:/plugins/custom:ro" \
			--entrypoint /usr/bin/resty \
			apache/apisix:3.17.0-debian \
			-e "local f, err = loadfile('/plugins/custom/$$(basename $$f)'); if not f then error(err) end" \
			|| { echo "FAIL: $$f"; exit 1; }; \
	done

test: ## Run all test stages (excludes live upstream API tests)
	@if [ -f .env ]; then set -a; source .env; set +a; fi; \
	bash tests/run_all.sh

test-live: ## Run all tests including live upstream API tests (RUN_LIVE_API_TESTS=1)
	@if [ -f .env ]; then set -a; source .env; set +a; fi; \
	RUN_LIVE_API_TESTS=1 bash tests/run_all.sh

check: lint type-check test ## Run all quality gates
	@echo "=== All checks passed ==="

check-push: check ## Pre-push gate: check + E2E if API key available
	@if [ -n "$$OPENCODE_API_KEY" ]; then \
		echo "=== Running E2E tests ==="; \
		bash tests/e2e/run.sh; \
	else \
		echo "=== OPENCODE_API_KEY not set, skipping E2E ==="; \
	fi

# Boot persistence via systemd user unit + Ansible
# =============================================================================
# Boot Persistence
# =============================================================================
.PHONY: gateway-deploy gateway-start gateway-stop gateway-restart gateway-status gateway-undeploy gateway-logs

gateway-deploy: ## Install + enable gateway compose on boot (systemd user + linger)
	$(ANSIBLE_COMPOSE) --tags deploy

gateway-start: ## Start gateway compose via systemd
	$(ANSIBLE_COMPOSE) --tags start

gateway-stop: ## Stop gateway compose via systemd
	$(ANSIBLE_COMPOSE) --tags stop

gateway-restart: ## Restart gateway compose via systemd
	$(ANSIBLE_COMPOSE) --tags restart

gateway-status: ## Show gateway systemd + container status
	$(ANSIBLE_COMPOSE) --tags status

gateway-undeploy: ## Disable + remove gateway compose systemd unit
	$(ANSIBLE_COMPOSE) --tags undeploy

gateway-logs: ## Tail gateway compose logs
	journalctl --user -u gateway-compose -f

# =============================================================================
# Cleanup
# =============================================================================
.PHONY: clean clean-precommit
clean: ## Remove build artifacts
	@:

clean-precommit: ## Remove pre-commit framework traces
	bash $(CI_DIR)/scripts/cleanup-precommit
