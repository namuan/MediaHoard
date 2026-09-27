PROJECT = MediaHoard.xcodeproj
SCHEME = MediaHoard
APP_BUNDLE_ID ?= com.mediahoard.app
DEVICE_BUILD_DIR ?= DerivedData/Device
DEVICE_ID ?= $(shell xcodebuild -project $(PROJECT) -scheme $(SCHEME) -showdestinations 2>/dev/null | sed -n 's/.*{ platform:iOS,[^}]*id:\([^,}]*\),.*/\1/p' | grep -v placeholder | head -1)
TEAM_ID ?= $(shell TEAM=$$(ls -t ~/Library/Developer/Xcode/UserData/Capabilities/capabilities-*-*-bundle.json 2>/dev/null | sed -E 's/.*-([A-Z0-9]{10})-bundle\.json/\1/' | head -1); if [ -n "$$TEAM" ]; then echo "$$TEAM"; else security find-identity -v -p codesigning 2>/dev/null | awk -F'[()]' '/Apple Development:/{gsub(/^[ \t]+|[ \t]+$$/, "", $$3); print $$3; exit}'; fi)
DEVICE_APP_PATH = $(DEVICE_BUILD_DIR)/Build/Products/Debug-iphoneos/MediaHoard.app

.PHONY: deploy device-install project build clean

deploy: device-install

device-install: project
	@test -n "$(DEVICE_ID)" || { echo 'No connected iPhone or iPad found. Connect and unlock it, then retry.'; exit 1; }
	@test -n "$(TEAM_ID)" || { echo 'No Apple Development team found. Add your Apple ID in Xcode Settings > Accounts, then retry.'; exit 1; }
	@printf 'Device: %s\nTeam: %s\nBundle: %s\n' '$(DEVICE_ID)' '$(TEAM_ID)' '$(APP_BUNDLE_ID)'
	xcodebuild -project "$(PROJECT)" -scheme "$(SCHEME)" \
		-configuration Debug \
		-destination 'platform=iOS,id=$(DEVICE_ID)' \
		-derivedDataPath '$(DEVICE_BUILD_DIR)' \
		-allowProvisioningUpdates \
		-allowProvisioningDeviceRegistration \
		DEVELOPMENT_TEAM='$(TEAM_ID)' \
		PRODUCT_BUNDLE_IDENTIFIER='$(APP_BUNDLE_ID)' \
		build
	xcrun devicectl device install app --device '$(DEVICE_ID)' '$(DEVICE_APP_PATH)'
	xcrun devicectl device process launch --terminate-existing --device '$(DEVICE_ID)' '$(APP_BUNDLE_ID)'

project:
	xcodegen generate --spec project.yml

build: project
	xcodebuild -project "$(PROJECT)" -scheme "$(SCHEME)" -configuration Debug -destination 'generic/platform=iOS' -derivedDataPath '$(DEVICE_BUILD_DIR)' CODE_SIGNING_ALLOWED=NO build

clean:
	rm -rf .build '$(DEVICE_BUILD_DIR)'
