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
# Without --norsrc on every ditto zip below, ditto embeds a "._*" AppleDouble sidecar per file
# (resource-fork/xattr preservation); unzipping it back out breaks the code signature ("a sealed resource is
# missing or invalid") because those sidecars didn't exist when the bundle was signed. Gatekeeper on a fresh
# quarantined download then refuses to open it. COPYFILE_DISABLE alone does NOT fix this — verified: 145
# sidecar entries in the zip with it set and no --norsrc, 0 with --norsrc. Sparkle's own update path doesn't
# re-zip, so this went unnoticed until a fresh download of 0.4.2.
VERSION=${1:?version required, e.g. 0.1.0}
SKIP_BUILD=${2:-}
BUILD=$(date -u +%Y%m%d%H%M)
# Xcode-beta when it is installed, otherwise the release Xcode — the beta comes and goes on this Mac.
if [[ -d /Applications/Xcode-beta.app ]]; then
  export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
else
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
TEAM=8PW5FWH7P2
IDENTITY="Developer ID Application: Vaclav Zmrhal ($TEAM)"
KEY_ID=C7WD5C4FK2
ISSUER=ca252666-8b4c-45a8-88b2-78606d80340d
P8=~/.appstoreconnect/private_keys/AuthKey_$KEY_ID.p8
WEB=../zmrhal_web/public/quotavadis
DIST=dist; mkdir -p "$DIST" "$WEB"
if [ "$SKIP_BUILD" = "--skip-build" ]; then
  APP="$DIST/export/QuotaVadis.app"
  BUILD=$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist")
else
rm -rf "$DIST"; mkdir -p "$DIST"
xcodegen generate >/dev/null
ARCHIVE="$DIST/QuotaVadis.xcarchive"
# Archive with automatic (development) signing, then let -exportArchive re-sign for Developer ID.
# That step creates/downloads the Developer ID provisioning profile carrying iCloud + App Group.
xcodebuild -project QuotaVadis.xcodeproj -scheme QuotaVadis -configuration Release \
  -archivePath "$ARCHIVE" -derivedDataPath .build/dd -allowProvisioningUpdates \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
  archive 2>&1 | grep -E 'error:|ARCHIVE'

cat > "$DIST/export.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>$TEAM</string>
  <key>destination</key><string>export</string>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$DIST/export" \
  -exportOptionsPlist "$DIST/export.plist" -allowProvisioningUpdates 2>&1 | grep -E 'error:|EXPORT'
APP="$DIST/export/QuotaVadis.app"
codesign --verify --deep --strict "$APP"
# grep -c reads the whole stream; grep -q would SIGPIPE codesign and trip pipefail.
[ "$(codesign -dvv "$APP" 2>&1 | grep -c 'Authority=Developer ID Application')" -ge 1 ] || { echo "not Developer ID signed"; exit 1; }
fi

ZIP="$DIST/QuotaVadis-$VERSION.zip"
if xcrun stapler validate "$APP" >/dev/null 2>&1; then
  echo "already notarized and stapled"
else
  ditto --norsrc -c -k --keepParent "$APP" "$ZIP"
  echo "notarizing…"
  xcrun notarytool submit "$ZIP" --key "$P8" --key-id $KEY_ID --issuer $ISSUER --wait 2>&1 | grep -E 'status|id:' | head -3
  xcrun stapler staple "$APP" >/dev/null
fi
rm -f "$ZIP"; ditto --norsrc -c -k --keepParent "$APP" "$ZIP"
rm -rf .build/dd

# Round-trip check: a zip that unzips into a broken signature must never ship (see the --norsrc comment
# above — this catches it even if some other AppleDouble source shows up later).
UNZIPPED=$(mktemp -d)
# Plain unzip, not "ditto -x": ditto merges AppleDouble sidecars back into real xattrs on extraction, which
# would hide exactly the bug this check exists to catch (it did, the first time this check was written).
unzip -q "$ZIP" -d "$UNZIPPED"
codesign --verify --deep --strict "$UNZIPPED/QuotaVadis.app"
rm -rf "$UNZIPPED"

# Sparkle CLI tools: from the official release tarball (Scripts/sparkle-tools.sh installs them).
SIGN=~/.local/share/sparkle-tools/sign_update
[ -x "$SIGN" ] || { echo "sign_update missing: run Scripts/sparkle-tools.sh"; exit 1; }
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
python3 - "$APPCAST" "$ITEM" "$VERSION" <<'PY'
import sys, re
path, item, version = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path).read()
# Re-releasing the same version (build number bumped) replaces the old entry instead of duplicating it.
s = re.sub(r"    <item>\n(?:(?!    </item>).*\n)*?      <sparkle:shortVersionString>" + re.escape(version) + r"</sparkle:shortVersionString>\n(?:(?!    </item>).*\n)*?    </item>\n", "", s)
s = s.replace("  </channel>", item, 1)
open(path, "w").write(s)
PY
cp "$ZIP" "$WEB/"
cp "$ZIP" "$WEB/QuotaVadis-latest.zip"   # stable link for the website download button
echo "release $VERSION ($BUILD) ready: $ZIP → $WEB (appcast updated). Deploy zmrhal_web to publish."
