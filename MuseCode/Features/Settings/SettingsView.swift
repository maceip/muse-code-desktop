//
//  SettingsView.swift
//  PiCode
//
//  PiCode preferences, installed harness configuration, and third-party
//  provider definitions. Harness-owned accounts stay with their harness.
//

import SwiftUI

struct SettingsView: View {
    @Bindable var state: AppState

    var body: some View {
        HStack(spacing: 0) {
            menu
            Rectangle().fill(AppTheme.cardStroke).frame(width: 1)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(AppTheme.background)
        }
        .onExitCommand { state.isSettingsPresented = false }
    }

    // MARK: - Left menu

    private var menu: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                Color.clear.frame(height: 8)

                ForEach(SettingsTab.Group.allCases) { group in
                    let tabs = SettingsTab.allCases.filter { $0.group == group }
                    if !tabs.isEmpty {
                        Text(group.title)
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.top, 14)
                            .padding(.bottom, 4)
                        ForEach(tabs) { settingsMenuRow($0) }
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 16)
        }
        .frame(width: 256)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(AppTheme.sidebar)
    }

    private func settingsMenuRow(_ tab: SettingsTab) -> some View {
        let isSelected = state.settingsTab == tab
        return Button {
            state.settingsTab = tab
        } label: {
            HStack(spacing: 10) {
                HugeIcon(name: tab.systemImage)
                    .font(.system(size: 13, weight: .regular))
                    .frame(width: 18)
                Text(tab.title)
                    .font(Typography.body)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? Color.primary : Color.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(isSelected ? AppTheme.railSelection : .clear)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Content

    private var content: some View {
        ZStack(alignment: .top) {
            Group {
                switch state.settingsTab {
                case .general: GeneralSettings(state: state)
                case .composer: ComposerSettings(state: state)
                case .sessions: SessionSettings(state: state)
                case .safari: SafariBridgeSettingsTab(state: state)
                case .pi: PiSettingsTab(state: state)
                }
            }
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 22)

            header
        }
        .frame(maxWidth: 860, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .top)
        .background(AppTheme.background)
    }

    /// The page title, pinned over the scrolling content. Equal space above and
    /// below the text; the background fades out so rows slide under it softly.
    private var header: some View {
        HStack(alignment: .center) {
            Text(state.settingsTab.title)
                .font(.system(size: 30, weight: .semibold))
            Spacer(minLength: 12)
        }
        .padding(.horizontal, 40)
        .frame(height: SettingsMetrics.headerHeight)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(
                stops: [
                    .init(color: AppTheme.background, location: 0),
                    .init(color: AppTheme.background, location: 0.55),
                    .init(color: AppTheme.background.opacity(0), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: SettingsMetrics.headerHeight + 24)
            .frame(maxHeight: SettingsMetrics.headerHeight, alignment: .top)
            .allowsHitTesting(false),
            alignment: .top
        )
    }
}

/// Tabs of the settings window, so the command palette can open a specific one
/// instead of dropping the user on General.
enum SettingsTab: String, CaseIterable, Identifiable, Hashable {
    case general
    case composer
    case sessions
    case safari
    case pi

    var id: String { rawValue }

    /// The labelled clusters in the settings menu.
    enum Group: String, CaseIterable, Identifiable {
        case personal, coding

        var id: String { rawValue }
        var title: String {
            switch self {
            case .personal: return "Personal"
            case .coding: return "Muse"
            }
        }
    }

    var group: Group {
        switch self {
        case .general, .composer: return .personal
        case .sessions, .safari, .pi: return .coding
        }
    }

    var title: String {
        switch self {
        case .general: return "General"
        case .composer: return "Composer"
        case .sessions: return "Sessions"
        case .safari: return "Safari Bridge"
        case .pi: return "Muse & Diagnostics"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "settings-02"
        case .composer: return "edit-02"
        case .sessions: return "message-multiple-01"
        case .safari: return "globe"
        case .pi: return "stethoscope"
        }
    }
}

// MARK: - General

struct GeneralSettings: View {
    @Bindable var state: AppState

    var body: some View {
        SettingsPage {
            SettingsSection("Appearance") {
                SettingsRow("Appearance", detail: "Match the system or force a light or dark window.") {
                    Dropdown(
                        selection: Binding(
                            get: { state.preferences.appearance },
                            set: { state.preferences.appearance = $0; state.preferences.persist() }
                        ),
                        values: PreferencesStore.Appearance.allCases,
                        label: { $0.label }
                    )
                }
                SettingsRow("Chat background", detail: "Backdrop artwork behind the Liquid Glass composer in the chat area.") {
                    Dropdown(
                        selection: Binding(
                            get: { state.preferences.chatBackground },
                            set: { state.preferences.chatBackground = $0; state.preferences.persist() }
                        ),
                        values: PreferencesStore.ChatBackground.allCases,
                        label: { $0.label }
                    )
                }
                SettingsRow("Reduce motion", detail: "Overrides the system setting for PiCode's animations only.") {
                    Toggle("", isOn: Binding(
                        get: { state.preferences.reducedMotionOverride ?? false },
                        set: { state.preferences.reducedMotionOverride = $0; state.preferences.persist() }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
                SettingsRow(
                    "Keep transcript built",
                    detail: "Screens of messages kept above and below the view. Fewer uses less memory in long chats."
                ) {
                    Dropdown(
                        selection: Binding(
                            get: { state.preferences.transcriptOffscreenScreens },
                            set: { state.preferences.transcriptOffscreenScreens = $0; state.preferences.persist() }
                        ),
                        values: PreferencesStore.transcriptOffscreenScreenChoices,
                        label: { "\($0) screens" }
                    )
                }
                SettingsRow("Notify when a long turn finishes") {
                    Toggle("", isOn: Binding(
                        get: { state.preferences.notificationsEnabled },
                        set: { state.preferences.notificationsEnabled = $0; state.preferences.persist() }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
            }

            SettingsSection("Workspace") {
                SettingsRow("Show inspector", detail: "The panel with the session's changes and context.") {
                    Toggle("", isOn: Binding(
                        get: { state.isInspectorVisible },
                        set: { state.isInspectorVisible = $0 }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
                SettingsRow(
                    "Project folder",
                    detail: state.selectedProjectPath?.abbreviatingHomeDirectory ?? "No project is selected."
                ) {
                    HStack(spacing: 8) {
                        if let path = state.selectedProjectPath {
                            CopyButton(text: path, help: "Copy project path")
                        }
                        Button("Open…") { Task { await state.addProject() } }
                            .buttonStyle(.settingsPill)
                    }
                }
            }
        }
    }
}

// MARK: - Composer

struct ComposerSettings: View {
    @Bindable var state: AppState
    private var stt: MuseVoiceSTTService { MuseVoiceSTTService.shared }

    var body: some View {
        SettingsPage {
            SettingsSection("Sending") {
                SettingsRow("Send key", detail: "The key that sends a message from the composer.") {
                    Dropdown(
                        selection: Binding(
                            get: { state.preferences.sendKey },
                            set: { state.preferences.sendKey = $0; state.preferences.persist() }
                        ),
                        values: PreferencesStore.SendKey.allCases,
                        label: { $0.label }
                    )
                }
            }

            SettingsSection("Voice & Speech-to-Text") {
                SettingsRow(
                    "Speech-to-text router",
                    detail: "Auto mode uses Muse STT (`muse voice transcribe`) and automatically fails over to macOS on-device speech recognition when Muse is down or unreachable."
                ) {
                    Dropdown(
                        selection: Binding(
                            get: { stt.routerMode },
                            set: { stt.setRouterMode($0) }
                        ),
                        values: MuseVoiceSTTRouterMode.allCases,
                        label: { $0.label }
                    )
                }
                SettingsRow(
                    "Active STT route",
                    detail: stt.routerStatusDescription
                ) {
                    HStack(spacing: 8) {
                        if stt.activePrimaryBackend() == .museCLI {
                            Button("Use System Backup") {
                                stt.switchToSystemBackupNow()
                            }
                            .buttonStyle(.settingsPill)
                        } else {
                            Button("Retry Muse STT") {
                                stt.retryMuseSTTNow()
                            }
                            .buttonStyle(.settingsPill)
                        }
                    }
                }
            }

            SettingsSection("Defaults for new sessions") {
                SettingsRow("Thinking level") {
                    Dropdown(
                        selection: Binding(
                            get: { state.preferences.defaultThinkingLevel ?? "" },
                            set: {
                                state.preferences.defaultThinkingLevel = $0.isEmpty ? nil : $0
                                state.preferences.persist()
                                if !$0.isEmpty {
                                    MuseRuntime.writeUserSettings(model: nil, reasoningEffort: $0)
                                }
                            }
                        ),
                        values: [""] + MuseRuntime.efforts,
                        label: { $0.isEmpty ? "Muse's default" : $0 }
                    )
                }
                if let controller = state.activeController, !controller.availableModels.isEmpty {
                    SettingsRow("Muse model") {
                        Dropdown(
                            selection: Binding(
                                get: { state.preferences.defaultModelByHarness[controller.harness.id.rawValue] ?? "" },
                                set: {
                                    state.preferences.defaultModelByHarness[controller.harness.id.rawValue] = $0.isEmpty ? nil : $0
                                    state.preferences.defaultModelQualifiedID = $0.isEmpty ? nil : $0
                                    state.preferences.persist()
                                    if !$0.isEmpty {
                                        MuseRuntime.writeUserSettings(model: $0, reasoningEffort: nil)
                                    }
                                }
                            ),
                            options: [.init(label: "Muse's default", value: "")]
                                + controller.availableModels.map {
                                    .init(label: "\($0.provider)/\($0.id)", value: $0.qualifiedID)
                                }
                        )
                    }
                } else {
                    SettingsRow(
                        "Default model",
                        detail: "Open a session to choose a default model. Muse's own default is used until then."
                    )
                }
            }
        }
    }
}

// MARK: - Sessions

struct SessionSettings: View {
    @Bindable var state: AppState

    var body: some View {
        SettingsPage {
            SettingsSection("Sessions") {
                SettingsRow("Ask before deleting a session") {
                    Toggle("", isOn: Binding(
                        get: { state.preferences.confirmBeforeDeletingSessions },
                        set: { state.preferences.confirmBeforeDeletingSessions = $0; state.preferences.persist() }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
                SettingsRow(
                    "Record event payloads",
                    detail: "Keeps the last \(PiDiagnosticsLog.shared.limit) event payloads in memory for troubleshooting. Nothing is written to disk."
                ) {
                    Toggle("", isOn: Binding(
                        get: { state.preferences.recordRPCPayloads },
                        set: { state.preferences.recordRPCPayloads = $0; state.preferences.persist() }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }
            }

            SettingsSection("Muse's session storage") {
                SettingsRow(
                    "Sessions folder",
                    detail: "\(PiPaths.sessionsDirectory.path.abbreviatingHomeDirectory)\nPiCode indexes these files read-only and never rewrites them."
                ) {
                    Button("Reveal") { WorkspaceLauncher.reveal(PiPaths.sessionsDirectory.path) }
                        .buttonStyle(.settingsPill)
                }
            }

            SettingsSection("Hidden and pinned") {
                SettingsRow(
                    "Hidden sessions",
                    detail: "\(state.preferences.pinnedSessions.count) pinned sessions, \(state.preferences.hiddenSessions.count) hidden sessions."
                ) {
                    Button("Forget Hidden Sessions") {
                        state.preferences.hiddenSessions = []
                        state.preferences.persist()
                    }
                    .buttonStyle(.settingsPill)
                }
            }
        }
    }
}

// MARK: - Muse

struct PiSettingsTab: View {
    @Bindable var state: AppState

    @State private var showsPayloadLog = false

    var body: some View {
        SettingsPage {
            SettingsSection("Muse installation") {
                if let installation = state.installation {
                    SettingsRow("Version") {
                        Text(installation.version).foregroundStyle(.secondary)
                    }
                    SettingsRow("Path", detail: installation.displayPath)
                } else {
                    SettingsRow("Not found", detail: state.discoveryDetail ?? "Muse CLI was not found yet.") {
                        Button("Search Again") { Task { await state.retryDiscovery() } }
                            .buttonStyle(.settingsPill)
                    }
                }
                SettingsRow("Version check") {
                    Button("Check Muse Version") { state.run(.checkForPiUpdates) }
                        .buttonStyle(.settingsPill)
                }
                SettingsRow("Setup instructions") {
                    Button("Show") { state.run(.showPiSetup) }
                        .buttonStyle(.settingsPill)
                }
            }

            SettingsSection("Muse account") {
                SettingsBlock {
                    LocalHarnessAccountSettingsView(state: state, descriptor: state.activeHarness)
                }
            }

            SettingsSection("Launch arguments") {
                SettingsBlock {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Extra arguments", text: Binding(
                            get: { state.preferences.extraLaunchArguments },
                            set: { state.preferences.extraLaunchArguments = $0; state.preferences.persist() }
                        ), prompt: Text("--verbose"))
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.callout, design: .monospaced))
                        Text("Appended to every `muse exec --json` launch. PiCode never writes to Muse's settings files.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            SettingsSection("Muse configuration") {
                ForEach(configFiles, id: \.path) { file in
                    SettingsRow(file.lastPathComponent, detail: file.path.abbreviatingHomeDirectory) {
                        if FileManager.default.fileExists(atPath: file.path) {
                            Button("Reveal") { WorkspaceLauncher.reveal(file.path) }
                                .buttonStyle(.settingsPill)
                        } else {
                            Text("missing").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                }
                SettingsRow("Muse's config folder") {
                    Button("Open") { state.run(.revealPiDirectory) }
                        .buttonStyle(.settingsPill)
                }
            }

            SettingsSection("Diagnostics") {
                SettingsRow("Recorded payloads", detail: "\(PiDiagnosticsLog.shared.count) recorded") {
                    HStack(spacing: 8) {
                        Button("View Payload Log") { showsPayloadLog = true }
                            .buttonStyle(.settingsPill)
                        Button("Clear") { PiDiagnosticsLog.shared.clear() }
                            .buttonStyle(.settingsPill)
                    }
                }
            }
        }
        .sheet(isPresented: $showsPayloadLog) {
            PayloadLogView()
        }
    }

    private var configFiles: [URL] {
        [PiPaths.settingsFile, PiPaths.trustFile, PiPaths.authFile, PiPaths.approvalPolicyFile]
    }
}

struct PayloadLogView: View {
    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("RPC payload log")
                    .font(.headline)
                Spacer(minLength: 0)
                CopyButton(text: text, help: "Copy log")
                Button("Refresh") { text = PiDiagnosticsLog.shared.text() }
                    .buttonStyle(.settingsPill)
                Button("Close") { dismiss() }
                    .buttonStyle(.settingsPill)
            }
            .padding(12)
            Divider()
            ScrollView {
                Text(text.isEmpty ? "Nothing recorded. Enable “Record RPC payloads” first." : text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
        .frame(width: 640, height: 460)
        .onAppear { text = PiDiagnosticsLog.shared.text() }
    }

    @Environment(\.dismiss) private var dismiss
}

// MARK: - Safari Bridge

struct SafariBridgeSettingsTab: View {
    @Bindable var state: AppState
    @Bindable private var safariBridge = MuseSafariBridgeService.shared
    @State private var targetURLText = "https://scholar.google.com"
    @State private var isRunningAction = false

    var body: some View {
        SettingsPage {
            SettingsSection("Bundled Safari Web Extension") {
                SettingsRow(
                    "Muse Safari Bridge",
                    detail: safariBridge.extensionStatusMessage
                ) {
                    HStack(spacing: 8) {
                        Button("Refresh") {
                            Task {
                                await safariBridge.refreshStatus(
                                    preferences: state.preferences,
                                    installation: state.installation
                                )
                            }
                        }
                        .buttonStyle(.settingsPill)

                        Button("Open Safari Extension Settings…") {
                            safariBridge.openSafariExtensionPreferences()
                        }
                        .buttonStyle(.settingsPillProminent)
                    }
                }

                SettingsRow(
                    "Extension bundle identifier",
                    detail: MuseSafariBridgeService.extensionBundleIdentifier
                ) {
                    CopyButton(text: MuseSafariBridgeService.extensionBundleIdentifier, help: "Copy bundle identifier")
                }
            }

            SettingsSection("Persistent JavaScript Bridge") {
                SettingsRow(
                    "Enable persistent Safari JS bridge",
                    detail: "Runs the local loopback coordinator (`\(safariBridge.bridgeEndpointURLString)`) so Muse can persistently control an owned tab and inspect or mutate the live DOM."
                ) {
                    Toggle("", isOn: Binding(
                        get: { state.preferences.safariBridgeEnabled },
                        set: { enabled in
                            state.preferences.safariBridgeEnabled = enabled
                            state.preferences.persist()
                            if enabled {
                                safariBridge.startServerIfNeeded(port: state.preferences.safariBridgePort)
                            } else {
                                safariBridge.stopServer()
                            }
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }

                SettingsRow(
                    "Auto-claim active tab when needed",
                    detail: "Automatically claims the active Safari tab when the Muse agent navigates or queries the DOM without a previously claimed tab."
                ) {
                    Toggle("", isOn: Binding(
                        get: { state.preferences.safariBridgeAutoClaimTab },
                        set: { autoClaim in
                            state.preferences.safariBridgeAutoClaimTab = autoClaim
                            state.preferences.persist()
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                }

                SettingsRow(
                    "Bridge endpoint",
                    detail: safariBridge.isServerRunning
                        ? "Listening on \(safariBridge.bridgeEndpointURLString) • Queue: \(PiPaths.safariBridgeDirectory.path.abbreviatingHomeDirectory)"
                        : "Stopped (\(safariBridge.bridgeEndpointURLString))"
                ) {
                    HStack(spacing: 8) {
                        CopyButton(text: safariBridge.bridgeEndpointURLString, help: "Copy bridge URL")
                        Button("Reveal Folder") {
                            WorkspaceLauncher.reveal(PiPaths.safariBridgeDirectory.path)
                        }
                        .buttonStyle(.settingsPill)
                    }
                }
            }

            SettingsSection("Agent-Owned Safari Tab") {
                SettingsRow(
                    "Owned tab status",
                    detail: safariBridge.ownedTab.isClaimed
                        ? "Tab #\(safariBridge.ownedTab.tabId ?? 1) (\(safariBridge.ownedTab.transport)) — \(safariBridge.ownedTab.title.isEmpty ? safariBridge.ownedTab.url : "\(safariBridge.ownedTab.title) • \(safariBridge.ownedTab.url)")"
                        : "No Safari tab is currently claimed by the Muse agent."
                ) {
                    HStack(spacing: 8) {
                        Button("Claim Tab") {
                            Task {
                                isRunningAction = true
                                defer { isRunningAction = false }
                                _ = await safariBridge.executeCommand([
                                    "action": "claimTab",
                                    "url": targetURLText
                                ])
                            }
                        }
                        .buttonStyle(.settingsPill)
                        .disabled(isRunningAction)

                        if safariBridge.ownedTab.isClaimed {
                            Button("Release") {
                                Task {
                                    isRunningAction = true
                                    defer { isRunningAction = false }
                                    _ = await safariBridge.executeCommand(["action": "releaseTab"])
                                }
                            }
                            .buttonStyle(.settingsPill)
                            .disabled(isRunningAction)
                        }
                    }
                }

                SettingsBlock {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            TextField("URL to open or navigate in owned tab", text: $targetURLText)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.callout, design: .monospaced))

                            Button("Navigate") {
                                Task {
                                    isRunningAction = true
                                    defer { isRunningAction = false }
                                    _ = await safariBridge.executeCommand([
                                        "action": "navigate",
                                        "url": targetURLText
                                    ])
                                }
                            }
                            .buttonStyle(.settingsPillProminent)
                            .disabled(isRunningAction || targetURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                            Button("Inspect DOM") {
                                Task {
                                    isRunningAction = true
                                    defer { isRunningAction = false }
                                    _ = await safariBridge.executeCommand(["action": "inspectDOM"])
                                }
                            }
                            .buttonStyle(.settingsPill)
                            .disabled(isRunningAction)
                        }

                        if let dom = safariBridge.latestDOMInspection {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Live DOM Snapshot: \(dom.title.isEmpty ? dom.url : dom.title)")
                                    .font(.system(size: 12.5, weight: .semibold))
                                Text("Ready: \(dom.readyState) • Forms: \(dom.formCount) • Inputs: \(dom.inputCount) • Buttons: \(dom.buttonCount) • Links: \(dom.linkCount) • Headings: \(dom.headingCount)")
                                    .font(.system(size: 11.5, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                if !dom.textExcerpt.isEmpty {
                                    Text(String(dom.textExcerpt.prefix(240)))
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(3)
                                }
                            }
                            .padding(.top, 4)
                        }

                        if let msg = safariBridge.lastActionMessage {
                            Text(msg)
                                .font(.system(size: 11.5))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            SettingsSection("Muse CLI Skill & Plugin (`safari-browser`)") {
                SettingsRow(
                    "Muse skill status",
                    detail: safariBridge.isSkillInstalled
                        ? "Installed & active at \(safariBridge.skillInstallPath.abbreviatingHomeDirectory)"
                        : "Not installed yet in ~/.agents/skills/safari-browser"
                ) {
                    HStack(spacing: 8) {
                        if safariBridge.isSkillInstalled {
                            Button("Reveal Skill") {
                                WorkspaceLauncher.reveal(safariBridge.skillInstallPath)
                            }
                            .buttonStyle(.settingsPill)
                        }
                        Button(safariBridge.isSkillInstalled ? "Reinstall Skill" : "Install Skill") {
                            Task {
                                _ = await safariBridge.installOrUpdateMuseSkill(installation: state.installation)
                                await MuseSkillsService.shared.refresh(
                                    cwd: state.selectedProjectPath ?? FileManager.default.currentDirectoryPath,
                                    installation: state.installation
                                )
                            }
                        }
                        .buttonStyle(.settingsPillProminent)
                    }
                }
            }
        }
        .task {
            await safariBridge.refreshStatus(
                preferences: state.preferences,
                installation: state.installation
            )
        }
    }
}
