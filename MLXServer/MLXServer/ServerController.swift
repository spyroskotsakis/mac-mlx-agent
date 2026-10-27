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

    enum OpenCodeConfigStatus {
        case checking
        case notConfigured
        case portMismatch(foundPort: Int)
        case configured
    }

    /// Single shared instance used by both the SwiftUI app and the AppDelegate
    /// (which needs to stop the server before the app exits).
    static let shared = ServerController()

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

    @Published private(set) var modelCached: Bool?
    @Published private(set) var installOutput: String = ""
    @Published private(set) var isInstalling: Bool = false
    @Published private(set) var openCodeConfigStatus: OpenCodeConfigStatus = .checking
    @Published private(set) var setupMessage: String = ""
    @Published private(set) var openCodePath: String?

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

    /// When true, the server omits `--kv-bits 4` so its KV cache stays full
    /// precision and requests can be batched in parallel. Off by default because
    /// quantized KV cache is what keeps larger models inside Metal memory.
    @Published var allowConcurrentRequests: Bool {
        didSet { UserDefaults.standard.set(allowConcurrentRequests, forKey: Keys.allowConcurrent) }
    }

    private var process: Process?
    private var pollTask: Task<Void, Never>?

    private enum Keys {
        static let model = "mlxServerModel"
        static let port = "mlxServerPort"
        static let executable = "mlxServerExecutable"
        static let allowConcurrent = "mlxServerAllowConcurrent"
    }

    init() {
        let savedPort = UserDefaults.standard.integer(forKey: Keys.port)
        self.port = savedPort == 0 ? 8080 : savedPort

        self.executablePath = UserDefaults.standard.string(forKey: Keys.executable) ?? ""
        self.allowConcurrentRequests = UserDefaults.standard.bool(forKey: Keys.allowConcurrent)
        self.openCodePath = Self.resolveOpenCode()

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
        proc.arguments = arguments(model: selectedModel.repoID, port: port)

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
        appendLog("$ \(exe) " + arguments(model: selectedModel.repoID, port: port).joined(separator: " ") + "\n\n")

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

        let tree = Self.processTreePIDs(root: proc.processIdentifier)
        Self.signal(tree, SIGTERM) // lets uvicorn shut down cleanly

        // Escalate to SIGKILL if anything is still alive after a few seconds.
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { [weak self] in
            let survivors = tree.filter { kill($0, 0) == 0 }
            guard !survivors.isEmpty else { return } // all gone
            DispatchQueue.main.async {
                self?.appendLog("[Server ignored SIGTERM; sending SIGKILL]\n")
            }
            Self.signal(survivors, SIGKILL)
        }
    }

    /// Stops the server and every process it spawned, waits (up to ~3s) for them
    /// to actually exit before hard-killing, then sweeps the port. Used on quit
    /// so the menu-bar app never leaves an `mlx_lm.server` (or any child process)
    /// running after it disappears.
    func stopSynchronouslyForQuit() {
        pollTask?.cancel()
        pollTask = nil

        if let proc = process {
            let root = proc.processIdentifier
            process = nil

            // Collect the whole tree up front, then signal it together so we
            // don't lose track of children after the parent starts dying.
            let tree = Self.processTreePIDs(root: root)
            Self.signal(tree, SIGTERM)

            // The kernel marks a pid dead independently of our run loop, so
            // polling is safe even though quit runs on the main thread.
            for _ in 0..<60 {
                if tree.allSatisfy({ kill($0, 0) != 0 }) { break } // all gone
                usleep(50_000)                                      // 50 ms
            }
            Self.signal(tree.filter { kill($0, 0) == 0 }, SIGKILL)
        }

        // Safety net: also kill anything still listening on our port, tracked or
        // not, so a server from a crashed/previous session can't outlive the app.
        Self.killListeners(on: port)
    }

    // MARK: - Process tree

    /// The PID of `root` and every process descended from it.
    private static func processTreePIDs(root: pid_t) -> [pid_t] {
        var seen: Set<pid_t> = [root]
        var frontier: [pid_t] = [root]
        while let parent = frontier.popLast() {
            for child in childPIDs(of: parent) where !seen.contains(child) {
                seen.insert(child)
                frontier.append(child)
            }
        }
        return Array(seen)
    }

    /// Direct child PIDs of `pid` (via `pgrep -P`). Empty on failure.
    private static func childPIDs(of pid: pid_t) -> [pid_t] {
        let output = runTool("/usr/bin/pgrep", ["-P", "\(pid)"])
        return output.split(separator: "\n").compactMap { Int32($0) }
    }

    /// Sends `signal` to every pid in `pids`.
    private static func signal(_ pids: [pid_t], _ signal: Int32) {
        for pid in pids { kill(pid, signal) }
    }

    /// Kills any process currently listening on `port`. A last-resort sweep.
    private static func killListeners(on port: Int) {
        let output = runTool("/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"])
        for pidStr in output.split(separator: "\n") {
            guard let pid = Int32(pidStr) else { continue }
            kill(pid, SIGTERM)
            usleep(200_000)
            if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        }
    }

    /// Runs a tool synchronously and returns its stdout ("" on failure).
    private static func runTool(_ path: String, _ arguments: [String]) -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = arguments
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch {
            return ""
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
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

    // MARK: - Prerequisites

    /// Checks whether the currently-selected model is already in the local
    /// HuggingFace cache and updates `modelCached`.
    func checkModelCached() {
        modelCached = Self.modelIsCached(repoID: selectedModel.repoID)
    }

    /// Re-resolves the `mlx_lm.server` binary (used after an install finishes).
    func refreshExecutableResolution() {
        resolvedExecutable = Self.resolveExecutable(override: executablePath)
    }

    /// Installs `mlx-lm` (plus the `uvicorn`/`fastapi` its server needs) into the
    /// discovered Python environment, streaming output to `installOutput`.
    func installMLX() {
        guard !isInstalling else { return }
        guard let python = Self.findPython() else {
            installOutput = "Could not find a Python interpreter to install into.\n"
            return
        }
        isInstalling = true
        installOutput = ""
        appendInstallOutput("$ \(python) -m pip install --upgrade mlx-lm uvicorn fastapi\n\n")
        runStreaming(executable: python,
                     arguments: ["-m", "pip", "install", "--upgrade", "mlx-lm", "uvicorn", "fastapi"],
                     sink: { [weak self] in self?.appendInstallOutput($0) },
                     completion: { [weak self] status in
            guard let self else { return }
            self.isInstalling = false
            self.appendInstallOutput(status == 0 ? "\n[mlx-lm installed]\n" : "\n[install failed (status \(status))]\n")
            self.refreshExecutableResolution()
        })
    }

    /// Downloads the currently-selected model into the local HuggingFace cache.
    func downloadModel() {
        guard !isInstalling else { return }
        guard let hf = Self.findHF() else {
            installOutput = "Download tool (`hf`) not found. Install mlx-lm first — it bundles huggingface_hub.\n"
            return
        }
        isInstalling = true
        installOutput = ""
        let repo = selectedModel.repoID
        appendInstallOutput("$ \(hf) download \(repo)\n\n")
        runStreaming(executable: hf,
                     arguments: ["download", repo],
                     sink: { [weak self] in self?.appendInstallOutput($0) },
                     completion: { [weak self] status in
            guard let self else { return }
            self.isInstalling = false
            self.appendInstallOutput(status == 0 ? "\n[Model downloaded]\n" : "\n[download failed (status \(status))]\n")
            self.checkModelCached()
        })
    }

    private func appendInstallOutput(_ text: String) {
        installOutput.append(text)
        if installOutput.count > 200_000 {
            installOutput = String(installOutput.suffix(100_000))
        }
    }

    /// Runs a subprocess, streaming stdout/stderr into `sink` on the main actor
    /// and reporting the exit status to `completion`.
    @discardableResult
    private func runStreaming(executable: String,
                              arguments: [String],
                              sink: @escaping (String) -> Void,
                              completion: @escaping (Int32) -> Void) -> Process? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        outPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                DispatchQueue.main.async { sink(text) }
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                DispatchQueue.main.async { sink(text) }
            }
        }
        proc.terminationHandler = { finished in
            DispatchQueue.main.async { completion(finished.terminationStatus) }
        }
        do {
            try proc.run()
            return proc
        } catch {
            DispatchQueue.main.async {
                sink("\nFailed to launch: \(error.localizedDescription)\n")
                completion(-1)
            }
            return nil
        }
    }

    // MARK: - Integrations

    /// Path to OpenCode's global config file.
    func openCodeConfigPath() -> String {
        FileManager.default.homeDirectoryForCurrentUser.path + "/.config/opencode/opencode.jsonc"
    }

    /// Re-checks the OpenCode config file. Because the config is port-specific,
    /// this verifies the file actually points at the *current* port (and reports
    /// a stale port as a mismatch rather than "configured"), so a manual or
    /// automatic setup is never treated as done unless it aligns with the server.
    func checkOpenCodeConfig() {
        let path = openCodeConfigPath()
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8),
              let found = Self.portReferenced(in: contents) else {
            openCodeConfigStatus = .notConfigured
            return
        }
        openCodeConfigStatus = found == port ? .configured : .portMismatch(foundPort: found)
    }

    /// Extracts the `127.0.0.1:<port>/v1` (or `localhost:<port>/v1`) port that a
    /// config file's `baseURL` points at, if any.
    private static func portReferenced(in text: String) -> Int? {
        let pattern = #"(?:127\.0\.0\.1|localhost):(\d+)/v1"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let portRange = Range(match.range(at: 1), in: text),
              let found = Int(text[portRange]) else {
            return nil
        }
        return found
    }

    /// Re-resolves the OpenCode CLI (nil if not installed).
    func checkOpenCode() {
        openCodePath = Self.resolveOpenCode()
    }

    /// Writes a global OpenCode config pointing at this server (current port +
    /// selected model), backing up any existing file first.
    func writeOpenCodeConfig() {
        let path = openCodeConfigPath()
        let dir = (path as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

            if FileManager.default.fileExists(atPath: path) {
                let df = DateFormatter()
                df.dateFormat = "yyyyMMdd-HHmmss"
                let backup = path + ".bak-" + df.string(from: Date())
                try FileManager.default.moveItem(atPath: path, toPath: backup)
                setupMessage = "Backed up existing config to \(backup)\n"
            } else {
                setupMessage = ""
            }

            try openCodeConfigText.write(toFile: path, atomically: true, encoding: .utf8)
            setupMessage += "Wrote \(path)\n"
            checkOpenCodeConfig()
        } catch {
            setupMessage = "Failed to write OpenCode config: \(error.localizedDescription)\n"
        }
    }

    /// The OpenCode config that points the agent at this MLX server. The
    /// `limit.output: 8192` caps OpenCode's requests to match the server's
    /// `--max-tokens`, which keeps a mid-generation disconnect from wedging the
    /// single generation thread (see the main repo README).
    var openCodeConfigText: String {
        let config: [String: Any] = [
            "$schema": "https://opencode.ai/config.json",
            "model": "mlx/default_model",
            "provider": [
                "mlx": [
                    "npm": "@ai-sdk/openai-compatible",
                    "name": "MLX (local)",
                    "options": [
                        "baseURL": "http://127.0.0.1:\(port)/v1",
                        "chunkTimeout": false,
                        "headerTimeout": false
                    ],
                    "models": [
                        "default_model": [
                            "name": selectedModel.displayName,
                            "limit": ["context": 32768, "output": 8192]
                        ]
                    ]
                ]
            ]
        ]
        if let data = try? JSONSerialization.data(withJSONObject: config,
                                                  options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            // JSONSerialization escapes "/" as "\/"; unescape for a readable
            // config and so the "already configured" substring check matches.
            return text.replacingOccurrences(of: "\\/", with: "/")
        }
        return "{}\n"
    }

    // MARK: - Connect info

    /// OpenAI-compatible base URL for the running server.
    var baseURL: String { "http://127.0.0.1:\(port)/v1" }

    /// Model name clients put in the `model` field. `mlx_lm.server` serves the
    /// loaded model under the fixed alias `default_model` (mapped to `--model`).
    var modelAlias: String { "default_model" }

    /// A ready-to-paste `curl` smoke test for the running server.
    var curlExample: String {
        """
        curl http://127.0.0.1:\(port)/v1/chat/completions \\
          -H "Content-Type: application/json" \\
          -d '{"model": "default_model", "messages": [{"role": "user", "content": "Hello!"}]}'
        """
    }

    /// A ready-to-paste Python example using the OpenAI SDK.
    var pythonExample: String {
        """
        from openai import OpenAI

        client = OpenAI(base_url="http://127.0.0.1:\(port)/v1", api_key="not-needed")
        resp = client.chat.completions.create(
            model="default_model",
            messages=[{"role": "user", "content": "Hello!"}],
        )
        print(resp.choices[0].message.content)
        """
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

    private func arguments(model: String, port: Int) -> [String] {
        // Mirrors start_server.sh: a token cap that lets tool calls finish, and
        // deterministic-but-not-greedy sampling to avoid repetition loops.
        var args: [String] = [
            "--model", model,
            "--host", "127.0.0.1",
            "--port", "\(port)"
        ]
        // Quantized KV cache (--kv-bits 4) keeps large models inside Metal memory
        // but forces mlx_lm.server to serve requests one at a time. Omit it (full
        // precision) when the user opts into concurrent/batched requests.
        if !allowConcurrentRequests {
            args += ["--kv-bits", "4"]
        }
        args += [
            "--max-tokens", "8192",
            "--temp", "0.2",
            "--top-p", "0.8",
            "--top-k", "20"
        ]
        return args
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
        return resolveViaLoginShell(command: "mlx_lm.server")
    }

    /// Finds the OpenCode CLI, preferring its standard install location.
    private static func resolveOpenCode() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            home + "/.opencode/bin/opencode",
            home + "/.local/bin/opencode",
            "/opt/homebrew/bin/opencode",
            "/usr/local/bin/opencode"
        ]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return resolveViaLoginShell(command: "opencode")
    }

    private static func resolveViaLoginShell(command: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = ["-ic", "command -v \(command)"]
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

    /// Directories that may contain the conda/homebrew Python and `hf` tooling.
    private static func candidateBinDirs() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "/opt/anaconda3/bin",
            "/opt/miniconda3/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            home + "/anaconda3/bin",
            home + "/miniconda3/bin",
            home + "/miniforge3/bin",
            home + "/.local/bin"
        ]
    }

    /// Finds a usable Python interpreter, preferring the one that owns
    /// `mlx_lm.server` (read from its shebang).
    private static func findPython() -> String? {
        if let exe = resolveExecutable(override: ServerController.shared.executablePath),
           let shebang = try? String(contentsOfFile: exe, encoding: .utf8).split(separator: "\n").first {
            let line = shebang.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#!") {
                var p = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
                if let space = p.firstIndex(of: " ") { p = String(p[..<space]) }
                if FileManager.default.isExecutableFile(atPath: p) { return p }
            }
        }
        for bin in candidateBinDirs() {
            for name in ["python3.13", "python3.12", "python3.11", "python3.10", "python3"] {
                let p = bin + "/" + name
                if FileManager.default.isExecutableFile(atPath: p) { return p }
            }
        }
        return nil
    }

    /// Finds the HuggingFace `hf` CLI used to download models.
    private static func findHF() -> String? {
        for bin in candidateBinDirs() {
            let p = bin + "/hf"
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    /// The local HuggingFace cache `hub/` directory (respects `HF_HOME`).
    private static func hfHubDir() -> String {
        if let hfHome = ProcessInfo.processInfo.environment["HF_HOME"], !hfHome.isEmpty {
            return (hfHome as NSString).expandingTildeInPath + "/hub"
        }
        return FileManager.default.homeDirectoryForCurrentUser.path + "/.cache/huggingface/hub"
    }

    private static let weightExtensions = [".safetensors", ".gguf", ".npz", ".bin"]

    /// A model is considered cached when some snapshot has both a `config.json`
    /// and at least one weight file.
    private static func modelIsCached(repoID: String) -> Bool {
        let repoName = "models--" + repoID.replacingOccurrences(of: "/", with: "--")
        let snapshots = hfHubDir() + "/" + repoName + "/snapshots"
        guard let dirs = try? FileManager.default.contentsOfDirectory(atPath: snapshots) else { return false }
        for dir in dirs {
            let snapshotDir = snapshots + "/" + dir
            guard let entries = try? FileManager.default.contentsOfDirectory(atPath: snapshotDir) else { continue }
            let hasConfig = entries.contains("config.json")
            let hasWeights = entries.contains { e in weightExtensions.contains(where: { e.hasSuffix($0) }) }
            if hasConfig && hasWeights { return true }
        }
        return false
    }
}
