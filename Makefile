# Makefile for WORKSPACE-GATEWAY
#
# Quality gates: lint, type-check, test, check, check-push.
# Dev lifecycle: fully automated via Ansible (res/ansible/dev.yml).
# Pattern follows WORKSPACE-PORTAL: Makefile delegates to ansible-playbook.

SHELL := /bin/bash
.DEFAULT_GOAL := help

REPO_ROOT := $(shell git rev-parse --show-toplevel || pwd)
CI_DIR := $(abspath $(REPO_ROOT)/../CI)
COMPOSE_FILE := $(REPO_ROOT)/res/docker/docker-compose.yml
VENV_BIN := $(REPO_ROOT)/.venv/bin
ANSIBLE_PLAYBOOK := ansible-playbook
ANSIBLE_DEV := $(ANSIBLE_PLAYBOOK) $(REPO_ROOT)/res/ansible/dev.yml

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
.PHONY: preflight bootstrap-podman setup install install-ci install-deps install-hooks sync

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
	@echo "=== Building container images ==="
	@$(VENV_BIN)/podman-compose -f $(COMPOSE_FILE) build
	@echo "=== Install complete ==="
	@echo "Run 'make dev-start' to start the gateway stack."

install-ci: install-deps ## CI install: deps only, no hooks
install-deps: setup ## Install project dependencies

install-hooks: ## (Re)generate native git hooks
	bash $(CI_DIR)/scripts/generate-hooks

sync: install-deps install-hooks ## Sync deps + reinstall hooks

# =============================================================================
# Dev Lifecycle (via Ansible)
# =============================================================================
.PHONY: dev-start dev-stop dev-restart dev-rebuild dev-logs dev-status \
        dev-clean dev-shell dev-reset-db dev-test dev-smoke

dev-start: ## Start the gateway stack (Ansible-managed)
	$(ANSIBLE_DEV) --tags start

dev-stop: ## Stop the gateway stack (keep volumes)
	$(ANSIBLE_DEV) --tags stop

dev-restart: ## Restart the gateway stack (stop + start)
	$(ANSIBLE_DEV) --tags stop
	$(ANSIBLE_DEV) --tags start

dev-rebuild: ## Rebuild images and restart
	$(ANSIBLE_DEV) --tags stop
	$(ANSIBLE_DEV) --tags start

dev-logs: ## Tail container logs (Ctrl-C to stop)
	$(ANSIBLE_DEV) --tags logs

dev-status: ## Show running containers and health status
	$(ANSIBLE_DEV) --tags status

dev-clean: ## Stop stack and remove all volumes (data loss!)
	$(ANSIBLE_DEV) --tags clean

dev-shell: ## Exec into APISIX container shell
	@podman exec -it docker_apisix_1 /bin/bash

dev-reset-db: ## Reset ClickHouse (drop + recreate tables)
	$(ANSIBLE_DEV) --tags reset-db

dev-test: ## Run full test suite against running stack
	$(ANSIBLE_DEV) --tags test

dev-smoke: ## Quick smoke test: one request through the gateway
	$(ANSIBLE_DEV) --tags smoke

sync-models: ## Sync models from gateway into opencode config
	bash $(REPO_ROOT)/res/scripts/sync-opencode-models.sh

# =============================================================================
# Key Management (OpenBao-backed virtual keys)
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
.PHONY: check lint type-check test check-push

lint: ## Lint shell scripts and validate YAML
	@echo "=== Linting shell scripts ==="
	@for f in $$(find . -name '*.sh' -not -path './.git/*'); do \
		echo "  checking $$f"; \
		bash -n "$$f" || { echo "FAIL: $$f"; exit 1; }; \
	done
	@echo "=== Validating YAML ==="
	@for f in conf/*.yaml res/docker/*.yml res/ansible/*.yml; do \
		[ -f "$$f" ] || continue; \
		echo "  checking $$f"; \
		python3 -c "import yaml; yaml.safe_load(open('$$f'))" || { echo "FAIL: $$f"; exit 1; }; \
	done

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

test: ## Run all test stages (1-5; 6 if Zen key set)
	@if [ -f .env ]; then set -a; source .env; set +a; fi; \
	bash tests/run_all.sh

check: lint type-check test ## Run all quality gates
	@echo "=== All checks passed ==="

check-push: check ## Pre-push gate: check + E2E if Zen key available
	@if [ -n "$$OPENCODE_ZEN_API_KEY" ]; then \
		echo "=== Running E2E tests ==="; \
		bash tests/e2e/run.sh; \
	else \
		echo "=== OPENCODE_ZEN_API_KEY not set, skipping E2E ==="; \
	fi

# =============================================================================
# Cleanup
# =============================================================================
.PHONY: clean clean-precommit
clean: ## Remove build artifacts
	@:

clean-precommit: ## Remove pre-commit framework traces
	bash $(CI_DIR)/scripts/cleanup-precommit
