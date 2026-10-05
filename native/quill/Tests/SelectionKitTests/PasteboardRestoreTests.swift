import AppKit
import Testing

@testable import SelectionKit

/// PLAN P2-T1: snapshot and restore on a private named pasteboard, and the access policy
/// through the fake (only the general pasteboard can be Ask or Deny).
@Suite("Pasteboard snapshot, restore and access policy")
struct PasteboardRestoreTests {
    private func roundTrip(_ items: [NSPasteboardItem]) async throws -> (LivePasteboardClient, [String: Data], PasteboardSnapshotter.RestoreOutcome) {
        let client = LivePasteboardClient.unique()
        let pasteboard = NSPasteboard(name: client.name)
        pasteboard.clearContents()
        pasteboard.writeObjects(items)
        // What was there, type by type, before Quill touched it.
        var before: [String: Data] = [:]
        for (index, types) in client.itemTypes().enumerated() {
            for type in types where !PasteboardMarkers.isRegeneratedAlias(type) {
                before["\(index)|\(type)"] = client.data(forType: type, item: index)
            }
        }
        let outcome = await PasteboardSnapshotter.take(from: client, deadline: .seconds(2), clock: ContinuousClock())
        #expect(outcome.snapshot.isComplete, "\(String(describing: outcome.snapshot.incompleteReason))")
        let written = client.write([PasteboardMarkers.transientText("rewrite")], hostOnly: true)
        let restored = PasteboardSnapshotter.restore(outcome.snapshot, to: client, ifChangeCountIs: written)
        return (client, before, restored)
    }

    private func expectSame(_ client: LivePasteboardClient, as before: [String: Data]) {
        for (key, data) in before {
            let parts = key.split(separator: "|", maxSplits: 1)
            let restored = client.data(forType: String(parts[1]), item: Int(parts[0])!)
            #expect(restored == data, "\(key) differs after the restore")
        }
    }

    @Test("text with RTF is restored byte for byte")
    func textAndRTF() async throws {
        let item = NSPasteboardItem()
        item.setString("plain words, bold words", forType: .string)
        let rich = NSAttributedString(string: "plain words, bold words", attributes: [.font: NSFont.boldSystemFont(ofSize: 12)])
        item.setData(try rich.data(from: NSRange(location: 0, length: rich.length),
                                   documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]), forType: .rtf)
        let (client, before, restored) = try await roundTrip([item])
        defer { client.releaseGlobally() }
        #expect(restored == .restored)
        expectSame(client, as: before)
    }

    @Test("an image is restored byte for byte")
    func image() async throws {
        let image = NSImage(size: NSSize(width: 8, height: 8))
        image.lockFocus()
        NSColor.systemOrange.setFill()
        NSRect(x: 0, y: 0, width: 8, height: 8).fill()
        image.unlockFocus()
        let item = NSPasteboardItem()
        item.setData(try #require(image.tiffRepresentation), forType: .tiff)
        let png = try #require(NSBitmapImageRep(data: image.tiffRepresentation!)?.representation(using: .png, properties: [:]))
        item.setData(png, forType: .png)
        let (client, before, restored) = try await roundTrip([item])
        defer { client.releaseGlobally() }
        #expect(restored == .restored)
        expectSame(client, as: before)
    }

    @Test("file URLs are restored byte for byte, several items included")
    func fileURLs() async throws {
        let urls = [URL(fileURLWithPath: "/tmp/quill-a.txt"), URL(fileURLWithPath: "/tmp/quill-b.txt")]
        let items = urls.map { url -> NSPasteboardItem in
            let item = NSPasteboardItem()
            item.setString(url.absoluteString, forType: .fileURL)
            return item
        }
        let (client, before, restored) = try await roundTrip(items)
        defer { client.releaseGlobally() }
        #expect(restored == .restored)
        #expect(client.itemTypes().count == 2)
        expectSame(client, as: before)
    }

    @Test("file promises make the snapshot incomplete; regenerated aliases are skipped without loss")
    func skippedTypes() async {
        let promise = FakePasteboard(items: [PasteboardItemData(entries: [
            .init(type: "public.utf8-plain-text", data: Data("x".utf8)),
            .init(type: "com.apple.pasteboard.promised-file-url", data: Data()),
        ])])
        let outcome = await PasteboardSnapshotter.take(from: promise, deadline: .seconds(1), clock: ContinuousClock())
        #expect(outcome.snapshot.incompleteReason == .skippedType)

        let alias = FakePasteboard(items: [PasteboardItemData(entries: [
            .init(type: "public.tiff", data: Data([1, 2, 3])),
            .init(type: "NeXT TIFF v4.0 pasteboard type", data: Data([1, 2, 3])),
        ])])
        let aliased = await PasteboardSnapshotter.take(from: alias, deadline: .seconds(1), clock: ContinuousClock())
        #expect(aliased.snapshot.isComplete)
        #expect(aliased.snapshot.items.first?.types == ["public.tiff"])
    }

    @Test("over 10 MB the snapshot is abandoned")
    func sizeCap() async {
        let big = FakePasteboard(items: [PasteboardItemData(entries: [
            .init(type: "public.tiff", data: Data(count: PasteboardSnapshot.defaultSizeCap + 1)),
        ])])
        let outcome = await PasteboardSnapshotter.take(from: big, deadline: .seconds(1), clock: ContinuousClock())
        #expect(outcome.snapshot.incompleteReason == .tooLarge)
        #expect(outcome.snapshot.items.isEmpty)
    }

    @Test("a read that does not finish in time leaves an incomplete snapshot and a pending read; it is never restored")
    func timedOutRead() async {
        let slow = FakePasteboard(items: [PasteboardItemData(entries: [.init(type: "com.example.lazy", data: Data([9]))])])
        slow.blockingTypes = ["com.example.lazy"]
        let outcome = await PasteboardSnapshotter.take(from: slow, deadline: .milliseconds(50), clock: ContinuousClock())
        #expect(outcome.snapshot.incompleteReason == .timedOut)
        let pending = outcome.pendingRead
        #expect(pending != nil, "the caller is told a read may still be running")
        let written = slow.write([PasteboardMarkers.transientText("rewrite")], hostOnly: true)
        #expect(PasteboardSnapshotter.restore(outcome.snapshot, to: slow, ifChangeCountIs: written) == .skippedIncomplete)
        slow.release.signal()
        if let pending { _ = await pending.finished() }
    }

    @Test("no snapshot, or a changed changeCount, means no restore")
    func restoreGuards() {
        let pasteboard = FakePasteboard(items: [textItem("mine")])
        let written = pasteboard.write([PasteboardMarkers.transientText("rewrite")], hostOnly: true)
        #expect(PasteboardSnapshotter.restore(nil, to: pasteboard, ifChangeCountIs: written) == .skippedIncomplete)
        let snapshot = PasteboardSnapshot(items: [textItem("mine")], changeCount: 1, incompleteReason: nil)
        pasteboard.simulateUserCopy("newer")
        #expect(PasteboardSnapshotter.restore(snapshot, to: pasteboard, ifChangeCountIs: written) == .skippedChangedSinceWrite)
        #expect(pasteboard.string() == "newer")
    }

    @Test("Ask, Deny and Default: nothing is read, nothing restored, the ⌘C fallback refused", arguments: [
        PasteboardAccess.ask, .alwaysDeny, .default,
    ])
    func accessPolicy(_ access: PasteboardAccess) async {
        let pasteboard = FakePasteboard(items: [textItem("the user's copy")], access: access)
        let outcome = await PasteboardSnapshotter.take(from: pasteboard, deadline: .seconds(1), clock: ContinuousClock())
        #expect(outcome.snapshot.incompleteReason == .readingNotAllowed)
        #expect(pasteboard.reads == 0, "not a single read under \(access)")
        let written = pasteboard.write([PasteboardMarkers.transientText("rewrite")], hostOnly: true)
        #expect(PasteboardSnapshotter.restore(outcome.snapshot, to: pasteboard, ifChangeCountIs: written) == .skippedIncomplete)
        let keys = FakeKeys()
        let operations = SelectionOperations(accessibility: FakeAccessibility(), pasteboard: pasteboard, keys: keys)
        #expect(await operations.copySelection(phase: .milliseconds(200), clock: ManualClock()) == .readingNotAllowed)
        #expect(keys.postedShortcuts.isEmpty, "no ⌘C is posted")
    }
}
