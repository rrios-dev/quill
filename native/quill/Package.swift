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
        .library(name: "ListenKit", targets: ["ListenKit"]),
        .library(name: "SynthesisKit", targets: ["SynthesisKit"]),
        .library(name: "MeetingKit", targets: ["MeetingKit"]),
        .executable(name: "Quill", targets: ["Quill"]),
        .executable(name: "quill-mcp", targets: ["QuillMCP"]),
        .executable(name: "quill-bench", targets: ["QuillBench"]),
        .executable(name: "meeting-bench", targets: ["MeetingBench"]),
    ],
    dependencies: [
        .package(name: "Ambar", path: ".."),
        // Speaker diarization on the Neural Engine, Apache 2.0 (MEETINGS.md). The only
        // third-party dependency, confined to SpeakerKit, and only because macOS has no
        // diarization of its own (checked in the macOS 27 SDK). Everything else in a
        // meeting — capture, transcription, echo cancellation — is the system's.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4"),
        // The MCP server agents launch (docs/initiatives/mac-apps-mcp/DESIGN.md): the
        // owner's own package, MIT, Foundation only — shared with Ámbar and Tessera.
        .package(url: "https://github.com/rrios-dev/mcpkit.git", from: "0.2.0"),
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

        // Meeting transcription: capturing a meeting app's audio and the microphone, and
        // turning both into a transcript on the device (MEETINGS.md). Keeps no audio.
        // Knows nothing about models, profiles or AppKit.
        .target(
            name: "ListenKit",
            path: "packages/ListenKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // Meeting synthesis: focuses, prompts and chunking for short contexts, over
        // ModelKit (MEETINGS.md §3). Knows nothing about audio or AppKit.
        .target(
            name: "SynthesisKit",
            dependencies: ["ModelKit"],
            path: "packages/SynthesisKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // Meetings as Quill keeps them: records, people, roles, focuses on disk, and which
        // apps meetings happen in (MEETINGS.md §6–7). No UI, no models.
        .target(
            name: "MeetingKit",
            dependencies: ["ListenKit", "SynthesisKit"],
            path: "packages/MeetingKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // Telling the other people in a meeting apart (diarization), over FluidAudio.
        // Its own target so the dependency stays out of everything else.
        .target(
            name: "SpeakerKit",
            dependencies: [
                "ListenKit",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            path: "packages/SpeakerKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // What agents (Claude Code, Codex…) can do with Quill over MCP: the tools, the access
        // switch and log, and the request the MCP server hands to the running app
        // (docs/initiatives/mac-apps-mcp/DESIGN.md). No AppKit.
        .target(
            name: "QuillAgent",
            dependencies: [
                "MeetingKit", "SynthesisKit", "ListenKit", "RewriteKit",
                .product(name: "MCPKit", package: "mcpkit"),
            ],
            path: "packages/QuillAgent",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // quill-mcp: the MCP server inside Quill.app, launched by the agent over stdio.
        .executableTarget(
            name: "QuillMCP",
            dependencies: [
                "QuillAgent", "QuillSupport", "MeetingKit",
                .product(name: "MCPKit", package: "mcpkit"),
            ],
            path: "apps/QuillMCP",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // The app. Thin: wiring and UI (ARCHITECTURE §5).
        .executableTarget(
            name: "Quill",
            dependencies: [
                "QuillSupport", "SelectionKit", "ModelKit", "RewriteKit", "ListenKit", "SpeakerKit",
                "SynthesisKit", "MeetingKit", "QuillAgent",
                .product(name: "MCPKit", package: "mcpkit"),
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
            dependencies: ["RewriteKit", "ModelKit", "QuillSupport", "SynthesisKit"],
            path: "tools/QuillBench",
            exclude: ["data"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // meeting-bench: transcription and voice separation scored on meetings with a
        // known answer (docs/initiatives/quill/TESTING-MEETINGS.md, tier T2). The corpus
        // fetchers are Python and the gate is data, both excluded from the target.
        .executableTarget(
            name: "MeetingBench",
            dependencies: ["ListenKit", "SpeakerKit"],
            path: "tools/MeetingBench",
            exclude: ["fetch_corpus.py", "fetch_ami.py", "remote_zip.py", "gate.json", "owner-script.txt"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MeetingBenchTests",
            dependencies: ["MeetingBench"],
            path: "Tests/MeetingBenchTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        .testTarget(
            name: "QuillAgentTests",
            dependencies: ["QuillAgent", "MeetingKit", "ListenKit", "SynthesisKit", "RewriteKit",
                           .product(name: "MCPKit", package: "mcpkit")],
            path: "Tests/QuillAgentTests",
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
            name: "ListenKitTests",
            dependencies: ["ListenKit"],
            path: "Tests/ListenKitTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "SynthesisKitTests",
            dependencies: ["SynthesisKit", "ModelKit"],
            path: "Tests/SynthesisKitTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "MeetingKitTests",
            dependencies: ["MeetingKit", "ListenKit", "SynthesisKit"],
            path: "Tests/MeetingKitTests",
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
