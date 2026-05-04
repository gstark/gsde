APP_NAME := GSDE
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

.PHONY: build libghostty cef app app-with-ghostty app-with-chromium run run-cef run-cef-two-browsers run-foreground run-cef-foreground smoke-cef reset-state clean

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
	open -n --env GSDE_ENABLE_CEF=1 $(BUNDLE_DIR)

run-cef-two-browsers: app-with-chromium
	rm -f "$$HOME/Library/Application Support/GSDE/Chromium/SingletonLock" "$$HOME/Library/Application Support/GSDE/Chromium/SingletonCookie" "$$HOME/Library/Application Support/GSDE/Chromium/SingletonSocket"
	open -n --env GSDE_ENABLE_CEF=1 --env GSDE_BROWSER_PANES=2 $(BUNDLE_DIR)

run-foreground: app
	$(MACOS_DIR)/$(APP_NAME)

run-cef-foreground: app-with-chromium
	rm -f "$$HOME/Library/Application Support/GSDE/Chromium/SingletonLock" "$$HOME/Library/Application Support/GSDE/Chromium/SingletonCookie" "$$HOME/Library/Application Support/GSDE/Chromium/SingletonSocket"
	GSDE_ENABLE_CEF=1 GSDE_BROWSER_PANES=$${GSDE_BROWSER_PANES:-1} $(MACOS_DIR)/$(APP_NAME)

smoke-cef: app-with-chromium
	./scripts/smoke-test-cef.sh

reset-state:
	./scripts/reset-state.sh

clean:
	rm -rf .build build
