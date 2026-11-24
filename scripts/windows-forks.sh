#!/bin/sh
# Points the Windows build at two forks, each upstream's release plus a reviewed patch, until upstream merges them:
#   - the MCP Swift SDK 0.12.1 with modelcontextprotocol/swift-sdk#279 (EventSource guarded by its availability)
#   - swift-nio-ssl with apple/swift-nio-ssl#567 (Windows support) and BoringSSL's TLS callback renamed, so a
#     binary can link swift-crypto too
# Only CI's Windows jobs run this; macOS and Linux build from upstream. docs/threat-model.md lists both forks.
set -eu
cd "$(dirname "$0")/.."
for manifest in Packages/PosternKit/Package.swift Packages/PosternDesktop/Package.swift; do
    sed -i.bak \
        -e 's#.package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1")#.package(url: "https://github.com/ruben4reall/swift-sdk.git", revision: "47629eaef004081f5b1289f52208a4be17af09fc")#' \
        -e 's#.package(url: "https://github.com/apple/swift-nio-ssl.git", exact: "2.37.5")#.package(url: "https://github.com/ruben4reall/swift-nio-ssl.git", revision: "540b4a30d3c1f109a4c88ef317a5eab38741ebc7")#' \
        "$manifest"
    rm -f "$manifest.bak" "$(dirname "$manifest")/Package.resolved"
done
grep -h "ruben4reall" Packages/PosternKit/Package.swift Packages/PosternDesktop/Package.swift
