import SwiftUI
import AppKit
import Carbon.HIToolbox
import WhereFilmIndex

@main
struct WhereFilmApp: App {
    @State private var model = AppModel.shared
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environment(model)
        } label: {
            Image(systemName: menuBarSymbol)
        }
        .menuBarExtraStyle(.window)
    }

    /// The icon carries the state, so the indexer's status is legible at a glance
    /// without opening anything.
    private var menuBarSymbol: String {
        if model.pauseRemaining != nil || model.mode == .paused { "pause.circle" }
        else if model.currentActivity != nil { "sparkle.magnifyingglass" }
        else { "magnifyingglass.circle" }
    }
}

/// A menu-bar app has no ordinary WindowGroup lifecycle. Owning this window
/// explicitly guarantees that first launch, the menu action, and the global
/// shortcut all target the same persistent search surface.
@MainActor
final class SearchWindowController {
    static let shared = SearchWindowController()
    private var window: NSWindow?

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let content = SearchView().environment(AppModel.shared)
        let controller = NSHostingController(rootView: content)
        let window = NSWindow(contentViewController: controller)
        window.title = "WhereFilm — Encuentra cualquier momento"
        window.identifier = NSUserInterfaceItemIdentifier(SearchWindowID)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 1080, height: 760))
        window.minSize = NSSize(width: 820, height: 620)
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unifiedCompact
        // Set on the window, not only through SwiftUI's `preferredColorScheme`.
        // The interface is painted on a near-black gradient, so if the dark
        // appearance fails to propagate for any reason the default label colour
        // turns the headline black-on-black. AppKit is the authority here.
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(red: 11 / 255, green: 20 / 255, blue: 33 / 255, alpha: 1)
        window.center()
        return window
    }
}

/// Owns the pieces AppKit still does better than SwiftUI: the activation policy
/// for a menu-bar-only app, and a true system-wide hotkey.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var hotKeyRef: EventHotKeyRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar app: no Dock icon, no menu bar of its own, until a window is
        // explicitly opened.
        NSApp.setActivationPolicy(.accessory)
        installEditMenu()
        // Start indexing as soon as the app is alive, not when a window happens
        // to open: the point of a menu-bar app is that it works while you ignore it.
        AppModel.shared.start()
        registerGlobalHotKey()
        SearchWindowController.shared.show()
        Snapshot.runIfRequested()
    }

    /// An `LSUIElement` app gets no main menu, and without one the standard
    /// editing shortcuts are dead keys — a search box you cannot paste into.
    /// The responder chain already implements all of this; it only needs
    /// menu items to route the key equivalents to.
    private func installEditMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Ocultar WhereFilm",
                        action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Salir de WhereFilm",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edición")
        editMenu.addItem(withTitle: "Deshacer", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Rehacer", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cortar", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copiar", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Pegar", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Seleccionar todo",
                         action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Ventana")
        windowMenu.addItem(withTitle: "Cerrar",
                           action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimizar",
                           action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowItem.submenu = windowMenu
        mainMenu.addItem(windowItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
    }

    /// ⌘⇧Space, registered through Carbon's hot key API.
    ///
    /// Deliberately not `NSEvent.addGlobalMonitorForEvents`: that route requires
    /// Accessibility permission, which is a wildly disproportionate thing to ask
    /// for from a search tool. `RegisterEventHotKey` needs no permission at all.
    private func registerGlobalHotKey() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async {
                SearchWindowController.shared.show()
            }
            return noErr
        }, 1, &eventType, nil, nil)

        let hotKeyID = EventHotKeyID(signature: OSType(0x5746_4C4D), id: 1)  // 'WFLM'
        RegisterEventHotKey(UInt32(kVK_Space),
                            UInt32(cmdKey | shiftKey),
                            hotKeyID,
                            GetApplicationEventTarget(),
                            0,
                            &hotKeyRef)
    }
}
