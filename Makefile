APP_NAME := GSDE
SWIFT_PRODUCT := GSDEApp
CONFIG := release
BUNDLE_DIR := build/$(APP_NAME).app
CONTENTS_DIR := $(BUNDLE_DIR)/Contents
MACOS_DIR := $(CONTENTS_DIR)/MacOS
BINARY := .build/$(CONFIG)/$(SWIFT_PRODUCT)

.PHONY: build app run run-foreground clean

build:
	swift build -c $(CONFIG)

app: build
	rm -rf $(BUNDLE_DIR)
	mkdir -p $(MACOS_DIR)
	cp $(BINARY) $(MACOS_DIR)/$(APP_NAME)
	cp Info.plist $(CONTENTS_DIR)/Info.plist
	chmod +x $(MACOS_DIR)/$(APP_NAME)

run: app
	open $(BUNDLE_DIR)

run-foreground: app
	$(MACOS_DIR)/$(APP_NAME)

clean:
	rm -rf .build build
