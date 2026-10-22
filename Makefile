# yap
#
#   make run    build, install to /Applications and launch
#   make test   Core unit tests

SCHEME    := Yap
PROJECT   := Yap.xcodeproj
CONFIG    := Debug
ARCH      := $(shell uname -m)
# Build into the repo rather than DerivedData, so the app has a fixed path.
DERIVED   := .build/xcode
BUILT     := $(DERIVED)/Build/Products/$(CONFIG)/Yap.app
INSTALLED := /Applications/Yap.app

.DEFAULT_GOAL := help
.PHONY: help run build generate test kill logs clean

help: ## Show this help
	@awk -F'##' '/^[a-z][a-z-]*:.*##/ { split($$1, a, ":"); printf "  \033[1m%-9s\033[0m %s\n", a[1], $$2 }' $(MAKEFILE_LIST)

# Always launched from /Applications. A permission grant follows the bundle, so
# a copy anywhere else is a separate app that has to be granted again.
run: build ## Build, install to /Applications and launch
	@pkill -x Yap 2>/dev/null || true
	@rm -rf "$(INSTALLED)"
	@cp -R "$(BUILT)" "$(INSTALLED)"
	@open "$(INSTALLED)"
	@echo "launched $(INSTALLED)"

build: generate ## Build the app
	@xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) \
		-destination 'platform=macOS,arch=$(ARCH)' \
		-derivedDataPath $(DERIVED) -quiet build

generate: ## Regenerate Yap.xcodeproj from project.yml (cached)
	@xcodegen generate --quiet --use-cache

test: ## Run the Core unit tests
	@cd Packages/Core && swift test

kill: ## Quit Yap
	@pkill -x Yap 2>/dev/null && echo "stopped Yap" || true

logs: ## Stream Yap's log output
	@log stream --style compact --predicate 'process == "Yap"'

clean: ## Remove build products and the generated project
	@rm -rf .build Packages/Core/.build $(PROJECT)
