import AppCore
import AppKit
import Combine
import GlassUI
import ModelKit
import QuillSupport
import SwiftUI

/// The first-run window (PRODUCT F4).
@MainActor
final class OnboardingWindowController {
    private var window: NSWindow?
    let model: OnboardingModel
    private let general: GeneralPaneModel
    var onFinished: () -> Void = {}

    init(model: OnboardingModel, general: GeneralPaneModel) {
        self.model = model
        self.general = general
    }

    func show() {
        if window == nil {
            let view = OnboardingView(model: model, general: general) { [weak self] in
                self?.model.finish()
                self?.window?.close()
                self?.onFinished()
            }
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = PickerCopy.string("onboarding.title \(QuillSupport.productName)")
            window.styleMask = [.titled, .closable]
            window.setContentSize(NSSize(width: Metrics.onboardingWidth, height: Metrics.onboardingHeight))
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApplication.shared.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    var isShown: Bool { window?.isVisible == true }
    var shownWindow: NSWindow? { window }
}

struct OnboardingView: View {
    let model: OnboardingModel
    let general: GeneralPaneModel
    let done: () -> Void
    @State private var practice = PickerCopy.string("onboarding.practice.sample")
    @State private var keys: [ProviderID: String] = [:]
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.Spacing.loose) {
            ScrollView {
                VStack(alignment: .leading, spacing: Metrics.Spacing.regular) { content }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
            HStack {
                Text(PickerCopy.string("onboarding.progress \(position) \(model.steps.count)"))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if model.current != model.steps.first {
                    Button(PickerCopy.string("onboarding.back")) { model.back() }
                }
                if model.isLast {
                    Button(PickerCopy.string("onboarding.done"), action: done).keyboardShortcut(.defaultAction)
                } else {
                    Button(PickerCopy.string("onboarding.continue")) { model.next() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(Metrics.Inset.pane)
        .frame(width: Metrics.onboardingWidth, height: Metrics.onboardingHeight)
        .onReceive(ticker) { _ in
            model.refreshPermission()
            model.refreshClipboardAccess()
        }
        .task { await model.evaluateProviders(); general.reload() }
        // A hosted provider shows, once, who receives the text (PRODUCT F4 step 5).
        .alert(PickerCopy.string("providers.notice.title"), isPresented: Binding(
            get: { model.providers.notice != nil }, set: { if !$0 { model.providers.declineNotice() } })) {
            Button(PickerCopy.string("providers.notice.accept")) { model.providers.acceptNotice(); model.next() }
            Button(PickerCopy.string("picker.action.cancel"), role: .cancel) { model.providers.declineNotice() }
        } message: {
            if let notice = model.providers.notice {
                Text(Presentation.tradeoff(.textLeavesDevice(recipients: notice.recipients)).text)
            }
        }
    }

    private var position: Int { (model.steps.firstIndex(of: model.current) ?? 0) + 1 }

    @ViewBuilder private var content: some View {
        switch model.current {
        case .welcome:
            title(PickerCopy.string("onboarding.welcome.title \(QuillSupport.productName)"))
            paragraph(PickerCopy.string("onboarding.welcome.body"))
        case .relocate:
            title(PickerCopy.string("onboarding.relocate.title"))
            paragraph(PickerCopy.string("onboarding.relocate.body \(QuillSupport.productName)"))
            Button(PickerCopy.string("onboarding.relocate.move")) {
                if let destination = try? AppRelocation.perform(model.relocation) {
                    AppRelocation.relaunch(at: destination) { NSApplication.shared.terminate(nil) }
                }
            }
        case .accessibility:
            title(PickerCopy.string("onboarding.accessibility.title"))
            paragraph(PickerCopy.string("onboarding.accessibility.body \(QuillSupport.productName)"))
            switch model.permission {
            case .trusted:
                Label(PickerCopy.string("onboarding.accessibility.granted"), systemImage: "checkmark.circle").foregroundStyle(.green)
            case .notTrusted:
                Button(PickerCopy.string("picker.action.openAccessibility")) { NSWorkspace.shared.open(PermissionWatcher.settingsURL) }
            case .grantedWhileRunning:
                Button(PickerCopy.string("menu.permission.restart \(QuillSupport.productName)")) { PermissionWatcher.restart() }
            }
        case .clipboard:
            title(PickerCopy.string("onboarding.clipboard.title"))
            paragraph(PickerCopy.string("onboarding.clipboard.body \(QuillSupport.productName)"))
            if model.clipboardAccess.allowsReading {
                Label(PickerCopy.string("onboarding.clipboard.allowed"), systemImage: "checkmark.circle").foregroundStyle(.green)
            } else {
                HStack {
                    // One user-initiated read at a calm moment: macOS asks and lists Quill.
                    Button(PickerCopy.string("onboarding.clipboard.check")) { _ = NSPasteboard.general.string(forType: .string) }
                    Button(PickerCopy.string("onboarding.clipboard.open")) {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Pasteboard")!)
                    }
                    Button(PickerCopy.string("menu.permission.restart \(QuillSupport.productName)")) { PermissionWatcher.restart() }
                }
            }
        case .provider:
            providerStep
        case .shortcut:
            title(PickerCopy.string("onboarding.shortcut.title"))
            ShortcutRecorder(combination: Binding(get: { general.shortcut }, set: { general.setShortcut($0) }))
            if let conflict = general.systemConflict { Label(conflict, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            if let problem = general.shortcutProblem { Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.red) }
            paragraph(PickerCopy.string("general.shortcut.note \(QuillSupport.productName)"))
        case .practice:
            title(PickerCopy.string("onboarding.practice.title"))
            paragraph(PickerCopy.string("onboarding.practice.body \(general.shortcut.displayString)"))
            TextEditor(text: $practice).font(.body).frame(minHeight: 120)
        }
    }

    @ViewBuilder private var providerStep: some View {
        title(PickerCopy.string("onboarding.provider.title"))
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(PickerCopy.string("onboarding.provider.onDevice")).font(.headline)
                    if model.providerDefault == .onDevice { Text(PickerCopy.string("onboarding.provider.recommended")).font(.caption) }
                    Spacer()
                    Text(ReadinessCopy.label(model.onDeviceLabel)).font(.caption).foregroundStyle(.secondary)
                }
                if model.onDeviceAvailability.isAvailable {
                    Button(PickerCopy.string("onboarding.provider.useOnDevice")) { model.chooseOnDevice(); model.next() }
                } else if case .unavailable(let reason) = model.onDeviceAvailability {
                    Text(Presentation.unavailable(reason).text).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        if model.providerDefault == .hosted {
            Text(PickerCopy.string("onboarding.provider.hostedRecommended")).font(.callout).foregroundStyle(.secondary)
        }
        ForEach(model.providers.rows.filter { $0.isRemote && !$0.isCustom }) { row in
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Text(row.name).font(.headline)
                    ForEach(Array((row.advantages + row.drawbacks).enumerated()), id: \.offset) { _, tradeoff in
                        Text("· " + Presentation.tradeoff(tradeoff).text).font(.caption)
                    }
                    if !row.hasKey {
                        HStack {
                            SecureField(PickerCopy.string("providers.key.enter"), text: Binding(
                                get: { keys[row.id] ?? "" }, set: { keys[row.id] = $0 }))
                            Button(PickerCopy.string("providers.key.save")) {
                                let entered = keys[row.id] ?? ""
                                keys[row.id] = nil
                                Task {
                                    try? await model.providers.setKey(entered, for: row.id)
                                    await model.providers.loadModels(for: row.id, force: true)
                                }
                            }
                        }
                    } else {
                        ForEach(row.models.prefix(8)) { descriptor in
                            Button(descriptor.displayName) { model.providers.choose(ModelSelection(provider: row.id, model: descriptor.id)) }
                                .buttonStyle(.link)
                        }
                    }
                }
            }
        }
        HStack {
            if model.offersAppleIntelligenceSettings {
                Button(PickerCopy.string("onboarding.provider.turnOn")) {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Siri-Settings.extension")!)
                }
            }
            Button(PickerCopy.string("onboarding.provider.later")) { model.next() }
        }
    }

    private func title(_ text: String) -> some View {
        Text(text).font(.title2.weight(.semibold))
    }

    private func paragraph(_ text: String) -> some View {
        Text(text).font(.body).fixedSize(horizontal: false, vertical: true)
    }
}
