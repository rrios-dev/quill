import AppKit
import ModelKit
import SwiftUI

/// "Sign in to Claude Code" in one click: a Terminal window running the user's own
/// `claude auth login --claudeai`, Anthropic's flow, so Quill never sees the sign-in
/// (Anthropic's terms, J-23). Run from inside Quill, that flow can ask the user to paste a
/// code back into the tool, which only a terminal the user types in may receive.
@MainActor
enum ClaudeCodeSignIn {
    /// How long Quill keeps looking for the new session after opening Terminal.
    static let watchFor: Duration = .seconds(300)
    static let watchEvery: Duration = .seconds(3)

    /// Opens Terminal with the sign-in command. A `.command` file opens in Terminal without
    /// the Automation permission scripting Terminal would ask for.
    static func open(_ command: String, in directory: URL) -> Bool {
        let script = directory.appending(path: "claude-sign-in.command")
        let text = """
            #!/bin/zsh
            clear
            echo \(Self.quoted(PickerCopy.string("claudeCode.signIn.terminal.intro")))
            echo
            \(command)
            echo
            echo \(Self.quoted(PickerCopy.string("claudeCode.signIn.terminal.done")))

            """
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try text.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        } catch {
            return false
        }
        return NSWorkspace.shared.open(script)
    }

    /// Single-quoted for zsh.
    static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Polls the account until it is ready or the time runs out.
    static func waitForPlan(_ provider: ClaudeCodeProvider) async -> ClaudeCodeAccount {
        let deadline = ContinuousClock.now.advanced(by: watchFor)
        var last = await provider.account()
        while ContinuousClock.now < deadline, !Task.isCancelled {
            if case .ready = last { return last }
            try? await Task.sleep(for: watchEvery)
            last = await provider.account()
        }
        return last
    }
}


/// Claude Code's state in a provider row or in onboarding: what is missing, in one sentence,
/// and the one button that fixes it.
struct ClaudeCodeAccountControls: View {
    let model: ProvidersPaneModel
    let row: ProvidersPaneModel.Row

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.signingInLocally == row.id {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(PickerCopy.string("claudeCode.signIn.waiting")).font(.callout).foregroundStyle(.secondary)
                }
            } else if let account = row.localAccount, let entry = Presentation.claudeCodeAccount(account) {
                Text(entry.text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                switch account {
                case .notInstalled:
                    Link(PickerCopy.string("onboarding.provider.claudeInstall"),
                         destination: URL(string: "https://code.claude.com/docs/en/setup")!).font(.callout)
                case .noPlan:
                    HStack {
                        signInButton
                        Link(PickerCopy.string("claudeCode.account.plans"), destination: URL(string: "https://claude.com/pricing")!)
                            .font(.callout)
                    }
                default:
                    signInButton
                }
            } else if case .failed(.unavailable(.notSignedIn))? = row.connection {
                // `auth status` said signed in, the call said otherwise: a session that ended.
                Text(PickerCopy.string("claudeCode.account.expired")).font(.callout).foregroundStyle(.secondary)
                signInButton
            }
        }
    }

    private var signInButton: some View {
        Button(PickerCopy.string("claudeCode.signIn.button")) { Task { await model.signInLocally(row.id) } }
            .disabled(model.signingInLocally != nil)
    }
}
