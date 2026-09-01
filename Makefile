.PHONY: clean debug release
.DEFAULT_GOAL := help

PROJECT_DIR := .
PROJECT := $(PROJECT_DIR)/SnapRead.xcodeproj
SCHEME := SnapRead
DERIVED_DATA := $(PROJECT_DIR)/build

help: ## Show this help message
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-15s\033[0m %s\n", $$1, $$2}'

clean: ## Clean the build artifacts
	rm -rf "$(DERIVED_DATA)" "$(PROJECT)"

debug: ## Build the project in Debug configuration
	cd "$(PROJECT_DIR)" && xcodegen generate
	xcodebuild -project "$(PROJECT)" -scheme "$(SCHEME)" \
		-configuration Debug -derivedDataPath "$(DERIVED_DATA)" build

release: ## Build the project in Release configuration
	cd "$(PROJECT_DIR)" && xcodegen generate
	xcodebuild -project "$(PROJECT)" -scheme "$(SCHEME)" \
		-configuration Release -derivedDataPath "$(DERIVED_DATA)" build
