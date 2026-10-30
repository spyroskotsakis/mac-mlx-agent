import SwiftUI
import AppKit

/// App-level lifecycle: reclaims stale processes, sets up update checking, and
/// keeps the app alive in the Dock/menu bar after its window is closed, so the
/// user reopens it by clicking the Dock icon or the menu-bar item, and quits
/// explicitly (⌘Q / in-app Quit / force-quit).
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// Set by the main window so Dock clicks and the menu-bar "Show" item can
    /// reopen it through SwiftUI's scene system.
    static var reopenMainWindow: (() -> Void)?

    private static let showMainWindowNotification = Notification.Name("MLXServerShowMainWindow")

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Listen for "show yourself" pings from a duplicate launch attempt. This
        // must come first so a duplicate that launches while we're still starting
        // up can still summon our window.
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleShowMainWindow(_:)),
            name: Self.showMainWindowNotification,
            object: nil
        )

        // Reclaim anything a previous session left running before we show any UI,
        // so launching the app never leaves stale servers competing for memory.
        ServerController.shared.killAllServers()

        // Set up update checking: register for notifications, ask permission, and
        // check for a newer release now (then periodically while the app runs).
        ServerController.shared.startUpdateChecking()

        // A minimal app menu with Show + Quit so ⌘Q works everywhere.
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "Show MLX Server",
            action: #selector(showMainWindow(_:)),
            keyEquivalent: "0"
        )
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(
            withTitle: "Quit MLX Server",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        appMenuItem.submenu = appMenu
        NSApp.mainMenu = mainMenu
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Stop the child server synchronously so quitting never leaves it running.
        ServerController.shared.stopSynchronouslyForQuit()
        return .terminateNow
    }

    /// Closing the window hides the app to the Dock/menu bar instead of quitting.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Dock-icon click: bring the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        Self.reopenMainWindow?()
        return true
    }

    @objc private func showMainWindow(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        Self.reopenMainWindow?()
    }

    @objc private func handleShowMainWindow(_ note: Notification) {
        DispatchQueue.main.async { [weak self] in
            self?.showMainWindow(nil)
        }
    }
}

struct MLXServerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var server = ServerController.shared

    var body: some Scene {
        // The panel lives in one real, persistent window. `Window` (not
        // `WindowGroup`) keeps it single: re-opening the app or clicking the
        // menu-bar "Show" item focuses the existing window instead of spawning a
        // duplicate. (A `MenuBarExtra(.window)` popover would auto-close on focus
        // loss, which tears down any alert shown from it.)
        Window("MLX Server", id: "main") {
            MainWindow(server: server)
        }
        // `.contentMinSize` (not `.contentSize`) stops the window from resizing
        // itself to fit content — a long warning would otherwise drag the window
        // taller than the screen. The content scrolls instead, and only the user
        // resizes the window.
        .windowResizability(.contentMinSize)
        .defaultSize(width: 900, height: 680)

        // Menu-bar item: a plain dropdown (no window), so it can't steal focus or
        // auto-close. Left- and right-click both open it; Quit lives here too.
        MenuBarExtra {
            MenuBarCommands()
        } label: {
            Image(systemName: statusSymbol)
        }
        .menuBarExtraStyle(.menu)
    }

    /// The menu-bar icon reflects the server state. It renders monochrome in the
    /// menu bar, so state is conveyed by the glyph shape rather than color.
    private var statusSymbol: String {
        switch server.state {
        case .stopped: return "circle"
        case .starting, .stopping: return "circle.dotted"
        case .running: return "circle.fill"
        case .failed: return "exclamationmark.circle"
        }
    }
}

/// Wraps `ContentView` so it can register the reopen hook once the window shows.
private struct MainWindow: View {
    @ObservedObject var server: ServerController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        ContentView(server: server)
            .onAppear {
                AppDelegate.reopenMainWindow = { openWindow(id: "main") }
            }
    }
}

/// The menu-bar dropdown's items.
private struct MenuBarCommands: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Show MLX Server") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Button("Quit MLX Server") {
            NSApp.terminate(nil)
        }
    }
}
