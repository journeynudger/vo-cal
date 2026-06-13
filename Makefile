# Vo-Cal Makefile — mirrors Beacon's command surface.
.DEFAULT_GOAL := help
SHELL := /bin/bash

# ── Setup ────────────────────────────────────────────────────────────────────

.PHONY: setup
setup: ## Install dev dependencies (Homebrew + uv sync)
	brew bundle
	cd services/api && uv sync

.PHONY: dev
dev: ## Prepare local environment (env file + db if docker is up)
	@[ -f .env ] || cp .env.example .env
	@docker info >/dev/null 2>&1 && $(MAKE) db-start || echo "docker down — skipping local supabase (tests use fakes)"

.PHONY: doctor
doctor: ## Environment diagnostics
	@scripts/doctor.sh

# ── Database (Supabase) ─────────────────────────────────────────────────────

.PHONY: db-start
db-start: ## Start local Supabase (requires docker)
	supabase start

.PHONY: db-stop
db-stop: ## Stop local Supabase
	supabase stop

.PHONY: db-migrate
db-migrate: ## Apply migrations (USER-RUN ONLY — agents must not invoke)
	supabase db push

.PHONY: db-reset
db-reset: ## Destructive reset — requires ALLOW_DB_RESET=1
ifndef ALLOW_DB_RESET
	$(error db-reset is destructive. Run: ALLOW_DB_RESET=1 make db-reset)
endif
	supabase db reset

# ── API ──────────────────────────────────────────────────────────────────────

.PHONY: api-dev
api-dev: ## Run API on :8000 (logs to .logs/api-dev.log)
	@mkdir -p .logs
	cd services/api && uv run uvicorn api.main:app --factory --reload --port 8000 2>&1 | tee ../../.logs/api-dev.log

.PHONY: api-check
api-check: ## Lint + tests for the API
	@scripts/check-api

.PHONY: api-test
api-test: ## API tests only
	cd services/api && uv run pytest -q

# ── iOS ──────────────────────────────────────────────────────────────────────

.PHONY: ios-generate
ios-generate: ## Generate VoCal.xcodeproj from project.yml
	cd apps/ios && xcodegen generate

.PHONY: ios-env
ios-env: ## Generate Environment.generated.swift from .env
	scripts/generate_ios_env.sh

.PHONY: ios-check
ios-check: ## Compile check, no simulator (bin/ios-app-build)
	@bin/ios-app-build

.PHONY: ios-sim
ios-sim: ios-generate ## Build & run on the simulator
	cd apps/ios && xcodebuild -project VoCal.xcodeproj -scheme VoCal \
		-destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
		-derivedDataPath ../../DerivedData/ios-sim build | xcbeautify --quiet
	xcrun simctl boot "iPhone 17 Pro" 2>/dev/null || true
	xcrun simctl install "iPhone 17 Pro" DerivedData/ios-sim/Build/Products/Debug-iphonesimulator/VoCal.app
	xcrun simctl launch "iPhone 17 Pro" com.vocal.app

# ── Quality gates ────────────────────────────────────────────────────────────

.PHONY: check
check: ## SPM tests + API checks (blind to the iOS app — see AGENTS.md tiers)
	@scripts/check

.PHONY: metrics
metrics: ## Live metrics dashboard (TUI)
	@scripts/metrics-dashboard

# ── Task tracking ────────────────────────────────────────────────────────────

.PHONY: todo
todo: ## List tasks
	@scripts/todo list

.PHONY: todo-next
todo-next: ## Highest-priority unblocked task
	@scripts/todo next

.PHONY: todo-status
todo-status: ## Progress summary
	@scripts/todo status

# ── Help ─────────────────────────────────────────────────────────────────────

.PHONY: help
help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'
