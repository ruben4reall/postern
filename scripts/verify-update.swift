// swift scripts/verify-update.swift <Info.plist> <appcast.xml> [<version> <file.dmg>]
//
// Checks what Sparkle checks before it installs an update: the whole feed carries a valid EdDSA (Ed25519) signature
// under the public key in <Info.plist> (SUPublicEDKey; the app sets SURequireSignedFeed). With a version and a disk
// image, also that the feed offers <version>, and that <file.dmg> has that item's exact length and a valid signature.
// scripts/finish-release.sh runs it on the local image; scripts/publish.sh runs it on the published download.
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("verify-update: \(message)\n".utf8))
    exit(1)
}

let arguments = CommandLine.arguments
guard arguments.count == 3 || arguments.count == 5 else {
    fail("usage: verify-update.swift <Info.plist> <appcast.xml> [<version> <file.dmg>]")
}
let (plistPath, appcastPath) = (arguments[1], arguments[2])

guard let plistData = FileManager.default.contents(atPath: plistPath),
      let plist = try? PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
      let keyString = plist["SUPublicEDKey"] as? String, let keyData = Data(base64Encoded: keyString),
      let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData)
else { fail("no valid SUPublicEDKey in \(plistPath)") }

// The feed's signature sits in a comment at its end, over every byte before that comment (SPUExtractSignedFeed.m).
guard let feedData = FileManager.default.contents(atPath: appcastPath) else { fail("cannot read \(appcastPath)") }
let prefix = Data("<!-- sparkle-signatures:\n".utf8)
guard let block = feedData.range(of: prefix, options: .backwards),
      let end = feedData.range(of: Data("-->".utf8), in: block.upperBound..<feedData.endIndex),
      let fields = String(data: feedData[block.upperBound..<end.lowerBound], encoding: .utf8)
else { fail("\(appcastPath) is not signed") }
let content = feedData[feedData.startIndex..<block.lowerBound]
var feedSignature: Data?
var feedLength: Int?
for line in fields.split(separator: "\n") {
    if line.hasPrefix("edSignature:") {
        feedSignature = Data(base64Encoded: line.dropFirst("edSignature:".count).trimmingCharacters(in: .whitespaces))
    } else if line.hasPrefix("length:") {
        feedLength = Int(line.dropFirst("length:".count).trimmingCharacters(in: .whitespaces))
    }
}
guard let feedSignature, let feedLength else { fail("\(appcastPath) has an incomplete signature block") }
guard content.count == feedLength else { fail("\(appcastPath) is \(content.count) bytes before its signature, it says \(feedLength)") }
guard publicKey.isValidSignature(feedSignature, for: content) else { fail("the feed's EdDSA signature does not match \(appcastPath)") }
guard arguments.count == 5 else {
    print("OK: \(appcastPath), feed signature valid")
    exit(0)
}

let (version, archivePath) = (arguments[3], arguments[4])
guard let feed = try? XMLDocument(data: feedData, options: []) else { fail("cannot parse \(appcastPath)") }
let items = ((try? feed.nodes(forXPath: "/rss/channel/item")) ?? []).compactMap { $0 as? XMLElement }
let offered = items.first { item in
    item.elements(forName: "sparkle:shortVersionString").first?.stringValue == version
}
guard let offered, let enclosure = offered.elements(forName: "enclosure").first else { fail("\(appcastPath) offers no \(version)") }
guard let signatureString = enclosure.attribute(forName: "sparkle:edSignature")?.stringValue,
      let signature = Data(base64Encoded: signatureString) else { fail("the \(version) item has no EdDSA signature") }
guard let lengthString = enclosure.attribute(forName: "length")?.stringValue, let length = Int(lengthString) else {
    fail("the \(version) item has no length")
}
guard let archive = FileManager.default.contents(atPath: archivePath) else { fail("cannot read \(archivePath)") }
guard archive.count == length else { fail("\(archivePath) is \(archive.count) bytes, the appcast says \(length)") }
guard publicKey.isValidSignature(signature, for: archive) else { fail("the EdDSA signature does not match \(archivePath)") }
print("OK: feed signature valid; \(version), \(length) bytes, signature valid, \(enclosure.attribute(forName: "url")?.stringValue ?? "no url")")
