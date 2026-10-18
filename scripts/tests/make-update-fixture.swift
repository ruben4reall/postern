// swift scripts/tests/make-update-fixture.swift <dir>: a fake release signed the way Sparkle signs one (Ed25519 over
// the whole disk image, and over the whole feed before its signature comment): <dir>/Info.plist (SUPublicEDKey),
// <dir>/Postern-1.0.0.dmg (4096 bytes of "A"), <dir>/appcast.xml offering 1.0.0 as build 2.
import CryptoKit
import Foundation

let dir = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
let key = Curve25519.Signing.PrivateKey()
let archive = Data(repeating: 0x41, count: 4096)
let signature = try key.signature(for: archive).base64EncodedString()
try archive.write(to: dir.appendingPathComponent("Postern-1.0.0.dmg"))
let plist: [String: Any] = ["SUPublicEDKey": key.publicKey.rawRepresentation.base64EncodedString()]
try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: dir.appendingPathComponent("Info.plist"))
let feed = Data("""
<?xml version="1.0" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
    <channel>
        <title>Postern</title>
        <item>
            <title>1.0.0</title>
            <sparkle:version>2</sparkle:version>
            <sparkle:shortVersionString>1.0.0</sparkle:shortVersionString>
            <enclosure url="https://github.com/ruben4reall/postern/releases/download/v1.0.0/Postern-1.0.0.dmg" length="\(archive.count)" type="application/octet-stream" sparkle:edSignature="\(signature)"/>
        </item>
    </channel>
</rss>
""".utf8)
let feedSignature = try key.signature(for: feed).base64EncodedString()
let signed = feed + Data("<!-- sparkle-signatures:\nedSignature: \(feedSignature)\nlength: \(feed.count)\n-->\n".utf8)
try signed.write(to: dir.appendingPathComponent("appcast.xml"))
