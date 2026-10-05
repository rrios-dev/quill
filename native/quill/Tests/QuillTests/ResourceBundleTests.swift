import Foundation
import Testing

import QuillSupport

@Suite("Resource bundle resolution")
struct ResourceBundleTests {
    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ResourceBundleTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("a bundle in the app's Resources wins over the fallback")
    func packagedBundleWins() throws {
        let resources = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: resources) }
        let packaged = resources.appendingPathComponent("Example_Target.bundle", isDirectory: true)
        try FileManager.default.createDirectory(at: packaged, withIntermediateDirectories: true)

        let bundle = ResourceBundle.resolve("Example_Target", in: resources, fallback: .main)

        #expect(bundle.bundleURL.standardizedFileURL == packaged.standardizedFileURL)
    }

    @Test("without a packaged bundle, the fallback is used")
    func fallbackWhenMissing() throws {
        let resources = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: resources) }

        let bundle = ResourceBundle.resolve("Example_Target", in: resources, fallback: .main)

        #expect(bundle == .main)
    }

    @Test("with no Resources directory at all, the fallback is used")
    func fallbackWithoutDirectory() {
        #expect(ResourceBundle.resolve("Example_Target", in: nil, fallback: .main) == .main)
    }
}
