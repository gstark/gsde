APP_NAME := GSDE
APP_VERSION ?= 0.1.0
APP_BUILD ?= $(shell git rev-list --count HEAD 2>/dev/null || echo 1)
SWIFT_PRODUCT := GSDEApp
CHROMIUM_HELPER_PRODUCT := GSDEChromiumHelper
CONFIG := release
BUNDLE_DIR := build/$(APP_NAME).app
CONTENTS_DIR := $(BUNDLE_DIR)/Contents
MACOS_DIR := $(CONTENTS_DIR)/MacOS
FRAMEWORKS_DIR := $(CONTENTS_DIR)/Frameworks
CHROMIUM_HELPER_BUNDLE := $(FRAMEWORKS_DIR)/$(APP_NAME) Helper.app
CHROMIUM_HELPER_MACOS_DIR := $(CHROMIUM_HELPER_BUNDLE)/Contents/MacOS
BINARY := .build/$(CONFIG)/$(SWIFT_PRODUCT)
CHROMIUM_HELPER_BINARY := .build/$(CONFIG)/$(CHROMIUM_HELPER_PRODUCT)
BUILT_LIBGHOSTTY := build/libghostty/libghostty.dylib
CEF_FRAMEWORK := external/cef/Release/Chromium Embedded Framework.framework

.PHONY: build libghostty cef app app-with-ghostty app-with-chromium run run-cef run-cef-two-browsers run-cef-four-browsers run-foreground run-cef-foreground smoke-default smoke-cef smoke-cef-custom-urls smoke-cef-four smoke-cef-graceful smoke-cef-repeat verify-cef-bundle verify-cef verify release release-adhoc release-signed release-notarized sign-release notarize-release reset-state clean

build:
	swift build -c $(CONFIG)

libghostty:
	./scripts/build-libghostty.sh

cef:
	./scripts/fetch-cef.sh

app: build
	rm -rf $(BUNDLE_DIR)
	mkdir -p $(MACOS_DIR) $(FRAMEWORKS_DIR)
	cp $(BINARY) $(MACOS_DIR)/$(APP_NAME)
	cp Info.plist $(CONTENTS_DIR)/Info.plist
	/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $(APP_VERSION)" $(CONTENTS_DIR)/Info.plist
	/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(APP_BUILD)" $(CONTENTS_DIR)/Info.plist
	if [ -n "$$LIBGHOSTTY_PATH" ]; then cp "$$LIBGHOSTTY_PATH" $(FRAMEWORKS_DIR)/libghostty.dylib; elif [ -f "$(BUILT_LIBGHOSTTY)" ]; then cp "$(BUILT_LIBGHOSTTY)" $(FRAMEWORKS_DIR)/libghostty.dylib; fi
	if [ -d "$(CEF_FRAMEWORK)" ]; then cp -R "$(CEF_FRAMEWORK)" $(FRAMEWORKS_DIR)/; fi
	./scripts/package-cef-helper.sh "$(CHROMIUM_HELPER_BINARY)" "$(FRAMEWORKS_DIR)" "$(APP_NAME)" "personal.gsde"
	chmod +x $(MACOS_DIR)/$(APP_NAME)

app-with-ghostty: libghostty app

app-with-chromium: cef app

run: app
	open $(BUNDLE_DIR)

run-cef: app-with-chromium
	rm -f "$$HOME/Library/Application Support/GSDE/Chromium/SingletonLock" "$$HOME/Library/Application Support/GSDE/Chromium/SingletonCookie" "$$HOME/Library/Application Support/GSDE/Chromium/SingletonSocket"
	if [ -n "$$GSDE_BROWSER_URLS" ]; then open -n --env GSDE_ENABLE_CEF=1 --env GSDE_BROWSER_PANES=$${GSDE_BROWSER_PANES:-1} --env GSDE_BROWSER_URLS="$$GSDE_BROWSER_URLS" $(BUNDLE_DIR); else open -n --env GSDE_ENABLE_CEF=1 --env GSDE_BROWSER_PANES=$${GSDE_BROWSER_PANES:-1} $(BUNDLE_DIR); fi

run-cef-two-browsers:
	GSDE_BROWSER_PANES=2 $(MAKE) run-cef

run-cef-four-browsers:
	GSDE_BROWSER_PANES=4 $(MAKE) run-cef

run-foreground: app
	$(MACOS_DIR)/$(APP_NAME)

run-cef-foreground: app-with-chromium
	rm -f "$$HOME/Library/Application Support/GSDE/Chromium/SingletonLock" "$$HOME/Library/Application Support/GSDE/Chromium/SingletonCookie" "$$HOME/Library/Application Support/GSDE/Chromium/SingletonSocket"
	GSDE_ENABLE_CEF=1 GSDE_BROWSER_PANES=$${GSDE_BROWSER_PANES:-1} $(MACOS_DIR)/$(APP_NAME)

smoke-default: app
	./scripts/smoke-test-default.sh

smoke-cef: app-with-chromium
	./scripts/smoke-test-cef.sh

smoke-cef-custom-urls: app-with-chromium
	GSDE_BROWSER_PANES=2 GSDE_BROWSER_URLS="https://example.com,https://www.iana.org/domains/reserved" GSDE_EXPECT_URL_SUBSTRINGS="example.com,iana.org" ./scripts/smoke-test-cef.sh

smoke-cef-four: app-with-chromium
	GSDE_BROWSER_PANES=4 GSDE_SMOKE_WAIT_SECONDS=60 ./scripts/smoke-test-cef.sh

smoke-cef-graceful: app-with-chromium
	GSDE_BROWSER_PANES=2 GSDE_SMOKE_GRACEFUL_QUIT=1 ./scripts/smoke-test-cef.sh

smoke-cef-repeat: app-with-chromium
	for run in 1 2; do GSDE_BROWSER_PANES=2 GSDE_SMOKE_GRACEFUL_QUIT=1 ./scripts/smoke-test-cef.sh; done

verify-cef-bundle: app-with-chromium
	./scripts/verify-cef-bundle.sh "$(BUNDLE_DIR)"

verify-cef: verify-cef-bundle smoke-cef smoke-cef-custom-urls smoke-cef-four smoke-cef-graceful smoke-cef-repeat

verify: smoke-default verify-cef

release: app-with-chromium verify-cef-bundle
	./scripts/package-release.sh "$(BUNDLE_DIR)"

release-adhoc: app-with-chromium verify-cef-bundle
	GSDE_ADHOC_SIGN=1 ./scripts/package-release.sh "$(BUNDLE_DIR)"

release-signed: app-with-chromium verify-cef-bundle
	./scripts/sign-release.sh "$(BUNDLE_DIR)"
	./scripts/package-release.sh "$(BUNDLE_DIR)"

release-notarized: release-signed
	./scripts/notarize-release.sh "$$(cat dist/latest-release.txt)"

sign-release: app-with-chromium verify-cef-bundle
	./scripts/sign-release.sh "$(BUNDLE_DIR)"

notarize-release:
	./scripts/notarize-release.sh "$${GSDE_RELEASE_ARCHIVE:?Set GSDE_RELEASE_ARCHIVE=dist/GSDE-...zip}"

reset-state:
	./scripts/reset-state.sh

clean:
	rm -rf .build build
