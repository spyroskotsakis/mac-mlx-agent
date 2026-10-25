import SwiftUI

@main
struct MLXServerApp: App {
    @StateObject private var server = ServerController()

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
