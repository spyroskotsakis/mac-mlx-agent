import Foundation
import SwiftUI
import Darwin

/// One selectable model. `repoID` is the HuggingFace `mlx-community/…` id passed
/// to `mlx_lm.server --model`; `displayName` is what the picker shows.
struct ModelOption: Identifiable, Hashable {
    let repoID: String
    let displayName: String
    var id: String { repoID }
}

/// Owns the `mlx_lm.server` subprocess: starts/stops it, streams its output into
/// a log, and reports readiness by polling the server's own `/v1/models` endpoint.
final class ServerController: ObservableObject {

    enum ServerState: Equatable {
        case stopped
        case starting
        case running
        case stopping
        case failed(String)

        var isRunning: Bool {
            if case .running = self { return true }
            return false
        }

        var isTransitioning: Bool {
            if case .starting = self { return true }
            if case .stopping = self { return true }
            return false
        }
    }

    /// Models offered by the picker. Add more entries here as you download them
    /// (the server auto-downloads on first launch if they aren't cached). The
    /// first entry is the default selection.
    static let availableModels: [ModelOption] = [
        ModelOption(repoID: "mlx-community/Qwen3.5-35B-A3B-4bit",
                    displayName: "Qwen3.5-35B-A3B (4-bit)")
        // To add another model later, uncomment and fill in, e.g.:
        // ModelOption(repoID: "mlx-community/Some-Model-4bit",
        //             displayName: "Some Model (4-bit)")
    ]

    @Published private(set) var state: ServerState = .stopped
    @Published private(set) var log: String = ""
    @Published private(set) var resolvedExecutable: String?

    @Published var selectedModel: ModelOption {
        didSet { UserDefaults.standard.set(selectedModel.repoID, forKey: Keys.model) }
    }

    @Published var port: Int {
        didSet { UserDefaults.standard.set(port, forKey: Keys.port) }
    }

    @Published var executablePath: String {
        didSet {
            UserDefaults.standard.set(executablePath, forKey: Keys.executable)
            resolvedExecutable = Self.resolveExecutable(override: executablePath)
        }
    }

    private var process: Process?
    private var pollTask: Task<Void, Never>?

    private enum Keys {
        static let model = "mlxServerModel"
        static let port = "mlxServerPort"
        static let executable = "mlxServerExecutable"
    }

    init() {
        let savedPort = UserDefaults.standard.integer(forKey: Keys.port)
        self.port = savedPort == 0 ? 8080 : savedPort

        self.executablePath = UserDefaults.standard.string(forKey: Keys.executable) ?? ""

        let savedModel = UserDefaults.standard.string(forKey: Keys.model)
        self.selectedModel = Self.availableModels.first(where: { $0.repoID == savedModel })
            ?? Self.availableModels.first!

        self.resolvedExecutable = Self.resolveExecutable(override: self.executablePath)
    }

    // MARK: - UI helpers

    var canSwitchModel: Bool {
        !state.isRunning && !state.isTransitioning
    }

    var primaryLabel: String {
        switch state {
        case .stopped, .failed: return "Start Server"
        case .starting: return "Cancel"
        case .running: return "Stop Server"
        case .stopping: return "Stopping…"
        }
    }

    var primaryDisabled: Bool {
        state == .stopping || resolvedExecutable == nil
    }

    func primaryAction() {
        switch state {
        case .stopped, .failed: start()
        case .starting, .running: stop()
        case .stopping: break
        }
    }

    func clearLog() {
        log = ""
    }

    // MARK: - Lifecycle

    func onAppear() {
        // If a server is already listening on our port (started by a previous
        // launch or a shell script), reflect that instead of launching a second
        // one on top of it.
        Task { [weak self] in
            guard let self else { return }
            if await self.isServerUp() {
                await MainActor.run {
                    guard self.state == .stopped else { return }
                    self.state = .running
                    self.appendLog("[Detected an already-running server on port \(self.port)]\n")
                }
            }
        }
    }

    // MARK: - Start / stop

    func start() {
        guard let exe = resolvedExecutable else {
            state = .failed("mlx_lm.server not found. Set its full path in Advanced.")
            return
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        proc.arguments = Self.arguments(model: selectedModel.repoID, port: port)

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                DispatchQueue.main.async { self?.appendLog(text) }
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                DispatchQueue.main.async { self?.appendLog(text) }
            }
        }

        process = proc
        state = .starting
        log = ""
        appendLog("$ \(exe) " + Self.arguments(model: selectedModel.repoID, port: port).joined(separator: " ") + "\n\n")

        proc.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async {
                self?.handleTermination(of: finished)
            }
        }

        do {
            try proc.run()
            beginHealthPoll()
        } catch {
            state = .failed(error.localizedDescription)
            process = nil
            appendLog("\nFailed to launch: \(error.localizedDescription)\n")
        }
    }

    func stop() {
        guard let proc = process else {
            state = .stopped
            return
        }
        state = .stopping
        appendLog("\n[Stopping server…]\n")
        let pid = proc.processIdentifier
        proc.terminate() // SIGTERM — lets uvicorn shut down cleanly

        // Escalate to SIGKILL if it's still alive after a few seconds.
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [weak self] in
            guard kill(pid, 0) == 0 else { return } // already gone
            DispatchQueue.main.async {
                self?.appendLog("[Server ignored SIGTERM; sending SIGKILL]\n")
            }
            kill(pid, SIGKILL)
        }
    }

    // MARK: - Polling / process bookkeeping

    private func beginHealthPoll() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            guard let self else { return }
            // The 35B model can take 10–30s (longer on first load) before the
            // HTTP server accepts requests. Poll for up to ~2 minutes.
            for _ in 0..<120 {
                if Task.isCancelled { return }
                let up = await self.isServerUp()
                let keepGoing = await MainActor.run { self.notePoll(serverUp: up) }
                if !keepGoing { return }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            await MainActor.run { self.pollTimedOut() }
        }
    }

    /// Runs on the main actor. Returns false to stop polling.
    private func notePoll(serverUp: Bool) -> Bool {
        if process == nil {
            return false // process already exited; termination handler handled it
        }
        if serverUp {
            if state == .starting {
                state = .running
                appendLog("\n[Server is ready on port \(port)]\n")
            }
            return false
        }
        return true
    }

    private func pollTimedOut() {
        if state == .starting {
            state = .failed("Server did not become ready within 2 minutes — see log.")
        }
        pollTask = nil
    }

    private func handleTermination(of finished: Process) {
        pollTask?.cancel()
        pollTask = nil

        if process !== finished { return } // stale process; ignore
        process = nil

        let status = finished.terminationStatus
        switch state {
        case .stopping:
            state = .stopped
            appendLog("\n[Server stopped]\n")
        case .starting:
            state = .failed("Server exited during startup (status \(status)). See log.")
        case .running:
            state = .failed("Server exited unexpectedly (status \(status)). See log.")
        case .stopped, .failed:
            break
        }
    }

    // MARK: - Networking

    private func isServerUp() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/v1/models") else {
            return false
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    // MARK: - Logging

    private func appendLog(_ text: String) {
        log.append(text)
        if log.count > 200_000 {
            log = String(log.suffix(100_000))
        }
    }

    // MARK: - Static helpers

    private static func arguments(model: String, port: Int) -> [String] {
        // Mirrors start_server.sh: 4-bit KV cache (keeps the 35B-A3B MoE inside
        // Metal memory), a token cap that lets tool calls finish, and
        // deterministic-but-not-greedy sampling to avoid repetition loops.
        [
            "--model", model,
            "--host", "127.0.0.1",
            "--port", "\(port)",
            "--kv-bits", "4",
            "--max-tokens", "8192",
            "--temp", "0.2",
            "--top-p", "0.8",
            "--top-k", "20"
        ]
    }

    private static func resolveExecutable(override: String) -> String? {
        if !override.isEmpty {
            return FileManager.default.isExecutableFile(atPath: override) ? override : nil
        }

        // GUI apps don't inherit the shell PATH, so check common install spots.
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            "/opt/anaconda3/bin/mlx_lm.server",
            "/opt/miniconda3/bin/mlx_lm.server",
            "/opt/homebrew/bin/mlx_lm.server",
            "/usr/local/bin/mlx_lm.server",
            "\(home)/anaconda3/bin/mlx_lm.server",
            "\(home)/miniconda3/bin/mlx_lm.server",
            "\(home)/miniforge3/bin/mlx_lm.server",
            "\(home)/.local/bin/mlx_lm.server"
        ]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return resolveViaLoginShell()
    }

    private static func resolveViaLoginShell() -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-ic", "command -v mlx_lm.server"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let path, !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        } catch {
            // fall through to nil
        }
        return nil
    }
}
