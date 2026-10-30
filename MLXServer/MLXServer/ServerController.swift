import Foundation
import SwiftUI
import AppKit
import UserNotifications
import Darwin

/// One selectable model. `repoID` is the HuggingFace `mlx-community/…` id passed
/// to `mlx_lm.server --model`; `displayName` is what the picker shows.
/// Per-model capabilities. `maxContext` is the model's maximum context length
/// (from its config's `max_position_embeddings`); `thinkingSupported` says
/// whether its chat template accepts `enable_thinking`.
struct ModelProfile: Hashable {
    let maxContext: Int
    let thinkingSupported: Bool
    /// Approximate RAM (GiB) the 4-bit weights occupy once loaded. Used by the
    /// memory-safety guard to decide whether concurrent requests (full-precision
    /// KV cache, no byte cap) can fit alongside the model on this machine.
    let weightGB: Double
}

/// One selectable model. `repoID` is the HuggingFace `mlx-community/…` id passed
/// to `mlx_lm.server --model`; `displayName` is what the picker shows. `summary`
/// and `highlights` are the one-line description and hashtag-style tags shown
/// under the picker once a model is selected.
struct ModelOption: Identifiable, Hashable {
    let repoID: String
    let displayName: String
    let profile: ModelProfile
    /// What the model is and what it's good for (one short sentence).
    let summary: String
    /// Short hashtag-style highlights (rendered with a leading `#`).
    let highlights: [String]
    var id: String { repoID }
    /// Link to the model's Hugging Face page.
    var hfURL: URL { URL(string: "https://huggingface.co/\(repoID)")! }
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
    /// Default prompt-cache cap in GB, passed as `--prompt-cache-bytes`. The cache
    /// must hold the system prompt's quantized KV cache TWICE (the stored entry
    /// plus the in-flight copy), so size this to ~2× your largest system prompt.
    /// Claude Code's ~85k-token system prompt quantizes to ~6 GB, which fills a
    /// 6 GB cache and defeats caching — trim MCP servers/skills (or raise this) to
    /// make caching effective. OpenCode's far smaller prompt caches comfortably.
    static let promptCacheBytesGB = 6
}

/// One missing prerequisite in the startup guide, with a one-line fix hint.
/// `optional` marks the Claude Code / LiteLLM items that only the optional
/// Claude Code path needs (OpenCode alone is enough to start).
struct SetupStep: Identifiable {
    let id = UUID()
    let title: String
    let hint: String
    let optional: Bool
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
                    profile: ModelProfile(maxContext: 262_144, thinkingSupported: true, weightGB: 18),
                    summary: "Flagship mixture-of-experts (35B total, 3B active per token) — the strongest agentic coding and reasoning here, with vision.",
                    highlights: ["MoE 3B active", "Agentic coding", "Vision", "262K ctx"]),
        ModelOption(repoID: "mlx-community/Qwen3.6-35B-A3B-4bit",
                    displayName: "Qwen3.6-35B-A3B (4-bit)",
                    profile: ModelProfile(maxContext: 262_144, thinkingSupported: true, weightGB: 18),
                    summary: "Newest Qwen MoE (35B total, 3B active) — refined reasoning and tool use for long, demanding agent sessions.",
                    highlights: ["MoE 3B active", "Reasoning", "Agentic", "262K ctx"]),
        ModelOption(repoID: "mlx-community/Qwen3.8-27B-4bit",
                    displayName: "Qwen3.8-27B (4-bit)",
                    profile: ModelProfile(maxContext: 262_144, thinkingSupported: true, weightGB: 14),
                    summary: "Dense 27B — consistent, high-quality coding and multi-turn agent work with vision.",
                    highlights: ["Dense 27B", "Coding", "Vision", "262K ctx"]),
        ModelOption(repoID: "mlx-community/Qwen3-14B-4bit",
                    displayName: "Qwen3-14B (4-bit)",
                    profile: ModelProfile(maxContext: 40_960, thinkingSupported: true, weightGB: 7),
                    summary: "Balanced 14B — fast tool calling and solid reasoning; the memory-safe default for most Macs.",
                    highlights: ["Fast", "Tool-calling", "40K ctx"]),
        ModelOption(repoID: "mlx-community/Qwen3.5-9B-4bit",
                    displayName: "Qwen3.5-9B (4-bit)",
                    profile: ModelProfile(maxContext: 262_144, thinkingSupported: true, weightGB: 6),
                    summary: "Compact 9B with huge context — quick daily coding and chat that still fits smaller-RAM Macs.",
                    highlights: ["Compact", "Coding", "262K ctx"]),
        ModelOption(repoID: "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit",
                    displayName: "Qwen2.5-Coder-7B-Instruct (4-bit)",
                    profile: ModelProfile(maxContext: 32_768, thinkingSupported: false, weightGB: 4.28),
                    summary: "Dedicated code model — strong at snippets, edits, and refactors; no thinking mode.",
                    highlights: ["Code specialist", "Fast", "No thinking"]),
        ModelOption(repoID: "mlx-community/Qwen3.5-4B-4bit",
                    displayName: "Qwen3.5-4B (4-bit)",
                    profile: ModelProfile(maxContext: 262_144, thinkingSupported: true, weightGB: 3.03),
                    summary: "Tiny 4B — snappy replies and full 262K context for light tasks.",
                    highlights: ["Tiny", "Fast", "262K ctx"]),
        ModelOption(repoID: "mlx-community/Qwen3.5-2B-4bit",
                    displayName: "Qwen3.5-2B (4-bit)",
                    profile: ModelProfile(maxContext: 262_144, thinkingSupported: true, weightGB: 1.72),
                    summary: "Smallest Qwen — near-instant on any Mac; fine for quick Q&A.",
                    highlights: ["Smallest", "Instant", "262K ctx"]),
        ModelOption(repoID: "mlx-community/Devstral-Small-2-24B-Instruct-2512-4bit",
                    displayName: "Devstral Small 2 24B Instruct (4-bit)",
                    profile: ModelProfile(maxContext: 393_216, thinkingSupported: false, weightGB: 15.10),
                    summary: "Mistral's 24B coding specialist — strong instruction following and tool use for agents.",
                    highlights: ["Coding", "Agentic", "393K ctx"]),
        ModelOption(repoID: "mlx-community/gemma-4-12B-it-qat-4bit",
                    displayName: "Gemma 4 12B IT QAT (4-bit)",
                    profile: ModelProfile(maxContext: 262_144, thinkingSupported: false, weightGB: 10.99),
                    summary: "Google's 12B with quantized-aware training — capable multilingual general assistant with long context.",
                    highlights: ["Multilingual", "QAT", "262K ctx"]),
        ModelOption(repoID: "mlx-community/Ministral-3-8B-Instruct-2512-4bit",
                    displayName: "Ministral 3 8B Instruct (4-bit)",
                    profile: ModelProfile(maxContext: 262_144, thinkingSupported: false, weightGB: 5.60),
                    summary: "Mistral 8B built for edge/on-device — efficient multilingual chat and light coding.",
                    highlights: ["Multilingual", "Efficient", "262K ctx"]),
        ModelOption(repoID: "mlx-community/gemma-4-e4b-it-4bit",
                    displayName: "Gemma 4 E4B Instruct (4-bit)",
                    profile: ModelProfile(maxContext: 131_072, thinkingSupported: false, weightGB: 5.15),
                    summary: "Google's efficient 4B-class assistant — vision and long context at low memory cost.",
                    highlights: ["Vision", "Efficient", "131K ctx"]),
        ModelOption(repoID: "mlx-community/gemma-4-e2b-it-4bit",
                    displayName: "Gemma 4 E2B Instruct (4-bit)",
                    profile: ModelProfile(maxContext: 131_072, thinkingSupported: false, weightGB: 3.55),
                    summary: "Google's smallest Gemma 4 — fast general chat and vision.",
                    highlights: ["Small", "Vision", "131K ctx"]),
        ModelOption(repoID: "mlx-community/Ministral-3-3B-Instruct-2512-4bit",
                    displayName: "Ministral 3 3B Instruct (4-bit)",
                    profile: ModelProfile(maxContext: 262_144, thinkingSupported: false, weightGB: 2.75),
                    summary: "Mistral 3B for edge devices — tiny multilingual assistant.",
                    highlights: ["Tiny", "Multilingual", "262K ctx"]),
        ModelOption(repoID: "mlx-community/Llama-3.2-3B-Instruct-4bit",
                    displayName: "Llama 3.2 3B Instruct (4-bit)",
                    profile: ModelProfile(maxContext: 131_072, thinkingSupported: false, weightGB: 1.81),
                    summary: "Meta's on-device 3B — small, fast, multilingual general assistant.",
                    highlights: ["On-device", "Multilingual", "131K ctx"])
    ]

    /// Guards the CLI-detection probes so opening the panel in quick succession
    /// (or an `onAppear` racing a "Check status") never stacks duplicate
    /// `--version` subprocesses. Read/written on the main thread only.
    private static var openCodeProbeInFlight = false
    private static var claudeCodeProbeInFlight = false
    private static var litellmProbeInFlight = false

    @Published private(set) var state: ServerState = .stopped
    @Published private(set) var log: String = ""
    @Published private(set) var resolvedExecutable: String?

    @Published private(set) var modelCached: Bool?
    @Published private(set) var modelPartialDownload: Bool = false
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
    @Published private(set) var claudeCodeProfilePortMismatch: Bool = false
    @Published private(set) var litellmPath: String?
    @Published private(set) var hfPath: String?
    @Published private(set) var pythonPath: String?
    @Published private(set) var litellmVersion: String?
    @Published private(set) var litellmConfigWritten: Bool = false
    @Published private(set) var litellmConfigPortMismatch: Bool = false
    @Published private(set) var bridgeRunning: Bool = false
    @Published private(set) var portConflictMessage: String?
    @Published private(set) var mlxLMHealthy: Bool = true
    @Published private(set) var mlxOutOfMemory: Bool = false

    // MARK: - Update checking

    /// The GitHub release feed polled to detect newer versions. This is the
    /// project's own public repo; change it if the project ever relocates.
    private static let updateFeedURL = URL(string: "https://api.github.com/repos/spyroskotsakis/mac-mlx-agent/releases/latest")!

    /// True when the feed reports a release newer than this build.
    @Published private(set) var updateAvailable = false
    /// The latest release's semantic version (tag without the leading "v").
    @Published private(set) var latestVersion: String?
    /// The latest release's page, opened when the user taps the notification/banner.
    @Published private(set) var releaseURL: URL?
    /// True while a feed request is in flight (drives the Check spinner).
    @Published private(set) var isCheckingForUpdates = false

    private var updateCheckTimer: Timer?

    /// This build's marketing version (CFBundleShortVersionString), e.g. "1.6.0".
    static var currentAppVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    @Published var selectedModel: ModelOption {
        didSet {
            UserDefaults.standard.set(selectedModel.repoID, forKey: Keys.model)
            // Reflect this model's own thinking preference in the UI. A model
            // whose chat template has no `enable_thinking` is forced off, and the
            // user is alerted when a previous model had it on.
            let hadThinkingOn = enableThinking
            let supportsThinking = selectedModel.profile.thinkingSupported
            enableThinking = supportsThinking ? Self.loadThinking(for: selectedModel.repoID) : false
            // A large model must never stay in concurrent-requests mode.
            clampConcurrentRequestsForSelectedModel()
            if hadThinkingOn && !supportsThinking {
                notifyThinkingUnsupported()
            }
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
    /// Prompt-cache cap in GB, passed as `--prompt-cache-bytes`. See
    /// `ModelDefaults.promptCacheBytesGB` for the sizing rule.
    @Published var promptCacheBytesGB: Int {
        didSet { UserDefaults.standard.set(promptCacheBytesGB, forKey: Keys.promptCacheBytes) }
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
        static let promptCacheBytes = "mlxServerPromptCacheBytes"
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

        self.enableThinking = initialModel.profile.thinkingSupported
            ? Self.loadThinking(for: initialModel.repoID) : false
        self.temperature = UserDefaults.standard.object(forKey: Keys.temperature) as? Double ?? ModelDefaults.temperature
        self.topP = UserDefaults.standard.object(forKey: Keys.topP) as? Double ?? ModelDefaults.topP
        self.topK = UserDefaults.standard.object(forKey: Keys.topK) as? Int ?? ModelDefaults.topK
        self.maxTokens = UserDefaults.standard.object(forKey: Keys.maxTokens) as? Int ?? ModelDefaults.maxTokens
        self.promptCacheBytesGB = UserDefaults.standard.object(forKey: Keys.promptCacheBytes) as? Int ?? ModelDefaults.promptCacheBytesGB
        self.openCodePath = Self.resolveOpenCode()
        self.claudeCodePath = Self.resolveClaudeCode()
        self.claudeCodeVersion = self.claudeCodePath.flatMap { Self.claudeVersion(at: $0) }
        self.claudeCodeProfileWritten = FileManager.default.fileExists(atPath: Self.claudeCodeEnvFilePath())
        self.claudeCodeProfilePortMismatch = Self.configPortMismatch(atPath: Self.claudeCodeEnvFilePath(), port: self.bridgePort)
        self.litellmPath = Self.resolveLitellm()
        self.hfPath = Self.findHF()
        self.pythonPath = Self.findPython()
        self.litellmVersion = self.litellmPath.flatMap { Self.litellmVersion(at: $0) }
        self.litellmConfigWritten = FileManager.default.fileExists(atPath: Self.litellmConfigFilePath())
        self.litellmConfigPortMismatch = Self.configPortMismatch(atPath: Self.litellmConfigFilePath(), port: self.port)

        self.resolvedExecutable = Self.resolveExecutable(override: self.executablePath)

        // A persisted unsafe combination (large model + concurrent requests) must
        // not survive a relaunch: clamp it before the app can start the server.
        clampConcurrentRequestsForSelectedModel()
    }

    // MARK: - UI helpers

    var canSwitchModel: Bool {
        !state.isRunning && !state.isTransitioning
    }

    /// Installed RAM in GiB (Apple's advertised unified-memory tier, e.g. 36).
    /// Drives the memory-safety guard below.
    static var physicalRAMGB: Double {
        Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
    }

    /// Whether "Allow concurrent requests" is safe with the currently-selected
    /// model on this machine. Concurrent mode drops the 4-bit KV cache and the
    /// prompt-cache byte cap, so it needs roughly 4× the model's weight footprint
    /// free in unified memory; anything larger risks a whole-machine Metal OOM.
    var concurrentRequestsSafe: Bool {
        selectedModel.profile.weightGB <= Self.physicalRAMGB / 4
    }

    /// Human-readable reason the current configuration must not be started, or nil
    /// when it's safe. `start()` treats this as a hard block, not a warning: the
    /// unsafe combination can take the whole machine down, not just the server.
    private func memorySafetyBlock() -> String? {
        guard allowConcurrentRequests else { return nil }
        guard concurrentRequestsSafe else {
            return "Allow concurrent requests is unsafe with \(selectedModel.displayName) on \(Int(Self.physicalRAMGB)) GB of RAM. Turn it off, or switch to Qwen3-14B."
        }
        return nil
    }

    /// Forces concurrent requests off when the selected model is too large for it
    /// on this machine, so an unsafe combination never persists.
    private func clampConcurrentRequestsForSelectedModel() {
        if allowConcurrentRequests && !concurrentRequestsSafe {
            allowConcurrentRequests = false
        }
    }

    /// True when the selected model's weight footprint is a large share of this
    /// Mac's RAM — the same `weightGB > RAM/4` line the concurrent-requests guard
    /// uses. On such a machine, high output caps and thinking mode are what tip it
    /// into OOM, so the UI warns about both (RAM-dependent: a bigger Mac shows no
    /// warning for the same model).
    var selectedModelIsMemoryTight: Bool {
        selectedModel.profile.weightGB > Self.physicalRAMGB / 4
    }

    /// Warning for the Max tokens field when the cap is raised beyond the safe
    /// default on a memory-tight machine.
    var maxTokensWarning: String? {
        guard maxTokens > ModelDefaults.maxTokens, selectedModelIsMemoryTight else { return nil }
        return "Max tokens \(maxTokens) is above the safe \(ModelDefaults.maxTokens) for \(selectedModel.displayName) on this \(Int(Self.physicalRAMGB)) GB Mac — long replies fill the KV cache and can exhaust memory. Keep it at \(ModelDefaults.maxTokens), or free RAM / switch to a smaller model."
    }

    /// Warning for the thinking toggle. With mlx-lm ≥ 0.32 the reasoning arrives in
    /// a separate `reasoning` field, so agents still get a clean answer — but each
    /// turn is slower and, on a memory-tight machine, the extra tokens cost KV cache.
    var thinkingWarning: String? {
        // Models with no thinking chat template can't reason first, so the toggle
        // is disabled and forced off — tell the user why it won't switch on.
        if !selectedModel.profile.thinkingSupported {
            return "\(selectedModel.displayName) doesn't support thinking mode, so the toggle stays off for this model."
        }
        guard enableThinking else { return nil }
        var msg = "Thinking mode is ON — the model reasons in a separate step before answering. Claude Code and OpenCode still get a clean answer, but each turn is slower because it first emits those extra reasoning tokens."
        if selectedModelIsMemoryTight {
            msg += " On this \(Int(Self.physicalRAMGB)) GB Mac, \(selectedModel.displayName) is memory-tight, so those extra reasoning tokens can also exhaust memory."
        }
        return msg
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
        // Reclaim any stale server/bridge processes (from a previous crash or a
        // manual `start_server.sh`) so the app is the single owner of the model and
        // multiple instances never pile up competing for unified memory.
        killAllServers()
        checkMLXLM()
    }

    /// Kills every `mlx_lm.server` process and the app's own LiteLLM bridge,
    /// wherever they were started from — any port, any model — excluding the
    /// app's own tracked process/bridge. Matching is by command line (not port),
    /// so a stale instance left running on a *different* port is caught too.
    /// Synchronous: waits briefly for a clean SIGTERM exit, then SIGKILLs, so a
    /// Start right after this has the port free.
    func killAllServers() {
        let ownPIDs: Set<pid_t> = Set([process?.processIdentifier, bridgeProcess?.processIdentifier].compactMap { $0 })
        let targets = Array(Set(Self.pidsMatching("mlx_lm\\.server") + Self.pidsMatching("litellm-mlx\\.yaml")))
            .filter { $0 > 0 && !ownPIDs.contains($0) }
        guard !targets.isEmpty else { return }

        appendLog("[Stopping \(targets.count) stale server/bridge process(es)]\n")
        Self.signal(targets, SIGTERM)
        var remaining = targets
        for _ in 0..<10 {                       // up to ~1s of grace for uvicorn
            remaining = remaining.filter { kill($0, 0) == 0 }
            if remaining.isEmpty { break }
            usleep(100_000)
        }
        if !remaining.isEmpty {
            Self.signal(remaining, SIGKILL)
        }
    }

    // MARK: - Update checking

    /// Sets up update checking once per launch: registers the notification
    /// delegate, asks for notification permission, runs an immediate check, and
    /// schedules a periodic re-check. Called from the AppDelegate before any UI.
    func startUpdateChecking() {
        UNUserNotificationCenter.current().delegate = UpdateNotificationDelegate.shared
        UpdateNotificationDelegate.shared.requestPermissionIfNeeded()
        checkForUpdates()
        scheduleUpdateChecks()
    }

    /// Queries the GitHub release feed for the latest tag and, if it's newer than
    /// this build, flips `updateAvailable` and posts a system notification (once
    /// per version).
    func checkForUpdates() {
        guard !isCheckingForUpdates else { return }
        isCheckingForUpdates = true
        let url = Self.updateFeedURL
        URLSession.shared.dataTask(with: url) { [weak self] data, _, error in
            guard let self = self else { return }
            defer { DispatchQueue.main.async { self.isCheckingForUpdates = false } }
            guard error == nil,
                  let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String,
                  let htmlURL = json["html_url"] as? String,
                  let releaseURL = URL(string: htmlURL) else { return }
            let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            let isNew = Self.isNewer(version, than: Self.currentAppVersion)
            DispatchQueue.main.async {
                self.latestVersion = version
                self.releaseURL = releaseURL
                if isNew && !self.updateAvailable {
                    self.notifyUpdate(version: version, url: releaseURL)
                }
                self.updateAvailable = isNew
            }
        }.resume()
    }

    /// Re-checks for updates every few hours while the app stays running, so a
    /// menu-bar app left open all week still notices a release.
    private func scheduleUpdateChecks() {
        guard updateCheckTimer == nil else { return }
        let timer = Timer(timeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            self?.checkForUpdates()
        }
        RunLoop.main.add(timer, forMode: .common)
        updateCheckTimer = timer
    }

    /// Posts an "update available" system notification, at most once per version.
    private func notifyUpdate(version: String, url: URL) {
        let key = "lastNotifiedVersion"
        if UserDefaults.standard.string(forKey: key) == version { return }
        UserDefaults.standard.set(version, forKey: key)

        let content = UNMutableNotificationContent()
        content.title = "MLX Server update available"
        content.body = "Version \(version) is out — click to open the release."
        content.sound = .default
        content.userInfo = ["releaseURL": url.absoluteString]
        let request = UNNotificationRequest(
            identifier: "mlx-server-update-\(version)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    /// System alert when switching to a model that can't think while the previous
    /// model had thinking on: the toggle is forced off, so tell the user instead
    /// of silently changing their setting.
    private func notifyThinkingUnsupported() {
        let content = UNMutableNotificationContent()
        content.title = "Thinking mode turned off"
        content.body = "\(selectedModel.displayName) doesn't support thinking mode, so it was turned off for this model."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "mlx-server-thinking-unsupported",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    // MARK: - Start / stop

    func start() {
        killAllServers()
        checkPortConflicts()
        if let conflict = portConflictMessage {
            state = .failed(conflict)
            return
        }
        // Hard block: the unsafe combination (concurrent requests on a large
        // model) can exhaust unified memory and take the whole machine down.
        if let block = memorySafetyBlock() {
            state = .failed(block)
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
        mlxOutOfMemory = false
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

    /// PIDs whose full command line matches `pattern` (via `pgrep -f`). Empty on
    /// failure or no match.
    private static func pidsMatching(_ pattern: String) -> [pid_t] {
        let output = runTool("/usr/bin/pgrep", ["-f", pattern])
        return output.split(separator: "\n").compactMap { Int32($0) }
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
        // A partial download leaves blobs but no complete snapshot — flag it so
        // the UI can offer "Retry download" (hf resumes) instead of a fresh start.
        modelPartialDownload = (modelCached == false) && Self.modelIsPartiallyDownloaded(repoID: selectedModel.repoID)
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
    /// shipped with), including the concurrent-requests memory-safety toggle.
    /// Takes effect on the next Start.
    func resetModelSettings() {
        enableThinking = ModelDefaults.enableThinking
        temperature = ModelDefaults.temperature
        topP = ModelDefaults.topP
        topK = ModelDefaults.topK
        maxTokens = ModelDefaults.maxTokens
        promptCacheBytesGB = ModelDefaults.promptCacheBytesGB
        allowConcurrentRequests = false
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

    /// Re-resolves the HuggingFace `hf` CLI (nil if not installed).
    func checkHF() {
        hfPath = Self.findHF()
    }

    /// Re-resolves the Python interpreter (nil if none found). Everything here —
    /// mlx-lm, the `hf` CLI, and the server itself — runs on Python, so this is
    /// the base prerequisite the install buttons depend on.
    func checkPython() {
        pythonPath = Self.findPython()
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
        checkHF()
        checkPython()
        checkPortConflicts()
        checkMLXLM()
    }

    /// Whether every prerequisite is met: mlx-lm installed, the selected model
    /// downloaded, OpenCode installed + configured, and Claude Code installed +
    /// runnable with its bridge profile and the LiteLLM bridge config written.
    var isReady: Bool {
        resolvedExecutable != nil &&
        mlxLMHealthy == true &&
        pythonPath != nil &&
        hfPath != nil &&
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
        if pythonPath == nil { missing.append("Python 3") }
        if resolvedExecutable == nil {
            missing.append("mlx-lm")
        } else if !mlxLMHealthy {
            missing.append("mlx-lm (broken)")
        }
        if hfPath == nil { missing.append("Hugging Face CLI (hf)") }
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

    /// Ordered, guided view of every prerequisite still missing, each with a
    /// one-line "what to do" hint. Drives the startup banner so a fresh machine
    /// sees a path to a working setup, not just a bare list of names.
    var setupGuide: [SetupStep] {
        var steps: [SetupStep] = []
        if pythonPath == nil {
            steps.append(.init(title: "Python 3",
                               hint: "Install it — xcode-select --install, or brew install python@3.12 (see “How to install Python”).",
                               optional: false))
        }
        if resolvedExecutable == nil {
            steps.append(.init(title: "mlx-lm (mlx_lm.server)",
                               hint: "Click Install in Requirements — runs pip install mlx-lm.",
                               optional: false))
        } else if !mlxLMHealthy {
            steps.append(.init(title: "mlx-lm (broken)",
                               hint: "Click Repair in Requirements to reinstall and clear the dependency conflict.",
                               optional: false))
        }
        if hfPath == nil {
            steps.append(.init(title: "Hugging Face CLI (hf)",
                               hint: "Click Install in Requirements. No Hugging Face account is needed.",
                               optional: false))
        }
        if modelCached != true {
            steps.append(.init(title: "Model files",
                               hint: "Click Download in Requirements to fetch the selected model.",
                               optional: false))
        }
        if openCodePath == nil {
            steps.append(.init(title: "OpenCode",
                               hint: "Install it — curl -fsSL https://opencode.ai/install | bash (see “How to install OpenCode”).",
                               optional: false))
        }
        if openCodeConfigStatus != .configured {
            steps.append(.init(title: "OpenCode config",
                               hint: "Click Set up in Integrations to point OpenCode at the server.",
                               optional: false))
        }
        if claudeCodePath == nil {
            steps.append(.init(title: "Claude Code",
                               hint: "Install it — npm install -g @anthropic-ai/claude-code (see “How to install Claude Code”).",
                               optional: true))
        } else if claudeCodeVersion == nil {
            steps.append(.init(title: "Claude Code (broken)",
                               hint: "Reinstall — npm install -g @anthropic-ai/claude-code.",
                               optional: true))
        }
        if !claudeCodeProfileWritten {
            steps.append(.init(title: "Claude Code profile",
                               hint: "Click Set up in Integrations to write the bridge profile.",
                               optional: true))
        }
        if litellmPath == nil {
            steps.append(.init(title: "LiteLLM",
                               hint: "Click Install in Integrations — installs into its own venv.",
                               optional: true))
        } else if litellmVersion == nil {
            steps.append(.init(title: "LiteLLM (broken)",
                               hint: "Click Repair in Integrations.",
                               optional: true))
        }
        if !litellmConfigWritten {
            steps.append(.init(title: "LiteLLM config",
                               hint: "Click Set up in Integrations to write the bridge config.",
                               optional: true))
        }
        return steps
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
        appendInstallOutput("$ \(python) -m pip install --upgrade mlx-lm uvicorn fastapi huggingface_hub\n\n")
        runStreaming(executable: python,
                     arguments: ["-m", "pip", "install", "--upgrade", "mlx-lm", "uvicorn", "fastapi", "huggingface_hub"],
                     sink: { [weak self] in self?.appendInstallOutput($0) },
                     completion: { [weak self] status in
            guard let self else { return }
            self.isInstalling = false
            self.appendInstallOutput(status == 0 ? "\n[mlx-lm installed]\n" : "\n[install failed (status \(status))]\n")
            self.refreshExecutableResolution()
            self.checkMLXLM()
        })
    }

    /// Installs `huggingface_hub` (which provides the `hf` download CLI) into the
    /// discovered Python environment, streaming output to `installOutput`.
    func installHF() {
        guard !isInstalling else { return }
        guard let python = Self.findPython() else {
            installOutput = "Could not find a Python interpreter to install into.\n"
            return
        }
        isInstalling = true
        installOutput = ""
        appendInstallOutput("$ \(python) -m pip install --upgrade huggingface_hub\n\n")
        runStreaming(executable: python,
                     arguments: ["-m", "pip", "install", "--upgrade", "huggingface_hub"],
                     sink: { [weak self] in self?.appendInstallOutput($0) },
                     completion: { [weak self] status in
            guard let self else { return }
            self.isInstalling = false
            self.appendInstallOutput(status == 0 ? "\n[huggingface_hub (hf) installed]\n" : "\n[install failed (status \(status))]\n")
            self.checkHF()
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

    /// Extracts the first `127.0.0.1:<port>` / `localhost:<port>` from `text`,
    /// with or without a trailing `/v1`. Used for config files that embed the
    /// port in an `api_base` or `ANTHROPIC_BASE_URL` line.
    private static func firstHostPort(in text: String) -> Int? {
        let pattern = #"(?:127\.0\.0\.1|localhost):(\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let portRange = Range(match.range(at: 1), in: text),
              let found = Int(text[portRange]) else {
            return nil
        }
        return found
    }

    /// True when the config/profile at `path` exists but points at a different
    /// `host:port` than `port` (stale after a port change). False when missing,
    /// matching, or unparseable.
    private static func configPortMismatch(atPath path: String, port: Int) -> Bool {
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8),
              let found = firstHostPort(in: contents) else {
            return false
        }
        return found != port
    }

    /// Re-resolves the OpenCode CLI (nil if not installed). The probe runs off
    /// the main thread — resolving can shell out to a login shell — so opening
    /// the panel never stalls; the path fills in a moment later.
    func checkOpenCode() {
        guard !Self.openCodeProbeInFlight else { return }
        Self.openCodeProbeInFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let path = Self.resolveOpenCode()
            DispatchQueue.main.async {
                Self.openCodeProbeInFlight = false
                guard let self else { return }
                self.openCodePath = path
            }
        }
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
    /// re-checks whether its env profile exists. The profile/exists checks are
    /// cheap file reads and stay synchronous; the path resolution + `--version`
    /// subprocess (a cold Node start) runs off the main thread so the panel
    /// doesn't stall on open.
    func checkClaudeCode() {
        claudeCodeProfileWritten = FileManager.default.fileExists(atPath: Self.claudeCodeEnvFilePath())
        claudeCodeProfilePortMismatch = Self.configPortMismatch(atPath: Self.claudeCodeEnvFilePath(), port: bridgePort)
        guard !Self.claudeCodeProbeInFlight else { return }
        Self.claudeCodeProbeInFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let path = Self.resolveClaudeCode()
            let version = path.flatMap { Self.claudeVersion(at: $0) }
            DispatchQueue.main.async {
                Self.claudeCodeProbeInFlight = false
                guard let self else { return }
                self.claudeCodePath = path
                self.claudeCodeVersion = version
            }
        }
    }

    /// Lightweight re-check of just the profile's bridge port (no subprocess) —
    /// used when the bridge port changes so the UI flags a stale profile fast.
    func checkClaudeCodeProfilePort() {
        claudeCodeProfilePortMismatch = Self.configPortMismatch(atPath: Self.claudeCodeEnvFilePath(), port: bridgePort)
    }

    /// The Claude Code env profile. Points `claude` at the LiteLLM bridge, which
    /// translates Anthropic → OpenAI to reach the MLX server on its configured port.
    var claudeCodeConfigText: String {
        """
        # Claude Code → local MLX model via the LiteLLM bridge.
        # Sourced by the `claude-local` / `claude-mlx` shell alias (see ~/.bashrc),
        # or by `source`-ing this file before running `claude`.
        # Prerequisites: the MLX server (\(port)) AND the LiteLLM bridge (\(bridgePort))
        # running — the app starts the bridge automatically with the server.
        export ANTHROPIC_BASE_URL="http://127.0.0.1:\(bridgePort)"
        export ANTHROPIC_AUTH_TOKEN="sk-local-claude"
        export ANTHROPIC_MODEL="default_model"
        export ANTHROPIC_DEFAULT_OPUS_MODEL="default_model"
        export ANTHROPIC_DEFAULT_SONNET_MODEL="default_model"
        export ANTHROPIC_DEFAULT_HAIKU_MODEL="default_model"
        export CLAUDE_CODE_SUBAGENT_MODEL="default_model"
        export CLAUDE_CODE_DISABLE_EXPERIMENTAL_BETAS=1
        # "default_model" isn't a Claude model ID, so Claude Code can't resolve its
        # context window: it warns and assumes 200k. Tell it the selected model's real
        # window so auto-compact fires at the right size and the warning goes away.
        export CLAUDE_CODE_MAX_CONTEXT_TOKENS=\(selectedModel.profile.maxContext)
        # Claude Code sends max_tokens: 32000 on every request, overriding the
        # server's --max-tokens default. Cap it here (client-side) to the app's
        # Max tokens so a long reply can't balloon the history and OOM Metal.
        export CLAUDE_CODE_MAX_OUTPUT_TOKENS=\(maxTokens)
        export MAX_THINKING_TOKENS=0
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

    /// Re-writes the Claude Code env profile in place when it already exists, so a
    /// model change keeps `CLAUDE_CODE_MAX_CONTEXT_TOKENS` in sync with the selected
    /// model. Does nothing if the profile hasn't been set up yet.
    func autoSyncClaudeCodeConfig() {
        guard claudeCodeProfileWritten else { return }
        let path = claudeCodeEnvPath()
        do {
            try claudeCodeConfigText.write(toFile: path, atomically: true, encoding: .utf8)
            checkClaudeCode()
        } catch {
            // Non-fatal: a stale value persists until the next "Set up".
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

    /// Re-resolves the `litellm` CLI and re-checks whether the bridge config
    /// exists. The config-file checks are cheap and stay synchronous; the path
    /// resolution + `litellm --version` (a cold Python import) run off the main
    /// thread so opening the panel doesn't stall.
    func checkLitellm() {
        litellmConfigWritten = FileManager.default.fileExists(atPath: Self.litellmConfigFilePath())
        litellmConfigPortMismatch = Self.configPortMismatch(atPath: Self.litellmConfigFilePath(), port: port)
        guard !Self.litellmProbeInFlight else { return }
        Self.litellmProbeInFlight = true
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let path = Self.resolveLitellm()
            let version = path.flatMap { Self.litellmVersion(at: $0) }
            DispatchQueue.main.async {
                Self.litellmProbeInFlight = false
                guard let self else { return }
                self.litellmPath = path
                self.litellmVersion = version
            }
        }
    }

    /// Lightweight re-check of just the bridge config's MLX port (no subprocess)
    /// — used when the MLX port changes so the UI flags a stale config fast.
    func checkLitellmConfigPort() {
        litellmConfigPortMismatch = Self.configPortMismatch(atPath: Self.litellmConfigFilePath(), port: port)
    }

    /// The LiteLLM bridge config. Maps `default_model` to the MLX server's OpenAI
    /// endpoint so Claude Code (Anthropic API) can reach the local model.
    var litellmConfigText: String {
        """
        # LiteLLM bridge: Anthropic Messages API (/v1/messages) -> MLX-LM OpenAI API.
        # Written and auto-started by MLX Server when you click "Start Server" —
        # you don't need to launch this proxy yourself.

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
        litellmConfigPortMismatch = false

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
    /// selected model), backing up any existing file first. The app's `mlx`
    /// provider is merged into whatever is already there, so other providers,
    /// MCP servers and agent settings the user added are left untouched.
    func writeOpenCodeConfig() {
        let path = openCodeConfigPath()
        let dir = (path as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

            // Read the current config before backing it up so the merge below
            // preserves the user's non-mlx entries.
            let existing = Self.existingOpenCodeConfig(at: path)

            if FileManager.default.fileExists(atPath: path) {
                let df = DateFormatter()
                df.dateFormat = "yyyyMMdd-HHmmss"
                let backup = path + ".bak-" + df.string(from: Date())
                try FileManager.default.moveItem(atPath: path, toPath: backup)
                setupMessage = "Backed up existing config to \(backup)\n"
            } else {
                setupMessage = ""
            }

            try Self.openCodeConfigJSON(mergedOpenCodeConfig(existing: existing))
                .write(toFile: path, atomically: true, encoding: .utf8)
            setupMessage += "Wrote \(path)\n"
            checkOpenCodeConfig()
        } catch {
            setupMessage = "Failed to write OpenCode config: \(error.localizedDescription)\n"
        }
    }

    /// Re-writes the OpenCode config in place (no backup) to reflect the current
    /// model name and limits. Only does anything when OpenCode is already
    /// configured for this server, so switching models never creates a config the
    /// user didn't ask for. Called when the selected model or Max tokens changes.
    func autoSyncOpenCodeConfig() {
        checkOpenCodeConfig()
        guard openCodeConfigStatus == .configured else { return }
        let path = openCodeConfigPath()
        do {
            let existing = Self.existingOpenCodeConfig(at: path)
            try Self.openCodeConfigJSON(mergedOpenCodeConfig(existing: existing))
                .write(toFile: path, atomically: true, encoding: .utf8)
            checkOpenCodeConfig()
        } catch {
            // Non-fatal: the stale name/limits remain until the next "Update".
        }
    }

    /// The `mlx` provider entry written into the OpenCode config. Kept as a dict
    /// so `mergedOpenCodeConfig` can drop it into an existing config without
    /// clobbering the rest of the file.
    private var mlxProviderConfig: [String: Any] {
        [
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
    }

    /// Merges the app's `mlx` provider into `existing`, keeping every other key
    /// (other providers, MCP servers, agent settings) intact.
    private func mergedOpenCodeConfig(existing: [String: Any]) -> [String: Any] {
        var config = existing
        config["$schema"] = "https://opencode.ai/config.json"
        config["model"] = "mlx/default_model"
        var provider = config["provider"] as? [String: Any] ?? [:]
        provider["mlx"] = mlxProviderConfig
        config["provider"] = provider
        return config
    }

    /// Reads an existing OpenCode config as a dictionary (`[:]` when missing or
    /// not parseable, e.g. a `.jsonc` with comments).
    private static func existingOpenCodeConfig(at path: String) -> [String: Any] {
        guard let data = FileManager.default.contents(atPath: path),
              let json = try? JSONSerialization.jsonObject(with: data),
              let dict = json as? [String: Any] else {
            return [:]
        }
        return dict
    }

    /// Serializes an OpenCode config dict to pretty-printed JSON. JSONSerialization
    /// escapes "/" as "\/"; unescape for a readable file and so the "already
    /// configured" substring check matches.
    private static func openCodeConfigJSON(_ config: [String: Any]) -> String {
        if let data = try? JSONSerialization.data(withJSONObject: config,
                                                  options: [.prettyPrinted, .sortedKeys]),
           let text = String(data: data, encoding: .utf8) {
            return text.replacingOccurrences(of: "\\/", with: "/")
        }
        return "{}\n"
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
            "provider": ["mlx": mlxProviderConfig]
        ]
        return Self.openCodeConfigJSON(config)
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
        // The MLX server's generation thread dies unrecoverably when Metal runs
        // out of memory (e.g. two large-context requests at once on a small-RAM
        // machine). Surface that so the user knows to restart instead of staring
        // at a silent "Generating…".
        if !mlxOutOfMemory,
           text.contains("Insufficient Memory") || text.contains("generation thread died") {
            mlxOutOfMemory = true
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
        // Quantized KV cache (--kv-bits 4) keeps large models inside Metal
        // memory. Combined with prompt/decode concurrency of 1, requests are
        // served one at a time so two agents (e.g. Claude Code + OpenCode)
        // can't be prefilled together and exhaust Metal RAM — the trigger for
        // the "generation thread died" out-of-memory crash. A byte cap on the
        // prompt cache keeps a long session from accumulating 10 full KV caches
        // and OOMing too. When the user opts into concurrent requests we drop
        // the caps, at their own risk.
        if !allowConcurrentRequests {
            args += [
                "--kv-bits", "4",
                "--prompt-concurrency", "1",
                "--decode-concurrency", "1",
                "--prompt-cache-bytes", "\(promptCacheBytesGB)GB"
            ]
        }
        args += [
            "--max-tokens", "\(maxTokens)",
            "--temp", Self.samplingText(temperature),
            "--top-p", Self.samplingText(topP),
            "--top-k", "\(topK)"
        ]
        // Only models whose chat template accepts `enable_thinking` (Qwen3-family)
        // get the flag. Non-thinking models (Coder, Ministral, Gemma, Llama,
        // Devstral) don't — passing it there is meaningless noise.
        if selectedModel.profile.thinkingSupported {
            args += ["--chat-template-args", "{\"enable_thinking\":\(enableThinking ? "true" : "false")}"]
        }
        return args
    }

    /// Formats a sampling Double for the command line without trailing noise
    /// (0.8, not 0.80).
    private static func samplingText(_ value: Double) -> String {
        String(format: "%.4g", value)
    }

    /// Splits "1.6.0" / "v1.6.0" into (major, minor, patch), tolerating missing
    /// or non-numeric components.
    private static func parseVersion(_ raw: String) -> (Int, Int, Int) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let noV = trimmed.hasPrefix("v") ? String(trimmed.dropFirst()) : trimmed
        let parts = noV.split(separator: ".", omittingEmptySubsequences: false)
        func component(_ i: Int) -> Int { i < parts.count ? (Int(parts[i]) ?? 0) : 0 }
        return (component(0), component(1), component(2))
    }

    /// True when `lhs` is a strictly newer semantic version than `rhs`.
    static func isNewer(_ lhs: String, than rhs: String) -> Bool {
        let a = parseVersion(lhs), b = parseVersion(rhs)
        if a.0 != b.0 { return a.0 > b.0 }
        if a.1 != b.1 { return a.1 > b.1 }
        return a.2 > b.2
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
        return resolveViaLoginShell(command: "hf")
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

    /// True when the repo's `blobs/` folder already has bytes on disk — evidence
    /// of a started (possibly interrupted) download — even though no complete
    /// snapshot exists yet. Lets the UI offer "Retry download" (hf resumes).
    private static func modelIsPartiallyDownloaded(repoID: String) -> Bool {
        let repoName = "models--" + repoID.replacingOccurrences(of: "/", with: "--")
        let blobsDir = hfHubDir() + "/" + repoName + "/blobs"
        return directorySize(atPath: blobsDir) > 0
    }

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

/// Handles a tap on the "update available" notification by opening the release
/// page, and asks for alert/sound permission once at launch.
final class UpdateNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = UpdateNotificationDelegate()

    func requestPermissionIfNeeded() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let urlString = response.notification.request.content.userInfo["releaseURL"] as? String,
           let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
        completionHandler()
    }
}
