.PHONY: help test sim sim-replay coverage recall core-purity app run uitest uitest-update uitest-foreground parity docs-check

help: ## List the common commands
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-20s %s\n", $$1, $$2}'

sim: ## Run the simulations longer: make sim SIM_RUNS=50000 SIM_SEED=7
	SIM_RUNS=$(or $(SIM_RUNS),20000) SIM_SEED=$(or $(SIM_SEED),1) swift test --filter 'LoomCoreTests.*ModelTests'

sim-replay: ## Replay one seed step by step: make sim-replay MODEL=SessionModelTests SEED=<hex>
	SIM_REPLAY=$(SEED) swift test --filter 'LoomCoreTests.$(MODEL)/testReplay'

coverage: ## Line coverage of the core under the simulations alone
	sh scripts/coverage.sh

recall: ## Blind recall: make recall WT=<scratch worktree outside /tmp>
	sh scripts/recall.sh $(WT)

record: ## Record traces from a real loomd: make record LOOMD_BIN=<loomd> [OUT=Tests/LoomCoreTests/Traces]
	swift build --product loom-probe
	sh scripts/record-traces.sh $(or $(OUT),Tests/LoomCoreTests/Traces)

conformance: ## Regenerate Loom's projection of the traces: make conformance LOOM_CHECKOUT=<loom checkout>
	sh scripts/conformance.sh

core-purity: ## Fail if Sources/LoomCore can block, wait or read a clock
	sh scripts/core-purity.sh

test: core-purity ## Run the unit tests and the simulation
	swift test

app: ## Build build/Loom.app, optimized
	CONFIG=release scripts/bundle.sh

run: app ## Build and open the app
	open build/Loom.app

uitest: ## UI scenarios, no focus taken. Gates only a PR that touches App/Sources or the views (docs/testing.md)
	CONFIG=release SWIFT_FLAGS="-Xswiftc -DDEBUG" scripts/bundle.sh
	python3 tests/ui/run.py $(ARGS)

uitest-foreground: ## Also the scenarios that need a key window. Same gating as uitest
	CONFIG=release SWIFT_FLAGS="-Xswiftc -DDEBUG" scripts/bundle.sh
	python3 tests/ui/run.py --foreground $(ARGS)

uitest-update: ## Accept current screens as the visual baselines
	python3 tests/ui/run.py --only appearance --update

parity: ## Fail if docs/parity.md claims a capability no scenario covers
	python3 tests/ui/parity_check.py
