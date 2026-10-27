import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var server: ServerController
    @State private var showManualConfig = false

    var body: some View {
        TabView {
            serverTab
                .tabItem { Label("Server", systemImage: "cpu") }
            connectTab
                .tabItem { Label("Connect", systemImage: "link") }
        }
        .frame(width: 470)
        .onAppear {
            server.onAppear()
            server.checkModelCached()
            server.checkOpenCodeConfig()
            server.checkOpenCode()
        }
        .onChange(of: server.selectedModel) { _, _ in
            server.checkModelCached()
        }
        .onChange(of: server.port) { _, _ in
            server.checkOpenCodeConfig()
        }
    }

    private var serverTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            statusCard
            requirementsSection
            integrationsSection
            modelSection
            controls
            Divider()
            advancedSection
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
            Text("port \(server.port)")
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
    }

    private var requirementsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Requirements").font(.subheadline).foregroundStyle(.secondary)

            requirementRow(
                ok: server.resolvedExecutable != nil,
                showAction: server.resolvedExecutable == nil,
                title: "mlx-lm (mlx_lm.server)",
                detail: server.resolvedExecutable ?? "not installed",
                buttonTitle: "Install",
                action: server.installMLX
            )

            requirementRow(
                ok: server.modelCached == true,
                showAction: server.modelCached == false,
                title: "Model files",
                detail: modelDetail,
                buttonTitle: "Download",
                action: server.downloadModel
            )

            if server.isInstalling {
                ProgressView().controlSize(.small)
                ScrollView {
                    Text(server.installOutput.isEmpty ? "Working…" : server.installOutput)
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

    private var modelDetail: String {
        if let cached = server.modelCached {
            return cached ? "downloaded" : "not downloaded — required before first start"
        }
        return "checking…"
    }

    private func requirementRow(ok: Bool,
                                showAction: Bool,
                                title: String,
                                detail: String,
                                buttonTitle: String,
                                action: @escaping () -> Void) -> some View {
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
                Text("Install OpenCode, then reopen this panel:\ncurl -fsSL https://opencode.ai/install | bash")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
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
                    Button(configButtonTitle) { server.writeOpenCodeConfig() }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(server.openCodePath == nil)
                }
                Button(showManualConfig ? "Hide" : "Manual") { showManualConfig.toggle() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
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
        }
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
                    Text(model.displayName).tag(model)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .disabled(!server.canSwitchModel)
            Text("Stop the server before switching models.")
                .font(.caption2)
                .foregroundStyle(.secondary)
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
                    Text("Port: \(server.port)")
                }
                .disabled(!server.canSwitchModel)

                Divider()

                Toggle(isOn: $server.allowConcurrentRequests) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Allow concurrent requests")
                        Text("Uses full-precision KV cache so the server can batch requests in parallel. Needs more memory — use only with a smaller model.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .disabled(!server.canSwitchModel)
            }
            .padding(.top, 6)
        }
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Server log").font(.subheadline).foregroundStyle(.secondary)
                Spacer()
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

    private var footer: some View {
        HStack {
            Text("⌘Q to quit").font(.caption2).foregroundStyle(.tertiary)
            Spacer()
            Button("Quit MLX Server") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
        }
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
