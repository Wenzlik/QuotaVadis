#!/bin/zsh
# Build, sign (Developer ID), notarize, staple, zip and publish a QuotaVadis release.
#
#   Scripts/release.sh 0.1.0            # version; build number = UTC timestamp
#
# Output: dist/QuotaVadis-<version>.zip + appcast entry appended to
# ../zmrhal_web/public/quotavadis/appcast.xml and the zip copied next to it.
# Deploying zmrhal_web is a separate, deliberate step (see docs/DEPLOY.md there).
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION=${1:?version required, e.g. 0.1.0}
BUILD=$(date -u +%Y%m%d%H%M)
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
TEAM=8PW5FWH7P2
IDENTITY="Developer ID Application: Vaclav Zmrhal ($TEAM)"
KEY_ID=C7WD5C4FK2
ISSUER=ca252666-8b4c-45a8-88b2-78606d80340d
P8=~/.appstoreconnect/private_keys/AuthKey_$KEY_ID.p8
WEB=../zmrhal_web/public/quotavadis
DIST=dist; rm -rf "$DIST"; mkdir -p "$DIST" "$WEB"

xcodegen generate >/dev/null
ARCHIVE="$DIST/QuotaVadis.xcarchive"
xcodebuild -project QuotaVadis.xcodeproj -scheme QuotaVadis -configuration Release \
  -archivePath "$ARCHIVE" -derivedDataPath .build/dd \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
  CODE_SIGN_IDENTITY="$IDENTITY" CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=$TEAM \
  PROVISIONING_PROFILE_SPECIFIER="" OTHER_CODE_SIGN_FLAGS="--timestamp --options runtime" \
  archive 2>&1 | grep -E 'error:|ARCHIVE' 

APP="$ARCHIVE/Products/Applications/QuotaVadis.app"
# Sparkle's XPC services and framework are signed by the archive step; verify the whole bundle.
codesign --verify --deep --strict "$APP"

ZIP="$DIST/QuotaVadis-$VERSION.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "notarizing…"
xcrun notarytool submit "$ZIP" --key "$P8" --key-id $KEY_ID --issuer $ISSUER --wait 2>&1 | grep -E 'status|id:' | head -3
xcrun stapler staple "$APP" >/dev/null
rm "$ZIP"; ditto -c -k --keepParent "$APP" "$ZIP"
rm -rf .build/dd

SIGN=$(find ~/Library/Developer/Xcode/DerivedData .build -type f -name sign_update 2>/dev/null | head -1)
[ -n "$SIGN" ] || SIGN=$(find / -type f -name sign_update -path '*Sparkle*' 2>/dev/null | head -1)
SIG=$("$SIGN" --account QuotaVadis "$ZIP" | tr -d '\n')   # sparkle:edSignature="…" length="…"
SIZE=$(stat -f%z "$ZIP")
DATE=$(date -R)
NOTES_FILE="Releases/$VERSION.md"
NOTES=$( [ -f "$NOTES_FILE" ] && sed 's/&/\&amp;/g; s/</\&lt;/g' "$NOTES_FILE" || echo "QuotaVadis $VERSION" )

APPCAST="$WEB/appcast.xml"
if [ ! -f "$APPCAST" ]; then cat > "$APPCAST" <<'XML'
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>QuotaVadis</title>
    <link>https://zmrhal.cz/quotavadis/</link>
    <description>QuotaVadis updates</description>
  </channel>
</rss>
XML
fi
ITEM="    <item>
      <title>QuotaVadis $VERSION</title>
      <pubDate>$DATE</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <description><![CDATA[<pre>$NOTES</pre>]]></description>
      <enclosure url=\"https://zmrhal.cz/quotavadis/QuotaVadis-$VERSION.zip\" $SIG type=\"application/octet-stream\"/>
    </item>
  </channel>"
python3 - "$APPCAST" "$ITEM" <<'PY'
import sys
path, item = sys.argv[1], sys.argv[2]
s = open(path).read()
s = s.replace("  </channel>", item, 1)
open(path, "w").write(s)
PY
cp "$ZIP" "$WEB/"
echo "release $VERSION ($BUILD) ready: $ZIP → $WEB (appcast updated). Deploy zmrhal_web to publish."
