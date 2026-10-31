import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var server: ServerController
    @State private var showManualConfig = false
    @State private var showManualClaudeCode = false
    @State private var showManualLitellm = false
    @State private var samplingInfo: SamplingInfo?
    @State private var maxTokensText = ""
    @FocusState private var maxTokensFocused: Bool

    /// A one-click install/config action awaiting confirmation. Auto-install and
    /// auto-config buttons modify the Python environment or overwrite a config
    /// file, so the user confirms each one before it runs.
    private enum PendingConfirm: String, Identifiable {
        case installMLX, installHF, installLitellm
        case writeOpenCode, writeClaudeCode, writeLitellm
        case deleteModel, deleteAllModels

        var id: String { rawValue }

        var title: String {
            switch self {
            case .installMLX: return "Install mlx-lm?"
            case .installHF: return "Install the Hugging Face CLI?"
            case .installLitellm: return "Install LiteLLM?"
            case .writeOpenCode: return "Write the OpenCode config?"
            case .writeClaudeCode: return "Write the Claude Code profile?"
            case .writeLitellm: return "Write the LiteLLM config?"
            case .deleteModel: return "Delete model?"
            case .deleteAllModels: return "Delete all models?"
            }
        }

        var message: String {
            switch self {
            case .installMLX:
                return "This runs pip install into your Python environment (mlx-lm, uvicorn, fastapi, huggingface_hub, brotli>=1.2.0) and may upgrade existing packages. You can run the same command yourself from “How to install mlx-lm manually”."
            case .installHF:
                return "This runs pip install huggingface_hub (and pins brotli>=1.2.0, which model downloads need) into your Python environment. No Hugging Face account or token is needed."
            case .installLitellm:
                return "This creates an isolated .venv-litellm and installs litellm[proxy] there — it does not touch your mlx-lm environment."
            case .writeOpenCode:
                return "This overwrites ~/.config/opencode/opencode.jsonc (your existing file is backed up first). You can instead copy it by hand from “Manual”."
            case .writeClaudeCode:
                return "This overwrites ~/.config/mlx-local/claude-code.env (your existing file is backed up first). You can instead copy it by hand from “Manual”."
            case .writeLitellm:
                return "This overwrites ~/.config/mlx-local/litellm-mlx.yaml (your existing file is backed up first)."
            case .deleteModel:
                return ""
            case .deleteAllModels:
                return ""
            }
        }

        var actionLabel: String {
            switch self {
            case .installMLX: return "Install mlx-lm"
            case .installHF: return "Install hf"
            case .installLitellm: return "Install LiteLLM"
            case .writeOpenCode: return "Write config"
            case .writeClaudeCode: return "Write profile"
            case .writeLitellm: return "Write config"
            case .deleteModel: return "Delete"
            case .deleteAllModels: return "Delete all"
            }
        }

        /// Overwriting a user's existing config is treated as destructive; a pip
        /// install into a Python env is a normal (but still confirmed) action.
        var destructive: Bool {
            switch self {
            case .installMLX, .installHF, .installLitellm: return false
            case .writeOpenCode, .writeClaudeCode, .writeLitellm: return true
            case .deleteModel, .deleteAllModels: return true
            }
        }
    }

    var body: some View {
        TabView {
            ScrollView {
                serverTab
            }
            .tabItem { Label("Server", systemImage: "cpu") }

            ScrollView {
                connectTab
            }
            .tabItem { Label("Connect", systemImage: "link") }
        }
        .frame(minWidth: 880, minHeight: 600)
        .onAppear {
            server.onAppear()
            server.checkModelCached()
            server.checkOpenCodeConfig()
            server.checkOpenCode()
            // The installer fold-outs tell users to reopen the panel to re-detect
            // Claude Code / LiteLLM after installing them, so re-run those checks
            // here alongside the OpenCode ones.
            server.checkClaudeCode()
            server.checkLitellm()
            maxTokensText = String(server.maxTokens)
        }
        .onChange(of: server.selectedModel) { _, _ in
            server.checkModelCached()
            server.autoSyncOpenCodeConfig()
            server.autoSyncClaudeCodeConfig()
        }
        .onChange(of: server.port) { _, _ in
            server.checkOpenCodeConfig()
            server.checkLitellmConfigPort()
            server.checkPortConflicts()
        }
        .onChange(of: server.bridgePort) { _, _ in
            server.checkClaudeCodeProfilePort()
            server.checkPortConflicts()
        }
        .onChange(of: server.maxTokens) { _, newValue in
            maxTokensText = String(newValue)
            server.autoSyncOpenCodeConfig()
            server.autoSyncClaudeCodeConfig()
        }
    }

    /// Dispatches a confirmed action. Every entry point here is also available
    /// as a manual terminal command or a "Manual" view, so a cautious user can
    /// do the same thing by hand instead of one-click.
    private func run(_ confirm: PendingConfirm) {
        switch confirm {
        case .installMLX: server.installMLX()
        case .installHF: server.installHF()
        case .installLitellm: server.installLitellm()
        case .writeOpenCode: server.writeOpenCodeConfig()
        case .writeClaudeCode: server.writeClaudeCodeConfig()
        case .writeLitellm: server.writeLitellmConfig()
        case .deleteModel: server.deleteModel()
        case .deleteAllModels: server.deleteAllModels()
        }
    }

    private func confirmTitle(_ confirm: PendingConfirm) -> String {
        confirm == .deleteModel ? "Delete \(server.selectedModel.displayName)?" : confirm.title
    }

    private func confirmMessage(_ confirm: PendingConfirm) -> String {
        switch confirm {
        case .deleteModel:
            return "This removes the model from the local HuggingFace cache and frees \(selectedModelSizeText) of disk space. You can download it again later."
        case .deleteAllModels:
            return "This removes every cached model from the local HuggingFace cache and frees \(allModelsSizeText) of disk space. You can download them again later."
        default:
            return confirm.message
        }
    }

    /// SwiftUI's `.alert` is unreliable inside a `MenuBarExtra(.window)` — the
    /// alert is a separate window, so clicking it steals focus, the menu-bar
    /// popover closes, and the alert (and often its action) is torn down with it.
    /// We present the confirmation as an `NSAlert` instead, which stays on screen
    /// independently of the popover and keeps the action running.
    private func confirm(_ action: PendingConfirm) {
        let alert = NSAlert()
        alert.messageText = confirmTitle(action)
        alert.informativeText = confirmMessage(action)
        if action == .deleteModel || action == .deleteAllModels {
            alert.alertStyle = .critical
        } else if action.destructive {
            alert.alertStyle = .warning
        }
        alert.addButton(withTitle: action.actionLabel)
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            run(action)
        }
    }

    private var serverTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            statusCard
            if !server.isReady {
                missingPrerequisitesBanner
            }
            if server.updateAvailable {
                updateBanner
            }
            if server.mlxOutOfMemory {
                outOfMemoryWarning
            }
            controls
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 14) {
                    requirementsSection
                    integrationsSection
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                VStack(alignment: .leading, spacing: 14) {
                    modelSection
                    modelSettingsSection
                    advancedSection
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            logSection
            footer
        }
        .padding(16)
    }

    private var connectTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Connect to the local model")
                .font(.title3.bold())
            Text("The server speaks the OpenAI chat-completions API. Point any OpenAI-compatible client at the base URL below.")
                .font(.caption)
                .foregroundStyle(.secondary)

            copyRow(title: "Base URL", value: server.baseURL)
            copyRow(title: "Model", value: server.modelAlias)
            copyRow(title: "Loaded model (HF id)", value: server.selectedModel.repoID)

            VStack(alignment: .leading, spacing: 4) {
                Text("Endpoints").font(.subheadline).foregroundStyle(.secondary)
                endpointRow(method: "POST", path: "/v1/chat/completions", note: "chat + tool calling")
                endpointRow(method: "GET", path: "/v1/models", note: "list cached models")
            }

            codeBlock(title: "curl", code: server.curlExample)
            codeBlock(title: "Python — OpenAI SDK", code: server.pythonExample)

            Text("api_key is not checked — pass any non-empty value (e.g. \"not-needed\").")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func copyRow(title: String, value: String) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption2).foregroundStyle(.secondary)
                Text(value)
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Button {
                copy(value)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy")
        }
    }

    private func endpointRow(method: String, path: String, note: String) -> some View {
        HStack(spacing: 8) {
            Text(method)
                .font(.caption2.monospaced().bold())
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(Color.accentColor.opacity(0.15)))
                .foregroundStyle(Color.accentColor)
            Text(path)
                .font(.callout.monospaced())
                .textSelection(.enabled)
            Text(note)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private func codeBlock(title: String, code: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button("Copy") { copy(code) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
            Text(code)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .windowBackgroundColor)))
        }
    }

    private func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Parses the Max tokens text field and clamps it to the valid range.
    private func commitMaxTokens() {
        let parsed = Int(maxTokensText.trimmingCharacters(in: .whitespacesAndNewlines))
        let value = min(max(256, parsed ?? server.maxTokens), ModelDefaults.maxOutputTokens)
        server.maxTokens = value
        maxTokensText = String(value)
    }

    /// Which sampling setting the user tapped "(i)" on — drives the popover.
    private enum SamplingInfo: String, Identifiable {
        case temperature, topP, topK
        var id: String { rawValue }

        var title: String {
            switch self {
            case .temperature: return "Temperature"
            case .topP: return "Top-p"
            case .topK: return "Top-k"
            }
        }

        var detail: String {
            switch self {
            case .temperature:
                return "Controls how random the output is. Lower (near 0) = focused and deterministic; higher (near 2) = creative and varied. Too high makes the model ramble or wander off-topic."
            case .topP:
                return "Nucleus sampling: at each step the model only picks from the smallest set of most-likely tokens whose combined probability reaches p. Lower = safer and more predictable; higher = more diverse. Works together with Top-k."
            case .topK:
                return "Caps each step to the K most-likely next tokens. Lower = more conservative and coherent; higher = more variety but riskier. 0 disables the filter."
            }
        }
    }

    /// A small blue "i" badge that toggles an inline explanation below the control.
    /// Built from text (not an SF Symbol) so it always renders, including in the
    /// menu-bar popover.
    private func infoIcon(for field: SamplingInfo) -> some View {
        Button {
            samplingInfo = (samplingInfo == field) ? nil : field
        } label: {
            Text("i")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 16, height: 16)
                .background(Circle().fill(samplingInfo == field ? Color.accentColor.opacity(0.5) : Color.accentColor))
        }
        .buttonStyle(.plain)
    }

    /// Inline explanation shown under a sampling control when its "(i)" is open.
    private func infoDetail(_ field: SamplingInfo) -> some View {
        Text(field.detail)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .windowBackgroundColor)))
    }

    /// Opens `path` in Finder, falling back to the nearest existing ancestor so
    /// the click always lands somewhere sensible (a not-yet-created folder opens
    /// its parent instead).
    private func openInFinder(_ path: String) {
        var p = path
        while !FileManager.default.fileExists(atPath: p) {
            let parent = (p as NSString).deletingLastPathComponent
            if parent == p { break }
            p = parent
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: p))
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "cpu")
                .font(.title2)
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("MLX Server").font(.title3.bold())
                Text("Local model server for Xcode & coding agents")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text("v\(appVersion)")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(Capsule().stroke(.quaternary))
        }
    }

    private var statusCard: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(server.state.color)
                .frame(width: 12, height: 12)
            Text(server.state.title)
                .font(.headline)
                .lineLimit(1)
            if server.state.isTransitioning {
                ProgressView().controlSize(.small)
            }
            Spacer()
            Text(verbatim: "port \(server.port)")
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
    }

    private var outOfMemoryWarning: some View {
        Label("The model ran out of memory (Metal OOM) — the server is no longer answering. Stop and restart, then avoid running two agents at once (a 35B model can't fit two large contexts on this much RAM). For concurrent agents, switch to Qwen3-14B.", systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(.orange)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.12)))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(.orange.opacity(0.4)))
    }

    /// Prominent, guided setup checklist shown at the top of the panel while
    /// anything needed to start is missing. Each item carries a one-line fix and
    /// points at the one-click buttons / install instructions in the sections below.
    private var missingPrerequisitesBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label("Missing prerequisites — \(server.setupGuide.count) left",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.orange)
                Spacer()
                Button("Check status") { server.checkAllPrerequisites() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(server.setupGuide) { step in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: step.optional ? "circle" : "exclamationmark.circle.fill")
                                .foregroundStyle(step.optional ? Color.secondary : Color.orange)
                                .font(.caption)
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 4) {
                                    Text(step.title).font(.callout.weight(.medium))
                                    if step.optional {
                                        Text("optional")
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 1)
                                            .background(Capsule().fill(Color(nsColor: .controlBackgroundColor)))
                                    }
                                }
                                Text(step.hint)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 190)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.orange.opacity(0.4)))
    }

    private var updateBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(.green)
            Text("Update available — v\(server.latestVersion ?? "newer")")
                .font(.callout.weight(.medium))
            Spacer()
            Button("View release") {
                if let url = server.releaseURL { NSWorkspace.shared.open(url) }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.green.opacity(0.12)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.green.opacity(0.4)))
    }

    private var requirementsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Requirements").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Button("Check status") { server.checkAllPrerequisites() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

            readinessLine

            requirementRow(
                ok: server.pythonPath != nil,
                showAction: false,
                title: "Python 3",
                detail: pythonDetail,
                buttonTitle: "",
                action: {}
            )

            if server.pythonPath == nil {
                DisclosureGroup("How to install Python") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Everything here runs on Python — mlx-lm, the `hf` download tool, and the server itself. Install it with one of:")
                            .font(.caption)
                        codeBlock(title: "bash", code: "xcode-select --install  # provides /usr/bin/python3 (or install the Command Line Tools)")
                        Text("Homebrew (recommended):")
                            .font(.caption)
                        codeBlock(title: "bash", code: "brew install python@3.12")
                        Text("Or download from https://www.python.org/downloads/.")
                            .font(.caption)
                        Text("Then click \"Check status\" (or reopen the panel) so it re-detects Python.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                }
            }

            requirementRow(
                ok: server.resolvedExecutable != nil && server.mlxLMHealthy,
                showAction: server.resolvedExecutable == nil || !server.mlxLMHealthy,
                title: "mlx-lm (mlx_lm.server)",
                detail: mlxLMDetail,
                buttonTitle: server.resolvedExecutable == nil ? "Install" : "Repair",
                action: { confirm(.installMLX) }
            )

            if server.resolvedExecutable != nil && !server.mlxLMHealthy {
                Text("mlx_lm.server won't import — usually a conflicting transformers / huggingface_hub. Click Repair, and make sure LiteLLM uses its own venv (see Integrations).")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            if server.resolvedExecutable == nil {
                DisclosureGroup("How to install mlx-lm manually") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Run this in the terminal (the same Python the rest uses):")
                            .font(.caption)
                        codeBlock(title: "bash", code: "python3 -m pip install --upgrade mlx-lm uvicorn fastapi huggingface_hub 'brotli>=1.2.0'")
                        Text("Then click \"Check status\" (or reopen the panel) so it re-detects mlx-lm.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                }
            }

            requirementRow(
                ok: server.hfPath != nil,
                showAction: server.hfPath == nil,
                title: "Hugging Face CLI (hf)",
                detail: hfDetail,
                buttonTitle: "Install",
                action: { confirm(.installHF) }
            )

            if server.hfPath == nil {
                DisclosureGroup("How to install the Hugging Face CLI") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("The `hf` tool ships with `huggingface_hub`. Install it into the same Python environment as mlx-lm:")
                            .font(.caption)
                        codeBlock(title: "bash", code: "python3 -m pip install --upgrade huggingface_hub 'brotli>=1.2.0'")
                        Text("Then click \"Check status\" (or reopen the panel) so it re-detects `hf`.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                }
            }

            requirementRow(
                ok: server.modelCached == true,
                showAction: server.modelCached == false,
                title: "Model files",
                detail: modelDetail,
                buttonTitle: server.modelPartialDownload ? "Retry download" : "Download",
                action: server.downloadModel,
                deleteAction: server.modelCached == true ? { confirm(.deleteModel) } : nil,
                folderAction: { openInFinder(server.modelFolderPath) }
            )

            if !server.modelMessage.isEmpty {
                Text(server.modelMessage)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }

            if server.isInstalling {
                if let progress = server.downloadProgress {
                    ProgressView(value: progress)
                        .controlSize(.small)
                    Text(downloadProgressLabel)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView().controlSize(.small)
                    Text("Working…").font(.caption).foregroundStyle(.secondary)
                }
                if server.downloadRetrySecondsRemaining > 0 {
                    HStack(spacing: 8) {
                        Label("Retrying in \(server.downloadRetrySecondsRemaining)s…",
                              systemImage: "arrow.clockwise")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Button("Retry now") { server.retryNow() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        Button("Stop") { server.cancelDownload() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                } else {
                    Button("Stop download") { server.cancelDownload() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                ScrollView {
                    Text(server.installOutput.isEmpty ? "Waiting…" : server.installOutput)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
                .frame(height: 90)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .windowBackgroundColor)))
            }
        }
    }

    /// A single "ready to go / N things left" line, so after installing a missing
    /// piece the user can click "Check status" and see whether they're done.
    @ViewBuilder
    private var readinessLine: some View {
        if server.isReady {
            Label("Ready to go — all prerequisites met.", systemImage: "checkmark.seal.fill")
                .font(.caption)
                .foregroundStyle(.green)
        } else {
            Label("Not ready — \(server.missingPrerequisites.joined(separator: ", ")) still needed.",
                  systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private var pythonDetail: String {
        if server.pythonPath == nil { return "not installed — needed for mlx-lm, hf, and the server" }
        return server.pythonPath ?? ""
    }

    private var mlxLMDetail: String {
        if server.resolvedExecutable == nil { return "not installed" }
        if !server.mlxLMHealthy { return "installed but broken — dependency conflict" }
        return server.resolvedExecutable ?? ""
    }

    private var hfDetail: String {
        if server.hfPath == nil { return "not installed — needed to download models" }
        return server.hfPath ?? ""
    }

    private var modelDetail: String {
        if let cached = server.modelCached {
            if cached { return "downloaded" }
            return server.modelPartialDownload
                ? "download interrupted — incomplete (Retry resumes it)"
                : "not downloaded — required before first start"
        }
        return "checking…"
    }

    private var selectedModelSizeText: String {
        ByteCountFormatter.string(fromByteCount: server.selectedModelDiskBytes, countStyle: .file)
    }

    private var allModelsSizeText: String {
        ByteCountFormatter.string(fromByteCount: server.allModelsDiskBytes, countStyle: .file)
    }

    private var downloadProgressLabel: String {
        let pct = Int((server.downloadProgress ?? 0) * 100)
        if let total = server.downloadTotalBytes, total > 0 {
            let done = ByteCountFormatter.string(fromByteCount: server.downloadBytes, countStyle: .file)
            let all = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
            return "\(pct)% — \(done) of \(all)"
        }
        return "\(pct)% downloaded"
    }

    private func requirementRow(ok: Bool,
                                showAction: Bool,
                                title: String,
                                detail: String,
                                buttonTitle: String,
                                action: @escaping () -> Void,
                                deleteAction: (() -> Void)? = nil,
                                folderAction: (() -> Void)? = nil) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            if let deleteAction {
                Button("Delete") { deleteAction() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!server.canSwitchModel || server.isInstalling)
            }
            if let folderAction {
                Button { folderAction() } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("Show in Finder")
            }
            if showAction {
                Button(buttonTitle, action: action)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(server.isInstalling)
            }
        }
    }

    private var integrationsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Integrations").font(.subheadline).foregroundStyle(.secondary)

            // OpenCode binary: detect whether the CLI is installed.
            HStack(spacing: 8) {
                Image(systemName: server.openCodePath != nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .foregroundStyle(server.openCodePath != nil ? Color.green : Color.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text("OpenCode").font(.callout)
                    Text(server.openCodePath ?? "not installed")
                        .font(.caption2)
                        .foregroundStyle(server.openCodePath == nil ? .orange : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
            }

            if server.openCodePath == nil {
                DisclosureGroup("How to install OpenCode") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("1. Install the CLI (official installer):")
                            .font(.caption)
                        codeBlock(title: "bash", code: "curl -fsSL https://opencode.ai/install | bash")
                        Text("Or with Homebrew:")
                            .font(.caption)
                        codeBlock(title: "bash", code: "brew install sst/tap/opencode")
                        Text("2. Reopen this panel (or restart the app) so it re-detects OpenCode.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                }
                .font(.caption2)
            }

            // Config: automatic or manual. The config is port-specific, so the
            // status re-checks the current port and flags a stale one.
            HStack(spacing: 8) {
                Image(systemName: configSymbol)
                    .foregroundStyle(configColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Config").font(.callout)
                    Text(configDetail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                if showsAutoSetup {
                    Button(configButtonTitle) { confirm(.writeOpenCode) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(server.openCodePath == nil)
                }
                Button(showManualConfig ? "Hide" : "Manual") { showManualConfig.toggle() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button { openInFinder(server.configFolderPath) } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("Show config folder in Finder")
            }

            if showManualConfig {
                manualConfigView
            }

            if !server.setupMessage.isEmpty {
                Text(server.setupMessage)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }

            claudeCodeSection
        }
    }

    /// Claude Code integration. Like OpenCode it's an agent front-end, but it
    /// speaks the Anthropic API, so it needs the LiteLLM bridge and its own env
    /// profile (sourced by the `claude-local` shell alias) instead of the OpenCode
    /// config file.
    private var claudeCodeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            // CLI: detect whether `claude` is installed and actually runs.
            HStack(spacing: 8) {
                Image(systemName: claudeCodeIcon)
                    .foregroundStyle(claudeCodeColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Claude Code").font(.callout)
                    Text(claudeCodeDetail)
                        .font(.caption2)
                        .foregroundStyle(server.claudeCodeVersion == nil ? .orange : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
            }

            Label("Claude Code is problematic with local models: it is slow and can stall or return empty replies. On Macs with limited RAM or compute it performs especially poorly — OpenCode is recommended for local agent work.", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)

            if server.claudeCodePath == nil {
                DisclosureGroup("How to install Claude Code") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("1. Install the CLI:")
                            .font(.caption)
                        codeBlock(title: "bash", code: "npm install -g @anthropic-ai/claude-code")
                        Text("Or the official installer:")
                            .font(.caption)
                        codeBlock(title: "bash", code: "curl -fsSL https://claude.ai/install.sh | bash")
                        Text("2. Reopen this panel (or click Check status) so it re-detects Claude Code.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                }
                .font(.caption2)
            } else if server.claudeCodeVersion == nil {
                // Installed but the binary doesn't run — a broken npm install.
                VStack(alignment: .leading, spacing: 6) {
                    Text("Claude Code is installed but not runnable — usually a broken npm install (a shim without its native binary).")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    codeBlock(title: "bash", code: "npm install -g @anthropic-ai/claude-code")
                    Text("Then reopen this panel (or click Check status) to re-verify.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }

            // LiteLLM bridge: Claude Code's Anthropic → OpenAI translator proxy.
            HStack(spacing: 8) {
                Image(systemName: server.litellmConfigPortMismatch ? "exclamationmark.triangle.fill" : (litellmOk ? "checkmark.circle.fill" : "circle"))
                    .foregroundStyle(server.litellmConfigPortMismatch ? Color.orange : (litellmOk ? Color.green : Color.secondary))
                VStack(alignment: .leading, spacing: 1) {
                    Text("LiteLLM bridge").font(.callout)
                    Text(litellmDetail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button(server.litellmConfigPortMismatch ? "Update config" : "Set up config") { confirm(.writeLitellm) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(server.litellmPath == nil)
                Button(showManualLitellm ? "Hide" : "Manual") { showManualLitellm.toggle() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                if server.litellmPath == nil || server.litellmVersion == nil {
                    Button(server.litellmPath == nil ? "Install" : "Repair") { confirm(.installLitellm) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
                Button { openInFinder(server.litellmConfigFolderPath) } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("Show bridge config folder in Finder")
            }

            if server.litellmConfigPortMismatch {
                Label("The bridge config points at a different MLX port — click \"Update config\" so Claude Code still reaches the server.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if showManualLitellm {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Write this to \(server.litellmConfigPath())")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    ScrollView {
                        Text(server.litellmConfigText)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(height: 140)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .windowBackgroundColor)))
                    HStack(spacing: 8) {
                        Button("Copy config") { copy(server.litellmConfigText) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        Button("Verify") { server.checkLitellm() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            }

            if server.litellmPath != nil && server.litellmVersion == nil {
                VStack(alignment: .leading, spacing: 6) {
                    Text("litellm is installed but its proxy extras are missing (e.g. boto3).")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    codeBlock(title: "bash", code: "pip install 'litellm[proxy]'")
                    Text("Then reopen this panel (or click Check status) to re-verify.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            } else if server.litellmPath == nil {
                DisclosureGroup("How to install LiteLLM") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("1. Install LiteLLM with its proxy extras:")
                            .font(.caption)
                        codeBlock(title: "bash", code: "pip install 'litellm[proxy]'")
                        Text("2. Reopen this panel (or click Check status) so it re-detects LiteLLM.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 4)
                }
                .font(.caption2)
            }

            // Profile: a separate env file pointing Claude Code at the LiteLLM bridge.
            HStack(spacing: 8) {
                Image(systemName: server.claudeCodeProfilePortMismatch ? "exclamationmark.triangle.fill" : (server.claudeCodeProfileWritten ? "checkmark.circle.fill" : "circle"))
                    .foregroundStyle(server.claudeCodeProfilePortMismatch ? Color.orange : (server.claudeCodeProfileWritten ? Color.green : Color.secondary))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Profile").font(.callout)
                    Text(claudeCodeProfileDetail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button(server.claudeCodeProfilePortMismatch ? "Update" : "Set up") { confirm(.writeClaudeCode) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(server.claudeCodePath == nil)
                Button(showManualClaudeCode ? "Hide" : "Manual") { showManualClaudeCode.toggle() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                Button { openInFinder(server.claudeCodeEnvFolderPath) } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.borderless)
                .help("Show profile folder in Finder")
            }

            if server.claudeCodeProfilePortMismatch {
                Label("The profile points at a different bridge port — click \"Update\" so Claude Code reaches the bridge.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if showManualClaudeCode {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Write this to \(server.claudeCodeEnvPath()) — or source it before running `claude`.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    ScrollView {
                        Text(server.claudeCodeConfigText)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(height: 150)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .windowBackgroundColor)))
                    HStack(spacing: 8) {
                        Button("Copy profile") { copy(server.claudeCodeConfigText) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        Button("Verify") { server.checkClaudeCode() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            }

            // How to launch it — self-contained, no repo required.
            DisclosureGroup("How to start Claude Code") {
                VStack(alignment: .leading, spacing: 8) {
                    Text("1. Click Start Server at the top — it launches the MLX server and the LiteLLM bridge together, so there's no separate bridge step.")
                        .font(.caption)
                    Text("2. Launch Claude Code pointed at the bridge:")
                        .font(.caption)
                    codeBlock(title: "bash", code: "source ~/.config/mlx-local/claude-code.env && claude")
                    Text("If you've set up the `claude-local` shell alias, `claude-local` does the same thing.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }
            .font(.caption2)
        }
    }

    private var claudeCodeColor: Color {
        server.claudeCodeVersion != nil ? .green : .orange
    }

    private var claudeCodeIcon: String {
        server.claudeCodeVersion != nil ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    private var claudeCodeDetail: String {
        if let path = server.claudeCodePath {
            if let version = server.claudeCodeVersion {
                return "\(version) — \(path)"
            }
            return "installed but not runnable — \(path)"
        }
        return "not installed"
    }

    private var claudeCodeProfileDetail: String {
        if !server.claudeCodeProfileWritten { return "no env profile yet" }
        if server.claudeCodeProfilePortMismatch { return "profile points at a different bridge port — update it" }
        return "env profile written"
    }

    private var litellmOk: Bool {
        server.litellmPath != nil && server.litellmVersion != nil && server.litellmConfigWritten
    }

    private var litellmDetail: String {
        if server.bridgeRunning { return "running on 127.0.0.1:\(server.bridgePort)" }
        if server.litellmPath == nil { return "not installed — click Install" }
        if server.litellmVersion == nil { return "installed but missing proxy extras — see below" }
        if !server.litellmConfigWritten { return "installed — no bridge config yet" }
        if server.litellmConfigPortMismatch { return "config points at a different MLX port — update it" }
        return server.litellmVersion ?? server.litellmPath ?? ""
    }

    private var configSymbol: String {
        switch server.openCodeConfigStatus {
        case .configured: return "checkmark.circle.fill"
        case .checking: return "hourglass"
        case .notConfigured, .portMismatch: return "exclamationmark.triangle.fill"
        }
    }

    private var configColor: Color {
        switch server.openCodeConfigStatus {
        case .configured: return .green
        case .checking: return .gray
        case .notConfigured, .portMismatch: return .orange
        }
    }

    private var configDetail: String {
        switch server.openCodeConfigStatus {
        case .checking: return "checking…"
        case .notConfigured: return "no config yet — set it up automatically or manually"
        case .portMismatch(let foundPort): return "points at port \(foundPort), not \(server.port)"
        case .configured: return "configured for port \(server.port)"
        }
    }

    /// Show the auto "Set up"/"Update" button only when the config is missing or
    /// stale. Once it's correctly configured we hide it, so a manual setup can't
    /// be overwritten by an accidental click.
    private var showsAutoSetup: Bool {
        switch server.openCodeConfigStatus {
        case .notConfigured, .portMismatch: return true
        case .checking, .configured: return false
        }
    }

    private var configButtonTitle: String {
        if case .portMismatch = server.openCodeConfigStatus { return "Update" }
        return "Set up"
    }

    private var manualConfigView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Write this to \(server.openCodeConfigPath())")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            ScrollView {
                Text(server.openCodeConfigText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(height: 170)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .windowBackgroundColor)))
            HStack(spacing: 8) {
                Button("Copy config") { copy(server.openCodeConfigText) }
                .buttonStyle(.bordered)
                .controlSize(.small)
                Button("Verify") { server.checkOpenCodeConfig() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
    }

    private var modelSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Model").font(.subheadline).foregroundStyle(.secondary)
            Picker("Model", selection: $server.selectedModel) {
                ForEach(ServerController.availableModels) { model in
                    Text("\(model.displayName) — \(model.params)").tag(model)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .disabled(!server.canSwitchModel || server.isInstalling)

            Text("Parameters: \(server.selectedModel.params)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)

            Text(server.selectedModel.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            FlowLayout(spacing: 6) {
                ForEach(server.selectedModel.highlights, id: \.self) { tag in
                    Text("#\(tag)")
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.accentColor.opacity(0.14)))
                        .foregroundStyle(.tint)
                }
            }

            if let warning = server.toolCallingWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Link(destination: server.selectedModel.hfURL) {
                Label("View on Hugging Face", systemImage: "arrow.up.right.square")
                    .font(.caption)
            }

            Text("Stop the server before switching models.")
                .font(.caption2)
                .foregroundStyle(.secondary)

            Divider()

            Button {
                confirm(.deleteAllModels)
            } label: {
                Label("Delete all models", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(.red)
            .disabled(server.isInstalling || !server.canSwitchModel)
        }
    }

    private var modelSettingsSection: some View {
        DisclosureGroup("Model settings") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Max context").font(.callout)
                    Spacer()
                    Text(verbatim: "\(server.selectedModel.profile.maxContext) tokens")
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                }

                Toggle(isOn: $server.enableThinking) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Thinking mode")
                        Text(server.selectedModel.profile.thinkingSupported
                             ? "Qwen3 models reason first, then answer — the reply stays clean either way."
                             : "This model has no thinking mode.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .disabled(!server.canSwitchModel || !server.selectedModel.profile.thinkingSupported)

                if let warning = server.thinkingWarning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Divider()

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Temperature").font(.callout)
                        infoIcon(for: .temperature)
                        Spacer()
                        Text(String(format: "%.2f", server.temperature))
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $server.temperature, in: 0...2, step: 0.05)
                        .disabled(!server.canSwitchModel)
                    if samplingInfo == .temperature {
                        infoDetail(.temperature)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Top-p").font(.callout)
                        infoIcon(for: .topP)
                        Spacer()
                        Text(String(format: "%.2f", server.topP))
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $server.topP, in: 0...1, step: 0.05)
                        .disabled(!server.canSwitchModel)
                    if samplingInfo == .topP {
                        infoDetail(.topP)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Stepper(value: $server.topK, in: 0...200) {
                        HStack(spacing: 4) {
                            Text(verbatim: "Top-k: \(server.topK)").font(.callout)
                            infoIcon(for: .topK)
                        }
                    }
                    .disabled(!server.canSwitchModel)
                    if samplingInfo == .topK {
                        infoDetail(.topK)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Max tokens").font(.callout)
                        Spacer()
                        TextField("Max tokens", text: $maxTokensText)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 90)
                            .textFieldStyle(.roundedBorder)
                            .focused($maxTokensFocused)
                            .onSubmit { commitMaxTokens() }
                            .onChange(of: maxTokensFocused) { _, focused in
                                if !focused { commitMaxTokens() }
                            }
                            .disabled(!server.canSwitchModel)
                    }
                    Text(verbatim: "Up to \(ModelDefaults.maxOutputTokens) output tokens per response. 8192 is right for coding agents. Claude Code ignores this server cap and sends max_tokens=32000; its profile caps output client-side.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    if let warning = server.maxTokensWarning {
                        Label(warning, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Stepper(value: $server.promptCacheBytesGB, in: 1...32) {
                        Text(verbatim: "Prompt cache: \(server.promptCacheBytesGB) GB").font(.callout)
                    }
                    .disabled(!server.canSwitchModel)
                    Text("Cap on cached prompt/KV memory (--prompt-cache-bytes). It must hold your system prompt's KV cache twice. Claude Code's ~85k-token system prompt needs ~6 GB, so the 6 GB default barely caches it — trim MCP servers/skills, or raise this if the Mac has spare RAM. OpenCode's small prompt caches fine at the default.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Spacer()
                    Button("Reset to defaults") { server.resetModelSettings() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(!server.canSwitchModel)
                }

                Text("Settings apply on the next Start.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 6)
        }
    }

    private var controls: some View {
        Button(action: server.primaryAction) {
            Text(server.primaryLabel)
                .fontWeight(.semibold)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .tint(server.state == .running ? .red : .accentColor)
        .disabled(server.primaryDisabled)
    }

    private var advancedSection: some View {
        DisclosureGroup("Advanced") {
            VStack(alignment: .leading, spacing: 10) {
                Text("mlx_lm.server path (blank = auto-detect)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("auto-detect", text: $server.executablePath)
                    .textFieldStyle(.roundedBorder)
                    .font(.callout.monospaced())
                HStack(spacing: 6) {
                    Text("Resolved:").font(.caption2).foregroundStyle(.secondary)
                    Text(server.resolvedExecutable ?? "not found")
                        .font(.caption2.monospaced())
                        .foregroundStyle(server.resolvedExecutable == nil ? .red : .secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                }
                Stepper(value: $server.port, in: 1024...65535) {
                    Text(verbatim: "MLX server port: \(server.port)")
                }
                .disabled(!server.canSwitchModel)

                Stepper(value: $server.bridgePort, in: 1024...65535) {
                    Text(verbatim: "LiteLLM bridge port: \(server.bridgePort)")
                }
                .disabled(!server.canSwitchModel)

                if let conflict = server.portConflictMessage {
                    Label(conflict, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Divider()

                Toggle(isOn: $server.allowConcurrentRequests) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Allow concurrent requests")
                        Text("Uses full-precision KV cache and lets the server batch requests in parallel. Needs a small model on a machine with plenty of RAM — the app blocks this when it would run out of memory.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .disabled(!server.canSwitchModel || !server.concurrentRequestsSafe)

                if !server.concurrentRequestsSafe {
                    Label("Concurrent requests is unavailable for \(server.selectedModel.displayName) on this Mac (\(Int(ServerController.physicalRAMGB)) GB RAM) — full-precision KV cache could take the whole machine down. Switch to Qwen3-14B to enable it.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if server.allowConcurrentRequests {
                    Label("Concurrent requests are ON — a large Claude Code prompt can still run out of memory. Turn this off to restore quantized KV cache (--kv-bits 4) and safe serialization.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding(.top, 6)
        }
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Server log").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                Button("Copy") { copyLog() }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .disabled(server.log.isEmpty)
                Button("Download") { downloadLog() }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .disabled(server.log.isEmpty)
                Button("Clear") { server.clearLog() }
                    .buttonStyle(.borderless)
                    .font(.caption)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(server.log.isEmpty ? "No output yet." : server.log)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(server.log.isEmpty ? Color.gray : Color.white)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                        Color.clear.frame(height: 1).id("log-bottom")
                    }
                }
                .frame(height: 130)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.black))
                .onChange(of: server.log) { _, _ in
                    withAnimation {
                        proxy.scrollTo("log-bottom", anchor: .bottom)
                    }
                }
            }
        }
    }

    private func copyLog() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(server.log, forType: .string)
    }

    private func downloadLog() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "mlx-server.log"
        panel.allowedContentTypes = [UTType(filenameExtension: "log") ?? .plainText]
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            try? server.log.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("⌘Q to quit").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
                Button("Quit MLX Server") {
                    NSApplication.shared.terminate(nil)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Text("v\(appVersion) (\(appBuild))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Button("Check for updates") {
                    server.checkForUpdates()
                }
                .buttonStyle(.borderless)
                .font(.caption2)
                .foregroundStyle(.secondary)
                if server.isCheckingForUpdates {
                    ProgressView().controlSize(.mini)
                }
                Spacer()
            }
        }
    }

    /// The marketing version (CFBundleShortVersionString) and build number
    /// (CFBundleVersion) from the app's Info.plist, shown in the footer so you
    /// can tell which release you're running.
    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    private var appBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }
}

private extension ServerController.ServerState {
    var title: String {
        switch self {
        case .stopped: return "Stopped"
        case .starting: return "Starting…"
        case .running: return "Running"
        case .stopping: return "Stopping…"
        case .failed(let message): return "Failed — \(message)"
        }
    }

    var color: Color {
        switch self {
        case .stopped: return .gray
        case .starting, .stopping: return .orange
        case .running: return .green
        case .failed: return .red
        }
    }
}

/// Simple left-to-right wrapping layout for the hashtag pills under the model
/// picker. Not a full flow layout — just enough to wrap short tags.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        let width = maxWidth == .infinity ? x : maxWidth
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y),
                          proposal: ProposedViewSize(width: size.width, height: size.height))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
