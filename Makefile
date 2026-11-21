# Applebot: build and deploy the iPhone app.
#
#   make sim       build, install and launch on the iOS Simulator
#   make device    build, sign, install and launch on your connected iPhone
#   make devices   list iPhones/iPads this Mac can see
#   make test      run all portable tests in Docker (no host dependencies)
#
# Why these run on the host: Xcode, the Simulator and device signing cannot run in a container.
# Everything that can run in Docker (tests, docs, site) does: see docker-compose.yml.
#
# Overrides (command line or .env):
#   SIM_NAME   simulator to use                    (default: iPhone 17 Pro)
#   DEVICE     device name or UDID                 (default: the only connected iPhone)
#   TEAM_ID    Apple Developer team for signing    (default: detected from Xcode)
#   MOCK=1     launch with the mock engine instead of Apple Intelligence (UI demo / no model needed)
#   GOOGLE_CLIENT_ID  Google OAuth client ID that enables the Gmail connector (see docs/connectors.md)
#   BRAVE_API_KEY     Brave Search API key that enables the Web search connector (see docs/connectors.md)

-include .env
export

SHELL          := /bin/bash
.DEFAULT_GOAL  := help

BUNDLE_ID      ?= dev.kekaflow.applebot
SCHEME         ?= Applebot
SIM_NAME       ?= iPhone 17 Pro
DEVICE         ?=
MOCK           ?= 0

IOS_DIR        := ios
PROJECT        := $(IOS_DIR)/Applebot.xcodeproj
BUILD_DIR      := build
SIM_DERIVED    := $(BUILD_DIR)/DerivedData-sim
DEV_DERIVED    := $(BUILD_DIR)/DerivedData-device
SIM_APP        := $(SIM_DERIVED)/Build/Products/Debug-iphonesimulator/Applebot.app
DEV_APP        := $(DEV_DERIVED)/Build/Products/Debug-iphoneos/Applebot.app

# Signing team: explicit TEAM_ID wins, otherwise the first team Xcode knows about.
TEAM_ID ?= $(shell defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier 2>/dev/null \
             | awk '/teamID/ { gsub(/[;" ]/, "", $$3); print $$3; exit }')

LAUNCH_ARGS := $(if $(filter 1,$(MOCK)),-UITestMockEngine,)

.PHONY: help project sim device devices test clean check-xcode

help: ## Show this help
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z_-]+:.*## / {printf "  \033[36mmake %-9s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)
	@echo
	@echo "Options: SIM_NAME=\"iPhone 17\"  DEVICE=\"<name|UDID>\"  TEAM_ID=XXXXXXXXXX  MOCK=1"

check-xcode:
	@command -v xcodebuild >/dev/null || { echo "Xcode is required (xcode-select --install, then install Xcode 26)."; exit 1; }
	@command -v xcodegen  >/dev/null || { echo "XcodeGen is required: brew install xcodegen"; exit 1; }

project: check-xcode ## Generate the Xcode project (applies your signing team)
	@mkdir -p $(BUILD_DIR)
	@if [ -n "$(TEAM_ID)" ]; then \
	  echo "DEVELOPMENT_TEAM = $(TEAM_ID)" > $(IOS_DIR)/Local.xcconfig; \
	else \
	  : > $(IOS_DIR)/Local.xcconfig; \
	fi
	@if [ -n "$(GOOGLE_CLIENT_ID)" ]; then echo "GOOGLE_CLIENT_ID = $(GOOGLE_CLIENT_ID)" >> $(IOS_DIR)/Local.xcconfig; fi
	@if [ -n "$(BRAVE_API_KEY)" ]; then echo "BRAVE_API_KEY = $(BRAVE_API_KEY)" >> $(IOS_DIR)/Local.xcconfig; fi
	@cd $(IOS_DIR) && xcodegen generate --quiet
	@echo "Project ready: $(PROJECT)  (team: $(if $(TEAM_ID),$(TEAM_ID),none: simulator only))"

# ---------------------------------------------------------------- simulator

sim: project ## Build, install and launch on the iOS Simulator
	@set -e; \
	UDID=$$(xcrun simctl list devices available | grep -m1 -F "    $(SIM_NAME) (" | grep -oE '[0-9A-F]{8}-([0-9A-F]{4}-){3}[0-9A-F]{12}' || true); \
	if [ -z "$$UDID" ]; then \
	  echo "Simulator '$(SIM_NAME)' not found. Available iPhones:"; \
	  xcrun simctl list devices available | grep -E "^\s+iPhone" ; exit 1; \
	fi; \
	echo "==> Simulator: $(SIM_NAME) ($$UDID)"; \
	xcrun simctl boot "$$UDID" 2>/dev/null || true; \
	open -a Simulator; \
	echo "==> Building for simulator"; \
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug \
	  -destination "platform=iOS Simulator,id=$$UDID" \
	  -derivedDataPath $(SIM_DERIVED) CODE_SIGNING_ALLOWED=NO -quiet build; \
	echo "==> Installing"; \
	xcrun simctl install "$$UDID" "$(SIM_APP)"; \
	echo "==> Launching $(BUNDLE_ID) $(LAUNCH_ARGS)"; \
	xcrun simctl launch --terminate-running-process "$$UDID" $(BUNDLE_ID) $(LAUNCH_ARGS); \
	echo "Done. Simulators use your Mac's Apple Intelligence model; use MOCK=1 to demo without it."

# ------------------------------------------------------------------- device

devices: ## List iPhones/iPads this Mac can see
	@python3 tools/select_device.py --list

device: project ## Build, sign, install and launch on your connected iPhone
	@set -e; \
	if [ -z "$(TEAM_ID)" ]; then \
	  echo "No signing team found. Sign in to Xcode (Settings > Accounts) or run: make device TEAM_ID=XXXXXXXXXX"; exit 1; \
	fi; \
	UDID=$$(python3 tools/select_device.py "$(DEVICE)"); \
	echo "==> Device: $$UDID   Team: $(TEAM_ID)"; \
	echo "==> Building and signing (first run may take a few minutes)"; \
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug \
	  -destination "id=$$UDID" -derivedDataPath $(DEV_DERIVED) \
	  -allowProvisioningUpdates DEVELOPMENT_TEAM=$(TEAM_ID) -quiet build; \
	echo "==> Installing"; \
	xcrun devicectl device install app --device "$$UDID" "$(DEV_APP)"; \
	echo "==> Launching $(BUNDLE_ID) $(LAUNCH_ARGS)"; \
	xcrun devicectl device process launch --device "$$UDID" --terminate-existing $(BUNDLE_ID) $(LAUNCH_ARGS) \
	  || { echo; echo "Launch failed. Unlock the phone and, on first install, trust the developer:"; \
	       echo "  Settings > General > VPN & Device Management > $(TEAM_ID) > Trust"; exit 1; }; \
	echo "Done. Applebot is running on your iPhone."

# -------------------------------------------------------------------- misc

test: ## Run all portable tests in Docker
	docker compose run --rm test

clean: ## Remove build output and the generated Xcode project
	rm -rf $(BUILD_DIR) $(PROJECT) $(IOS_DIR)/Local.xcconfig $(IOS_DIR)/App/Info.plist .build
