import SwiftUI
import AppKit

/// App-level lifecycle: a menu-bar-only app (LSUIElement) has no visible menu bar
/// or Dock icon, so the standard "Quit" item — and its Cmd+Q key equivalent — is
/// missing by default. This restores both, and makes sure the model server is
/// stopped before the app exits so we never leave an orphaned process behind.
final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Reclaim anything a previous session left running before we show any UI,
        // so launching the app never leaves stale servers competing for memory.
        ServerController.shared.killAllServers()

        // Set up update checking: register for notifications, ask permission, and
        // check for a newer release now (then periodically while the app runs).
        ServerController.shared.startUpdateChecking()

        // Build a minimal menu with just a Quit item so Cmd+Q works everywhere.
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu()
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
}

@main
struct MLXServerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var server = ServerController.shared

    var body: some Scene {
        MenuBarExtra {
            ContentView(server: server)
        } label: {
            Image(systemName: statusSymbol)
        }
        .menuBarExtraStyle(.window)
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
