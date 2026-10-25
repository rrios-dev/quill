import AppKit
import GlassUI
import ListenKit
import MeetingKit
import Observation
import SwiftUI
import SynthesisKit

/// The history window (mockup 5).
@MainActor
final class MeetingHistoryController {
    private var window: NSWindow?
    let model: MeetingHistoryModel

    init(coordinator: MeetingsCoordinator) {
        model = MeetingHistoryModel(coordinator: coordinator)
    }

    var shownWindow: NSWindow? { window }

    func show() {
        model.reload()
        if window == nil {
            let hosting = NSHostingController(rootView: MeetingHistoryView(model: model))
            hosting.sizingOptions = []
            let window = NSWindow(contentViewController: hosting)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.title = MeetingCopy.t("history.title")
            window.contentMinSize = MeetingLayout.minimumSize
            window.setContentSize(NSSize(width: min(1080, (NSScreen.main?.visibleFrame.width ?? 1080) - 40), height: 680))
            window.setFrameAutosaveName("QuillMeetingHistory")
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApplication.shared.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func reload() { model.reload() }
}

@MainActor
@Observable
final class MeetingHistoryModel {
    enum Tab: Hashable { case syntheses, transcript }

    var query = "" { didSet { reload() } }
    private(set) var meetings: [MeetingRecord] = []
    var selectedID: UUID?
    var selectedSynthesisID: UUID?
    var tab: Tab = .syntheses
    var confirmingDelete = false
    let coordinator: MeetingsCoordinator

    init(coordinator: MeetingsCoordinator) {
        self.coordinator = coordinator
    }

    func reload() {
        meetings = coordinator.store.search(query)
        if selectedID == nil || !meetings.contains(where: { $0.id == selectedID }) { selectedID = meetings.first?.id }
    }

    var selected: MeetingRecord? { meetings.first { $0.id == selectedID } }

    var selectedSynthesis: SynthesisRecord? {
        guard let selected else { return nil }
        return selected.syntheses.first { $0.id == selectedSynthesisID } ?? selected.syntheses.last
    }

    /// Meetings grouped by the week they started in, newest first.
    var weeks: [(title: String, meetings: [MeetingRecord])] {
        let calendar = Calendar.current
        let thisWeek = calendar.dateInterval(of: .weekOfYear, for: Date())
        let lastWeek = thisWeek.flatMap { calendar.dateInterval(of: .weekOfYear, for: $0.start.addingTimeInterval(-1)) }
        var groups: [(String, [MeetingRecord])] = []
        for meeting in meetings {
            let title: String
            if thisWeek?.contains(meeting.startedAt) == true {
                title = MeetingCopy.t("history.thisWeek")
            } else if lastWeek?.contains(meeting.startedAt) == true {
                title = MeetingCopy.t("history.lastWeek")
            } else {
                title = meeting.startedAt.formatted(.dateTime.month(.wide).year())
            }
            if let index = groups.firstIndex(where: { $0.0 == title }) {
                groups[index].1.append(meeting)
            } else {
                groups.append((title, [meeting]))
            }
        }
        return groups.map { (title: $0.0, meetings: $0.1) }
    }

    func names(of meeting: MeetingRecord) -> [(label: String, name: String)] {
        meeting.labels.map { label in
            let segment = TranscriptSegment(channel: label == "me" ? .me : .others, start: 0, end: 0, text: "",
                                            speaker: label == "me" || label == "others" ? nil : label)
            return (label, meeting.transcript.label(for: segment))
        }
    }

    func exportMarkdown() {
        guard let meeting = selected else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(meeting.title).md"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var text = "# \(meeting.title)\n\n\(meeting.sourceApp) · \(meeting.startedAt.formatted()) · \(MeetingCopy.duration(meeting.duration))\n\n"
        for synthesis in meeting.syntheses {
            text += "## \(coordinator.store.displayName(of: synthesis)) (\(synthesis.model))\n\n\(synthesis.text)\n\n"
        }
        text += "## \(MeetingCopy.t("history.transcript"))\n\n\(meeting.transcript.rendered())\n"
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }

    func deleteSelected() {
        guard let id = selectedID else { return }
        try? coordinator.store.delete(id)
        selectedID = nil
        reload()
    }
}

struct MeetingHistoryView: View {
    @Bindable var model: MeetingHistoryModel
    /// The detail is narrow (a tile, a portrait screen): the syntheses go above the text.
    @State private var narrow = false

    var body: some View {
        NavigationSplitView {
            List(selection: $model.selectedID) {
                ForEach(model.weeks, id: \.title) { week in
                    Section(week.title) {
                        ForEach(week.meetings) { meeting in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(meeting.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                                Text("\(meeting.sourceApp) · \(meeting.startedAt.formatted(.dateTime.weekday().day().hour().minute())) · \(MeetingCopy.duration(meeting.duration))")
                                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .tag(meeting.id)
                        }
                    }
                }
            }
            .searchable(text: $model.query, placement: .sidebar, prompt: MeetingCopy.t("history.search"))
            .navigationSplitViewColumnWidth(min: 260, ideal: 300)
            .overlay {
                if model.meetings.isEmpty {
                    ContentUnavailableView(MeetingCopy.t("history.empty"), systemImage: "waveform",
                                           description: Text(MeetingCopy.t("history.empty.body")))
                }
            }
        } detail: {
            if let meeting = model.selected { detail(meeting) } else { Color.clear }
        }
        .alert(MeetingCopy.t("history.delete.title"), isPresented: $model.confirmingDelete) {
            Button(MeetingCopy.t("history.delete.confirm"), role: .destructive) { model.deleteSelected() }
        }
    }

    private func detail(_ meeting: MeetingRecord) -> some View {
        VStack(alignment: .leading, spacing: Metrics.Spacing.regular) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(meeting.title).font(.system(size: 20, weight: .bold))
                    FlowLayout(spacing: 6) {
                        ForEach(model.names(of: meeting), id: \.label) { entry in
                            Text(entry.name)
                                .font(.system(size: 12))
                                .padding(.horizontal, 8).padding(.vertical, 2)
                                .background(SpeakerColors.color(for: entry.label).opacity(0.18), in: .capsule)
                                .foregroundStyle(SpeakerColors.color(for: entry.label))
                        }
                        Text("\(meeting.sourceApp) · \(meeting.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(MeetingCopy.duration(meeting.duration))")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Menu {
                    Button(MeetingCopy.t("history.people")) { model.coordinator.openMeeting(meeting.id, step: .people) }
                    Button(MeetingCopy.t("history.export")) { model.exportMarkdown() }
                    Divider()
                    Button(MeetingCopy.t("history.delete"), role: .destructive) { model.confirmingDelete = true }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .accessibilityLabel(MeetingCopy.t("history.more"))
                Button(MeetingCopy.t("history.newSynthesis")) { model.coordinator.openMeeting(meeting.id, step: .synthesis) }
                    .buttonStyle(.borderedProminent)
            }

            Picker("", selection: $model.tab) {
                Text(String(localized: "history.syntheses \(meeting.syntheses.count)", bundle: .localized)).tag(MeetingHistoryModel.Tab.syntheses)
                Text(MeetingCopy.t("history.transcript")).tag(MeetingHistoryModel.Tab.transcript)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 320)

            switch model.tab {
            case .syntheses: syntheses(meeting)
            case .transcript: transcript(meeting)
            }
        }
        .padding(Metrics.Inset.pane)
        // Its column decides its width, never its content (see AnalysisPane), and the
        // switch has hysteresis so it cannot flicker at the boundary.
        .frame(minWidth: 0, maxWidth: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            let next = width < (narrow ? 820 : 760)
            if next != narrow { narrow = next }
        }
    }

    @ViewBuilder private func synthesisList(_ meeting: MeetingRecord) -> some View {
        let items = ForEach(meeting.syntheses.reversed()) { synthesis in
            let selected = synthesis.id == model.selectedSynthesis?.id
            Button { model.selectedSynthesisID = synthesis.id } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.coordinator.store.displayName(of: synthesis)).font(.system(size: 13, weight: .semibold))
                    Text("\(synthesis.model.split(separator: "/").last ?? "") · \(synthesis.createdAt.formatted(date: .omitted, time: .shortened))")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: narrow ? nil : .infinity, alignment: .leading)
                .padding(10)
                .background(selected ? AnyShapeStyle(.tint.opacity(0.15)) : AnyShapeStyle(.clear),
                            in: .rect(cornerRadius: 10))
                .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.hairline)) }
            }
            .buttonStyle(.plain)
        }
        if meeting.syntheses.isEmpty {
            Text(MeetingCopy.t("history.noSyntheses")).foregroundStyle(.secondary).font(.system(size: 13))
        } else if narrow {
            FlowLayout(spacing: Metrics.Spacing.snug) { items }
        } else {
            VStack(alignment: .leading, spacing: Metrics.Spacing.snug) { items }
        }
    }

    private func syntheses(_ meeting: MeetingRecord) -> some View {
        // Beside the synthesis when there is room, above it on a narrow window.
        let layout = narrow ? AnyLayout(VStackLayout(alignment: .leading, spacing: Metrics.Spacing.regular))
                            : AnyLayout(HStackLayout(alignment: .top, spacing: Metrics.Spacing.regular))
        return layout {
            synthesisList(meeting)
                .frame(width: narrow ? nil : 220)

            ScrollView {
                if let synthesis = model.selectedSynthesis {
                    VStack(alignment: .leading, spacing: 8) {
                        if synthesis.truncated {
                            Label(MeetingCopy.t("synthesis.truncated"), systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                        }
                        if synthesis.isDraft {
                            Label(MeetingCopy.t("synthesis.draftNote"), systemImage: "pencil.line").foregroundStyle(.orange)
                        }
                        SynthesisView(document: SynthesisDocument(markdown: synthesis.text), palette: MeetingPalette(record: meeting))
                            .environment(\.compactAnalysis, narrow)
                    }
                    .font(.system(size: 13))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Metrics.Spacing.loose)
                }
            }
            .background(.black.opacity(0.12), in: .rect(cornerRadius: Metrics.cardCornerRadius))
        }
    }

    private func transcript(_ meeting: MeetingRecord) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Metrics.Spacing.snug) {
                ForEach(Array(meeting.transcript.ordered.enumerated()), id: \.offset) { _, segment in
                    HStack(alignment: .firstTextBaseline, spacing: Metrics.Spacing.regular) {
                        Text(MeetingCopy.clock(segment.start)).font(.system(size: 11)).foregroundStyle(.tertiary).monospacedDigit()
                        Text(meeting.transcript.label(for: segment))
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(SpeakerColors.color(for: segment.speaker ?? segment.channel.rawValue))
                            .frame(width: 90, alignment: .leading)
                        Text(segment.text).font(.system(size: 13))
                    }
                }
            }
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Metrics.Spacing.loose)
        }
        .background(.black.opacity(0.12), in: .rect(cornerRadius: Metrics.cardCornerRadius))
    }
}
