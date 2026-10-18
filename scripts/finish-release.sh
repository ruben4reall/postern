#!/bin/bash
# scripts/finish-release.sh <version>: turns the notarized, stapled dist/Postern-<version>.dmg into everything a
# release publishes, and publishes nothing: its stable copy dist/Postern.dmg, its SHA-256, the release notes (from
# CHANGELOG.md), the new item of the update feed, and the Homebrew cask. scripts/release.sh runs it at the end.
#
# The feed item is signed with Postern's EdDSA key, and so is the whole feed (the app sets SURequireSignedFeed). The
# key is read from the login Keychain (account ch.rubencatalao.postern): macOS asks once to let generate_appcast use
# it. POSTERN_SPARKLE_KEY_FILE names a file holding the key instead ("-" reads it from standard input).
#
# POSTERN_APPCAST (default site/appcast.xml) and POSTERN_DOWNLOAD_PREFIX (default the GitHub release of <version>) let
# an update rehearsal serve a feed from this Mac.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?usage: scripts/finish-release.sh <version>}"
REPO_URL=https://github.com/ruben4reall/postern
SITE_URL=https://getpostern.vercel.app
ACCOUNT=ch.rubencatalao.postern
APPCAST="${POSTERN_APPCAST:-site/appcast.xml}"
PREFIX="${POSTERN_DOWNLOAD_PREFIX:-$REPO_URL/releases/download/v$VERSION/}"
DMG="dist/Postern-$VERSION.dmg"
fail() { echo "finish-release: $*" >&2; exit 1; }
[ -f "$DMG" ] || fail "$DMG is missing: run scripts/release.sh first"
[ -f "$APPCAST" ] || fail "$APPCAST is missing: the website serves the update feed"

# 1. The image as Apple accepted it: everything below signs or hashes these exact bytes.
xcrun stapler validate "$DMG" >/dev/null || fail "$DMG carries no notarization ticket"
hdiutil verify "$DMG" >/dev/null 2>&1 || fail "$DMG does not verify"
cp "$DMG" dist/Postern.dmg
SHA=$(shasum -a 256 "$DMG" | awk '{print $1}')
echo "$SHA" > "$DMG.sha256"

# 2. Release notes, for GitHub and for the update window.
NOTES=$(scripts/changelog-section.sh "$VERSION")
UPDATES=build/release-updates
rm -rf "$UPDATES" && mkdir -p "$UPDATES"
cp "$DMG" "$UPDATES/"
printf '%s\n' "$NOTES" > "$UPDATES/Postern-$VERSION.md"
{
  printf '%s\n\n' "$NOTES"
  printf 'Download `Postern.dmg` (or `Postern-%s.dmg`, the same file), open it and drag Postern to Applications. ' "$VERSION"
  printf 'Or with Homebrew: `brew install --cask ruben4reall/tap/postern`. From 0.1.1 on, Postern updates itself: '
  printf 'choose Check for Updates in the Postern menu.\n\n'
  printf 'Requires macOS 26 or later and Proton Mail Bridge, signed in, on the same Mac. Signed with a Developer ID, '
  printf 'notarized by Apple, and signed for updates with EdDSA.\n\n'
  printf '**SHA-256** of the disk image: `%s`\n\n' "$SHA"
  printf 'Postern is an independent project, not affiliated with or endorsed by Proton AG.\n'
} > dist/release-notes.md

# 3. The feed: the new item on top, older items kept, the whole feed signed.
GENERATE_APPCAST=$(find build/spm/artifacts -type f -name generate_appcast -perm -u+x 2>/dev/null | head -1)
[ -n "$GENERATE_APPCAST" ] || fail "Sparkle's tools are missing from build/spm: build with scripts/release.sh first"
KEY=(--account "$ACCOUNT")
if [ -n "${POSTERN_SPARKLE_KEY_FILE:-}" ]; then KEY=(--ed-key-file "$POSTERN_SPARKLE_KEY_FILE"); fi
"$GENERATE_APPCAST" "${KEY[@]}" --download-url-prefix "$PREFIX" --link "$SITE_URL" \
  --full-release-notes-url "$REPO_URL/releases" --embed-release-notes --maximum-deltas 0 -o "$APPCAST" "$UPDATES"
swift scripts/verify-update.swift App/Info.plist "$APPCAST" "$VERSION" "$DMG"

# 4. The cask for the tap.
mkdir -p dist/homebrew/Casks
scripts/render-cask.sh "$VERSION" "$SHA" > dist/homebrew/Casks/postern.rb

echo "Ready: $DMG, dist/Postern.dmg, dist/release-notes.md, $APPCAST, dist/homebrew/Casks/postern.rb"
echo "Publication, each step on the maintainer's go-ahead: scripts/publish.sh release $VERSION, then tap, then site."
