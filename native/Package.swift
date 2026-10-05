// swift-tools-version: 6.2
import PackageDescription

// The two Ámbar libraries Quill reuses, exported with Quill so its repository builds on its
// own: AppCore (shortcuts, paste, launch at login) and GlassUI (Liquid Glass primitives).
// Ámbar itself lives at github.com/rrios-dev/ambar. The package keeps the name `Ambar`
// because AppCore's resource bundle is named after it.

let package = Package(
    name: "Ambar",
    defaultLocalization: "es",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "GlassUI", targets: ["GlassUI"]),
        .library(name: "AppCore", targets: ["AppCore"]),
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
    ]
)
