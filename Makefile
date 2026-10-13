# ccserver developer tasks. Run `make` or `make help` for the list.

SHELL := /bin/bash
BOOTSTRAP ?= assets/example/example_server.lua
CARGO ?= cargo

.DEFAULT_GOAL := help

.PHONY: help build check test fmt fmt-check clippy agent-check lint \
        run start stop restart status db-up db-down db-reset test-db test-lua backup verify-backup restore bench \
        cluster-up cluster-down test-multinode cluster-etcd-up test-multinode-etcd smoke clean

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'

build: ## Build the release binary
	$(CARGO) build --release

check: ## Type-check the workspace
	$(CARGO) check --workspace

test: ## Run Rust tests
	$(CARGO) test

fmt: ## Format code
	$(CARGO) fmt

fmt-check: ## Check formatting
	$(CARGO) fmt --check

clippy: ## Run clippy
	$(CARGO) clippy --workspace --all-targets

agent-check: ## Validate the agent memory layer
	$(CARGO) xtask agent-check

lint: fmt-check clippy agent-check ## Format + clippy + agent-check

run: ## Run in the foreground (BOOTSTRAP=...)
	$(CARGO) run --release -- $(BOOTSTRAP)

start: build ## Start in the background (pidfile + logfile)
	scripts/start.sh $(BOOTSTRAP)

stop: ## Stop the background server
	scripts/stop.sh

restart: ## Restart the background server
	scripts/restart.sh $(BOOTSTRAP)

status: ## Show server status
	scripts/status.sh

db-up: ## Start local Redis/MySQL/PostgreSQL/MongoDB (docker compose)
	scripts/db-up.sh

db-down: ## Stop local dependencies (keep data)
	scripts/db-down.sh

db-reset: ## Stop local dependencies and wipe data
	scripts/db-reset.sh

test-db: ## Run database integration tests (needs local deps)
	./target/release/moon_rs assets/test/test_db_stack.lua
	./target/release/moon_rs assets/test/test_migration.lua

test-lua: ## Run Lua integration tests that need no external services
	./target/release/moon_rs assets/test/test_topology.lua
	./target/release/moon_rs assets/test/test_gateway.lua
	./target/release/moon_rs assets/test/test_sharding.lua
	./target/release/moon_rs assets/test/test_failover.lua
	./target/release/moon_rs assets/test/test_config.lua
	./target/release/moon_rs assets/test/test_observability.lua
	./target/release/moon_rs assets/test/test_reliability.lua
	./target/release/moon_rs assets/test/test_hotreload.lua

cluster-up: ## Launch a 2-node local cluster (discovery + node1 + node2)
	scripts/run-cluster.sh

cluster-down: ## Stop the local cluster
	scripts/stop-cluster.sh

test-multinode: build ## Launch the cluster, run the cross-node routing test, stop
	scripts/run-cluster.sh
	sleep 2
	-CCS_BENCH_ADDR=127.0.0.1:9001 ./target/release/moon_rs assets/test/test_multinode.lua
	scripts/stop-cluster.sh

cluster-etcd-up: ## Launch a 2-node cluster with etcd discovery (docker etcd + adapter + nodes)
	scripts/run-cluster-etcd.sh

test-multinode-etcd: build ## etcd cluster + cross-node routing test + stop
	scripts/run-cluster-etcd.sh
	sleep 2
	-CCS_BENCH_ADDR=127.0.0.1:9001 ./target/release/moon_rs assets/test/test_multinode.lua
	scripts/stop-cluster.sh

backup: ## Back up local databases to backups/<timestamp>/
	scripts/backup.sh

verify-backup: ## Verify the newest backup's integrity (size + sha256)
	scripts/verify-backup.sh $(or $(BACKUP),latest)

restore: ## Restore from the newest backup (RESTORE=latest or a timestamp)
	scripts/restore.sh $(or $(RESTORE),latest)

bench: ## Gateway load test (CONN=100 SEC=5 MSG=PING)
	scripts/bench.sh

smoke: build ## End-to-end smoke: start app, check /ready, run a client flow, stop
	scripts/smoke.sh

clean: ## Remove build artifacts
	$(CARGO) clean
