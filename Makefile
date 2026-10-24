# yap
#
#   make run    build, install to /Applications and launch
#   make test   Core unit tests
#   make ios    build the iPhone app and keyboard for the simulator
#   make testflight  archive the iPhone app and upload it to TestFlight

SCHEME    := Yap
PROJECT   := Yap.xcodeproj
CONFIG    := Debug
ARCH      := $(shell uname -m)
# Build into the repo rather than DerivedData, so the app has a fixed path.
DERIVED   := .build/xcode
BUILT     := $(DERIVED)/Build/Products/$(CONFIG)/Yap.app
INSTALLED := /Applications/Yap.app

.DEFAULT_GOAL := help
.PHONY: help run build generate test kill logs clean ios testflight

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

# A lane is reflinked from the main checkout, so it inherits .build directories
# full of the main checkout's absolute paths, and xcodebuild warns about every
# file in them. Stamping the root and comparing clears them once per checkout.
.PHONY: check-root
check-root:
	@if [ ! -f $(DERIVED)/.root ] || [ "$$(cat $(DERIVED)/.root 2>/dev/null)" != "$(CURDIR)" ]; then \
		rm -rf $(DERIVED) Packages/Core/.build; \
		mkdir -p $(DERIVED); \
		echo "$(CURDIR)" > $(DERIVED)/.root; \
	fi

build: check-root generate ## Build the app
	@xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration $(CONFIG) \
		-destination 'platform=macOS,arch=$(ARCH)' \
		-derivedDataPath $(DERIVED) -quiet build

generate: ## Regenerate Yap.xcodeproj from project.yml (cached)
	@xcodegen generate --quiet --use-cache

IOS_ARCHIVE := .build/release/YapPhone.xcarchive

ios: check-root generate ## Build the iPhone app and keyboard for the simulator
	@xcodebuild -project $(PROJECT) -scheme YapPhone -configuration $(CONFIG) \
		-destination 'generic/platform=iOS Simulator' \
		-derivedDataPath $(DERIVED) -quiet build

# Signs with the account signed in to Xcode (Settings › Accounts): an App Store
# Connect API key fails here with "Authentication failed". The build number is
# bumped past the last upload by the export (manageAppVersionAndBuildNumber).
testflight: check-root generate ## Archive the iPhone app and upload it to TestFlight
	@rm -rf $(IOS_ARCHIVE) .build/release/export
	@xcodebuild -project $(PROJECT) -scheme YapPhone -configuration Release \
		-destination 'generic/platform=iOS' -archivePath $(IOS_ARCHIVE) \
		-allowProvisioningUpdates -quiet archive
	@xcodebuild -exportArchive -archivePath $(IOS_ARCHIVE) \
		-exportOptionsPlist iOS/ExportOptions.plist -exportPath .build/release/export \
		-allowProvisioningUpdates

test: check-root ## Run the Core unit tests
	@cd Packages/Core && swift test

kill: ## Quit Yap
	@pkill -x Yap 2>/dev/null && echo "stopped Yap" || true

logs: ## Stream Yap's log output
	@log stream --style compact --predicate 'process == "Yap"'

clean: ## Remove build products and the generated project
	@rm -rf .build Packages/Core/.build $(PROJECT)
