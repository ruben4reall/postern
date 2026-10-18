#!/bin/bash
# scripts/verify-update.swift accepts exactly the feed and the disk image Postern's key signs, and nothing else.
source "$(dirname "$0")/lib.sh"
cd "$ROOT"
swift scripts/tests/make-update-fixture.swift "$TMP/release" >/dev/null
swift scripts/tests/make-update-fixture.swift "$TMP/other" >/dev/null      # another key pair
R="$TMP/release"
verify() { swift scripts/verify-update.swift "$@"; }
check "the signed feed passes" verify "$R/Info.plist" "$R/appcast.xml"
check "the signed image passes" verify "$R/Info.plist" "$R/appcast.xml" 1.0.0 "$R/Postern-1.0.0.dmg"
cp "$R/Postern-1.0.0.dmg" "$TMP/changed.dmg" && printf 'B' | dd of="$TMP/changed.dmg" bs=1 seek=100 conv=notrunc 2>/dev/null
refuses "a changed byte fails" "signature does not match" verify "$R/Info.plist" "$R/appcast.xml" 1.0.0 "$TMP/changed.dmg"
cp "$R/Postern-1.0.0.dmg" "$TMP/longer.dmg" && printf 'A' >> "$TMP/longer.dmg"
refuses "another length fails" "the appcast says" verify "$R/Info.plist" "$R/appcast.xml" 1.0.0 "$TMP/longer.dmg"
refuses "a version the feed does not offer fails" "offers no 1.0.1" verify "$R/Info.plist" "$R/appcast.xml" 1.0.1 "$R/Postern-1.0.0.dmg"
refuses "another key fails" "feed's EdDSA signature does not match" verify "$TMP/other/Info.plist" "$R/appcast.xml"
sed 's/<title>Postern</<title>Pastern</' "$R/appcast.xml" > "$TMP/edited.xml"
refuses "an edited feed fails" "feed's EdDSA signature does not match" verify "$R/Info.plist" "$TMP/edited.xml"
sed '/sparkle-signatures/,$d' "$R/appcast.xml" > "$TMP/unsigned.xml"
refuses "an unsigned feed fails" "is not signed" verify "$R/Info.plist" "$TMP/unsigned.xml"
