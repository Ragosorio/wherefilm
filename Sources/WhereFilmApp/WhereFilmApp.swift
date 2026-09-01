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

        Window("Search your media", id: SearchWindowID) {
            SearchView()
                .environment(model)
        }
        .defaultSize(width: 760, height: 560)
        .windowResizability(.contentSize)
    }

    /// The icon carries the state, so the indexer's status is legible at a glance
    /// without opening anything.
    private var menuBarSymbol: String {
        if model.pauseRemaining != nil || model.mode == .paused { "pause.circle" }
        else if model.currentActivity != nil { "sparkle.magnifyingglass" }
        else { "magnifyingglass.circle" }
    }
}

/// Owns the pieces AppKit still does better than SwiftUI: the activation policy
/// for a menu-bar-only app, and a true system-wide hotkey.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var hotKeyRef: EventHotKeyRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar app: no Dock icon, no menu bar of its own, until a window is
        // explicitly opened.
        NSApp.setActivationPolicy(.accessory)
        // Start indexing as soon as the app is alive, not when a window happens
        // to open: the point of a menu-bar app is that it works while you ignore it.
        AppModel.shared.start()
        registerGlobalHotKey()
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
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows
                    .first { $0.identifier?.rawValue.contains(SearchWindowID) == true }?
                    .makeKeyAndOrderFront(nil)
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
