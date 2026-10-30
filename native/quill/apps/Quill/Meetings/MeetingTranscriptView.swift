import GlassUI
import SwiftUI
import Translation

/// The transcript, always at hand beside the analysis: turns by person, searchable,
/// filtered to one person from the sidebar, and scrolled by a click on the timeline.
struct MeetingTranscriptView: View {
    @Bindable var model: MeetingFlowModel
    @State private var flashed: Int?
    @State private var download: TranslationSession.Configuration?
    /// The sentence being corrected, and its text as typed so far.
    @State private var editing: Int?
    @State private var draft = ""
    @FocusState private var draftFocused: Bool

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
                if let proposal = model.proposal {
                    let name = palette.entry(for: proposal.target)?.name ?? model.displayName(for: proposal.target)
                    VStack(alignment: .leading, spacing: 6) {
                        Text(String(localized: "meeting.voice.proposal \(proposal.indices.count) \(name)", bundle: .localized))
                            .font(.system(size: 12))
                            .fixedSize(horizontal: false, vertical: true)
                        HStack(spacing: 8) {
                            Button(MeetingCopy.t("meeting.voice.proposal.accept")) { model.acceptProposal() }
                                .controlSize(.small)
                                .keyboardShortcut(.defaultAction)
                            Button(MeetingCopy.t("meeting.voice.proposal.dismiss")) { model.dismissProposal() }
                                .controlSize(.small)
                        }
                    }
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.10), in: .rect(cornerRadius: 7))
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
            if let notice = model.learnt {
                learntBanner(notice)
                Divider()
            }
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
                                    ForEach(turn.lines) { line in
                                        if editing == line.index {
                                            correction(line)
                                        } else {
                                            Text(line.text)
                                                .font(.system(size: 13))
                                                .fixedSize(horizontal: false, vertical: true)
                                                .padding(.horizontal, model.isProposed(line.index) ? 4 : 0)
                                                .background(model.isProposed(line.index) ? Color.accentColor.opacity(0.16) : .clear,
                                                            in: .rect(cornerRadius: 4))
                                                .onTapGesture(count: 2) { startEditing(line) }
                                                .contextMenu {
                                                    Button(MeetingCopy.t("meeting.transcript.correct")) { startEditing(line) }
                                                    if line.movable { saidByMenu(line: line, from: turn.label, palette: palette) }
                                                }
                                        }
                                    }
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
                .onChange(of: model.proposal) { _, proposal in
                    guard let first = proposal?.indices.first,
                          let turn = model.turns.first(where: { $0.lines.contains { $0.index == first } }) else { return }
                    withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(turn.id, anchor: .center) }
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

    private func startEditing(_ line: MeetingFlowModel.Line) {
        draft = line.text
        editing = line.index
        draftFocused = true
    }

    /// The sentence as a field: Return keeps the correction, Escape drops it.
    private func correction(_ line: MeetingFlowModel.Line) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(MeetingCopy.t("meeting.transcript.correct"), text: $draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13))
                .focused($draftFocused)
                .onSubmit {
                    model.correct(sentence: line.index, to: draft)
                    editing = nil
                }
                .onExitCommand { editing = nil }
            Text(MeetingCopy.t("meeting.transcript.correct.hint")).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    /// What a correction taught, with undo and, when it applies, "for everybody".
    private func learntBanner(_ notice: MeetingFlowModel.LearntNotice) -> some View {
        let pairs = notice.pairs.map { "«\($0.heard)» → «\($0.written)»" }.joined(separator: ", ")
        let owner = notice.owner.map { String(localized: "meeting.learnt.owner \($0)", bundle: .localized) }
            ?? MeetingCopy.t("meeting.learnt.everybody")
        return VStack(alignment: .leading, spacing: 6) {
            Label(String(localized: "meeting.learnt \(pairs) \(owner)", bundle: .localized), systemImage: "character.book.closed")
                .font(.system(size: 12, weight: .medium))
                .lineLimit(3)
            if notice.alsoCorrected > 0 {
                Text(String(localized: "meeting.learnt.also \(notice.alsoCorrected)", bundle: .localized))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                if !notice.promotable.isEmpty {
                    Button(MeetingCopy.t("meeting.learnt.global"), action: model.makeCorrectionGlobal)
                        .buttonStyle(.borderedProminent)
                        .help(MeetingCopy.t("meeting.learnt.global.help"))
                }
                Button(MeetingCopy.t("meeting.learnt.undo"), action: model.undoCorrection)
                Spacer()
                Button { model.dismissLearnt() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(MeetingCopy.t("meeting.learnt.dismiss"))
            }
            .controlSize(.small)
        }
        .padding(10)
        .background(Color.accentColor.opacity(0.08))
    }

    /// "Said by…": the sentence goes to another voice of the meeting, or to someone the
    /// separation did not hear as their own.
    @ViewBuilder
    private func saidByMenu(line: MeetingFlowModel.Line, from label: String, palette: MeetingPalette) -> some View {
        Menu(MeetingCopy.t("meeting.voice.saidBy")) {
            ForEach(model.voiceChoices(excluding: label), id: \.self) { choice in
                Button(palette.entry(for: choice)?.name ?? model.displayName(for: choice)) {
                    model.move(sentence: line.index, to: choice)
                }
            }
            Divider()
            Button(MeetingCopy.t("meeting.voice.newPerson")) { model.move(sentence: line.index, to: nil) }
        }
    }
}
