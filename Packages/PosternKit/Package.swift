// swift-tools-version:6.2
import PackageDescription

// Every dependency is pinned to an exact version: an update is a reviewed change, never a side effect of a build.
let package = Package(
    name: "PosternKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "PosternModel", targets: ["PosternModel"]),
        .library(name: "PosternText", targets: ["PosternText"]),
        .library(name: "PosternMail", targets: ["PosternMail"]),
        .library(name: "PosternBridge", targets: ["PosternBridge"]),
        .library(name: "PosternVault", targets: ["PosternVault"]),
        .library(name: "PosternPolicy", targets: ["PosternPolicy"]),
        .library(name: "PosternServer", targets: ["PosternServer"]),
    ],
    dependencies: [
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.104.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", exact: "2.37.5"),
        .package(url: "https://github.com/apple/swift-nio-imap.git", exact: "0.4.0"),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", exact: "2.14.3"),
    ],
    targets: [
        // Plain value types shared by every process. No I/O.
        .target(name: "PosternModel"),
        // Header decoding and invisible-character removal. No I/O.
        .target(name: "PosternText"),
        // MIME and HTML handling of hostile input. Linked only by the sandboxed parser service.
        .target(
            name: "PosternMail",
            dependencies: ["PosternModel", "PosternText", .product(name: "SwiftSoup", package: "SwiftSoup")]
        ),
        // The connection to Proton Mail Bridge: pinned STARTTLS, IMAP.
        .target(
            name: "PosternBridge",
            dependencies: [
                "PosternModel", "PosternText",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "NIOTLS", package: "swift-nio"),
                .product(name: "NIOIMAP", package: "swift-nio-imap"),
            ]
        ),
        // Secrets and policy in the data protection Keychain.
        .target(name: "PosternVault", dependencies: ["PosternModel"]),
        // What the user allows. No I/O.
        .target(name: "PosternPolicy", dependencies: ["PosternModel"]),
        // The MCP side: tools, sessions, the untrusted envelope.
        .target(
            name: "PosternServer",
            dependencies: [
                "PosternModel", "PosternText", "PosternPolicy",
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),
        .testTarget(name: "PosternModelTests", dependencies: ["PosternModel"]),
        .testTarget(name: "PosternTextTests", dependencies: ["PosternText"]),
        .testTarget(name: "PosternMailTests", dependencies: ["PosternMail"]),
        .testTarget(
            name: "PosternBridgeTests",
            dependencies: [
                "PosternBridge",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "NIOIMAP", package: "swift-nio-imap"),
            ]
        ),
        .testTarget(name: "PosternPolicyTests", dependencies: ["PosternPolicy"]),
        .testTarget(name: "PosternServerTests", dependencies: ["PosternServer", .product(name: "MCP", package: "swift-sdk")]),
    ],
    swiftLanguageModes: [.v6]
)
