import GlassUI
import SwiftUI
import Translation

/// The transcript, always at hand beside the analysis: turns by person, searchable,
/// filtered to one person from the sidebar, and scrolled by a click on the timeline.
struct MeetingTranscriptView: View {
    @Bindable var model: MeetingFlowModel
    @State private var flashed: Int?
    @State private var download: TranslationSession.Configuration?

    var body: some View {
        let palette = model.palette
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(MeetingCopy.t("meeting.transcript")).font(.system(size: 14, weight: .semibold))
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                    TextField(MeetingCopy.t("meeting.transcript.search"), text: $model.transcriptQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                }
                .padding(.horizontal, 8)
                .frame(height: 28)
                .background(.quaternary.opacity(0.5), in: .rect(cornerRadius: 7))
                if case .needsDownload(let configuration) = model.transcriptTranslation {
                    HStack(spacing: 6) {
                        Image(systemName: "translate").foregroundStyle(.tint).accessibilityHidden(true)
                        Text(MeetingCopy.t("meeting.translation.needsPack")).font(.system(size: 12))
                        Spacer()
                        Button(MeetingCopy.t("live.translation.download")) { download = configuration }
                            .controlSize(.small)
                            .disabled(download != nil)
                    }
                } else if model.transcriptTranslation == .working {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text(MeetingCopy.t("meeting.translation.working")).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                if let label = model.selectedLabel, let entry = palette.entry(for: label) {
                    HStack(spacing: 6) {
                        PersonChip(entry: entry)
                        Text(MeetingCopy.t("meeting.transcript.only")).font(.system(size: 12)).foregroundStyle(.secondary)
                        Spacer()
                        Button { model.selectedLabel = nil } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.borderless)
                            .foregroundStyle(.secondary)
                            .accessibilityLabel(MeetingCopy.t("meeting.transcript.all"))
                    }
                }
            }
            .padding(14)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        let turns = model.visibleTurns
                        if turns.isEmpty {
                            Text(MeetingCopy.t("meeting.transcript.none"))
                                .font(.system(size: 13)).foregroundStyle(.secondary)
                        }
                        ForEach(turns) { turn in
                            let entry = palette.entry(for: turn.label)
                            HStack(alignment: .top, spacing: 8) {
                                RoundedRectangle(cornerRadius: 1.5)
                                    .fill(entry?.color ?? .gray)
                                    .frame(width: 3)
                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(entry?.name ?? turn.label)
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(entry?.color ?? .primary)
                                        Text(MeetingCopy.clock(turn.start))
                                            .font(.system(size: 11)).foregroundStyle(.tertiary).monospacedDigit()
                                    }
                                    Text(turn.text)
                                        .font(.system(size: 13))
                                        .fixedSize(horizontal: false, vertical: true)
                                    if let translation = model.translation(of: turn) {
                                        Text(translation)
                                            .font(.system(size: 13))
                                            .foregroundStyle(.tint)
                                            .fixedSize(horizontal: false, vertical: true)
                                    }
                                }
                            }
                            .padding(6)
                            .background(flashed == turn.id ? Color.accentColor.opacity(0.18) : .clear, in: .rect(cornerRadius: 8))
                            .id(turn.id)
                        }
                    }
                    .textSelection(.enabled)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .translationTask(download) { session in
                    do {
                        try await session.prepareTranslation()
                        await model.translateTranscript()
                    } catch {
                        download = nil
                    }
                }
                .onChange(of: model.jumpTarget?.serial) { _, _ in
                    guard let time = model.jumpTarget?.time else { return }
                    let target = model.turns.last { $0.start <= time } ?? model.turns.first
                    guard let target else { return }
                    withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(target.id, anchor: .top) }
                    flashed = target.id
                    Task {
                        try? await Task.sleep(for: .seconds(1.6))
                        if flashed == target.id { withAnimation { flashed = nil } }
                    }
                }
            }
        }
    }
}
