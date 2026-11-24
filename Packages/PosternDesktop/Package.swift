// swift-tools-version:6.2
import PackageDescription

// Postern on Linux and Windows: the core as a background process, the relay MCP apps launch, the jailed message
// reader, the command line, and on Linux the GTK app. The Mac app is in the Xcode project; everything here shares
// PosternKit with it. Every dependency is pinned exactly, as in PosternKit.
let linux: [Platform] = [.linux]
let windows: [Platform] = [.windows]

let package = Package(
    name: "PosternDesktop",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "postern-core", targets: ["postern-core"]),
        .executable(name: "postern-mcp", targets: ["postern-mcp"]),
        .executable(name: "postern-parser", targets: ["postern-parser"]),
        .executable(name: "postern", targets: ["postern"]),
        .executable(name: "postern-app", targets: ["postern-app"]),
    ],
    dependencies: [
        .package(path: "../PosternKit"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "5.1.1"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
    ],
    targets: [
        // Linux: the reader's jail (seccomp, Landlock, limits) and the socket peer's credentials. Empty elsewhere.
        .target(name: "CPosternSys"),
        // Linux: the desktop's secret store, through libsecret.
        .systemLibrary(
            name: "CLibSecret", pkgConfig: "libsecret-1",
            providers: [.apt(["libsecret-1-dev"]), .yum(["libsecret-devel"])]
        ),
        .target(name: "CPosternSecret", dependencies: [.target(name: "CLibSecret", condition: .when(platforms: linux))]),
        // Linux: GTK 4 and libadwaita for the app.
        .systemLibrary(
            name: "CGtk", pkgConfig: "libadwaita-1",
            providers: [.apt(["libadwaita-1-dev", "libgtk-4-dev"]), .yum(["libadwaita-devel", "gtk4-devel"])]
        ),
        // What differs from one system to the other: secrets, the local channel, the jailed reader, the proof that
        // the user approved, the paths of the apps' settings files, and the control protocol of the interface.
        .target(
            name: "PosternPlatform",
            dependencies: [
                "CPosternSys",
                .target(name: "CPosternSecret", condition: .when(platforms: linux)),
                .product(name: "PosternCore", package: "PosternKit"),
                .product(name: "PosternModel", package: "PosternKit"),
                .product(name: "PosternVault", package: "PosternKit"),
                .product(name: "PosternPolicy", package: "PosternKit"),
                .product(name: "PosternServer", package: "PosternKit"),
                .product(name: "PosternApproval", package: "PosternKit"),
                .product(name: "PosternBridge", package: "PosternKit"),
                .product(name: "PosternAudit", package: "PosternKit"),
                .product(name: "PosternClients", package: "PosternKit"),
                .product(name: "PosternCompose", package: "PosternKit"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),
        // The core, one per user: holds the secrets, talks to Bridge, runs one MCP session per relay.
        .executableTarget(
            name: "postern-core",
            dependencies: ["PosternPlatform"],
            linkerSettings: [.unsafeFlags(["-Xlinker", "/SUBSYSTEM:WINDOWS", "-Xlinker", "/ENTRY:mainCRTStartup"], .when(platforms: windows))]
        ),
        // What MCP apps launch: carries JSON-RPC lines between stdio and the core. No secret, no decision.
        .executableTarget(name: "postern-mcp", dependencies: ["PosternPlatform"]),
        // Reads one hostile message, jailed, and exits. Links the mail reader and nothing that reaches the network.
        .executableTarget(
            name: "postern-parser",
            dependencies: [
                "CPosternSys",
                .product(name: "PosternMail", package: "PosternKit"),
                .product(name: "PosternModel", package: "PosternKit"),
            ]
        ),
        // The command line: status, setup, tools, apps, activity.
        .executableTarget(
            name: "postern",
            dependencies: [
                "PosternPlatform",
                .product(name: "PosternModel", package: "PosternKit"),
                .product(name: "PosternPolicy", package: "PosternKit"),
            ]
        ),
        // The Linux app. Elsewhere it builds to a stub that says so.
        .executableTarget(
            name: "postern-app",
            dependencies: [
                "PosternPlatform",
                .product(name: "PosternModel", package: "PosternKit"),
                .product(name: "PosternPolicy", package: "PosternKit"),
                .target(name: "CGtk", condition: .when(platforms: linux)),
            ],
            // GTK's C types are not Sendable: the app keeps to GTK's main thread itself (onMain).
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "PosternPlatformTests",
            dependencies: [
                "PosternPlatform",
                .product(name: "PosternCore", package: "PosternKit"),
                .product(name: "PosternModel", package: "PosternKit"),
                .product(name: "PosternVault", package: "PosternKit"),
                .product(name: "PosternPolicy", package: "PosternKit"),
                .product(name: "PosternApproval", package: "PosternKit"),
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
