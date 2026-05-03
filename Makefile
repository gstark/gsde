APP_NAME := GSDE
SWIFT_PRODUCT := GSDEApp
CHROMIUM_HELPER_PRODUCT := GSDEChromiumHelper
CONFIG := release
BUNDLE_DIR := build/$(APP_NAME).app
CONTENTS_DIR := $(BUNDLE_DIR)/Contents
MACOS_DIR := $(CONTENTS_DIR)/MacOS
FRAMEWORKS_DIR := $(CONTENTS_DIR)/Frameworks
CHROMIUM_HELPER_BUNDLE := $(FRAMEWORKS_DIR)/GSDE Chromium Helper.app
CHROMIUM_HELPER_MACOS_DIR := $(CHROMIUM_HELPER_BUNDLE)/Contents/MacOS
CHROMIUM_HELPER_FRAMEWORKS_DIR := $(CHROMIUM_HELPER_BUNDLE)/Contents/Frameworks
BINARY := .build/$(CONFIG)/$(SWIFT_PRODUCT)
CHROMIUM_HELPER_BINARY := .build/$(CONFIG)/$(CHROMIUM_HELPER_PRODUCT)
BUILT_LIBGHOSTTY := build/libghostty/libghostty.dylib
CEF_FRAMEWORK := external/cef/Release/Chromium Embedded Framework.framework

.PHONY: build libghostty cef app app-with-ghostty app-with-chromium run run-cef run-foreground run-cef-foreground clean

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
	if [ -f "$(CHROMIUM_HELPER_BINARY)" ]; then mkdir -p "$(CHROMIUM_HELPER_MACOS_DIR)" "$(CHROMIUM_HELPER_FRAMEWORKS_DIR)" && cp "$(CHROMIUM_HELPER_BINARY)" "$(CHROMIUM_HELPER_MACOS_DIR)/GSDE Chromium Helper" && cp ChromiumHelper-Info.plist "$(CHROMIUM_HELPER_BUNDLE)/Contents/Info.plist" && ln -sfn "../../../Chromium Embedded Framework.framework" "$(CHROMIUM_HELPER_FRAMEWORKS_DIR)/Chromium Embedded Framework.framework"; fi
	chmod +x $(MACOS_DIR)/$(APP_NAME)
	if [ -f "$(CHROMIUM_HELPER_MACOS_DIR)/GSDE Chromium Helper" ]; then chmod +x "$(CHROMIUM_HELPER_MACOS_DIR)/GSDE Chromium Helper"; fi

app-with-ghostty: libghostty app

app-with-chromium: cef app

run: app
	open $(BUNDLE_DIR)

run-cef: app-with-chromium
	GSDE_ENABLE_CEF=1 $(MACOS_DIR)/$(APP_NAME)

run-foreground: app
	$(MACOS_DIR)/$(APP_NAME)

run-cef-foreground: app-with-chromium
	GSDE_ENABLE_CEF=1 $(MACOS_DIR)/$(APP_NAME)

clean:
	rm -rf .build build
