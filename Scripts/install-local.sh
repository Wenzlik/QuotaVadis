#!/bin/zsh
# Build QuotaVadis (Release) and install it to ~/Applications, then relaunch.
# Derived data is deleted afterwards, so never run the app straight from the build folder.
set -euo pipefail
cd "$(dirname "$0")/.."
export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
xcodegen generate >/dev/null
xcodebuild -project QuotaVadis.xcodeproj -scheme QuotaVadis -configuration Release -derivedDataPath .build/dd build 2>&1 | grep -E 'error:|BUILD'
pkill -x QuotaVadis 2>/dev/null || true
sleep 1
mkdir -p ~/Applications
rm -rf ~/Applications/QuotaVadis.app
ditto .build/dd/Build/Products/Release/QuotaVadis.app ~/Applications/QuotaVadis.app
rm -rf .build/dd
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f ~/Applications/QuotaVadis.app >/dev/null 2>&1 || true
open ~/Applications/QuotaVadis.app
echo "installed ~/Applications/QuotaVadis.app"
