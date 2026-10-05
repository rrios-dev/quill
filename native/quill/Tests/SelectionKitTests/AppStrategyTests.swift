import Foundation
import Testing

@testable import SelectionKit

@Suite("App strategy table")
struct AppStrategyTests {
    /// SPIKES.md, found from this file's location in the repository.
    private func spikeRows() throws -> Set<String> {
        let spikes = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // SelectionKitTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // quill
            .deletingLastPathComponent()      // native
            .deletingLastPathComponent()      // repository root
            .appendingPathComponent("docs/initiatives/quill/SPIKES.md")
        let text = try String(contentsOf: spikes, encoding: .utf8)
        var rows = Set<String>()
        for line in text.split(separator: "\n") where line.hasPrefix("| S") {
            let id = line.dropFirst(2).prefix { $0 != " " && $0 != "|" }
            rows.insert(String(id))
        }
        return rows
    }

    @Test("every entry cites at least one row, and every cited row exists in SPIKES.md")
    func entriesCiteRows() throws {
        let rows = try spikeRows()
        #expect(!rows.isEmpty)
        for (bundleIdentifier, strategy) in AppStrategy.table {
            #expect(!strategy.rows.isEmpty, "\(bundleIdentifier) cites no row")
            for row in strategy.rows {
                #expect(rows.contains(row), "\(bundleIdentifier) cites \(row), which SPIKES.md does not have")
            }
        }
    }

    @Test("apps without an entry get the default strategy and the default restore delay")
    func defaults() {
        #expect(AppStrategy.strategy(for: "com.example.unknown") == .default)
        #expect(AppStrategy.strategy(for: nil) == .default)
        #expect(AppStrategy.default.effectiveRestoreDelay == AppStrategy.defaultRestoreDelay)
    }

    @Test("terminals are read-only-only; nothing replaces by accessibility write yet")
    func terminalDenylist() {
        for terminal in ["com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable",
                         "com.mitchellh.ghostty", "net.kovidgoyal.kitty", "org.alacritty"] {
            #expect(AppStrategy.strategy(for: terminal).readOnlyOnly, "\(terminal)")
        }
        #expect(AppStrategy.table.values.allSatisfy { !$0.replaceViaAccessibilityWrite })
    }
}
