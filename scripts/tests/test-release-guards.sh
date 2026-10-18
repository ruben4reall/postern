#!/bin/bash
# scripts/release.sh refuses what must never be published: a malformed version or build number, uncommitted sources,
# a version already tagged or already in the update feed, a build number not higher than every released one, a
# version without release notes, a missing notarization key.
source "$(dirname "$0")/lib.sh"

fresh() {   # a throwaway copy of the working tree, committed, with an empty feed and release notes for its version
  rm -rf "$TMP/repo" && mkdir "$TMP/repo"
  rsync -a --exclude .git --exclude build --exclude dist --exclude .build --exclude graphify-out "$ROOT/" "$TMP/repo/"
  cd "$TMP/repo"
  sed -i '' 's/CURRENT_PROJECT_VERSION: .*/CURRENT_PROJECT_VERSION: "5"/' project.yml
  printf '<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel></channel></rss>\n' > site/appcast.xml
  git init -q && git config user.name Test && git config user.email "tests@localhost"
  VERSION=$(grep -m1 'MARKETING_VERSION:' project.yml | awk '{print $2}' | tr -d '"')
  printf '# Changelog\n\n## %s (2026-10-18)\n\n- Test.\n' "$VERSION" > CHANGELOG.md
  git add -A && git commit -q -m "Snapshot"
  touch "$TMP/AuthKey_TEST.p8"
}
release() { POSTERN_TEAM_ID=TEAMTEST NOTARY_KEY_ID="TEST" NOTARY_ISSUER_ID="TEST" NOTARY_KEY_PATH="$TMP/AuthKey_TEST.p8" scripts/release.sh "$@"; }
item() {   # item <short version> <build>: a feed offering that release
  printf '<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><item>\n<sparkle:version>%s</sparkle:version>\n<sparkle:shortVersionString>%s</sparkle:shortVersionString>\n</item></channel></rss>\n' "$2" "$1"
}

fresh; sed -i '' 's/MARKETING_VERSION: .*/MARKETING_VERSION: "1.0"/' project.yml && git commit -qam "Bad version"
refuses "a malformed version" "is not x.y.z" release --check
fresh; sed -i '' 's/CURRENT_PROJECT_VERSION: .*/CURRENT_PROJECT_VERSION: "0.1.1"/' project.yml && git commit -qam "Bad build"
refuses "a build number that is not a whole number" "is not a whole number" release --check
fresh
refuses "no team" "set POSTERN_TEAM_ID" scripts/release.sh --check
fresh; echo "change" >> README.md
refuses "uncommitted changes" "uncommitted changes" release --check
fresh; git tag "v$VERSION"
refuses "a version already tagged" "tag v$VERSION exists" release --check
fresh; printf '# Changelog\n' > CHANGELOG.md && git commit -qam "No notes"
refuses "a version without release notes" "has no '## $VERSION" release --check
fresh; item "$VERSION" 4 > site/appcast.xml && git commit -qam "Feed"
refuses "a version already in the feed" "already offers $VERSION" release --check
fresh; item 9.9.9 5 > site/appcast.xml && git commit -qam "Feed"
refuses "a build number already released" "build 5 is not higher than build 5" release --check
fresh; sed -i '' 's/CURRENT_PROJECT_VERSION: .*/CURRENT_PROJECT_VERSION: "1"/' project.yml && git commit -qam "Build 1"
refuses "the build number of 0.1.0" "build 1 is not higher than build 1" release --check
fresh
refuses "a missing notarization key" "does not name a file" env POSTERN_TEAM_ID=TEAMTEST NOTARY_KEY_ID="TEST" NOTARY_ISSUER_ID="TEST" NOTARY_KEY_PATH="$TMP/none.p8" scripts/release.sh --check
