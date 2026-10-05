import Foundation
import Testing

@testable import Quill

@Suite("Data directory")
struct AppPathsTests {
    private let support = URL(fileURLWithPath: "/Users/someone/Library/Application Support", isDirectory: true)

    @Test("defaults to Application Support/<bundle id>")
    func defaultLocation() {
        let url = AppPaths.dataDirectory(
            bundleIdentifier: "dev.example.app", applicationSupport: support, overrideDirectory: nil)
        #expect(url.path == "/Users/someone/Library/Application Support/dev.example.app")
    }

    @Test("falls back to the development bundle id when the process has none (tests, swift run)")
    func missingBundleIdentifier() {
        let url = AppPaths.dataDirectory(
            bundleIdentifier: nil, applicationSupport: support, overrideDirectory: nil)
        #expect(url.lastPathComponent == AppPaths.defaultBundleIdentifier)
    }

    @Test("the debug hook's directory replaces it; an empty value does not")
    func overrideDirectory() {
        let overridden = AppPaths.dataDirectory(
            bundleIdentifier: "dev.example.app", applicationSupport: support,
            overrideDirectory: "/tmp/isolated")
        #expect(overridden.path == "/tmp/isolated")

        let empty = AppPaths.dataDirectory(
            bundleIdentifier: "dev.example.app", applicationSupport: support, overrideDirectory: "")
        #expect(empty.lastPathComponent == "dev.example.app")
    }

    @Test("debug hooks read the environment in debug builds and nothing in release builds")
    func hooksFollowTheBuild() {
        let environment = ["QUILL_DATA_DIR": "/tmp/isolated"]
        #if DEBUG
        #expect(DebugHooks.value("QUILL_DATA_DIR", in: environment) == "/tmp/isolated")
        #else
        #expect(DebugHooks.value("QUILL_DATA_DIR", in: environment) == nil)
        #endif
        #expect(DebugHooks.value("QUILL_ABSENT", in: environment) == nil)
    }
}
