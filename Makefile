# MacSCP — common development tasks
#
# Usage:
#   make              # show targets
#   make build test   # compile and run tests (42 tests)
#   make run          # launch MacSCP (starts local SFTP fixture first)

SWIFT       ?= swift
ROOT        := $(dir $(abspath $(lastword $(MAKEFILE_LIST))))
SCRIPTS     := $(ROOT)scripts
BENCH_ENV   := $(SCRIPTS)/benchmark-env.sh
RUN_BENCH   := $(SCRIPTS)/run-benchmarks.sh
CONFIG      := $(HOME)/.macscp/config.toml
LOG_DIR     := $(HOME)/.macscp/logs

.PHONY: help build build-release test check clean run \
        server-start server-stop server-restart server-status \
        bench bench-full bench-upload-spike \
        build-release check package-dmg icon \
        logs config paths

.DEFAULT_GOAL := help

help: ## Show this help
	@grep -E '^[a-zA-Z0-9_.-]+:.*##' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'

build: ## Build all targets (debug)
	$(SWIFT) build

build-release: ## Build optimized release binaries
	$(SWIFT) build -c release

test: build ## Run unit tests (39 XCTest + 3 Swift Testing)
	$(SWIFT) test

check: build test ## Build + test (CI-friendly)

clean: ## Remove build artifacts
	$(SWIFT) package clean
	rm -rf .build

run: server-start ## Run MacSCP app (starts local SFTP on :2222)
	$(SWIFT) run MacSCP

server-start: ## Start local OpenSSH SFTP test server (port 2222)
	$(BENCH_ENV) start

server-stop: ## Stop local SFTP test server
	$(BENCH_ENV) stop

server-restart: ## Restart local SFTP test server
	$(BENCH_ENV) restart

server-status: ## Check whether local SFTP test server is listening
	$(BENCH_ENV) status

bench: server-start ## Run SFTP benchmark suite (quick mode)
	$(RUN_BENCH)

bench-full: server-start ## Run full benchmark suite (1 MB / 100 MB / 1 GB, 10k files)
	MACSCP_BENCH_FULL=1 $(RUN_BENCH)

bench-upload-spike: server-start ## Citadel vs Traversio vs OpenSSH upload comparison
	$(SWIFT) run macscp-benchmark upload-spike

icon: ## Generate AppIcon.icns and populate Xcode asset catalog
	$(SCRIPTS)/generate-app-icon.sh

package-dmg: ## Build signed .app bundle and dist/MacSCP-<version>.dmg
	$(SCRIPTS)/package-dmg.sh

logs: ## Tail today's MacSCP log file (~/.macscp/logs)
	@mkdir -p "$(LOG_DIR)"
	@LOG="$(LOG_DIR)/macscp-$$(date +%Y-%m-%d).log"; \
	if [ -f "$$LOG" ]; then tail -f "$$LOG"; \
	else echo "No log yet: $$LOG (launch the app or enable logging in config.toml)"; fi

config: ## Show ~/.macscp/config.toml path and contents
	@echo "Config: $(CONFIG)"
	@if [ -f "$(CONFIG)" ]; then cat "$(CONFIG)"; \
	else echo "(not created yet — run the app once; see docs/user-guide.md §5.4)"; fi

paths: ## Print runtime paths (config, logs, profiles, known hosts)
	@echo "Config:     $(CONFIG)"
	@echo "Logs:       $(LOG_DIR)/"
	@echo "Profiles:   $(HOME)/Library/Application Support/MacSCP/profiles.json"
	@echo "Known hosts: $(HOME)/.macscp/known_hosts.json"
	@echo "Benchmark:  $(ROOT).benchmark/ (local SFTP fixture on :2222)"
