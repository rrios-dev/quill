import Foundation
import SelectionKit
import Testing

@testable import Quill

@Suite("Services entry")
struct ServicesTests {
    private let plain = AppStrategy()

    @Test("the settable rule applies only when the focused selection is the delivered text")
    func editability() {
        let same = SelectionOperations.SelectionRead(text: "hello john", selectedTextSettable: true)
        #expect(ServicesProvider.editability(delivered: "hello john", read: same, strategy: plain) == .editable)
        let other = SelectionOperations.SelectionRead(text: "something else", selectedTextSettable: true)
        #expect(ServicesProvider.editability(delivered: "hello john", read: other, strategy: plain) == .uncertain)
        let notSettable = SelectionOperations.SelectionRead(text: "hello john", selectedTextSettable: false)
        #expect(ServicesProvider.editability(delivered: "hello john", read: notSettable, strategy: plain) == .uncertain)
        #expect(ServicesProvider.editability(delivered: "hello john", read: nil, strategy: plain) == .uncertain)
    }

    @Test("terminals stay read-only-only, whatever the element says")
    func terminals() {
        let same = SelectionOperations.SelectionRead(text: "ls -la", selectedTextSettable: true)
        #expect(ServicesProvider.editability(delivered: "ls -la", read: same,
                                             strategy: AppStrategy.strategy(for: "com.apple.Terminal")) == .readOnlyOnly)
        let xterm = SelectionOperations.SelectionRead(text: "ls -la", selectedTextSettable: true, domClassList: ["xterm-helper-textarea"])
        #expect(ServicesProvider.editability(delivered: "ls -la", read: xterm, strategy: plain) == .readOnlyOnly)
    }

    @Test("Info.plist declares a send-only service with an empty required context")
    func declaration() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("../../apps/Quill/Info.plist").standardizedFileURL
        let plist = try #require(NSDictionary(contentsOf: url) as? [String: Any])
        let services = try #require(plist["NSServices"] as? [[String: Any]])
        #expect(services.count == 1)
        let service = services[0]
        #expect(service["NSMessage"] as? String == "rewriteText")
        #expect((service["NSSendTypes"] as? [String])?.contains("public.utf8-plain-text") == true)
        #expect(service["NSReturnTypes"] == nil, "send-only: the host never waits for a result")
        #expect((service["NSRequiredContext"] as? [String: Any])?.isEmpty == true)
    }
}
