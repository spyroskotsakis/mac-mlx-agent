import Foundation
import SwiftUI
import Darwin

/// One selectable model. `repoID` is the HuggingFace `mlx-community/…` id passed
/// to `mlx_lm.server --model`; `displayName` is what the picker shows.
/// Per-model capabilities. `maxContext` is the model's maximum context length
/// (from its config's `max_position_embeddings`); `thinkingSupported` says
/// whether its chat template accepts `enable_thinking`.
struct ModelProfile: Hashable {
    let maxContext: Int
    let thinkingSupported: Bool
}

/// One selectable model. `repoID` is the HuggingFace `mlx-community/…` id passed
/// to `mlx_lm.server --model`; `displayName` is what the picker shows.
struct ModelOption: Identifiable, Hashable {
    let repoID: String
    let displayName: String
    let profile: ModelProfile
    var id: String { repoID }
}

/// Defaults for the model settings exposed in the app. These are the values
/// `start_server.sh` shipped with; "Reset to defaults" restores them.
enum ModelDefaults {
    static let enableThinking = false
    static let temperature = 0.2
    static let topP = 0.8
    static let topK = 20
    static let maxTokens = 8192
    /// Hard cap for the output-tokens setting; Qwen3-family models generate at
    /// most this many tokens in a single response (same for every model, so it
    /// lives here rather than in each model's profile).
    static let maxOutputTokens = 32768
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

    enum OpenCodeConfigStatus: Equatable {
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
                    displayName: "Qwen3.5-35B-A3B (4-bit)",
                    profile: ModelProfile(maxContext: 262_144, thinkingSupported: true)),
        ModelOption(repoID: "mlx-community/Qwen3.6-35B-A3B-4bit",
                    displayName: "Qwen3.6-35B-A3B (4-bit)",
                    profile: ModelProfile(maxContext: 262_144, thinkingSupported: true)),
        ModelOption(repoID: "mlx-community/Qwen3.8-27B-4bit",
                    displayName: "Qwen3.8-27B (4-bit)",
                    profile: ModelProfile(maxContext: 262_144, thinkingSupported: true)),
        ModelOption(repoID: "mlx-community/Qwen3-14B-4bit",
                    displayName: "Qwen3-14B (4-bit)",
                    profile: ModelProfile(maxContext: 40_960, thinkingSupported: true))
    ]

    @Published private(set) var state: ServerState = .stopped
    @Published private(set) var log: String = ""
    @Published private(set) var resolvedExecutable: String?

    @Published private(set) var modelCached: Bool?
    @Published private(set) var installOutput: String = ""
    @Published private(set) var isInstalling: Bool = false
    @Published private(set) var downloadProgress: Double?
    @Published private(set) var downloadTotalBytes: Int64?
    @Published private(set) var downloadBytes: Int64 = 0
    @Published private(set) var modelMessage: String = ""
    @Published private(set) var openCodeConfigStatus: OpenCodeConfigStatus = .checking
    @Published private(set) var setupMessage: String = ""
    @Published private(set) var openCodePath: String?
    @Published private(set) var claudeCodePath: String?
    @Published private(set) var claudeCodeVersion: String?
    @Published private(set) var claudeCodeProfileWritten: Bool = false
    @Published private(set) var litellmPath: String?
    @Published private(set) var litellmVersion: String?
    @Published private(set) var litellmConfigWritten: Bool = false
    @Published private(set) var bridgeRunning: Bool = false
    @Published private(set) var portConflictMessage: String?
    @Published private(set) var mlxLMHealthy: Bool = true

    @Published var selectedModel: ModelOption {
        didSet {
            UserDefaults.standard.set(selectedModel.repoID, forKey: Keys.model)
            // Reflect this model's own thinking preference in the UI.
            enableThinking = Self.loadThinking(for: selectedModel.repoID)
        }
    }

    @Published var port: Int {
        didSet { UserDefaults.standard.set(port, forKey: Keys.port) }
    }

    /// Port for the LiteLLM bridge (Claude Code's Anthropic → OpenAI proxy).
    @Published var bridgePort: Int {
        didSet { UserDefaults.standard.set(bridgePort, forKey: Keys.bridgePort) }
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

    /// When true, the server passes `--chat-template-args '{"enable_thinking":true}'`
    /// so Qwen3-family models emit a hidden reasoning step before answering.
    /// Per-model (stored under the selected model's repo id); only takes effect
    /// on the next Start.
    @Published var enableThinking: Bool {
        didSet { UserDefaults.standard.set(enableThinking, forKey: Self.thinkingKey(for: selectedModel.repoID)) }
    }

    /// Sampling temperature (0–2).
    @Published var temperature: Double {
        didSet { UserDefaults.standard.set(temperature, forKey: Keys.temperature) }
    }

    /// Nucleus sampling top-p (0–1).
    @Published var topP: Double {
        didSet { UserDefaults.standard.set(topP, forKey: Keys.topP) }
    }

    /// Top-k sampling (0 disables it).
    @Published var topK: Int {
        didSet { UserDefaults.standard.set(topK, forKey: Keys.topK) }
    }

    /// Default maximum number of generated tokens per request.
    @Published var maxTokens: Int {
        didSet { UserDefaults.standard.set(maxTokens, forKey: Keys.maxTokens) }
    }

    private var process: Process?
    private var bridgeProcess: Process?
    private var pollTask: Task<Void, Never>?
    private var downloadPollTask: Task<Void, Never>?

    private enum Keys {
        static let model = "mlxServerModel"
        static let port = "mlxServerPort"
        static let bridgePort = "mlxServerBridgePort"
        static let executable = "mlxServerExecutable"
        static let allowConcurrent = "mlxServerAllowConcurrent"
        static let enableThinking = "mlxServerEnableThinking"
        static let temperature = "mlxServerTemperature"
        static let topP = "mlxServerTopP"
        static let topK = "mlxServerTopK"
        static let maxTokens = "mlxServerMaxTokens"
    }

    init() {
        let savedPort = UserDefaults.standard.integer(forKey: Keys.port)
        self.port = savedPort == 0 ? 8080 : savedPort

        let savedBridgePort = UserDefaults.standard.integer(forKey: Keys.bridgePort)
        self.bridgePort = savedBridgePort == 0 ? 4001 : savedBridgePort

        self.executablePath = UserDefaults.standard.string(forKey: Keys.executable) ?? ""
        self.allowConcurrentRequests = UserDefaults.standard.bool(forKey: Keys.allowConcurrent)

        let savedModel = UserDefaults.standard.string(forKey: Keys.model)
        let initialModel = Self.availableModels.first(where: { $0.repoID == savedModel })
            ?? Self.availableModels.first!
        self.selectedModel = initialModel

        self.enableThinking = Self.loadThinking(for: initialModel.repoID)
        self.temperature = UserDefaults.standard.object(forKey: Keys.temperature) as? Double ?? ModelDefaults.temperature
        self.topP = UserDefaults.standard.object(forKey: Keys.topP) as? Double ?? ModelDefaults.topP
        self.topK = UserDefaults.standard.object(forKey: Keys.topK) as? Int ?? ModelDefaults.topK
        self.maxTokens = UserDefaults.standard.object(forKey: Keys.maxTokens) as? Int ?? ModelDefaults.maxTokens
        self.openCodePath = Self.resolveOpenCode()
        self.claudeCodePath = Self.resolveClaudeCode()
        self.claudeCodeVersion = self.claudeCodePath.flatMap { Self.claudeVersion(at: $0) }
        self.claudeCodeProfileWritten = FileManager.default.fileExists(atPath: Self.claudeCodeEnvFilePath())
        self.litellmPath = Self.resolveLitellm()
        self.litellmVersion = self.litellmPath.flatMap { Self.litellmVersion(at: $0) }
        self.litellmConfigWritten = FileManager.default.fileExists(atPath: Self.litellmConfigFilePath())

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
        checkMLXLM()
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
        checkPortConflicts()
        if let conflict = portConflictMessage {
            state = .failed(conflict)
            return
        }
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
            startBridge()
        } catch {
            state = .failed(error.localizedDescription)
            process = nil
            appendLog("\nFailed to launch: \(error.localizedDescription)\n")
        }
    }

    func stop() {
        stopBridge()
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
        stopBridge()

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
        Self.killListeners(on: bridgePort)
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
        stopBridge()

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
        modelMessage = ""
    }

    /// On-disk bytes of the currently-selected model in the HF cache (0 if absent).
    var selectedModelDiskBytes: Int64 {
        let repo = selectedModel.repoID
        let blobsDir = Self.hfHubDir() + "/models--" + repo.replacingOccurrences(of: "/", with: "--") + "/blobs"
        return Self.directorySize(atPath: blobsDir)
    }

    /// The local HuggingFace cache folder for the currently-selected model.
    var modelFolderPath: String {
        Self.hfHubDir() + "/models--" + selectedModel.repoID.replacingOccurrences(of: "/", with: "--")
    }

    /// Deletes the currently-selected model from the local HuggingFace cache,
    /// removing its whole `models--…` directory (blobs, snapshots, and refs).
    func deleteModel() {
        guard !isInstalling, canSwitchModel else { return }
        let repo = selectedModel.repoID
        let repoDir = Self.hfHubDir() + "/models--" + repo.replacingOccurrences(of: "/", with: "--")
        let freed = Self.directorySize(atPath: repoDir + "/blobs")
        do {
            if FileManager.default.fileExists(atPath: repoDir) {
                try FileManager.default.removeItem(atPath: repoDir)
            }
            checkModelCached()
            let freedText = ByteCountFormatter.string(fromByteCount: freed, countStyle: .file)
            modelMessage = "Deleted \(repo) — freed \(freedText)."
        } catch {
            modelMessage = "Failed to delete \(repo): \(error.localizedDescription)"
        }
    }

    /// Restores every model setting to its default (the values `start_server.sh`
    /// shipped with). Takes effect on the next Start.
    func resetModelSettings() {
        enableThinking = ModelDefaults.enableThinking
        temperature = ModelDefaults.temperature
        topP = ModelDefaults.topP
        topK = ModelDefaults.topK
        maxTokens = ModelDefaults.maxTokens
    }

    // MARK: - Per-model settings

    /// UserDefaults key that stores a model's thinking preference.
    private static func thinkingKey(for repoID: String) -> String {
        Keys.enableThinking + "." + repoID
    }

    /// Loads a model's thinking preference (default: off).
    private static func loadThinking(for repoID: String) -> Bool {
        UserDefaults.standard.bool(forKey: thinkingKey(for: repoID))
    }

    /// Re-resolves the `mlx_lm.server` binary (used after an install finishes).
    func refreshExecutableResolution() {
        resolvedExecutable = Self.resolveExecutable(override: executablePath)
    }

    /// Runs `mlx_lm.server --help` to confirm the mlx-lm install actually imports
    /// (a broken install — e.g. a transformers/huggingface_hub conflict — exits
    /// non-zero). Off the main thread so the UI doesn't stall.
    func checkMLXLM() {
        guard let exe = resolvedExecutable else { return }
        DispatchQueue.global(qos: .utility).async {
            let healthy = Self.mlxLMHealth(at: exe)
            DispatchQueue.main.async {
                self.mlxLMHealthy = healthy
            }
        }
    }

    /// Re-runs every prerequisite check (mlx-lm binary, model cache, OpenCode CLI,
    /// and OpenCode config) in one go, so "Check status" can re-verify readiness
    /// after the user installs a missing piece.
    func checkAllPrerequisites() {
        refreshExecutableResolution()
        checkModelCached()
        checkOpenCode()
        checkOpenCodeConfig()
        checkClaudeCode()
        checkLitellm()
        checkPortConflicts()
        checkMLXLM()
    }

    /// Whether every prerequisite is met: mlx-lm installed, the selected model
    /// downloaded, OpenCode installed + configured, and Claude Code installed +
    /// runnable with its bridge profile and the LiteLLM bridge config written.
    var isReady: Bool {
        resolvedExecutable != nil &&
        mlxLMHealthy == true &&
        modelCached == true &&
        openCodePath != nil &&
        openCodeConfigStatus == .configured &&
        claudeCodePath != nil &&
        claudeCodeVersion != nil &&
        claudeCodeProfileWritten &&
        litellmPath != nil &&
        litellmVersion != nil &&
        litellmConfigWritten
    }

    /// The prerequisite names still missing (empty when `isReady`).
    var missingPrerequisites: [String] {
        var missing: [String] = []
        if resolvedExecutable == nil {
            missing.append("mlx-lm")
        } else if !mlxLMHealthy {
            missing.append("mlx-lm (broken)")
        }
        if modelCached != true { missing.append("model files") }
        if openCodePath == nil { missing.append("OpenCode") }
        if openCodeConfigStatus != .configured { missing.append("OpenCode config") }
        if claudeCodePath == nil {
            missing.append("Claude Code")
        } else if claudeCodeVersion == nil {
            missing.append("Claude Code (broken)")
        }
        if !claudeCodeProfileWritten { missing.append("Claude Code profile") }
        if litellmPath == nil {
            missing.append("LiteLLM")
        } else if litellmVersion == nil {
            missing.append("LiteLLM (broken)")
        }
        if !litellmConfigWritten { missing.append("LiteLLM config") }
        return missing
    }

    /// Warns if the MLX server or bridge port is already taken by another process
    /// (ignoring the app's own running server/bridge). Call before starting.
    func checkPortConflicts() {
        var conflicts: [String] = []
        if isExternalPortInUse(port) { conflicts.append("\(port) (MLX server)") }
        if isExternalPortInUse(bridgePort) { conflicts.append("\(bridgePort) (LiteLLM bridge)") }
        portConflictMessage = conflicts.isEmpty
            ? nil
            : "Port already in use: " + conflicts.joined(separator: ", ") + " — change it in Advanced."
    }

    /// Whether `port` is listened on by a process other than the app's own.
    private func isExternalPortInUse(_ port: Int) -> Bool {
        let output = Self.runTool("/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"])
        let pids = output.split(separator: "\n").compactMap { Int32($0) }
        let ours: Set<pid_t> = Set([process?.processIdentifier, bridgeProcess?.processIdentifier].compactMap { $0 })
        return pids.contains { !ours.contains($0) }
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
            self.checkMLXLM()
        })
    }

    /// Downloads the currently-selected model into the local HuggingFace cache,
    /// reporting byte-level progress to `downloadProgress` while it runs.
    func downloadModel() {
        guard !isInstalling else { return }
        guard let hf = Self.findHF() else {
            installOutput = "Download tool (`hf`) not found. Install mlx-lm first — it bundles huggingface_hub.\n"
            return
        }
        isInstalling = true
        installOutput = ""
        downloadProgress = 0
        downloadTotalBytes = nil
        downloadBytes = 0
        let repo = selectedModel.repoID
        appendInstallOutput("$ \(hf) download \(repo)\n\n")

        let blobsDir = Self.hfHubDir() + "/models--" + repo.replacingOccurrences(of: "/", with: "--") + "/blobs"

        // Poll the cache's blobs directory to turn bytes-on-disk into a real
        // percentage, instead of trying to parse the CLI's animated progress bar.
        downloadPollTask = Task { [weak self] in
            guard let self else { return }
            let total = await Self.totalDownloadSize(repoID: repo)
            await MainActor.run { self.downloadTotalBytes = total }
            while !Task.isCancelled {
                let bytes = Self.directorySize(atPath: blobsDir)
                let fraction: Double?
                if let total = total, total > 0 {
                    fraction = min(1.0, Double(bytes) / Double(total))
                } else {
                    fraction = nil
                }
                await MainActor.run {
                    self.downloadBytes = bytes
                    self.downloadProgress = fraction
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }

        runStreaming(executable: hf,
                     arguments: ["download", repo],
                     sink: { [weak self] in self?.appendInstallOutput($0) },
                     completion: { [weak self] status in
            guard let self else { return }
            self.downloadPollTask?.cancel()
            self.downloadPollTask = nil
            self.isInstalling = false
            self.downloadProgress = nil
            self.downloadTotalBytes = nil
            self.downloadBytes = 0
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

    /// Folder containing OpenCode's config file (used for "Show in Finder").
    var configFolderPath: String {
        (openCodeConfigPath() as NSString).deletingLastPathComponent
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

    // MARK: - Claude Code (separate profile via the LiteLLM bridge)

    /// Path to Claude Code's env profile (sourced by the `claude-local` /
    /// `claude-mlx` shell alias). Separate from OpenCode's config because Claude
    /// Code speaks the Anthropic API and reaches the model through the LiteLLM
    /// bridge rather than the OpenAI endpoint directly.
    func claudeCodeEnvPath() -> String {
        Self.claudeCodeEnvFilePath()
    }

    /// Folder containing Claude Code's env profile (for "Show in Finder").
    var claudeCodeEnvFolderPath: String {
        (Self.claudeCodeEnvFilePath() as NSString).deletingLastPathComponent
    }

    private static func claudeCodeEnvFilePath() -> String {
        FileManager.default.homeDirectoryForCurrentUser.path + "/.config/mlx-local/claude-code.env"
    }

    /// Re-resolves the Claude Code CLI, confirms it runs (`--version`), and
    /// re-checks whether its env profile exists.
    func checkClaudeCode() {
        claudeCodePath = Self.resolveClaudeCode()
        claudeCodeVersion = claudeCodePath.flatMap { Self.claudeVersion(at: $0) }
        claudeCodeProfileWritten = FileManager.default.fileExists(atPath: Self.claudeCodeEnvFilePath())
    }

    /// The Claude Code env profile. Points `claude` at the LiteLLM bridge, which
    /// translates Anthropic → OpenAI to reach the MLX server on its configured port.
    var claudeCodeConfigText: String {
        """
        # Claude Code → local MLX model via the LiteLLM bridge.
        # Sourced by the `claude-local` / `claude-mlx` shell alias (see ~/.bashrc).
        # Prerequisites: the MLX server (\(port)) AND the LiteLLM bridge (\(bridgePort)) running.
        export ANTHROPIC_BASE_URL="http://127.0.0.1:\(bridgePort)"
        export ANTHROPIC_AUTH_TOKEN="sk-local-claude"
        export ANTHROPIC_MODEL="default_model"
        export ANTHROPIC_DEFAULT_OPUS_MODEL="default_model"
        export ANTHROPIC_DEFAULT_SONNET_MODEL="default_model"
        export ANTHROPIC_DEFAULT_HAIKU_MODEL="default_model"
        export CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1
        """
    }

    /// Writes the Claude Code env profile (backing up any existing file first).
    func writeClaudeCodeConfig() {
        let path = claudeCodeEnvPath()
        let dir = (path as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

            if FileManager.default.fileExists(atPath: path) {
                let df = DateFormatter()
                df.dateFormat = "yyyyMMdd-HHmmss"
                let backup = path + ".bak-" + df.string(from: Date())
                try FileManager.default.moveItem(atPath: path, toPath: backup)
                setupMessage = "Backed up existing Claude Code profile to \(backup)\n"
            } else {
                setupMessage = ""
            }

            try claudeCodeConfigText.write(toFile: path, atomically: true, encoding: .utf8)
            setupMessage += "Wrote \(path)\n"
            checkClaudeCode()
        } catch {
            setupMessage = "Failed to write Claude Code profile: \(error.localizedDescription)\n"
        }
    }

    // MARK: - LiteLLM bridge (Claude Code needs it; written here so repo-less users get it too)

    /// Path to the LiteLLM bridge config the app writes for Claude Code.
    func litellmConfigPath() -> String {
        Self.litellmConfigFilePath()
    }

    /// Folder containing the LiteLLM bridge config (for "Show in Finder").
    var litellmConfigFolderPath: String {
        (Self.litellmConfigFilePath() as NSString).deletingLastPathComponent
    }

    private static func litellmConfigFilePath() -> String {
        FileManager.default.homeDirectoryForCurrentUser.path + "/.config/mlx-local/litellm-mlx.yaml"
    }

    /// Re-resolves the `litellm` CLI and re-checks whether the bridge config exists.
    func checkLitellm() {
        litellmPath = Self.resolveLitellm()
        litellmVersion = litellmPath.flatMap { Self.litellmVersion(at: $0) }
        litellmConfigWritten = FileManager.default.fileExists(atPath: Self.litellmConfigFilePath())
    }

    /// The LiteLLM bridge config. Maps `default_model` to the MLX server's OpenAI
    /// endpoint so Claude Code (Anthropic API) can reach the local model.
    var litellmConfigText: String {
        """
        # LiteLLM bridge: Anthropic Messages API (/v1/messages) -> MLX-LM OpenAI API.
        # Written by MLX Server. Start the MLX server first, then this proxy:
        #   litellm --config ~/.config/mlx-local/litellm-mlx.yaml --host 127.0.0.1 --port \(bridgePort)
        # Then point Claude Code at http://127.0.0.1:\(bridgePort).

        model_list:
          - model_name: default_model
            litellm_params:
              model: custom_openai/default_model
              api_base: http://127.0.0.1:\(port)/v1
              api_key: sk-no-key-needed

        litellm_settings:
          drop_params: true

        general_settings:
          master_key: sk-local-claude
        """
    }

    /// Writes the LiteLLM bridge config (backing up any existing file first).
    func writeLitellmConfig() {
        let path = litellmConfigPath()
        let dir = (path as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

            if FileManager.default.fileExists(atPath: path) {
                let df = DateFormatter()
                df.dateFormat = "yyyyMMdd-HHmmss"
                let backup = path + ".bak-" + df.string(from: Date())
                try FileManager.default.moveItem(atPath: path, toPath: backup)
                setupMessage = "Backed up existing LiteLLM config to \(backup)\n"
            } else {
                setupMessage = ""
            }

            try litellmConfigText.write(toFile: path, atomically: true, encoding: .utf8)
            setupMessage += "Wrote \(path)\n"
            checkLitellm()
        } catch {
            setupMessage = "Failed to write LiteLLM config: \(error.localizedDescription)\n"
        }
    }

    /// Installs `litellm[proxy]` into its own venv (`.venv-litellm`), never into
    /// the mlx-lm environment: litellm pins `tokenizers==0.22.2` while mlx_lm's
    /// transformers needs `>=0.23.1`, so they cannot share a Python environment.
    func installLitellm() {
        guard !isInstalling else { return }
        guard let python = Self.findPython() else {
            installOutput = "Could not find a Python interpreter to bootstrap litellm.\n"
            return
        }
        isInstalling = true
        installOutput = ""

        let venvDir = Self.litellmVenvFolderPath()
        let venvPython = venvDir + "/bin/python"
        let venvLitellm = venvDir + "/bin/litellm"

        if FileManager.default.isExecutableFile(atPath: venvLitellm) {
            installLitellmIntoVenv(python: venvPython)
        } else {
            appendInstallOutput("$ \(python) -m venv \(venvDir)\n\n")
            runStreaming(executable: python,
                         arguments: ["-m", "venv", venvDir],
                         sink: { [weak self] in self?.appendInstallOutput($0) },
                         completion: { [weak self] status in
                guard let self else { return }
                guard status == 0 else {
                    self.isInstalling = false
                    self.appendInstallOutput("\n[Failed to create the litellm venv (status \(status))]\n")
                    self.checkLitellm()
                    return
                }
                self.installLitellmIntoVenv(python: venvPython)
            })
        }
    }

    private func installLitellmIntoVenv(python: String) {
        appendInstallOutput("$ \(python) -m pip install --upgrade 'litellm[proxy]'\n\n")
        runStreaming(executable: python,
                     arguments: ["-m", "pip", "install", "--upgrade", "litellm[proxy]"],
                     sink: { [weak self] in self?.appendInstallOutput($0) },
                     completion: { [weak self] status in
            guard let self else { return }
            self.isInstalling = false
            self.appendInstallOutput(status == 0 ? "\n[litellm installed in its own venv]\n" : "\n[install failed (status \(status))]\n")
            self.checkLitellm()
        })
    }

    // MARK: - LiteLLM bridge process (auto-started with the server)

    /// Starts the LiteLLM bridge on `bridgePort` alongside the MLX server. Writes the
    /// bridge config first (so its `api_base` always matches the current port),
    /// then launches `litellm`. No-op if litellm isn't installed or already runs.
    private func startBridge() {
        guard let litellm = litellmPath else {
            appendLog("\n[LiteLLM bridge not started: litellm not installed]\n")
            return
        }
        guard bridgeProcess == nil else { return }

        let configPath = Self.litellmConfigFilePath()
        let dir = (configPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try? litellmConfigText.write(toFile: configPath, atomically: true, encoding: .utf8)
        litellmConfigWritten = FileManager.default.fileExists(atPath: configPath)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: litellm)
        proc.arguments = ["--config", configPath, "--host", "127.0.0.1", "--port", "\(bridgePort)"]

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                DispatchQueue.main.async { self?.appendLog("[bridge] " + text) }
            }
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if let text = String(data: data, encoding: .utf8), !text.isEmpty {
                DispatchQueue.main.async { self?.appendLog("[bridge] " + text) }
            }
        }
        proc.terminationHandler = { [weak self] finished in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.bridgeProcess === finished {
                    self.bridgeProcess = nil
                    self.bridgeRunning = false
                    if finished.terminationStatus != 0 && self.state.isRunning {
                        self.appendLog("\n[LiteLLM bridge exited (status \(finished.terminationStatus))]\n")
                    }
                }
            }
        }

        bridgeProcess = proc
        do {
            try proc.run()
            bridgeRunning = true
            appendLog("\n[LiteLLM bridge starting on port \(bridgePort)]\n")
        } catch {
            bridgeProcess = nil
            bridgeRunning = false
            appendLog("\n[Failed to launch LiteLLM bridge: \(error.localizedDescription)]\n")
        }
    }

    /// Stops the LiteLLM bridge (if running).
    private func stopBridge() {
        guard let proc = bridgeProcess else { return }
        bridgeProcess = nil
        bridgeRunning = false
        let tree = Self.processTreePIDs(root: proc.processIdentifier)
        Self.signal(tree, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            let survivors = tree.filter { kill($0, 0) == 0 }
            guard !survivors.isEmpty else { return }
            Self.signal(survivors, SIGKILL)
        }
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
    /// `limit.output` caps OpenCode's requests to match the server's
    /// `--max-tokens` (kept in sync with the Model settings), which keeps a
    /// mid-generation disconnect from wedging the single generation thread (see
    /// the main repo README).
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
                            "limit": ["context": selectedModel.profile.maxContext, "output": maxTokens]
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
        // A token cap that lets tool calls finish, and deterministic-but-not-greedy
        // sampling to avoid repetition loops. All values are user-configurable in
        // the Model settings section and only take effect on the next Start.
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
            "--max-tokens", "\(maxTokens)",
            "--temp", Self.samplingText(temperature),
            "--top-p", Self.samplingText(topP),
            "--top-k", "\(topK)",
            "--chat-template-args", "{\"enable_thinking\":\(enableThinking ? "true" : "false")}"
        ]
        return args
    }

    /// Formats a sampling Double for the command line without trailing noise
    /// (0.8, not 0.80).
    private static func samplingText(_ value: Double) -> String {
        String(format: "%.4g", value)
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

    /// Finds the LiteLLM CLI (the bridge Claude Code needs), preferring common
    /// venv / Homebrew / conda locations, then the login shell's PATH.
    private static func litellmVenvFolderPath() -> String {
        FileManager.default.homeDirectoryForCurrentUser.path + "/.config/mlx-local/.venv-litellm"
    }

    private static func resolveLitellm() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            litellmVenvFolderPath() + "/bin/litellm",
            home + "/.local/bin/litellm",
            "/opt/homebrew/bin/litellm",
            "/usr/local/bin/litellm",
            "/opt/anaconda3/bin/litellm",
            "/opt/miniconda3/bin/litellm"
        ]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return resolveViaLoginShell(command: "litellm")
    }

    /// Finds the Claude Code CLI, preferring the platform-native binary, then the
    /// npm/nvm shim, then common Homebrew / native-installer locations.
    private static func resolveClaudeCode() -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = [
            home + "/.local/bin/claude",
            home + "/.claude/local/claude",
            home + "/.claude/bin/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude"
        ]
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate) {
            return candidate
        }

        // npm-global installs under nvm live at ~/.nvm/versions/node/<v>/bin/claude.
        // That path is a symlink to a shim whose target can be non-executable when
        // npm's postinstall didn't run, so accept it if it merely exists.
        let nvmNodes = home + "/.nvm/versions/node"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: nvmNodes) {
            for version in versions.sorted(by: >) {
                let bin = nvmNodes + "/" + version + "/bin/claude"
                if FileManager.default.fileExists(atPath: bin) { return bin }
            }
        }

        return resolveViaLoginShell(command: "claude")
    }

    /// Runs `claude --version` to confirm the binary actually works — a broken
    /// npm install leaves a non-executable shim or a stub that exits non-zero.
    private static func claudeVersion(at path: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = ["--version"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return nil }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let version = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (version?.isEmpty == false) ? version : nil
        } catch {
            return nil
        }
    }

    /// Runs `litellm --version` to confirm the binary actually works — a partial
    /// install (missing the `[proxy]` extras such as `boto3`) exits non-zero.
    private static func litellmVersion(at path: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = ["--version"]
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            guard proc.terminationStatus == 0 else { return nil }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            let version = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (version?.isEmpty == false) ? version : nil
        } catch {
            return nil
        }
    }

    /// Runs `mlx_lm.server --help`; a healthy install exits 0, a broken one (e.g.
    /// a transformers/huggingface_hub conflict) exits non-zero.
    private static func mlxLMHealth(at path: String) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = ["--help"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
    }

    private static func resolveViaLoginShell(command: String) -> String? {
        for shell in ["/bin/bash", "/bin/zsh"] {
            for flags in [["-lc"], ["-ic"]] {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: shell)
                proc.arguments = flags + ["command -v \(command)"]
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
                    // try the next shell/flags
                }
            }
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

    /// Total byte size of a repo's downloadable files, from the HF API.
    private static func totalDownloadSize(repoID: String) async -> Int64? {
        guard let url = URL(string: "https://huggingface.co/api/models/\(repoID)?blobs=true") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let siblings = json["siblings"] as? [[String: Any]] else {
            return nil
        }
        let total = siblings.reduce(into: Int64(0)) { acc, file in
            if let size = file["size"] as? NSNumber { acc += size.int64Value }
        }
        return total > 0 ? total : nil
    }

    /// Sum of regular-file sizes directly under `path` (0 if it doesn't exist).
    private static func directorySize(atPath path: String) -> Int64 {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: path) else { return 0 }
        return names.reduce(into: Int64(0)) { acc, name in
            if let attrs = try? fm.attributesOfItem(atPath: path + "/" + name),
               let size = attrs[.size] as? NSNumber {
                acc += size.int64Value
            }
        }
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
