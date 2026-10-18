#!/bin/bash
# scripts/publish.sh <release|tap|site> <version> [--confirm <version>]
#
# The publication steps of a release, in this order, once scripts/release.sh is done. Each one needs the maintainer's
# go-ahead: in a terminal it asks for the version to be typed; an agent passes --confirm <version> only after the
# maintainer has said yes to that step.
#   release  tags the commit the app was built from as v<version>, pushes the tag, publishes the GitHub release with
#            the disk images, then checks that the published file is the one the update feed signs
#   tap      pushes the release's cask to ruben4reall/homebrew-tap, once the published download matches its SHA-256
#   site     deploys site/ to Vercel production in the scope POSTERN_VERCEL_SCOPE names (the maintainer's personal
#            scope, never a team), checks the live feed, then opens a pull request with the new site/appcast.xml
set -euo pipefail
cd "$(dirname "$0")/.."
REPO=ruben4reall/postern
TAP=ruben4reall/homebrew-tap
SITE_URL=https://getpostern.vercel.app
STEP="${1:-}"
VERSION="${2:-}"
fail() { echo "publish: $*" >&2; exit 1; }
if [[ ! "$STEP" =~ ^(release|tap|site)$ ]] || [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  fail "usage: scripts/publish.sh <release|tap|site> <version> [--confirm <version>]"
fi
DMG="dist/Postern-$VERSION.dmg"
DOWNLOAD="https://github.com/$REPO/releases/download/v$VERSION/Postern-$VERSION.dmg"

confirm() {
  if [ "${3:-}" = "--confirm" ] && [ "${4:-}" = "$VERSION" ]; then return 0; fi
  [ -t 0 ] || fail "not confirmed: run it in a terminal, or pass --confirm $VERSION once the maintainer has said yes"
  local answer
  read -r -p "Publish ($STEP) Postern $VERSION? Type the version to go ahead: " answer
  [ "$answer" = "$VERSION" ] || fail "not confirmed"
}

fetch() {   # fetch <url> <file>: downloads a published file, following GitHub's redirects
  curl -fsSL --retry 3 -o "$2" "$1" || fail "cannot download $1"
}

publish_release() {
  local file commit tmp
  for file in "$DMG" "$DMG.sha256" dist/Postern.dmg dist/release-notes.md dist/build-commit.txt; do
    [ -f "$file" ] || fail "dist/ is incomplete ($file): run scripts/release.sh for $VERSION first"
  done
  cmp -s "$DMG" dist/Postern.dmg || fail "dist/Postern.dmg is not the same file as $DMG"
  xcrun stapler validate "$DMG" >/dev/null || fail "$DMG carries no notarization ticket"
  swift scripts/verify-update.swift App/Info.plist site/appcast.xml "$VERSION" "$DMG"
  commit=$(cat dist/build-commit.txt)
  git fetch -q origin main
  git merge-base --is-ancestor "$commit" origin/main || fail "the build commit $commit is not on origin/main"
  if git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null; then fail "tag v$VERSION exists"; fi
  git tag -a "v$VERSION" "$commit" -m "Postern $VERSION"
  git push -q origin "v$VERSION"
  gh release create "v$VERSION" "$DMG" "$DMG.sha256" dist/Postern.dmg --repo "$REPO" --title "Postern $VERSION" \
    --notes-file dist/release-notes.md --verify-tag
  tmp=$(mktemp -d)
  fetch "$DOWNLOAD" "$tmp/Postern-$VERSION.dmg"
  cmp -s "$tmp/Postern-$VERSION.dmg" "$DMG" || fail "the published $DOWNLOAD differs from $DMG"
  swift scripts/verify-update.swift App/Info.plist site/appcast.xml "$VERSION" "$tmp/Postern-$VERSION.dmg"
  fetch "https://github.com/$REPO/releases/latest/download/Postern.dmg" "$tmp/Postern.dmg"
  cmp -s "$tmp/Postern.dmg" "$DMG" || fail "releases/latest/download/Postern.dmg is not Postern $VERSION"
  rm -rf "$tmp"
  echo "Published: https://github.com/$REPO/releases/tag/v$VERSION"
}

publish_tap() {
  local cask=dist/homebrew/Casks/postern.rb clone=build/homebrew-tap tmp published
  [ -f "$cask" ] || fail "$cask is missing: run scripts/finish-release.sh $VERSION"
  grep -qF "version \"$VERSION\"" "$cask" || fail "$cask is not for $VERSION"
  tmp=$(mktemp -d)
  fetch "$DOWNLOAD" "$tmp/Postern-$VERSION.dmg"
  published=$(shasum -a 256 "$tmp/Postern-$VERSION.dmg" | awk '{print $1}')
  rm -rf "$tmp"
  grep -qF "sha256 \"$published\"" "$cask" || fail "the cask's SHA-256 is not the published download's ($published)"
  if [ -d "$clone/.git" ]; then git -C "$clone" pull -q --ff-only; else gh repo clone "$TAP" "$clone" -- -q; fi
  mkdir -p "$clone/Casks"
  cp "$cask" "$clone/Casks/postern.rb"
  git -C "$clone" add Casks/postern.rb
  if git -C "$clone" diff --cached --quiet; then echo "The tap already has postern $VERSION."; return 0; fi
  git -C "$clone" -c user.name="Ruben Catalao" -c user.email=ruben.ctlo@protonmail.com commit -q -m "postern $VERSION"
  git -C "$clone" push -q origin HEAD
  echo "Pushed postern $VERSION to $TAP: brew install --cask ruben4reall/tap/postern"
}

publish_site() {
  local newest url code tmp branch
  : "${POSTERN_VERCEL_SCOPE:?set POSTERN_VERCEL_SCOPE to the personal Vercel scope of the maintainer}"
  grep -q '"projectName": *"getpostern"' site/.vercel/project.json 2>/dev/null \
    || fail "site/ is not linked to the Vercel project getpostern: (cd site && vercel link --yes --project getpostern --scope \"\$POSTERN_VERCEL_SCOPE\")"
  xmllint --noout site/appcast.xml || fail "site/appcast.xml is not well-formed XML"
  newest=$(xmllint --xpath 'string(/rss/channel/item[1]/*[local-name()="shortVersionString"])' site/appcast.xml)
  [ "$newest" = "$VERSION" ] || fail "the feed's newest item is '$newest', not $VERSION: run scripts/finish-release.sh $VERSION"
  url=$(xmllint --xpath 'string(/rss/channel/item[1]/enclosure/@url)' site/appcast.xml)
  [ "$url" = "$DOWNLOAD" ] || fail "the newest item downloads $url"
  code=$(curl -s -o /dev/null -L -w '%{http_code}' "$url")
  [ "$code" = 200 ] || fail "$url answers $code: publish the release first (scripts/publish.sh release $VERSION)"
  (cd site && vercel deploy --prod --yes --scope "$POSTERN_VERCEL_SCOPE")
  tmp=$(mktemp)
  fetch "$SITE_URL/appcast.xml" "$tmp"
  cmp -s "$tmp" site/appcast.xml || fail "$SITE_URL/appcast.xml is not the local feed"
  rm -f "$tmp"
  if git diff --quiet -- site/appcast.xml; then echo "Live: $SITE_URL (the feed was already committed)"; return 0; fi
  branch="appcast-$VERSION"
  git switch -q -c "$branch"
  git add site/appcast.xml
  git commit -q -m "Publish the update feed for $VERSION"
  git push -q -u origin "$branch"
  gh pr create --repo "$REPO" --head "$branch" --title "Publish the update feed for $VERSION" \
    --body "The feed deployed on $SITE_URL for Postern $VERSION, as served now."
  echo "Live: $SITE_URL. Merge the pull request above to keep the repository in step."
}

confirm "$@"
"publish_$STEP"
