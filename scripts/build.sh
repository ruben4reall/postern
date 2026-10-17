#!/bin/zsh
# Builds Postern for development, signed with the team's Apple Development certificate, and installs it in
# ~/Applications. Runs at background priority so it never slows down the machine.
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate --quiet
taskpolicy -b xcodebuild -project Postern.xcodeproj -scheme Postern -configuration Debug \
  -derivedDataPath build -allowProvisioningUpdates -quiet build
app="build/Build/Products/Debug/Postern.app"
pkill -x Postern 2>/dev/null || true
mkdir -p ~/Applications
rm -rf ~/Applications/Postern.app
ditto "$app" ~/Applications/Postern.app
echo "Installed ~/Applications/Postern.app"
~/Applications/Postern.app/Contents/MacOS/Postern --register-agent
