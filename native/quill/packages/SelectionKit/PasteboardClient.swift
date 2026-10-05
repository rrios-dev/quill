import AppKit
import Foundation

/// The general pasteboard's programmatic-access policy, macOS 15.4+ (ARCHITECTURE §3.4).
public enum PasteboardAccess: String, Codable, Sendable {
    /// "Ask upon programmatic access": the first read raises an alert.
    case `default`
    /// Asks on every read.
    case ask
    case alwaysAllow
    case alwaysDeny

    /// Quill reads the general pasteboard only with this behaviour: under any other, a
    /// read could raise an alert mid-paste, take focus, and send ⌘V to the wrong place.
    public var allowsReading: Bool { self == .alwaysAllow }
}

/// One pasteboard item: its types in order, each with its data.
public struct PasteboardItemData: Equatable, Sendable {
    public var entries: [Entry]

    public struct Entry: Equatable, Sendable {
        public var type: String
        public var data: Data

        public init(type: String, data: Data) {
            self.type = type
            self.data = data
        }
    }

    public init(entries: [Entry]) { self.entries = entries }

    public var types: [String] { entries.map(\.type) }

    public func data(forType type: String) -> Data? {
        entries.first { $0.type == type }?.data
    }
}

/// A pasteboard, behind a seam (ARCHITECTURE §3.7). Tests use a private named
/// pasteboard or a fake, never the general one: a suite that writes to it wipes the
/// developer's clipboard.
public protocol PasteboardClient: Sendable {
    func changeCount() -> Int
    func accessBehavior() -> PasteboardAccess
    /// The types of each item, in order. Listing types reads no data.
    func itemTypes() -> [[String]]
    /// Reads one type of one item. **May block**, for as long as the owner takes to
    /// produce lazily provided data, and cannot be cancelled.
    func data(forType type: String, item index: Int) -> Data?
    func string() -> String?
    /// Replaces the contents with `items`. `hostOnly` keeps them off Universal
    /// Clipboard. Returns the new change count.
    @discardableResult
    func write(_ items: [PasteboardItemData], hostOnly: Bool) -> Int
}

/// An `NSPasteboard`, by name.
///
/// `NSPasteboard` is not `Sendable`; the client holds only the name and resolves the
/// pasteboard on every call, which returns the same shared object.
public struct LivePasteboardClient: PasteboardClient {
    public let name: NSPasteboard.Name

    public init(name: NSPasteboard.Name = .general) { self.name = name }

    /// A private pasteboard for tests and the probe. Release it with `releaseGlobally`.
    public static func unique() -> LivePasteboardClient {
        LivePasteboardClient(name: NSPasteboard.withUniqueName().name)
    }

    public func releaseGlobally() { pasteboard.releaseGlobally() }

    private var pasteboard: NSPasteboard { NSPasteboard(name: name) }

    public func changeCount() -> Int { pasteboard.changeCount }

    public func accessBehavior() -> PasteboardAccess {
        switch pasteboard.accessBehavior {
        case .default: .default
        case .ask: .ask
        case .alwaysAllow: .alwaysAllow
        case .alwaysDeny: .alwaysDeny
        @unknown default: .ask
        }
    }

    public func itemTypes() -> [[String]] {
        (pasteboard.pasteboardItems ?? []).map { $0.types.map(\.rawValue) }
    }

    public func data(forType type: String, item index: Int) -> Data? {
        guard let items = pasteboard.pasteboardItems, items.indices.contains(index) else { return nil }
        return items[index].data(forType: NSPasteboard.PasteboardType(type))
    }

    public func string() -> String? { pasteboard.string(forType: .string) }

    @discardableResult
    public func write(_ items: [PasteboardItemData], hostOnly: Bool) -> Int {
        let pasteboard = pasteboard
        pasteboard.prepareForNewContents(with: hostOnly ? .currentHostOnly : [])
        let objects = items.map { item -> NSPasteboardItem in
            let object = NSPasteboardItem()
            for entry in item.entries {
                object.setData(entry.data, forType: NSPasteboard.PasteboardType(entry.type))
            }
            return object
        }
        pasteboard.writeObjects(objects)
        return pasteboard.changeCount
    }
}

/// What Quill puts on the pasteboard itself (ARCHITECTURE §3.2 step 6).
public enum PasteboardMarkers {
    /// nspasteboard.org: content that is on the pasteboard only briefly.
    public static let transient = "org.nspasteboard.TransientType"
    /// nspasteboard.org: content clipboard managers must not record.
    public static let concealed = "org.nspasteboard.ConcealedType"

    /// A plain-text item carrying both markers, so clipboard managers — Ámbar
    /// included — record neither the rewrite nor its restore.
    public static func transientText(_ text: String) -> PasteboardItemData {
        PasteboardItemData(entries: [
            .init(type: NSPasteboard.PasteboardType.string.rawValue, data: Data(text.utf8)),
            .init(type: transient, data: Data()),
            .init(type: concealed, data: Data()),
        ])
    }

    /// Legacy aliases macOS synthesizes from the modern types ("NeXT TIFF…", "Apple PICT…",
    /// "NSFilenamesPboardType"). Not read — some convert on demand and are heavy — and not
    /// a loss: writing the modern types back makes the system offer them again.
    public static func isRegeneratedAlias(_ type: String) -> Bool {
        type.hasPrefix("NeXT ") || type.hasPrefix("Apple ") || type.hasPrefix("CorePasteboardFlavorType")
            || type == "NSFilenamesPboardType" || type == "NSStringPboardType"
    }

    /// Types that promise files instead of holding data. They are never read: reading
    /// one asks the owner to write a file.
    public static func isFilePromise(_ type: String) -> Bool {
        type.hasPrefix("com.apple.pasteboard.promised-")
            || type.hasPrefix("com.apple.NSFilePromise")
            || type == "NSPromiseContentsPboardType"
    }
}
