// swift-tools-version: 6.2
import PackageDescription

// The Ámbar libraries Quill reuses, exported with Quill so its repository builds on its own:
// AppCore (shortcuts, paste, launch at login), GlassUI (Liquid Glass primitives), VoiceKit
// (the dictation engine and its dictionary, for dictate and rewrite) and AgentHost (the
// local channel to Batuta, over MCPKit).
// Ámbar itself lives at github.com/rrios-dev/ambar. The package keeps the name `Ambar`
// because AppCore's resource bundle is named after it.

let package = Package(
    name: "Ambar",
    defaultLocalization: "es",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "GlassUI", targets: ["GlassUI"]),
        .library(name: "AppCore", targets: ["AppCore"]),
        .library(name: "VoiceKit", targets: ["VoiceKit"]),
        .library(name: "AgentHost", targets: ["AgentHost"]),
    ],
    dependencies: [
        .package(url: "https://github.com/rrios-dev/mcpkit.git", from: "0.2.0"),
    ],
    targets: [
        .target(
            name: "GlassUI",
            path: "packages/GlassUI",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "AppCore",
            path: "packages/AppCore",
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "VoiceKit",
            path: "packages/VoiceKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "AgentHost",
            dependencies: [.product(name: "MCPKit", package: "mcpkit")],
            path: "packages/AgentHost",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
