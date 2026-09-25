#!/bin/zsh
# Build a classic macOS DMG for first-time install of QuotaVadis.
#
#   Scripts/make-dmg.sh /path/to/QuotaVadis.app [output.dmg]
#
# Staging: QuotaVadis.app + Applications → /Applications symlink.
# Creates a compressed UDZO DMG via hdiutil (no brew create-dmg).
# Codesigns with Developer ID Application, notarizes with notarytool
# (same ASC key pattern as Scripts/release.sh), and staples the DMG.
#
# Finder window layout (icon positions / window size) is best-effort via
# AppleScript on a temporary RW image. If that step flakes, the DMG still
# ships as a clean minimal disk image with the app + Applications symlink —
# that alone is enough for drag-to-install.
#
# Does NOT touch Sparkle / appcast / zip — those stay on the zip path.
set -euo pipefail

APP=${1:?usage: Scripts/make-dmg.sh /path/to/QuotaVadis.app [output.dmg]}
[[ -d "$APP" ]] || { echo "not an app bundle: $APP" >&2; exit 1; }
APP=$(cd "$(dirname "$APP")" && pwd)/$(basename "$APP")

TEAM=8PW5FWH7P2
IDENTITY="Developer ID Application: Vaclav Zmrhal ($TEAM)"
KEY_ID=C7WD5C4FK2
ISSUER=ca252666-8b4c-45a8-88b2-78606d80340d
P8=~/.appstoreconnect/private_keys/AuthKey_$KEY_ID.p8
VOLNAME=QuotaVadis

VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")
OUT=${2:-"QuotaVadis-$VERSION.dmg"}
OUT_DIR=$(cd "$(dirname "$OUT")" 2>/dev/null && pwd || echo "$(pwd)")
OUT_NAME=$(basename "$OUT")
OUT="$OUT_DIR/$OUT_NAME"

[[ -f "$P8" ]] || { echo "missing ASC key: $P8" >&2; exit 1; }

# Quick sanity: app should already be Developer ID signed (and ideally stapled).
codesign --verify --deep --strict "$APP"
[ "$(codesign -dvv "$APP" 2>&1 | grep -c 'Authority=Developer ID Application')" -ge 1 ] \
  || { echo "app is not Developer ID signed" >&2; exit 1; }

STAGE=$(mktemp -d -t qv-dmg-stage)
RW_DMG=$(mktemp -t qv-dmg-rw).dmg
cleanup() {
  # Detach any leftover mount of our RW image (best-effort).
  if [[ -n "${MOUNTPOINT:-}" && -d "$MOUNTPOINT" ]]; then
    hdiutil detach "$MOUNTPOINT" -quiet 2>/dev/null || true
  fi
  rm -rf "$STAGE"
  rm -f "$RW_DMG"
}
trap cleanup EXIT

# --- stage ---
ditto --norsrc "$APP" "$STAGE/QuotaVadis.app"
ln -s /Applications "$STAGE/Applications"

# --- RW image for optional Finder layout, then convert to UDZO ---
# Size: app + a bit of headroom. hdiutil wants sectors; -fs HFS+ / APFS both fine.
# Use UDIF RW, then convert — more reliable than mutating a compressed image.
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -ov -format UDRW -fs HFS+ "$RW_DMG" >/dev/null

# Mount and try to arrange icons. Failures here are non-fatal.
MOUNT_OUT=$(hdiutil attach "$RW_DMG" -readwrite -noverify -noautoopen 2>&1)
MOUNTPOINT=$(echo "$MOUNT_OUT" | awk '/\/Volumes\// {print $NF; exit}')
if [[ -z "$MOUNTPOINT" || ! -d "$MOUNTPOINT" ]]; then
  echo "warning: could not mount RW DMG for layout; shipping minimal DMG" >&2
else
  # Best-effort Finder layout. Documented as optional / flaky under automation.
  if osascript <<ASCRIPT >/dev/null 2>&1; then
    tell application "Finder"
      tell disk "$VOLNAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 840, 520}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        set position of item "QuotaVadis.app" of container window to {160, 200}
        set position of item "Applications" of container window to {480, 200}
        update without registering applications
        delay 0.5
        close
      end tell
    end tell
ASCRIPT
    echo "Finder layout applied"
  else
    echo "warning: Finder layout AppleScript failed; shipping minimal DMG (app + Applications)" >&2
  fi
  sync
  hdiutil detach "$MOUNTPOINT" -quiet
  MOUNTPOINT=
fi

# Convert RW → compressed UDZO
rm -f "$OUT"
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$OUT" >/dev/null

# --- codesign DMG ---
codesign --force --sign "$IDENTITY" --timestamp "$OUT"
codesign --verify --verbose=2 "$OUT" >/dev/null

# --- notarize + staple ---
echo "notarizing DMG…"
xcrun notarytool submit "$OUT" --key "$P8" --key-id "$KEY_ID" --issuer "$ISSUER" --wait 2>&1 \
  | grep -E 'status|id:' | head -5
xcrun stapler staple "$OUT" >/dev/null
xcrun stapler validate "$OUT" >/dev/null

echo "DMG ready: $OUT"
