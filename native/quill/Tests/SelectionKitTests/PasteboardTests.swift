import AppKit
import Testing

@testable import SelectionKit

/// Every test uses its own private named pasteboard: a suite that writes to the general
/// one wipes the developer's clipboard (ARCHITECTURE §3.7).
@Suite("Pasteboard writes, snapshot and restore")
struct PasteboardTests {
    private func withPrivatePasteboard(_ body: (LivePasteboardClient) async -> Void) async {
        let client = LivePasteboardClient.unique()
        defer { client.releaseGlobally() }
        await body(client)
    }

    @Test("a transient write carries the text and both nspasteboard.org markers")
    func transientMarkers() async {
        await withPrivatePasteboard { client in
            let operations = SelectionOperations(
                accessibility: LiveAccessibilityClient(), pasteboard: client, keys: LiveKeyEventPoster())
            let before = client.changeCount()
            let written = operations.writeTransient("rewritten text")

            #expect(written != before)
            #expect(written == client.changeCount())
            #expect(client.string() == "rewritten text")
            let types = client.itemTypes()
            #expect(types.count == 1)
            #expect(types.first?.contains(PasteboardMarkers.transient) == true)
            #expect(types.first?.contains(PasteboardMarkers.concealed) == true)
        }
    }

    private func original() -> [PasteboardItemData] {
        [
            PasteboardItemData(entries: [
                .init(type: NSPasteboard.PasteboardType.string.rawValue, data: Data("the user's copy".utf8)),
                .init(type: "com.example.custom", data: Data([0, 1, 2, 255])),
            ]),
            PasteboardItemData(entries: [
                .init(type: NSPasteboard.PasteboardType.string.rawValue, data: Data("a second item".utf8)),
            ]),
        ]
    }

    @Test("a snapshot is complete, and a restore puts every item and type back byte for byte")
    func snapshotRoundTrip() async {
        await withPrivatePasteboard { client in
            guard client.accessBehavior().allowsReading else {
                Issue.record("a private pasteboard should be readable; access is \(client.accessBehavior())")
                return
            }
            client.write(original(), hostOnly: true)

            let outcome = await PasteboardSnapshotter.take(from: client, deadline: .milliseconds(300), clock: ContinuousClock())
            #expect(outcome.snapshot.isComplete)
            #expect(outcome.pendingRead == nil)
            #expect(outcome.snapshot.items == original())

            let written = SelectionOperations(
                accessibility: LiveAccessibilityClient(), pasteboard: client, keys: LiveKeyEventPoster()
            ).writeTransient("rewrite")
            let restore = PasteboardSnapshotter.restore(outcome.snapshot, to: client, ifChangeCountIs: written)
            #expect(restore == .restored)

            let restoredTypes = client.itemTypes()
            #expect(restoredTypes.count == 2)
            for (index, item) in original().enumerated() {
                for entry in item.entries {
                    #expect(client.data(forType: entry.type, item: index) == entry.data, "\(entry.type) of item \(index)")
                }
            }
            // The restore itself is marked transient, so clipboard managers skip it.
            #expect(restoredTypes.first?.contains(PasteboardMarkers.transient) == true)
        }
    }

    @Test("if the user copied after Quill's write, the restore leaves their copy alone")
    func restoreGuardedByChangeCount() async {
        await withPrivatePasteboard { client in
            client.write(original(), hostOnly: true)
            let outcome = await PasteboardSnapshotter.take(from: client, deadline: .milliseconds(300), clock: ContinuousClock())
            let written = client.write([PasteboardMarkers.transientText("rewrite")], hostOnly: true)
            client.write([PasteboardItemData(entries: [
                .init(type: NSPasteboard.PasteboardType.string.rawValue, data: Data("newer copy".utf8)),
            ])], hostOnly: true)

            let restore = PasteboardSnapshotter.restore(outcome.snapshot, to: client, ifChangeCountIs: written)
            #expect(restore == .skippedChangedSinceWrite)
            #expect(client.string() == "newer copy")
        }
    }

    @Test("an incomplete snapshot is never restored")
    func incompleteNotRestored() async {
        await withPrivatePasteboard { client in
            client.write(original(), hostOnly: true)
            let tooLarge = await PasteboardSnapshotter.take(
                from: client, deadline: .milliseconds(300), sizeCap: 4, clock: ContinuousClock())
            #expect(tooLarge.snapshot.incompleteReason == .tooLarge)

            let written = client.write([PasteboardMarkers.transientText("rewrite")], hostOnly: true)
            #expect(PasteboardSnapshotter.restore(tooLarge.snapshot, to: client, ifChangeCountIs: written) == .skippedIncomplete)
            #expect(client.string() == "rewrite")
        }
    }

    @Test("file-promise types are skipped, which makes the snapshot incomplete")
    func filePromisesSkipped() {
        #expect(PasteboardMarkers.isFilePromise("com.apple.pasteboard.promised-file-url"))
        #expect(PasteboardMarkers.isFilePromise("com.apple.NSFilePromiseItemMetaData"))
        #expect(!PasteboardMarkers.isFilePromise("public.utf8-plain-text"))
    }
}
