// swift-tools-version: 6.2
import PackageDescription

// Quill — rewrite selected text with profiles.
//
// Its own package, nested under `native/` but outside `native/Package.swift`:
// Ámbar's public export copies `native/`, and this directory opts out of it
// with its `.not-exported` marker. Ámbar's shared libraries (AppCore, GlassUI)
// are reused by path; the dependency keeps the name `Ambar` so AppCore's
// resource bundle keeps the name its `StringsBundle` expects.
// See docs/initiatives/quill/ARCHITECTURE.md §1.

let package = Package(
    name: "Quill",
    defaultLocalization: "es",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "QuillSupport", targets: ["QuillSupport"]),
        .library(name: "ModelKit", targets: ["ModelKit"]),
        .library(name: "SelectionKit", targets: ["SelectionKit"]),
        .library(name: "RewriteKit", targets: ["RewriteKit"]),
        .executable(name: "Quill", targets: ["Quill"]),
        .executable(name: "quill-bench", targets: ["QuillBench"]),
    ],
    dependencies: [
        .package(name: "Ambar", path: ".."),
    ],
    targets: [
        // Leaf utilities every Quill target may import. Depends on nothing.
        .target(
            name: "QuillSupport",
            path: "packages/QuillSupport",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                // User text reaches the log only in debug builds (ARCHITECTURE §6).
                .define("QUILL_LOG_USER_TEXT", .when(configuration: .debug)),
            ]
        ),

        // Provider-agnostic language-model contract plus its adapters (Apple
        // on-device, Chat Completions presets). Dependency-free; logs nothing.
        .target(
            name: "ModelKit",
            path: "packages/ModelKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // Reading and replacing text in other apps (ARCHITECTURE §3). Knows nothing
        // about models or profiles.
        .target(
            name: "SelectionKit",
            dependencies: [
                "QuillSupport",
                .product(name: "AppCore", package: "Ambar"),
            ],
            path: "packages/SelectionKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // Profiles, prompts, guards, generation and evaluation (ARCHITECTURE §4).
        // Knows nothing about AppKit, the Accessibility API or SelectionKit.
        .target(
            name: "RewriteKit",
            dependencies: ["ModelKit", "QuillSupport"],
            path: "packages/RewriteKit",
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // The app. Thin: wiring and UI (ARCHITECTURE §5).
        .executableTarget(
            name: "Quill",
            dependencies: [
                "QuillSupport", "SelectionKit", "ModelKit", "RewriteKit",
                .product(name: "AppCore", package: "Ambar"),
                .product(name: "GlassUI", package: "Ambar"),
            ],
            path: "apps/Quill",
            // Copied into the bundle by Scripts/make-app.sh, not resources of the target.
            exclude: ["Info.plist", "Quill.entitlements", "BundleResources"],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // The bench CLI (BENCH.md). Every non-Swift file of the bench lives in data/,
        // excluded so SwiftPM raises no warning for it.
        .executableTarget(
            name: "QuillBench",
            dependencies: ["RewriteKit", "ModelKit", "QuillSupport"],
            path: "tools/QuillBench",
            exclude: ["data"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        .testTarget(
            name: "ModelKitTests",
            dependencies: ["ModelKit"],
            path: "Tests/ModelKitTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SelectionKitTests",
            dependencies: ["SelectionKit"],
            path: "Tests/SelectionKitTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "RewriteKitTests",
            dependencies: ["RewriteKit", "ModelKit"],
            path: "Tests/RewriteKitTests",
            // Golden files and fixtures are read by path, not bundled.
            exclude: ["Golden", "Fixtures"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "QuillBenchTests",
            dependencies: ["QuillBench", "RewriteKit", "ModelKit"],
            path: "Tests/QuillBenchTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "QuillTests",
            dependencies: ["Quill", "QuillSupport", "RewriteKit", "ModelKit"],
            path: "Tests/QuillTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
