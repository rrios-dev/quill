import AppKit
import Observation
import SwiftUI

/// Settings: General · Providers & models · Profiles · Apps · About (ARCHITECTURE §5.1).
@MainActor
final class SettingsWindowController {
    private var window: NSWindow?
    private let providers: ProvidersPaneModel
    private let profiles: ProfilesPaneModel
    private let apps: AppsPaneModel
    private let general: GeneralPaneModel
    private let selection = SettingsSelection()

    init(general: GeneralPaneModel, providers: ProvidersPaneModel, profiles: ProfilesPaneModel, apps: AppsPaneModel) {
        self.general = general
        self.providers = providers
        self.profiles = profiles
        self.apps = apps
    }

    var shownWindow: NSWindow? { window }

    private var tabs: NSTabViewController?

    /// The macOS Settings layout: a toolbar of panes, one pane at a time, every pane the
    /// same size so switching never makes the window jump.
    func show(_ pane: SettingsPane? = nil) {
        if let pane { selection.pane = pane }
        if window == nil {
            let tabs = NSTabViewController()
            tabs.tabStyle = .toolbar
            tabs.canPropagateSelectedChildViewControllerTitle = true
            for pane in SettingsPane.allCases {
                let item = NSTabViewItem(viewController: hostingController(for: pane))
                item.label = pane.title
                item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
                item.identifier = pane.rawValue
                tabs.addTabViewItem(item)
            }
            let window = NSWindow(contentViewController: tabs)
            window.styleMask = [.titled, .closable, .miniaturizable]
            window.toolbarStyle = .preference
            window.isReleasedWhenClosed = false
            self.tabs = tabs
            self.window = window
            select(selection.pane)
            window.center()
        } else {
            select(selection.pane)
        }
        // An accessory app has to activate for its window to take the keyboard.
        NSApplication.shared.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    private func select(_ pane: SettingsPane) {
        guard let tabs, let index = SettingsPane.allCases.firstIndex(of: pane) else { return }
        tabs.selectedTabViewItemIndex = index
    }

    static let paneWidth: CGFloat = 720

    private func hostingController(for pane: SettingsPane) -> NSViewController {
        func host(_ view: some View) -> NSViewController {
            let size = CGSize(width: Self.paneWidth, height: pane.height)
            let controller = NSHostingController(rootView: view.frame(width: size.width, height: size.height))
            controller.preferredContentSize = size
            // The window's title follows the pane, as in System Settings.
            controller.title = pane.title
            return controller
        }
        switch pane {
        case .general: return host(GeneralPane(model: general))
        case .providers: return host(ProvidersPane(model: providers))
        case .profiles: return host(ProfilesPane(model: profiles, providers: providers))
        case .apps: return host(AppsPane(model: apps))
        case .about: return host(AboutPane())
        }
    }
}

enum SettingsPane: String, Hashable, CaseIterable {
    case general, providers, profiles, apps, about

    var title: String {
        switch self {
        case .general: PickerCopy.string("settings.general")
        case .providers: PickerCopy.string("settings.providers")
        case .profiles: PickerCopy.string("settings.profiles")
        case .apps: PickerCopy.string("settings.apps")
        case .about: PickerCopy.string("settings.about")
        }
    }

    /// Each pane as tall as its content needs: no empty half-window under a short pane.
    var height: CGFloat {
        switch self {
        case .general: 520
        case .providers, .profiles: 620
        case .apps: 420
        case .about: 600
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .providers: "cpu"
        case .profiles: "person.text.rectangle"
        case .apps: "square.grid.2x2"
        case .about: "info.circle"
        }
    }
}

/// Which pane is showing, so Settings can open at the one an action names.
@MainActor
@Observable
final class SettingsSelection {
    var pane: SettingsPane = .general
}

/// The main menu with Edit (ARCHITECTURE §5.1): an `LSUIElement` has no menu bar, and in
/// AppKit the editing key equivalents are dispatched by the menu, not by the field — so
/// without it ⌘V does nothing in Quill's own fields (found in P2-T5; Ámbar's `EditMenu`
/// measured the same). The titles are never drawn, so they stay in English: what is used
/// is each item's key equivalent and selector.
enum EditMenu {
    static func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        let items: [(String, Selector, String, NSEvent.ModifierFlags)] = [
            ("Undo", Selector(("undo:")), "z", [.command]),
            ("Redo", Selector(("redo:")), "z", [.command, .shift]),
            ("Cut", #selector(NSText.cut(_:)), "x", [.command]),
            ("Copy", #selector(NSText.copy(_:)), "c", [.command]),
            ("Paste", #selector(NSText.paste(_:)), "v", [.command]),
            ("Select All", #selector(NSText.selectAll(_:)), "a", [.command]),
        ]
        for (title, action, key, modifiers) in items {
            // No target: the action climbs the responder chain to the focused field.
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.keyEquivalentModifierMask = modifiers
            edit.addItem(item)
        }
        editItem.submenu = edit
        main.addItem(editItem)
        return main
    }
}
