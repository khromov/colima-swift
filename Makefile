APP_NAME    := ColimaSwift
BUNDLE_ID   := dev.local.colima-swift
SRC_DIR     := ColimaSwift
BUILD_DIR   := build
APP_BUNDLE  := $(BUILD_DIR)/$(APP_NAME).app
MACOS_DIR   := $(APP_BUNDLE)/Contents/MacOS
RES_DIR     := $(APP_BUNDLE)/Contents/Resources
BINARY      := $(MACOS_DIR)/$(APP_NAME)

SWIFT_SOURCES := $(wildcard $(SRC_DIR)/*.swift)
INFO_PLIST    := $(SRC_DIR)/Info.plist
ENTITLEMENTS  := $(SRC_DIR)/$(APP_NAME).entitlements

SWIFTC        := xcrun swiftc
SDK           := $(shell xcrun --sdk macosx --show-sdk-path)
DEPLOY_TARGET := 13.0

SWIFTFLAGS = \
    -O \
    -sdk $(SDK) \
    -target arm64-apple-macos$(DEPLOY_TARGET) \
    -framework AppKit \
    -framework SwiftUI \
    -framework Combine \
    -framework Foundation

.PHONY: all clean run

all: $(APP_BUNDLE)

$(APP_BUNDLE): $(SWIFT_SOURCES) $(INFO_PLIST) $(ENTITLEMENTS) Makefile
	@mkdir -p $(MACOS_DIR) $(RES_DIR)
	@echo "==> Compiling $(APP_NAME)"
	$(SWIFTC) $(SWIFTFLAGS) -o $(BINARY) $(SWIFT_SOURCES)
	@echo "==> Writing Info.plist"
	@/usr/libexec/PlistBuddy -x -c "Print" $(INFO_PLIST) > $(APP_BUNDLE)/Contents/Info.plist 2>/dev/null || cp $(INFO_PLIST) $(APP_BUNDLE)/Contents/Info.plist
	@/usr/libexec/PlistBuddy -c "Set :CFBundleExecutable $(APP_NAME)" $(APP_BUNDLE)/Contents/Info.plist
	@/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $(BUNDLE_ID)"  $(APP_BUNDLE)/Contents/Info.plist
	@/usr/libexec/PlistBuddy -c "Set :CFBundleName $(APP_NAME)"          $(APP_BUNDLE)/Contents/Info.plist
	@echo "==> Codesigning ad-hoc with entitlements"
	@codesign --force --sign - --entitlements $(ENTITLEMENTS) --options runtime $(APP_BUNDLE) >/dev/null
	@echo "==> Built $(APP_BUNDLE)"

run: $(APP_BUNDLE)
	-@pkill -x $(APP_NAME) 2>/dev/null || true
	open $(APP_BUNDLE)

clean:
	rm -rf $(BUILD_DIR)
