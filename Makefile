.PHONY: help test app run uitest uitest-update uitest-foreground parity docs-check

help: ## List the common commands
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-20s %s\n", $$1, $$2}'

test: ## Run the unit tests
	swift test

app: ## Build build/Loom.app, optimized
	CONFIG=release scripts/bundle.sh

run: app ## Build and open the app
	open build/Loom.app

uitest: ## Run the UI scenarios without taking focus
	CONFIG=release SWIFT_FLAGS="-Xswiftc -DDEBUG" scripts/bundle.sh
	python3 tests/ui/run.py $(ARGS)

uitest-foreground: ## Also run the scenarios that need a key window
	CONFIG=release SWIFT_FLAGS="-Xswiftc -DDEBUG" scripts/bundle.sh
	python3 tests/ui/run.py --foreground $(ARGS)

uitest-update: ## Accept current screens as the visual baselines
	python3 tests/ui/run.py --only appearance --update

parity: ## Fail if docs/parity.md claims a capability no scenario covers
	python3 tests/ui/parity_check.py
