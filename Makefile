# Makefile for WORKSPACE-GATEWAY
#
# Quality gates: lint, type-check, test, check, check-push.

SHELL := /bin/bash
.DEFAULT_GOAL := help

REPO_ROOT := $(shell git rev-parse --show-toplevel || pwd)
CI_DIR := $(abspath $(REPO_ROOT)/../CI)

-include $(CI_DIR)/lib/makefile_contract.mk

# =============================================================================
# Help
# =============================================================================
.PHONY: help
help: ## Show this help
	@grep -hE '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

# =============================================================================
# Setup
# =============================================================================
.PHONY: preflight init install install-ci install-deps install-hooks sync setup bootstrap-podman
preflight: ## Verify environment
	@test -d "$(CI_DIR)" || { echo "ERROR: CI directory not found at $(CI_DIR)" >&2; exit 1; }
	@test -f "$(CI_DIR)/scripts/generate-hooks" || { echo "ERROR: generate-hooks missing" >&2; exit 1; }
	@echo "Preflight OK"

setup: bootstrap-podman ## Install podman + create .venv with podman-compose
	@echo "=== Creating .venv ==="
	@if [ ! -d .venv ]; then uv venv .venv; else echo "  .venv already exists"; fi
	@uv pip install --python .venv podman-compose
	@echo "=== Setup complete ==="
	@_podman="$$(command -v podman)" || _podman="NOT FOUND"; echo "  podman: $$_podman"
	@echo "  podman-compose: .venv/bin/podman-compose"

bootstrap-podman: ## Install podman binaries if not on PATH
	@command -v podman >/dev/null 2>&1 || { \
		echo "=== Bootstrapping podman ==="; \
		bash $(CI_DIR)/scripts/bootstrap-podman; \
	}

init: setup ## Install system-level dependencies
install: setup install-hooks ## Full install: podman + .venv + hooks
install-ci: install-deps ## CI install: deps only, no hooks
install-deps: setup ## Install project dependencies

install-hooks: ## (Re)generate native git hooks
	bash $(CI_DIR)/scripts/generate-hooks

sync: install-deps install-hooks ## Sync deps + reinstall hooks

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
	@for f in conf/*.yaml res/docker/*.yml; do \
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
	@bash tests/run_all.sh

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