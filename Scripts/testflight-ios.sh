#!/bin/zsh
# Archive the iOS app, export for App Store Connect and upload to TestFlight.
#   Scripts/testflight-ios.sh 0.1.0            # marketing version; build = UTC timestamp
#   Scripts/testflight-ios.sh 0.1.0 --no-upload  # stop after exporting the .ipa
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=${1:?version required}
UPLOAD=${2:-}
BUILD=$(date -u +%Y%m%d%H%M)
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
TEAM=8PW5FWH7P2
KEY_ID=C7WD5C4FK2
ISSUER=ca252666-8b4c-45a8-88b2-78606d80340d
DIST=dist/ios; rm -rf "$DIST"; mkdir -p "$DIST"

xcodegen generate >/dev/null
xcodebuild -project QuotaVadis.xcodeproj -scheme QuotaVadis-iOS -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$DIST/QuotaVadis-iOS.xcarchive" -derivedDataPath .build/dd-ios \
  -allowProvisioningUpdates MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
  archive 2>&1 | grep -E 'error:|ARCHIVE'

cat > "$DIST/export.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>$TEAM</string>
  <key>destination</key><string>export</string>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$DIST/QuotaVadis-iOS.xcarchive" -exportPath "$DIST/export" \
  -exportOptionsPlist "$DIST/export.plist" -allowProvisioningUpdates 2>&1 | grep -E 'error:|EXPORT'
IPA=$(ls "$DIST"/export/*.ipa | head -1)
echo "ipa: $IPA ($VERSION build $BUILD)"
rm -rf .build/dd-ios

if [ "$UPLOAD" = "--no-upload" ]; then exit 0; fi
xcrun altool --upload-app -f "$IPA" -t ios --apiKey $KEY_ID --apiIssuer $ISSUER 2>&1 | grep -iE 'uploaded|error|warning' | head -5
echo "uploaded $VERSION ($BUILD); processing takes a few minutes, then it appears under TestFlight."
