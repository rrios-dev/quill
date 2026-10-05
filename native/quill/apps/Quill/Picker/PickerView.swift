import GlassUI
import ModelKit
import RewriteKit
import SelectionKit
import SwiftUI

/// The picker's content (PRODUCT §4.1), top to bottom: what to do (an instruction, or a
/// profile), the result, and what to do with it. It only renders the session and
/// forwards what the user does; every rule lives in `RewriteSession`.
struct PickerView: View {
    @Bindable var session: RewriteSession
    var onOpenAccessibilitySettings: () -> Void = {}
    @FocusState private var instructionFocused: Bool

    static let width: CGFloat = 560

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Spacing.regular) {
            if showsInstruction { instructionField }
            if showsProfiles { profiles }
            if session.staleAppDefault { note(PickerCopy.string("picker.note.staleDefault")) }
            if let declined = session.directApplyDeclined { note(PickerCopy.declined(declined)) }
            card
            actionBar
        }
        .padding(Metrics.Inset.panel)
        .frame(width: Self.width, alignment: .leading)
        .onAppear { instructionFocused = showsInstruction }
        .onChange(of: showsInstruction) { _, shown in instructionFocused = shown }
    }

    private var showsInstruction: Bool {
        if case .correcting = session.state { return false }
        return session.acceptsInstruction || session.state == .capturing
    }

    private var showsProfiles: Bool {
        switch session.state {
        case .refusedCapture, .correcting, .waitingForClipboard: false
        default: !session.profileList.isEmpty
        }
    }

    // MARK: What to do

    /// Like the system's Writing Tools: say what you want, or pick a profile below.
    private var instructionField: some View {
        HStack(spacing: Metrics.Spacing.snug) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            TextField(PickerCopy.string("picker.instruction.placeholder"), text: $session.instructionDraft)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .focused($instructionFocused)
                .focusEffectDisabled()
                .accessibilityLabel(PickerCopy.string("picker.instruction.placeholder"))
            if session.instructionPending {
                Button { Task { await session.submitInstruction() } } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 20))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .help(PickerCopy.string("picker.instruction.send"))
                .accessibilityLabel(PickerCopy.string("picker.instruction.send"))
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .padding(.horizontal, Metrics.Spacing.regular)
        .frame(height: 38)
        .background(.quaternary.opacity(0.55), in: .rect(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(instructionFocused ? AnyShapeStyle(.tint.opacity(0.6)) : AnyShapeStyle(Color.hairline), lineWidth: 1)
        }
        .animation(.ambarQuick, value: session.instructionPending)
    }

    private var profiles: some View {
        ChipFlow(spacing: Metrics.Spacing.snug) {
            ForEach(Array(session.profileList.prefix(9).enumerated()), id: \.element.id) { index, profile in
                ProfileChip(number: index + 1, profile: profile, selected: profile.id == session.profile?.id) {
                    Task { await session.selectProfile(at: index) }
                }
            }
        }
    }

    // MARK: The result

    private var card: some View {
        VStack(alignment: .leading, spacing: Metrics.Spacing.snug) {
            if let status = status { statusLine(status) }
            content
        }
        .padding(Metrics.Spacing.regular)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.opacity(0.45), in: .rect(cornerRadius: Metrics.cardCornerRadius))
        .overlay { RoundedRectangle(cornerRadius: Metrics.cardCornerRadius).strokeBorder(.hairline) }
    }

    private struct Status {
        var symbol: String?
        var text: String
        var tint: Color = .secondary
        var spins = false
    }

    private var status: Status? {
        let name = session.profile?.name ?? ""
        switch session.state {
        case .capturing:
            return Status(text: PickerCopy.string("picker.status.capturing"), spins: true)
        case .generating:
            return Status(text: PickerCopy.string("picker.status.generating \(name)"), spins: true)
        case .ready:
            return Status(symbol: session.activeInstruction == nil ? "checkmark.circle" : "wand.and.stars", text: resultLine())
        case .flagged:
            return Status(symbol: "exclamationmark.triangle.fill", text: PickerCopy.string("picker.status.flagged"), tint: .orange)
        case .noChanges:
            return Status(symbol: "checkmark.circle.fill", text: PickerCopy.string("picker.noChanges"), tint: .green)
        case .awaitingConsent:
            return Status(symbol: "lock.shield", text: PickerCopy.string("picker.status.consent"))
        case .applying:
            return Status(text: PickerCopy.string("picker.status.applying"), spins: true)
        default:
            return nil
        }
    }

    /// What made the text: the instruction, quoted, or the model (the profile is already
    /// marked among the chips above).
    private func resultLine() -> String {
        let model = session.model.map { $0.model.rawValue.split(separator: "/").last.map(String.init) ?? $0.model.rawValue }
        if let instruction = session.activeInstruction {
            let quoted = "«\(instruction)»"
            return model.map { "\(quoted) · \($0)" } ?? quoted
        }
        return model ?? session.profile?.name ?? ""
    }

    private func statusLine(_ status: Status) -> some View {
        HStack(spacing: Metrics.Spacing.tight + 2) {
            if status.spins {
                ProgressView().controlSize(.mini)
            } else if let symbol = status.symbol {
                Image(systemName: symbol).font(.caption).foregroundStyle(status.tint)
            }
            Text(status.text).font(.caption).foregroundStyle(status.tint == .secondary ? .secondary : .primary)
                .lineLimit(1)
            Spacer(minLength: 0)
            if showsDiffToggle { diffToggle }
        }
    }

    private var showsDiffToggle: Bool {
        switch session.state {
        case .ready, .flagged: true
        default: false
        }
    }

    private var diffToggle: some View {
        Button { Task { await session.handle(.d) } } label: {
            Label(PickerCopy.string("picker.hint.diff"), systemImage: "plus.forwardslash.minus")
                .font(.caption)
                .padding(.horizontal, Metrics.Spacing.snug)
                .padding(.vertical, 3)
                .background(session.showsDiff ? AnyShapeStyle(.tint.opacity(0.18)) : AnyShapeStyle(.clear), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(session.showsDiff ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
        .help(PickerCopy.string("picker.help.diff"))
        .accessibilityAddTraits(session.showsDiff ? .isSelected : [])
    }

    @ViewBuilder private var content: some View {
        switch session.state {
        case .idle, .capturing, .applying, .applied, .closed:
            placeholder(session.capture?.text ?? " ")
        case .refusedCapture(let refusal):
            Label(PickerCopy.refusal(refusal), systemImage: refusal == .notTrusted ? "hand.raised" : "text.cursor")
                .font(.body).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
        case .awaitingConsent(let notice):
            message(PickerCopy.string("picker.consent \(PickerCopy.recipients(notice.recipients))"))
            if notice.profileTextToNewRecipient { secondary(PickerCopy.string("picker.consent.examples")) }
            if let large = notice.largeText { secondary(startLine(large)) }
        case .waitingToStart(let notice):
            message(startLine(notice))
        case .generating(let partial):
            // The original, invisible, holds the height: the card does not jump as the
            // answer streams in (and the panel is not resized on every token).
            ZStack(alignment: .topLeading) {
                placeholderText(session.capture?.text ?? " ").hidden()
                Text(partial).font(.body).frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: Self.resultHeight, alignment: .top)
            .clipped()
        case .ready(let text):
            result(text)
        case .flagged(let text, let flags):
            result(text)
            VStack(alignment: .leading, spacing: Metrics.Spacing.tight) {
                ForEach(Array(flags.enumerated()), id: \.offset) { _, flag in
                    Label(PickerCopy.flag(flag), systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange)
                }
            }
        case .noChanges:
            resultText(session.capture?.text ?? "").foregroundStyle(.secondary)
        case .truncated(let partial):
            resultText(partial).foregroundStyle(.secondary)
            secondary(PickerCopy.string("picker.truncated"))
        case .refused:
            message(PickerCopy.string("picker.refused"))
        case .failed(let failure, let partial):
            Label(PickerCopy.failure(failure), systemImage: "exclamationmark.circle")
                .font(.body).foregroundStyle(.primary)
            if !partial.isEmpty { resultText(partial).foregroundStyle(.secondary) }
        case .tooLong(let model, let suggestion):
            message(PickerCopy.string("picker.tooLong \(model.model.rawValue)"))
            secondary(suggestion.map { PickerCopy.string("picker.tooLong.suggestion \($0.model.rawValue)") }
                      ?? PickerCopy.string("picker.tooLong.shorten"))
        case .correcting(let correction):
            CorrectionEditor(session: session, correction: correction)
        case .waitingForClipboard(let text, _):
            resultText(text).foregroundStyle(.secondary)
            secondary(PickerCopy.string("picker.waitingForClipboard"))
        }
    }

    static let resultHeight: CGFloat = 300

    private func result(_ text: String) -> some View {
        Group {
            if session.showsDiff {
                diff(from: session.capture?.text ?? "", to: text)
            } else {
                resultText(text)
            }
        }
    }

    private func resultText(_ text: String) -> some View {
        ScrollView {
            Text(text).font(.body).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: Self.resultHeight)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The selection, dimmed, while there is nothing else to show yet.
    private func placeholder(_ text: String) -> some View {
        placeholderText(text).foregroundStyle(.tertiary)
            .frame(maxHeight: Self.resultHeight, alignment: .top)
            .clipped()
    }

    private func placeholderText(_ text: String) -> some View {
        Text(text).font(.body).frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Changes as the system's proofreading shows them: the new text, with what changed
    /// underlined and tinted. What went is not painted — struck-through runs next to
    /// their replacements turn a corrected sentence into two sentences on top of each
    /// other; "Cambios" off shows the plain result.
    private func diff(from old: String, to new: String) -> some View {
        let attributed = WordDiff.segments(from: old, to: new).reduce(into: AttributedString()) { result, segment in
            switch segment.kind {
            case .same:
                result += AttributedString(segment.text)
            case .removed:
                break
            case .added:
                // The mark covers the words, not the space after them.
                let words = segment.text.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
                var piece = AttributedString(words)
                piece.underlineStyle = Text.LineStyle(pattern: .solid, color: .accentColor)
                piece.backgroundColor = Color.accentColor.opacity(0.16)
                result += piece + AttributedString(String(segment.text.dropFirst(words.count)))
            }
        }
        return ScrollView {
            Text(attributed).font(.body).frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: Self.resultHeight)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func startLine(_ notice: StartNotice) -> String {
        if let cost = notice.estimatedCost {
            return PickerCopy.string("picker.start.wordsCost \(notice.words) \(PickerCopy.cost(cost))")
        }
        return PickerCopy.string("picker.start.words \(notice.words)")
    }

    private func message(_ text: String) -> some View {
        Text(text).font(.body).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
    }

    private func secondary(_ text: String) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    private func note(_ text: String) -> some View {
        Label(text, systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
    }

    // MARK: What to do with it

    private var actionBar: some View {
        let bar = PickerActions.bar(for: session)
        return HStack(spacing: Metrics.Spacing.snug) {
            if case .refusedCapture(.notTrusted) = session.state {
                // The one useful thing to do is grant the permission: that is the primary.
                Spacer(minLength: 0)
                Button { perform(PickerActions.Action(key: .escape, keys: "esc", label: "")) } label: {
                    ActionLabel(action: PickerActions.Action(key: .escape, keys: "esc", label: PickerCopy.string("picker.hint.close")))
                }
                .buttonStyle(.bordered)
                Button(action: onOpenAccessibilitySettings) {
                    Text(PickerCopy.string("picker.action.openAccessibility")).font(.callout)
                }
                .buttonStyle(.borderedProminent)
            } else {
                actions(bar)
            }
        }
        .controlSize(.large)
    }

    @ViewBuilder private func actions(_ bar: PickerActions.Bar) -> some View {
            ForEach(bar.secondary, id: \.label) { action in
                Button { perform(action) } label: { ActionLabel(action: action) }
                    .buttonStyle(.bordered)
                    .disabled(!action.enabled)
                    .help(action.help)
            }
            Spacer(minLength: 0)
            if let dismiss = bar.dismiss {
                Button { perform(dismiss) } label: { ActionLabel(action: dismiss) }
                    .buttonStyle(.bordered)
                    .help(dismiss.help)
            }
            if let primary = bar.primary {
                Button { perform(primary) } label: { ActionLabel(action: primary, prominent: true).fixedSize() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!primary.enabled)
                    .help(primary.help)
            }
    }

    private func perform(_ action: PickerActions.Action) {
        let session = session
        Task { action.key == .returnKey ? await session.pressReturn() : await session.handle(action.key) }
    }
}

/// A profile as a button: its number (the key that picks it), its symbol and its name.
private struct ProfileChip: View {
    let number: Int
    let profile: Profile
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text("\(number)")
                    .font(.caption2.monospacedDigit().weight(.semibold))
                    .foregroundStyle(selected ? AnyShapeStyle(.white.opacity(0.75)) : AnyShapeStyle(.tertiary))
                Image(systemName: profile.symbol).font(.caption)
                Text(profile.name).font(.callout).lineLimit(1).fixedSize()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(selected ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .background(background, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.ambarSelection, value: selected)
        .animation(.ambarQuick, value: hovering)
        .help(PickerCopy.string("picker.help.profile \(number)"))
        .accessibilityLabel(profile.name)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private var background: AnyShapeStyle {
        if selected { return AnyShapeStyle(Color.accentColor) }
        return AnyShapeStyle(.quaternary.opacity(hovering ? 0.95 : 0.55))
    }
}

/// "Replace ↩": the action's name with its key, quieter, beside it.
private struct ActionLabel: View {
    let action: PickerActions.Action
    var prominent = false

    var body: some View {
        HStack(spacing: 6) {
            if action.caution { Image(systemName: "exclamationmark.triangle.fill") }
            if let symbol = action.symbol, !prominent { Image(systemName: symbol) }
            Text(action.label)
            Text(action.keys)
                .font(.caption.weight(.medium))
                .foregroundStyle(prominent ? AnyShapeStyle(.white.opacity(0.7)) : AnyShapeStyle(.tertiary))
        }
        .font(.callout)
    }
}

/// ⌘E's editor: a multi-line field (Return inserts a line break), "Save as example" and
/// the decisions a save may need.
private struct CorrectionEditor: View {
    let session: RewriteSession
    let correction: Correction
    @State private var text = ""
    @FocusState private var editing: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Spacing.snug) {
            TextEditor(text: $text)
                .font(.body)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 80, maxHeight: 220)
                .focused($editing)
                .onAppear { text = correction.text; editing = true }
                .onChange(of: text) { _, value in session.updateCorrection(value) }
            Toggle(isOn: Binding(get: { correction.saveAsExample }, set: { session.setSaveAsExample($0) })) {
                Text(PickerCopy.string("picker.correct.saveAsExample \(session.providerName ?? "")"))
            }
            .disabled(correction.saveDisabledReason != nil)
            if correction.saveDisabledReason == .tooLong {
                Text(PickerCopy.string("picker.correct.tooLong")).font(.callout).foregroundStyle(.secondary)
            }
            switch correction.pending {
            case .chooseReplacement(let examples)?:
                Text(PickerCopy.string("picker.correct.chooseReplacement")).font(.callout)
                ForEach(examples) { example in
                    Button(example.input) { session.chooseExampleToReplace(example.id) }.buttonStyle(.link)
                }
                Button(PickerCopy.string("picker.action.cancel")) { session.chooseExampleToReplace(nil) }
            case .personalData?:
                Text(PickerCopy.string("picker.correct.personalData")).font(.callout)
                HStack {
                    Button(PickerCopy.string("picker.correct.useStandIns")) { session.resolvePersonalData(useStandIns: true) }
                    Button(PickerCopy.string("picker.correct.withoutExample")) { session.resolvePersonalData(useStandIns: false) }
                }
            case nil:
                EmptyView()
            }
        }
    }
}

/// The buttons each state offers (PRODUCT §4.1): one primary action — what Return does
/// — the secondary ones, and the way out where leaving is a real choice. Every button
/// shows its key, so the keyboard is learned by using the mouse.
enum PickerActions {
    struct Action: Equatable {
        var key: PickerKey
        var keys: String
        var label: String
        var symbol: String?
        var enabled = true
        /// Accepts a result with warnings: marked, so it does not read as routine.
        var caution = false

        var help: String { "\(label) (\(keys))" }
    }

    struct Bar: Equatable {
        var primary: Action?
        var secondary: [Action] = []
        var dismiss: Action?
    }

    @MainActor
    static func bar(for session: RewriteSession) -> Bar {
        func action(_ key: PickerKey, _ keys: String, _ label: String.LocalizationValue, _ symbol: String? = nil,
                    enabled: Bool = true, caution: Bool = false) -> Action {
            Action(key: key, keys: keys, label: PickerCopy.string(label), symbol: symbol, enabled: enabled, caution: caution)
        }
        let copy = action(.commandC, "⌘C", "picker.hint.copy", "doc.on.doc")
        let correct = action(.commandE, "⌘E", "picker.hint.correct", "pencil")
        let rerun = action(.r, "⌘R", "picker.hint.rerun", "arrow.clockwise")
        let cancel = action(.escape, "esc", "picker.hint.cancel")
        let close = action(.escape, "esc", "picker.hint.close")
        let editability = session.capture?.editability

        // A typed instruction is what Return does now, whatever the state offered.
        if session.instructionPending, session.acceptsInstruction {
            let send = action(.returnKey, "↩", "picker.hint.send")
            if case .ready = session.state { return Bar(primary: send, secondary: [copy, correct]) }
            return Bar(primary: send, dismiss: close)
        }

        switch session.state {
        case .awaitingConsent:
            return Bar(primary: action(.returnKey, "↩", "picker.hint.send"), dismiss: cancel)
        case .waitingToStart:
            return Bar(primary: action(.returnKey, "↩", "picker.hint.start"), dismiss: close)
        case .generating:
            return Bar(primary: action(.returnKey, "↩", "picker.hint.replace", enabled: false),
                       secondary: [action(.commandC, "⌘C", "picker.hint.copy", "doc.on.doc", enabled: false)])
        case .ready:
            if editability == .editable {
                return Bar(primary: action(.returnKey, "↩", "picker.hint.replace"), secondary: [copy, correct, rerun])
            }
            var secondary = [correct, rerun]
            if editability == .uncertain { secondary.insert(action(.optionReturn, "⌥↩", "picker.hint.pasteAnyway", "doc.on.clipboard"), at: 0) }
            return Bar(primary: action(.returnKey, "↩", "picker.hint.copy"), secondary: secondary)
        case .flagged:
            return Bar(primary: action(.commandReturn, "⌘↩", "picker.hint.useAnyway", caution: true), secondary: [copy, correct, rerun])
        case .noChanges:
            return Bar(primary: action(.returnKey, "↩", "picker.hint.close"), secondary: [copy, correct, rerun])
        case .truncated, .refused:
            return Bar(primary: action(.r, "⌘R", "picker.hint.rerun"), dismiss: close)
        case .failed(let failure, _):
            let label: String.LocalizationValue = RewriteSession.action(for: failure) == .openSettings
                ? "picker.hint.openSettings" : "picker.hint.retry"
            return Bar(primary: action(.returnKey, "↩", label), dismiss: close)
        case .tooLong(_, let suggestion):
            return Bar(primary: suggestion == nil ? nil : action(.returnKey, "↩", "picker.hint.trySuggestion"), dismiss: close)
        case .correcting:
            return Bar(primary: action(.commandReturn, "⌘↩", "picker.hint.commit"), dismiss: action(.escape, "esc", "picker.hint.discard"))
        case .refusedCapture:
            return Bar(primary: action(.returnKey, "↩", "picker.hint.close"))  // not trusted: the view's own bar
        case .waitingForClipboard:
            return Bar(dismiss: close)
        case .idle, .capturing, .applying, .applied, .closed:
            return Bar(dismiss: cancel)
        }
    }
}

/// Lays chips out left to right and wraps to a new row when one does not fit, so a
/// long profile name is never truncated.
struct ChipFlow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width ?? rows.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}
