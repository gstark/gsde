APP_NAME := GSDE
SWIFT_PRODUCT := GSDEApp
CONFIG := release
BUNDLE_DIR := build/$(APP_NAME).app
CONTENTS_DIR := $(BUNDLE_DIR)/Contents
MACOS_DIR := $(CONTENTS_DIR)/MacOS
FRAMEWORKS_DIR := $(CONTENTS_DIR)/Frameworks
BINARY := .build/$(CONFIG)/$(SWIFT_PRODUCT)
BUILT_LIBGHOSTTY := build/libghostty/libghostty.dylib
CEF_FRAMEWORK := external/cef/Release/Chromium Embedded Framework.framework

.PHONY: build libghostty cef app app-with-ghostty app-with-chromium run run-foreground clean

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
	chmod +x $(MACOS_DIR)/$(APP_NAME)

app-with-ghostty: libghostty app

app-with-chromium: cef app

run: app
	open $(BUNDLE_DIR)

run-foreground: app
	$(MACOS_DIR)/$(APP_NAME)

clean:
	rm -rf .build build
