#!/bin/zsh
# Build QuotaVadis (Release) and install it to /Applications, replacing whatever copy is there (including a
# Sparkle-updated release). Owner runs the release build day to day; use this only to test unreleased changes.
# Derived data is deleted afterwards, so never run the app straight from the build folder.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
xcodegen generate >/dev/null
# Unique build number per install: WidgetKit caches extensions by bundle version and would keep showing stale widgets.
BUILD=$(date +%Y%m%d%H%M)
xcodebuild -project QuotaVadis.xcodeproj -scheme QuotaVadis -configuration Release -derivedDataPath .build/dd CURRENT_PROJECT_VERSION="$BUILD" build 2>&1 | grep -E 'error:|BUILD'
# Quit the running copy and wait for it to be gone before touching the bundle.
pkill -x QuotaVadis 2>/dev/null || true
for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -x QuotaVadis >/dev/null || break; sleep 0.5; done
pgrep -x QuotaVadis >/dev/null && { pkill -9 -x QuotaVadis; sleep 1; }
# One copy only: the same place Sparkle-updated release builds live. A second copy in ~/Applications
# fights over UserDefaults, Keychain and the App Group file.
rm -rf ~/Applications/QuotaVadis.app /Applications/QuotaVadis.app
ditto .build/dd/Build/Products/Release/QuotaVadis.app /Applications/QuotaVadis.app
rm -rf .build/dd
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f ~/Applications/QuotaVadis.app >/dev/null 2>&1 || true
# Make WidgetKit pick up the new extension right away.
pluginkit -a /Applications/QuotaVadis.app/Contents/PlugIns/QuotaWidgets-Mac.appex >/dev/null 2>&1 || true
killall chronod 2>/dev/null || true
open /Applications/QuotaVadis.app
echo "installed /Applications/QuotaVadis.app (build $BUILD)"
