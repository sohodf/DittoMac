APP_NAME  = DittoMac
APP_BUNDLE = $(APP_NAME).app
BUILD_DIR  = .build/release

.PHONY: build app run debug clean

## Build release binary
build:
	swift build -c release 2>&1

## Package into a runnable .app bundle
app: build
	@rm -rf $(APP_BUNDLE)
	@mkdir -p $(APP_BUNDLE)/Contents/MacOS
	@mkdir -p $(APP_BUNDLE)/Contents/Resources
	@cp $(BUILD_DIR)/$(APP_NAME) $(APP_BUNDLE)/Contents/MacOS/
	@cp Info.plist $(APP_BUNDLE)/Contents/
	@echo "<?xml version=\"1.0\" encoding=\"UTF-8\"?>" > $(APP_BUNDLE)/Contents/PkgInfo
	@echo -n "APPLDiMc" >> $(APP_BUNDLE)/Contents/PkgInfo
	@echo "Built $(APP_BUNDLE)"

## Build and launch
run: app
	@open $(APP_BUNDLE)

## Debug build (faster, with symbols)
debug:
	swift build
	@rm -rf $(APP_NAME)-Debug.app
	@mkdir -p $(APP_NAME)-Debug.app/Contents/MacOS
	@mkdir -p $(APP_NAME)-Debug.app/Contents/Resources
	@cp .build/debug/$(APP_NAME) $(APP_NAME)-Debug.app/Contents/MacOS/
	@cp Info.plist $(APP_NAME)-Debug.app/Contents/
	@open $(APP_NAME)-Debug.app

## Remove build artifacts
clean:
	@rm -rf $(APP_BUNDLE) $(APP_NAME)-Debug.app .build
	@echo "Cleaned"
