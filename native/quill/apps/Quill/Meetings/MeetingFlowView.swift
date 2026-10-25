import AppKit
import GlassUI
import ListenKit
import MeetingKit
import SwiftUI
import SynthesisKit

/// The window of one meeting.
@MainActor
final class MeetingWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let model: MeetingFlowModel
    var onClose: () -> Void = {}

    init(model: MeetingFlowModel) {
        self.model = model
    }

    var shownWindow: NSWindow? { window }

    func show(step: MeetingFlowModel.Step) {
        model.step = step
        if window == nil {
            let size = MeetingLayout.initialSize(on: NSScreen.main?.visibleFrame)
            // Born in the layout its size calls for: starting in columns inside a narrow
            // window gives the split views minimums the window cannot meet, and AppKit
            // aborts after endless constraint passes.
            let hosting = NSHostingController(rootView: MeetingFlowView(model: model, layout: MeetingLayout(size: size)))
            // The window's size is the user's (or the tiler's), never the content's: with
            // the default, SwiftUI pushes each layout's minimum onto the window, which
            // resizes it, which switches the layout again.
            hosting.sizingOptions = []
            let window = NSWindow(contentViewController: hosting)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.title = model.record.title
            // Small enough to go in any tile (the owner's main display is 1080 pt wide,
            // vertical, and Tessera tiles it); the layout adapts to whatever it gets.
            window.contentMinSize = MeetingLayout.minimumSize
            window.setContentSize(size)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            window.setFrameAutosaveName("QuillMeetingWindow")
            self.window = window
        }
        NSApplication.shared.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func reloadFocuses() { model.reload() }

    #if DEBUG
    var debugModel: MeetingFlowModel { model }
    #endif

    func windowWillClose(_ notification: Notification) {
        model.commitPeople()
        onClose()
    }
}

/// How the meeting window arranges its three parts — people, analysis, transcript — for
/// the space it has.
///
/// It was three columns with a 980 pt minimum, which does not fit the owner's main
/// display: a 1080 × 2560 screen in portrait, tiled by Tessera (2026-10-14). Wide windows
/// keep the columns; tall ones stack the analysis over the transcript, which is what a
/// portrait screen has room for; small ones use tabs.
enum MeetingLayout: Equatable {
    case columns
    case stacked
    /// Tabs for analysis and transcript; the people beside them when there is room.
    case tabs(peopleBeside: Bool)

    static let minimumSize = NSSize(width: 420, height: 460)

    /// The layout for `size`, coming from `current`: thresholds differ going in and out
    /// (hysteresis), so a window resized across a boundary does not flicker between two.
    init(size: CGSize, from current: MeetingLayout? = nil) {
        let columnsAt: CGFloat = current == .columns ? 1180 : 1240
        if size.width >= columnsAt {
            self = .columns
        } else if size.height >= size.width * (current == .stacked ? 1.05 : 1.15) {
            self = .stacked
        } else {
            self = .tabs(peopleBeside: size.width >= 760)
        }
    }

    /// The columns on a landscape screen; on a portrait one, its width and most of its
    /// height, so the stacked layout has room to breathe.
    static func initialSize(on screen: NSRect?) -> NSSize {
        guard let screen else { return NSSize(width: 1240, height: 800) }
        if screen.height > screen.width {
            return NSSize(width: min(screen.width - 40, 1240), height: min(screen.height * 0.75, 1800))
        }
        return NSSize(width: min(screen.width - 40, 1240), height: min(screen.height - 80, 800))
    }
}

struct MeetingFlowView: View {
    @Bindable var model: MeetingFlowModel
    @State private var tab: Tab = .analysis

    enum Tab: Hashable { case analysis, transcript, people }

    @State private var layout: MeetingLayout

    init(model: MeetingFlowModel, layout: MeetingLayout) {
        self.model = model
        _layout = State(initialValue: layout)
    }

    var body: some View {
        // The layout follows the window's size, measured on the container: what is
        // measured must not change with what it decides, or layout never settles (a
        // first version measured the analysis inside its own padding and AppKit aborted
        // the window after endless constraint passes).
        Group {
            switch layout {
            case .columns: columns
            case .stacked: stacked
            case .tabs(let peopleBeside): tabbed(peopleBeside: peopleBeside)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size in
            let next = MeetingLayout(size: size, from: layout)
            guard next != layout else { return }
            layout = next
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    if layout == .columns { model.showsTranscript.toggle() } else { tab = .transcript }
                } label: {
                    Label(MeetingCopy.t("meeting.transcript.toggle"), systemImage: "text.bubble")
                }
                .help(MeetingCopy.t("meeting.transcript.toggle"))
            }
        }
    }

    /// Wide: people, analysis and transcript side by side.
    private var columns: some View {
        NavigationSplitView {
            PeopleSidebar(model: model)
                .frame(minWidth: 0, maxWidth: .infinity)
                .navigationSplitViewColumnWidth(min: 260, ideal: 290, max: 340)
        } detail: {
            AnalysisPane(model: model)
                .inspector(isPresented: $model.showsTranscript) {
                    MeetingTranscriptView(model: model)
                        .frame(minWidth: 0, maxWidth: .infinity)
                        .inspectorColumnWidth(min: 300, ideal: 380, max: 560)
                }
        }
    }

    /// Tall: the people in a strip on top, then the analysis over the transcript, with a
    /// divider the user can drag.
    private var stacked: some View {
        VStack(spacing: 0) {
            PeopleStrip(model: model)
            Divider()
            VSplitView {
                AnalysisPane(model: model)
                    .frame(minHeight: 240, idealHeight: 900)
                MeetingTranscriptView(model: model)
                    .frame(minHeight: 160, idealHeight: 600)
            }
        }
        .padding(.top, 28)
    }

    /// Small: one part at a time.
    private func tabbed(peopleBeside: Bool) -> some View {
        HStack(spacing: 0) {
            if peopleBeside {
                PeopleSidebar(model: model)
                    .frame(width: 270)
                Divider()
            }
            VStack(spacing: 0) {
                Picker("", selection: $tab) {
                    Text(MeetingCopy.t("meeting.tab.analysis")).tag(Tab.analysis)
                    Text(MeetingCopy.t("meeting.transcript")).tag(Tab.transcript)
                    if !peopleBeside { Text(MeetingCopy.t("people.title")).tag(Tab.people) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, Metrics.Spacing.regular)
                .padding(.vertical, Metrics.Spacing.snug)
                Divider()
                switch tab == .people && peopleBeside ? .analysis : tab {
                case .analysis: AnalysisPane(model: model)
                case .transcript: MeetingTranscriptView(model: model)
                case .people: PeopleSidebar(model: model)
                }
            }
        }
        .padding(.top, 28)
        // A click on the timeline or a person's filter wants the transcript in view.
        .onChange(of: model.jumpTarget?.serial) { _, _ in tab = .transcript }
        .onChange(of: model.selectedLabel) { _, label in if label != nil { tab = .transcript } }
    }
}

/// The people as a horizontal strip, for the stacked layout: the same cards as the
/// sidebar, side by side.
private struct PeopleStrip: View {
    @Bindable var model: MeetingFlowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(MeetingCopy.t("people.title")).font(.system(size: 14, weight: .semibold))
                Text(String(localized: "people.subtitle \(MeetingCopy.duration(model.record.duration)) \(model.rows.count)",
                            bundle: .localized))
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
                if model.needsNames {
                    Label(MeetingCopy.t("people.hint.short"), systemImage: "person.crop.circle.badge.questionmark")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
                Button(MeetingCopy.t("people.roles.edit")) { model.openFocusEditor() }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
            }
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: Metrics.Spacing.snug) {
                    ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                        PersonCard(model: model, index: index, row: row)
                            .frame(width: 250)
                    }
                }
                .padding(.bottom, 6)
            }
        }
        .padding(.horizontal, Metrics.Spacing.regular)
        .padding(.top, Metrics.Spacing.snug)
    }
}

// MARK: - People

/// Who spoke, how much, as whom: named and given a role in place, at any moment.
private struct PeopleSidebar: View {
    @Bindable var model: MeetingFlowModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Metrics.Spacing.regular) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(MeetingCopy.t("people.title")).font(.system(size: 15, weight: .semibold))
                    Text(String(localized: "people.subtitle \(MeetingCopy.duration(model.record.duration)) \(model.rows.count)",
                                bundle: .localized))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                if model.needsNames {
                    Label(MeetingCopy.t("people.hint"), systemImage: "person.crop.circle.badge.questionmark")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orange.opacity(0.1), in: .rect(cornerRadius: 10))
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                    PersonCard(model: model, index: index, row: row)
                }
                Button(MeetingCopy.t("people.roles.edit")) { model.openFocusEditor() }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
            }
            .padding(Metrics.Spacing.regular)
        }
    }
}

private struct PersonCard: View {
    @Bindable var model: MeetingFlowModel
    let index: Int
    let row: MeetingFlowModel.PersonRow
    @FocusState private var editingName: Bool

    var body: some View {
        let entry = MeetingPalette.Entry(label: row.label, name: model.displayName(for: row.label),
                                         color: SpeakerColors.color(for: row.label))
        let stat = model.stats.first { $0.label == row.label }
        let selected = model.selectedLabel == row.label
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Avatar(entry: entry, size: 28)
                TextField(model.defaultLabel(for: row.label), text: $model.rows[index].name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .semibold))
                    .focused($editingName)
                    // Saved when the name is finished, never per keystroke: each save
                    // remembers a person, and "Luc" is nobody.
                    .onSubmit { model.commitPeople() }
                    .onChange(of: editingName) { _, editing in if !editing { model.commitPeople() } }
                    .onChange(of: model.rows[index].name) { _, _ in model.nameChanged(at: index) }
                    .accessibilityLabel(String(localized: "people.name.for \(model.defaultLabel(for: row.label))",
                                               bundle: .localized))
                Button { model.toggleSelection(row.label) } label: {
                    Image(systemName: selected ? "text.bubble.fill" : "text.bubble")
                        .foregroundStyle(selected ? entry.color : .secondary)
                }
                .buttonStyle(.borderless)
                .help(MeetingCopy.t("people.filter"))
                .accessibilityLabel(String(localized: "people.filter.for \(entry.name)", bundle: .localized))
            }
            HStack(spacing: 6) {
                Picker(MeetingCopy.t("people.role"), selection: $model.rows[index].roleID) {
                    Text(MeetingCopy.t("people.role.none")).tag(String?.none)
                    ForEach(model.roles) { role in Text(role.name).tag(Optional(role.id)) }
                }
                .labelsHidden()
                .controlSize(.small)
                .onChange(of: model.rows[index].roleID) { _, _ in model.commitPeople() }
                if let treatment = model.treatment(for: row.label) {
                    Button { model.cycleOverride(for: entry.name) } label: {
                        Text(MeetingCopy.treatment(treatment))
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(TreatmentStyle.color(treatment).opacity(0.15), in: .capsule)
                            .foregroundStyle(TreatmentStyle.color(treatment))
                            .fixedSize()
                    }
                    .buttonStyle(.plain)
                    .help(MeetingCopy.t("synthesis.participant.help"))
                }
            }
            if row.roleRemembered {
                Text(MeetingCopy.t("people.role.remembered")).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let stat {
                VStack(alignment: .leading, spacing: 3) {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            Capsule().fill(.quaternary)
                            Capsule().fill(entry.color).frame(width: max(geometry.size.width * stat.share, 3))
                        }
                    }
                    .frame(height: 5)
                    Text(String(localized: "people.share \(stat.share.formatted(.percent.precision(.fractionLength(0)))) \(stat.turns)", bundle: .localized))
                        .font(.system(size: 11)).foregroundStyle(.secondary).monospacedDigit()
                }
                .accessibilityElement(children: .combine)
            }
            if row.label != "me", !row.sample.isEmpty, row.name.isEmpty {
                Text("«\(row.sample)…»")
                    .font(.system(size: 12)).italic()
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .padding(10)
        .background(selected ? AnyShapeStyle(entry.color.opacity(0.12)) : AnyShapeStyle(.quaternary.opacity(0.35)),
                    in: .rect(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? entry.color.opacity(0.6) : .clear) }
    }
}

enum TreatmentStyle {
    static func color(_ treatment: Treatment) -> Color {
        switch treatment {
        case .decides: .green
        case .influences: .blue
        case .context: .secondary
        case .request: .orange
        case .minimal: .gray
        }
    }
}

// MARK: - Analysis

private struct AnalysisPane: View {
    @Bindable var model: MeetingFlowModel
    @State private var compact = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                MeetingOverview(model: model)
                ForEach(model.record.silentChannels, id: \.self) { channel in
                    Label(channel == .others
                          ? String(localized: "meeting.silent.others \(model.record.sourceApp)", bundle: .localized)
                          : MeetingCopy.t("meeting.silent.me"),
                          systemImage: "waveform.slash")
                        .font(.system(size: 13))
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orange.opacity(0.12), in: .rect(cornerRadius: 10))
                        .fixedSize(horizontal: false, vertical: true)
                }
                AnalysisControls(model: model)
                if let provider = model.consentProvider { consentNote(provider) }
                if let error = model.error {
                    Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).font(.system(size: 13))
                }
                result
            }
            .padding(compact ? 14 : 24)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
            .environment(\.compactAnalysis, compact)
        }
        // The scroll view's own width: it does not depend on the padding chosen from it.
        // Takes the width its column gives it and asks for none: if the content's own
        // minimum reached the split view, switching to compact would move the divider,
        // which would switch it back (measured: 610 → 431 → 321 → 610… until AppKit
        // aborted the window).
        .frame(minWidth: 0, maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            let next = width < (compact ? 640 : 560)
            if next != compact { compact = next }
        }
    }

    @ViewBuilder private var result: some View {
        if model.running {
            HStack(spacing: Metrics.Spacing.regular) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text(MeetingCopy.t("synthesis.running")).font(.system(size: 13, weight: .semibold))
                    Text(String(localized: "analysis.running.detail \(model.focus.name)", bundle: .localized))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.3), in: .rect(cornerRadius: 12))
        } else if let result = model.result, let document = model.document {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Text(model.focusName(of: result)).font(.system(size: 13, weight: .semibold))
                    Text("· \(result.model.split(separator: "/").last ?? "") · \(result.createdAt.formatted(.relative(presentation: .named)))")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(result.text, forType: .string)
                    } label: {
                        Label(MeetingCopy.t("synthesis.copy"), systemImage: "doc.on.doc")
                    }
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                }
                if result.truncated {
                    Label(MeetingCopy.t("synthesis.truncated"), systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                if result.isDraft {
                    Label(MeetingCopy.t("synthesis.draftNote"), systemImage: "pencil.line").foregroundStyle(.orange)
                }
                SynthesisView(document: document, palette: model.palette)
            }
        } else {
            VStack(spacing: 10) {
                Image(systemName: "sparkles.rectangle.stack")
                    .font(.system(size: 34)).foregroundStyle(.tint).accessibilityHidden(true)
                Text(MeetingCopy.t("analysis.empty.title")).font(.system(size: 15, weight: .semibold))
                Text(MeetingCopy.t("analysis.empty.body"))
                    .font(.system(size: 13)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
            }
            .padding(36)
            .frame(maxWidth: .infinity)
            .background(.quaternary.opacity(0.25), in: .rect(cornerRadius: 14))
        }
    }

    private func consentNote(_ provider: String) -> some View {
        HStack(spacing: Metrics.Spacing.snug) {
            Image(systemName: "paperplane").foregroundStyle(.orange).accessibilityHidden(true)
            Text(String(localized: "synthesis.consent \(provider)", bundle: .localized))
                .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(MeetingCopy.t("synthesis.consent.cancel")) { model.declineConsent() }
            Button(MeetingCopy.t("synthesis.consent.send")) { Task { await model.synthesize(consented: true) } }
                .buttonStyle(.borderedProminent)
        }
        .padding(Metrics.Spacing.regular)
        .background(.orange.opacity(0.12), in: .rect(cornerRadius: Metrics.cardCornerRadius))
    }
}

/// What the meeting was, before any model: when, how long, who talked when.
private struct MeetingOverview: View {
    let model: MeetingFlowModel

    var body: some View {
        let palette = model.palette
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.record.title).font(.system(size: 22, weight: .bold))
                Text("\(model.record.sourceApp) · \(model.record.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(MeetingCopy.duration(model.record.duration))")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            }
            Timeline(model: model, palette: palette)
            FlowLayout(spacing: 6) {
                ForEach(model.stats) { stat in
                    if let entry = palette.entry(for: stat.label) {
                        Button { model.toggleSelection(stat.label) } label: {
                            HStack(spacing: 5) {
                                Avatar(entry: entry, size: 16)
                                Text(entry.name).font(.system(size: 12, weight: .semibold))
                                Text(stat.share.formatted(.percent.precision(.fractionLength(0)))).font(.system(size: 12)).foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            .padding(.leading, 2).padding(.trailing, 8).padding(.vertical, 2)
                            .background(entry.color.opacity(model.selectedLabel == stat.label ? 0.3 : 0.12), in: .capsule)
                            .fixedSize()
                        }
                        .buttonStyle(.plain)
                        .help(MeetingCopy.t("people.filter"))
                    }
                }
            }
        }
    }
}

/// Who spoke when, along the meeting. A click takes the transcript to that moment.
private struct Timeline: View {
    let model: MeetingFlowModel
    let palette: MeetingPalette

    var body: some View {
        let length = model.timelineLength
        let lanes = model.stats.map(\.label)
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { geometry in
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.35))
                    ForEach(model.turns) { turn in
                        let lane = lanes.firstIndex(of: turn.label) ?? 0
                        let laneHeight = geometry.size.height / CGFloat(max(lanes.count, 1))
                        let x = geometry.size.width * turn.start / length
                        let width = max(geometry.size.width * (turn.end - turn.start) / length, 2)
                        RoundedRectangle(cornerRadius: 2)
                            .fill(palette.entry(for: turn.label)?.color ?? .gray)
                            .opacity(model.selectedLabel == nil || model.selectedLabel == turn.label ? 1 : 0.25)
                            .frame(width: width, height: max(laneHeight - 3, 3))
                            .offset(x: x, y: CGFloat(lane) * laneHeight + 1.5)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { location in
                    model.jump(to: length * Double(location.x / max(geometry.size.width, 1)))
                }
            }
            .frame(height: CGFloat(max(lanes.count, 1)) * 9 + 6)
            HStack {
                Text("00:00")
                Spacer()
                Text(MeetingCopy.clock(length))
            }
            .font(.system(size: 10)).foregroundStyle(.tertiary).monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(MeetingCopy.t("analysis.timeline"))
    }
}

/// The focus, the model, a nuance for this time, and the button.
private struct AnalysisControls: View {
    @Bindable var model: MeetingFlowModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            FlowLayout(spacing: 6) {
                ForEach(Array(model.focuses.enumerated()), id: \.element.id) { index, focus in
                    let selected = focus.id == model.focusID
                    Button {
                        model.choose(focus: focus.id)
                    } label: {
                        Text(focus.name)
                            .font(.system(size: 13, weight: selected ? .semibold : .regular))
                            .padding(.horizontal, 12)
                            .frame(height: 28)
                            .background(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.quaternary.opacity(0.5)), in: .capsule)
                            .foregroundStyle(selected ? Color.white : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .keyboardShortcut(KeyEquivalent(Character("\(min(index + 1, 9))")), modifiers: [.command])
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
                Button(MeetingCopy.t("synthesis.focuses.edit")) { model.openFocusEditor() }
                    .buttonStyle(.link)
                    .font(.system(size: 12))
                    .frame(height: 28)
            }
            if !model.focus.objective.isEmpty {
                Label(model.focus.objective, systemImage: "scope")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            // One row when it fits; on a narrow window the nuance takes its own line.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    nuanceField.frame(minWidth: 220)
                    modelPicker
                    runButton
                }
                VStack(alignment: .leading, spacing: 8) {
                    nuanceField
                    HStack(spacing: 8) {
                        modelPicker
                        Spacer(minLength: 0)
                        runButton
                    }
                }
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.25), in: .rect(cornerRadius: 12))
    }

    private var nuanceField: some View {
        HStack(spacing: 6) {
            Image(systemName: "wand.and.stars").foregroundStyle(.tint).accessibilityHidden(true)
            TextField(MeetingCopy.t("synthesis.nuance"), text: $model.nuance)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
        }
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 8))
    }

    private var modelPicker: some View {
        Picker(MeetingCopy.t("synthesis.model"), selection: $model.modelChoice) {
            ForEach(SynthesisModelChoice.allCases) { choice in
                Text("\(choice.name) · \(choice.costHint)").tag(choice)
            }
        }
        .labelsHidden()
        .fixedSize()
    }

    private var runButton: some View {
        Button(model.result == nil ? MeetingCopy.t("synthesis.run") : MeetingCopy.t("synthesis.again")) {
            Task { await model.synthesize() }
        }
        // ⌘↩, not ↩: Return finishes a name in the sidebar and must never send the
        // meeting to a paid model.
        .keyboardShortcut(.return, modifiers: [.command])
        .buttonStyle(.borderedProminent)
        .disabled(model.running)
    }
}
