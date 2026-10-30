import AppKit
import GlassUI
import ListenKit
import MeetingKit
import SwiftUI
import Translation

/// A floating glass panel near the menu bar, as the picker's: never takes the user out
/// of a full-screen call, never steals focus unless asked (`activates`).
@MainActor
final class MeetingPanelController<Content: View> {
    enum Placement { case topTrailing }

    private var panel: PickerPanel?
    private var hosting: NSHostingView<Content>?
    private let content: Content
    private let placement: Placement
    private let activates: Bool

    init(content: Content, placement: Placement, activates: Bool) {
        self.content = content
        self.placement = placement
        self.activates = activates
    }

    var window: NSWindow? { panel }

    func show() {
        guard panel == nil else { return }
        let hosting = NSHostingView(rootView: content)
        hosting.sizingOptions = [.intrinsicContentSize]
        let size = hosting.fittingSize
        hosting.frame = NSRect(origin: .zero, size: size)
        let panel = PickerPanel(contentRect: NSRect(origin: .zero, size: size))
        panel.contentView = Glass.makeWindowBackdrop(content: hosting, cornerRadius: Metrics.panelCornerRadius)
        self.hosting = hosting
        if let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screen.maxX - size.width - 16, y: screen.maxY - size.height - 12))
        }
        if activates {
            NSApplication.shared.activate()
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFrontRegardless()
        }
        self.panel = panel
    }

    func close() {
        panel?.dismiss()
        panel = nil
        hosting = nil
    }

    /// Fits the panel to what its content needs now (an error line appeared), keeping its
    /// top-right corner where it was.
    func refit() {
        guard let panel, let hosting else { return }
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        panel.setFrame(NSRect(x: panel.frame.maxX - size.width, y: panel.frame.maxY - size.height,
                              width: size.width, height: size.height), display: true, animate: true)
    }
}

/// "¿Transcribir esta reunión?" (mockup 1), with the meeting's language: the one in
/// Settings, changeable for this meeting only. While the language is prepared — the
/// first time, its model is downloaded — the offer stays and says so.
struct OfferView: View {
    let coordinator: MeetingsCoordinator
    let app: MeetingApp
    let accept: (String) -> Void
    let decline: () -> Void
    @State private var language: String

    init(coordinator: MeetingsCoordinator, app: MeetingApp, accept: @escaping (String) -> Void, decline: @escaping () -> Void) {
        self.coordinator = coordinator
        self.app = app
        self.accept = accept
        self.decline = decline
        _language = State(initialValue: coordinator.preferences.localeIdentifier)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Spacing.regular) {
            HStack(alignment: .top, spacing: Metrics.Spacing.regular) {
                Image(systemName: "mic.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(.tint, in: .rect(cornerRadius: 9))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(MeetingCopy.t("offer.title")).font(.system(size: 14, weight: .semibold))
                    Text(app.isBrowser || !app.isListed
                         ? String(localized: "offer.body.browser \(app.name)", bundle: .localized)
                         : String(localized: "offer.body \(app.name)", bundle: .localized))
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Picker(MeetingCopy.t("offer.language"), selection: $language) {
                ForEach(MeetingPreferences.languages, id: \.self) { identifier in
                    Text(MeetingPreferences.languageName(identifier)).tag(identifier)
                }
            }
            .font(.system(size: 13))
            .disabled(coordinator.preparing != nil)
            if let error = coordinator.offerError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Metrics.Spacing.snug) {
                if let preparing = coordinator.preparing {
                    ProgressView().controlSize(.small)
                    Text(String(localized: "offer.preparing \(preparing)", bundle: .localized))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                } else {
                    Spacer()
                    Button(MeetingCopy.t("offer.decline"), action: decline)
                        .keyboardShortcut(.cancelAction)
                    Button(MeetingCopy.t("offer.accept")) { accept(language) }
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
            }
            .frame(minHeight: 28)
        }
        .padding(Metrics.Inset.panel)
        .frame(width: 360)
    }
}

/// The live panel: elapsed time, "Yo" and "Los demás" with the others' words translated
/// when the meeting is in another language. It fills whatever size the user gives the
/// panel, and folds into the recording orb. Pause is not offered — a paused capture
/// leaves a hole the diarizer reads as one long silence.
struct LiveView: View {
    let coordinator: MeetingsCoordinator
    let app: MeetingApp
    let collapse: () -> Void
    @State private var download: TranslationSession.Configuration?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if !coordinator.liveVoices.isEmpty {
                voices
            }
            Divider().opacity(0.4)
            transcript
            Divider().opacity(0.4)
            footer
            Divider().opacity(0.4)
            actions
        }
        .frame(minWidth: LivePanelController.minimumSize.width, maxWidth: .infinity,
               minHeight: LivePanelController.minimumSize.height, maxHeight: .infinity)
        .translationTask(download) { session in
            do {
                try await session.prepareTranslation()
                coordinator.translationDownloaded()
            } catch {
                download = nil
            }
        }
    }

    private var header: some View {
        HStack(spacing: Metrics.Spacing.snug) {
            Circle().fill(.red).frame(width: 9, height: 9).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(String(localized: "live.title \(app.name)", bundle: .localized))
                    .font(.system(size: 14, weight: .semibold))
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(MeetingCopy.clock(context.date.timeIntervalSince(coordinator.listeningSince ?? context.date))
                         + " · " + MeetingCopy.t("live.subtitle"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Spacer()
            if case .active(let target) = coordinator.translationState {
                Label(String(localized: "live.translating \(target)", bundle: .localized), systemImage: "translate")
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(.tint.opacity(0.15), in: .capsule)
                    .foregroundStyle(.tint)
            }
            if coordinator.includesMicrophone {
                Button(action: coordinator.toggleMicrophone) {
                    Image(systemName: coordinator.isMicrophoneMutedInQuill ? "mic.slash.fill" : "mic.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(coordinator.microphoneMuted == nil ? Color.primary : Color.orange)
                }
                .buttonStyle(.borderless)
                .help(MeetingCopy.t(coordinator.isMicrophoneMutedInQuill ? "live.mic.unmute" : "live.mic.mute"))
                .accessibilityLabel(MeetingCopy.t(coordinator.isMicrophoneMutedInQuill ? "live.mic.unmute" : "live.mic.mute"))
            }
            Button(action: collapse) {
                Image(systemName: "smallcircle.filled.circle")
                    .font(.system(size: 15))
            }
            .buttonStyle(.borderless)
            .help(MeetingCopy.t("live.collapse"))
            .accessibilityLabel(MeetingCopy.t("live.collapse"))
        }
        .padding(Metrics.Inset.panel)
    }

    /// Why the user's words are not being written down, in their terms.
    static func mutedText(_ reason: MicrophoneGate.Reason, app: String) -> String {
        switch reason {
        case .mutedInApp: String(localized: "live.mic.mutedInApp \(app)", bundle: .localized)
        case .appReleasedMicrophone: String(localized: "live.mic.appReleased \(app)", bundle: .localized)
        case .mutedInQuill: MeetingCopy.t("live.mic.mutedInQuill")
        }
    }

    /// The voices heard so far, each a chip to name and give a role to as the meeting goes.
    private var voices: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(coordinator.liveVoices) { voice in
                    VoiceChip(coordinator: coordinator, voice: voice)
                }
                if coordinator.liveVoices.contains(where: { $0.name.isEmpty }) {
                    Text(MeetingCopy.t("live.voices.hint")).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, Metrics.Inset.panel)
            .padding(.bottom, Metrics.Spacing.snug)
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: Metrics.Spacing.regular) {
                    if coordinator.liveLines.isEmpty {
                        Text(MeetingCopy.t("live.waiting"))
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(coordinator.liveLines) { line in
                        HStack(alignment: .firstTextBaseline, spacing: Metrics.Spacing.regular) {
                            Group {
                                if line.segment.channel == .me {
                                    Text(MeetingCopy.t("label.me")).foregroundStyle(Color.cyan)
                                } else if let speaker = line.speaker {
                                    Text(coordinator.liveName(speaker)).foregroundStyle(SpeakerColors.color(for: speaker))
                                } else {
                                    Text(MeetingCopy.t("label.others")).foregroundStyle(Color.secondary)
                                }
                            }
                            .font(.system(size: 12, weight: .semibold))
                            .lineLimit(2)
                            .frame(width: 84, alignment: .leading)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(line.segment.text).font(.system(size: 13))
                                if let translation = line.translation {
                                    Text(translation)
                                        .font(.system(size: 13))
                                        .foregroundStyle(.tint)
                                        .accessibilityLabel(String(localized: "live.translation \(translation)", bundle: .localized))
                                }
                            }
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                        .id(line.id)
                    }
                }
                .padding(Metrics.Inset.panel)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity)
            .onChange(of: coordinator.liveLines.last?.id) { _, id in
                guard let id else { return }
                withAnimation(.ambarQuick) { proxy.scrollTo(id, anchor: .bottom) }
            }
        }
    }

    /// One line under the transcript: a lost channel first, then a missing language
    /// pack, else how people are told apart.
    @ViewBuilder private var footer: some View {
        Group {
            if !coordinator.lostChannels.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: Metrics.Spacing.snug) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityHidden(true)
                    Text(coordinator.lostChannels.contains(.others)
                         ? String(localized: "live.lost.others \(app.name)", bundle: .localized)
                         : MeetingCopy.t("live.lost.me"))
                }
            } else if let reason = coordinator.microphoneMuted {
                HStack(alignment: .firstTextBaseline, spacing: Metrics.Spacing.snug) {
                    Image(systemName: "mic.slash.fill").foregroundStyle(.orange).accessibilityHidden(true)
                    Text(Self.mutedText(reason, app: app.name))
                }
            } else if case .needsDownload(let configuration) = coordinator.translationState {
                HStack(spacing: Metrics.Spacing.snug) {
                    Image(systemName: "translate").foregroundStyle(.tint).accessibilityHidden(true)
                    Text(MeetingCopy.t("live.translation.needsPack"))
                    Spacer()
                    Button(MeetingCopy.t("live.translation.download")) { download = configuration }
                        .controlSize(.small)
                        .disabled(download != nil)
                }
            } else {
                Text(MeetingCopy.t("live.note")).foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 11))
        .padding(.horizontal, Metrics.Inset.panel)
        .padding(.vertical, Metrics.Spacing.snug)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actions: some View {
        HStack(spacing: Metrics.Spacing.snug) {
            Button(MeetingCopy.t("live.discard"), role: .destructive) { Task { await coordinator.discard() } }
            Button(MeetingCopy.t("live.hide")) { coordinator.hideLivePanel() }
            Spacer()
            Button(MeetingCopy.t("live.finish")) { Task { await coordinator.finish() } }
                .buttonStyle(.borderedProminent)
        }
        .padding(Metrics.Inset.panel)
    }
}

/// A voice in the live panel: its colour, its name or "Persona N", and on click a small
/// form to name it and give it a role. Carried into the meeting when it ends.
private struct VoiceChip: View {
    let coordinator: MeetingsCoordinator
    let voice: MeetingsCoordinator.LiveVoice
    @State private var editing = false
    @State private var name = ""
    @State private var roleID: String?

    var body: some View {
        let color = SpeakerColors.color(for: voice.label)
        let title = coordinator.liveName(voice.label)
        HStack(spacing: 4) {
            chip(title: title, color: color)
            if let person = voice.suggestion { suggestion(person, title: title, color: color) }
        }
    }

    private func chip(title: String, color: Color) -> some View {
        Button {
            name = voice.name
            roleID = voice.roleID
            editing = true
        } label: {
            HStack(spacing: 5) {
                Text(title.first.map { String($0).uppercased() } ?? "?")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 16, height: 16)
                    .background(color, in: .circle)
                Text(title).font(.system(size: 12, weight: .semibold))
                if let roleID = voice.roleID, let role = coordinator.roles.first(where: { $0.id == roleID }) {
                    Text(role.name).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if voice.name.isEmpty {
                    Image(systemName: "pencil").font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
            .padding(.leading, 3).padding(.trailing, 8).padding(.vertical, 3)
            .background(color.opacity(0.15), in: .capsule)
            .fixedSize()
        }
        .buttonStyle(.plain)
        .accessibilityLabel(String(localized: "live.voice.edit \(title)", bundle: .localized))
        .popover(isPresented: $editing, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text(String(localized: "live.voice.title \(title)", bundle: .localized)).font(.system(size: 13, weight: .semibold))
                TextField(MeetingCopy.t("live.voice.name"), text: $name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .onSubmit(save)
                Picker(MeetingCopy.t("people.role"), selection: $roleID) {
                    Text(MeetingCopy.t("people.role.none")).tag(String?.none)
                    ForEach(coordinator.roles) { role in Text(role.name).tag(Optional(role.id)) }
                }
                .frame(width: 220)
                HStack {
                    Spacer()
                    Button(MeetingCopy.t("live.voice.save"), action: save)
                        .keyboardShortcut(.defaultAction)
                        .buttonStyle(.borderedProminent)
                }
            }
            .padding(14)
        }
    }

    private func suggestion(_ person: MeetingFlowModel.KnownPerson, title: String, color: Color) -> some View {
        HStack(spacing: 2) {
            Button {
                coordinator.acceptLiveSuggestion(voice.label)
            } label: {
                Label(String(localized: "live.voice.suggestion \(person.name)", bundle: .localized), systemImage: "waveform")
                    .font(.system(size: 11, weight: .semibold))
            }
            .help(String(localized: "live.voice.suggestion.help \(title) \(person.name)", bundle: .localized))
            Button {
                coordinator.rejectLiveSuggestion(voice.label)
            } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .help(MeetingCopy.t("people.voice.no"))
            .accessibilityLabel(MeetingCopy.t("people.voice.no"))
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 6).padding(.vertical, 3)
        .background(color.opacity(0.1), in: .capsule)
        .fixedSize()
    }

    private func save() {
        coordinator.nameLiveVoice(voice.label, name: name, roleID: roleID)
        editing = false
    }
}
