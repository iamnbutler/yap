# yap
#
#   make run    build, install to /Applications and launch
#   make test   Core unit tests
#   make ios    build the iPhone app and keyboard for the simulator
#   make testflight  archive the iPhone app and upload it to TestFlight
#   make release VERSION=0.1.0  sign, notarize and publish the Mac app

SCHEME    := Yap
PROJECT   := Yap.xcodeproj
CONFIG    := Debug
ARCH      := $(shell uname -m)
# Build into the repo rather than DerivedData, so the app has a fixed path.
DERIVED   := .build/xcode
BUILT     := $(DERIVED)/Build/Products/$(CONFIG)/Yap.app
INSTALLED := /Applications/Yap.app

.DEFAULT_GOAL := help
.PHONY: help run build generate test kill logs clean ios testflight release

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

# The notarytool keychain profile. "hob" holds the team's App Store Connect
# credentials, which notarize any app of team 8S43JJMN6B.
NOTARY_PROFILE ?= hob

# Releases are cut from a pushed tag on main, so the GitHub release, its tag
# and the zip all name the same commit. The zip is stapled, so a download
# opens without a Gatekeeper prompt even offline.
release: check-root ## Sign, notarize and publish the Mac app (VERSION=0.1.0)
	@test -n "$(VERSION)" || { echo "usage: make release VERSION=0.1.0"; exit 1; }
	@test -z "$$(git status --porcelain)" || { echo "error: uncommitted changes"; exit 1; }
	@git fetch -q origin tag v$(VERSION) 2>/dev/null || { echo "error: push tag v$(VERSION) to origin first"; exit 1; }
	@test "$$(git rev-parse v$(VERSION)^{commit})" = "$$(git rev-parse HEAD)" || { echo "error: v$(VERSION) is not HEAD"; exit 1; }
	@NOTARY_PROFILE=$(NOTARY_PROFILE) scripts/release.sh $(VERSION) dist
	@gh release create v$(VERSION) dist/Yap-$(VERSION).zip --verify-tag --title "Yap $(VERSION)" \
		$(if $(NOTES),--notes-file "$(NOTES)",--generate-notes)

test: check-root ## Run the Core unit tests
	@cd Packages/Core && swift test

kill: ## Quit Yap
	@pkill -x Yap 2>/dev/null && echo "stopped Yap" || true

logs: ## Stream Yap's log output
	@log stream --style compact --predicate 'process == "Yap"'

clean: ## Remove build products and the generated project
	@rm -rf .build Packages/Core/.build $(PROJECT) dist
