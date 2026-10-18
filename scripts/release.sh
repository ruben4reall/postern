#!/bin/bash
# scripts/release.sh [--check]: builds Postern for distribution, signed with a Developer ID, notarized by Apple, and
# packed in a disk image, then hands over to scripts/finish-release.sh, which signs the update with EdDSA and adds it
# to the update feed. Publishes nothing: scripts/publish.sh does, step by step. Maintainers only.
#
# Needs:
# - POSTERN_TEAM_ID: the Apple team. Be signed in to Xcode with the team's Account Holder: the export signs with a
#   cloud-managed Developer ID certificate, and creates the Developer ID provisioning profiles the Keychain group
#   needs. Do not pass an App Store Connect key to the export: Apple answers 403 for cloud-managed certificates.
# - NOTARY_KEY_ID, NOTARY_ISSUER_ID, NOTARY_KEY_PATH: an App Store Connect API key, for notarytool only.
# - XcodeGen, dmgbuild (pip install dmgbuild) and xmllint.
# - Postern's EdDSA private key in the login Keychain (account ch.rubencatalao.postern), for scripts/finish-release.sh.
# None of these values belongs in this repository.
#
# Every release raises MARKETING_VERSION (x.y.z) and CURRENT_PROJECT_VERSION (the build number Sparkle compares) in
# project.yml, and adds its section to CHANGELOG.md.
#
# Output: dist/Postern-<version>.dmg, notarized and stapled, its SHA-256, dist/Postern.dmg, dist/release-notes.md,
# the new item in site/appcast.xml and dist/homebrew/Casks/postern.rb.
set -euo pipefail
cd "$(dirname "$0")/.."
MODE="${1:-build}"
VERSION=$(grep -m1 'MARKETING_VERSION:' project.yml | awk '{print $2}' | tr -d '"')
BUILD=$(grep -m1 'CURRENT_PROJECT_VERSION:' project.yml | awk '{print $2}' | tr -d '"')
TEAM="${POSTERN_TEAM_ID:-}"
APPCAST="${POSTERN_APPCAST:-site/appcast.xml}"
FEED_URL=https://getpostern.vercel.app/appcast.xml
WORK=build/release
SPM=build/spm
fail() { echo "release: $*" >&2; exit 1; }
notary() { xcrun notarytool "$@" --key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID"; }

# 0. Checks. A published build comes from committed sources, under a version never released before.
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "MARKETING_VERSION in project.yml is not x.y.z: '$VERSION'"
[[ "$BUILD" =~ ^[0-9]+$ ]] || fail "CURRENT_PROJECT_VERSION in project.yml is not a whole number: '$BUILD'"
[ -n "$TEAM" ] || fail "set POSTERN_TEAM_ID"
: "${NOTARY_KEY_ID:?set NOTARY_KEY_ID}" "${NOTARY_ISSUER_ID:?set NOTARY_ISSUER_ID}" "${NOTARY_KEY_PATH:?set NOTARY_KEY_PATH}"
[ -f "$NOTARY_KEY_PATH" ] || fail "NOTARY_KEY_PATH does not name a file"
[ -z "$(git status --porcelain)" ] || fail "the working tree has uncommitted changes"
if git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null; then fail "tag v$VERSION exists: raise MARKETING_VERSION"; fi
grep -q "^## $VERSION (" CHANGELOG.md || fail "CHANGELOG.md has no '## $VERSION (<date>)' section"
[ -f "$APPCAST" ] || fail "$APPCAST is missing: the website serves the update feed"
if grep -q "<sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>" "$APPCAST"; then
  fail "$APPCAST already offers $VERSION: raise MARKETING_VERSION"
fi
# Sparkle offers an update only when its build number is higher: 0.1.0 shipped as build 1.
for offered in 1 $(sed -n 's:.*<sparkle\:version>\([0-9]*\)</sparkle\:version>.*:\1:p' "$APPCAST"); do
  [ "$BUILD" -gt "$offered" ] || fail "build $BUILD is not higher than build $offered, already released: raise CURRENT_PROJECT_VERSION"
done
command -v xcodegen >/dev/null || fail "XcodeGen is missing: brew install xcodegen"
command -v dmgbuild >/dev/null || fail "dmgbuild is missing: pip install dmgbuild"
command -v xmllint >/dev/null || fail "xmllint is missing"
if [ "$MODE" = "--check" ]; then
  notary history >/dev/null 2>&1 || fail "Apple refused the App Store Connect key (notarytool history)"
  echo "Checks passed: Postern $VERSION (build $BUILD), team $TEAM, notarization key accepted."
  exit 0
fi

notarize() {   # notarize <file>: submits, waits, fails loudly on anything but Accepted
  local log; log="$WORK/notary-$(basename "$1").log"
  notary submit "$1" --wait --timeout 60m > "$log" 2>&1 || true
  if ! grep -q "status: Accepted" "$log"; then
    echo "Notarization of $(basename "$1") did not succeed:" >&2; cat "$log" >&2
    local id; id=$(grep -m1 -E '^ *id:' "$log" | awk '{print $2}')
    if [ -n "$id" ]; then notary log "$id" >&2 || true; fi
    exit 1
  fi
  echo "Notarized: $(basename "$1")"
}

check_signed() {   # every executable inside is signed by the team, with the hardened runtime
  local count=0 file sig
  while IFS= read -r -d '' file; do
    [[ "$(file -b "$file")" == *"Mach-O"*"executable"* ]] || continue
    sig=$(codesign -dv "$file" 2>&1 || true)
    [[ "$sig" == *"(runtime)"* ]] || fail "$file is not signed with the hardened runtime"
    [[ "$sig" == *"TeamIdentifier=$TEAM"* ]] || fail "$file is not signed by team $TEAM"
    count=$((count + 1))
  done < <(find "$1" -type f -print0)
  [ "$count" -ge 5 ] || fail "expected the app, the relay, the parser service and Sparkle's helpers, found $count executables"
  codesign --verify --deep --strict "$1" || fail "codesign --verify failed"
  echo "Signed: $count executables, team $TEAM, hardened runtime."
}

rm -rf "$WORK" && mkdir -p "$WORK" dist
xcodegen generate --quiet

# 1. Archive with automatic signing, then export for Developer ID. Packages go to build/spm, where
#    scripts/finish-release.sh finds Sparkle's tools.
xcodebuild archive -project Postern.xcodeproj -scheme Postern -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$WORK/Postern.xcarchive" -clonedSourcePackagesDirPath "$SPM" \
  DEVELOPMENT_TEAM="$TEAM" -allowProvisioningUpdates > "$WORK/archive.log" 2>&1 \
  || { tail -n 40 "$WORK/archive.log" >&2; exit 1; }
cat > "$WORK/export.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>automatic</string>
  <key>destination</key><string>export</string>
</dict></plist>
PLIST
xcodebuild -exportArchive -archivePath "$WORK/Postern.xcarchive" -exportPath "$WORK/export" \
  -exportOptionsPlist "$WORK/export.plist" -allowProvisioningUpdates > "$WORK/export.log" 2>&1 \
  || { tail -n 40 "$WORK/export.log" >&2; exit 1; }
APP="$WORK/export/Postern.app"
check_signed "$APP"
codesign -d --entitlements - "$APP" 2>/dev/null | grep -q "keychain-access-groups" \
  || fail "the exported app has no Keychain access group: the provisioning profile is missing"
# Updates: the production feed, the key the feed is checked against, and what a sandboxed app needs to install.
INFO="$APP/Contents/Info.plist"
[ "$(/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' "$INFO")" = "$FEED_URL" ] || fail "the app's SUFeedURL is not $FEED_URL"
[ "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$INFO")" = "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' App/Info.plist)" ] \
  || fail "the app's SUPublicEDKey is not the one in App/Info.plist"
[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$INFO")" = "$BUILD" ] || fail "the app's build number is not $BUILD"
[ -d "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Installer.xpc" ] || fail "Sparkle's installer service is missing"
codesign -d --entitlements - "$APP" 2>/dev/null | grep -q "ch.rubencatalao.postern-spki" \
  || fail "the exported app cannot reach Sparkle's installer: mach-lookup entitlements missing"

# 2. Notarize and staple the app, so it opens offline too.
ditto -c -k --keepParent "$APP" "$WORK/Postern.zip"
notarize "$WORK/Postern.zip"
xcrun stapler staple "$APP" >/dev/null
spctl -a -t exec "$APP" || fail "Gatekeeper rejects the app"

# 3. The disk image, laid out without Finder, then notarized and stapled.
DMG="dist/Postern-$VERSION.dmg"
rm -f "$DMG"
dmgbuild -s scripts/dmg/settings.py -D app="$APP" Postern "$DMG" > "$WORK/dmg.log" 2>&1 \
  || { tail -n 20 "$WORK/dmg.log" >&2; exit 1; }
notarize "$DMG"
xcrun stapler staple "$DMG" >/dev/null
git rev-parse HEAD > dist/build-commit.txt
echo "$DMG ($(du -h "$DMG" | awk '{print $1}')), notarized and stapled."

# 4. The update: EdDSA signature, feed item, release notes and cask.
exec scripts/finish-release.sh "$VERSION"
