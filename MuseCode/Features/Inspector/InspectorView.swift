//
//  InspectorView.swift
//  PiCode
//
//  The right panel: a single viewer, not a tab bar. Whatever the user last
//  selected in the conversation — a file's contents, an edit's diff, a command's
//  output, or any other tool's result — is shown here, with its path (or a title
//  when there is no path) along the top.
//
//  Everything here is read from Pi or from the working tree on disk. The panel
//  never edits files; Pi is the only actor that changes a project.
//

import SwiftUI

struct InspectorView: View {
    @Bindable var state: AppState
    @AppStorage("inspectorTextWrap") private var wrapsText = true

    var body: some View {
        Group {
            if state.isNotificationsVisible {
                NotificationsPanel(state: state)
            } else if let controller = state.activeController {
                if let artifact = state.inspectorArtifact {
                    VStack(spacing: 0) {
                        ArtifactHeader(
                            artifact: artifact,
                            controller: controller,
                            wrapsText: $wrapsText,
                            onBackToOverview: { state.showOverview() }
                        )
                        ArtifactContentView(
                            state: state,
                            artifact: artifact,
                            controller: controller,
                            wrapsText: wrapsText
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .frame(maxHeight: .infinity)
                } else {
                    MuseRightSidebarPanel(state: state, controller: controller)
                }
            } else {
                EmptyStateView(
                    systemImage: "layout-align-right",
                    title: "Nothing selected",
                    message: "Select or start a Muse session to inspect Overview and Agent Messages."
                )
            }
        }
        .background(
            LiquidGlassCardBackground(cornerRadius: 14, isDarkTopPill: false)
        )
    }
}

// MARK: - Muse Overview & Agent Messages Right Sidebar

struct MuseRightSidebarPanel: View {
    @Bindable var state: AppState
    var controller: PiSessionController
    var initiallyExpandMessages: Bool = false

    var body: some View {
        VStack(spacing: 8) {
            MuseOverviewCard(state: state, controller: controller)
                .frame(maxWidth: .infinity)

            MuseAgentMessagesCard(
                state: state,
                controller: controller,
                initiallyExpanded: initiallyExpandMessages
            )
            .frame(maxWidth: .infinity)
        }
        .padding(10)
    }
}

struct MuseOverviewCard: View {
    @Bindable var state: AppState
    var controller: PiSessionController

    @State private var showAllSubagents = false
    @State private var showAllArtifacts = false
    @State private var showContextSheet = false

    private var visibleSubagents: [MuseSubagentInfo] {
        showAllSubagents ? controller.subagents : Array(controller.subagents.prefix(3))
    }

    private var visibleArtifacts: [MuseArtifactInfo] {
        showAllArtifacts ? controller.sessionArtifacts : Array(controller.sessionArtifacts.prefix(4))
    }

    private var changedFileCount: Int {
        let writes = Set(controller.recentFileChanges.filter { $0.kind != .read }.map(\.path))
        let gitPaths = Set(controller.git.changes.map(\.path))
        return writes.union(gitPaths).count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Card Header: Overview + ⋯ menu
            HStack(spacing: 8) {
                Text("Overview")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)

                Spacer(minLength: 0)

                Menu {
                    Button {
                        Task {
                            await controller.refreshMuseTelemetry()
                            await controller.refreshGit()
                        }
                    } label: {
                        Label("Refresh Overview", huge: "refresh")
                    }
                    Button {
                        showContextSheet = true
                    } label: {
                        Label("Session & Context Details…", huge: "chart-01")
                    }
                    if let sessionFile = controller.sessionFile {
                        Divider()
                        Button {
                            WorkspaceLauncher.reveal(sessionFile)
                        } label: {
                            Label("Reveal Session File", huge: "folder-02")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Overview options")
            }
            .padding(.horizontal, 12)
            .padding(.top, 11)
            .padding(.bottom, 8)

            VStack(alignment: .leading, spacing: 0) {
                // 4 Quick-Action Navigation Rows: Review, Files, Terminal, Extensions >
                VStack(spacing: 1) {
                    overviewNavRow(
                        icon: "note-01",
                        title: "Review",
                        badge: changedFileCount > 0 ? "\(changedFileCount)" : nil
                    ) {
                        state.openReviewInInspector()
                    }

                    overviewNavRow(
                        icon: "folder-02",
                        title: "Files",
                        badge: nil
                    ) {
                        state.openFilesInInspector()
                    }

                    overviewNavRow(
                        icon: "terminal",
                        title: "Terminal",
                        badge: state.isTerminalVisible ? "On" : nil
                    ) {
                        state.toggleTerminal()
                    }

                    overviewNavRow(
                        icon: "puzzle",
                        title: "Extensions",
                        showsChevron: true
                    ) {
                        state.openExtensionsInInspector()
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 8)

                // Subagents section (only shown when subagents exist)
                if !controller.subagents.isEmpty {
                    Divider()
                        .padding(.horizontal, 12)

                    overviewSectionHeader(title: "Subagents", count: controller.subagents.count)

                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(visibleSubagents) { subagent in
                            subagentRow(subagent)
                        }
                        if controller.subagents.count > 3 {
                            Button(showAllSubagents ? "Show less" : "See all") {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    showAllSubagents.toggle()
                                }
                            }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                        }
                    }
                    .padding(.bottom, 6)
                }

                // Background Tasks section (only shown when background tasks exist)
                if !controller.backgroundTasks.isEmpty {
                    Divider()
                        .padding(.horizontal, 12)

                    overviewSectionHeader(title: "Background Tasks", count: controller.backgroundTasks.count)

                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(controller.backgroundTasks) { task in
                            backgroundTaskRow(task)
                        }
                    }
                    .padding(.bottom, 6)
                }

                // Artifacts section (only shown when artifacts exist)
                if !controller.sessionArtifacts.isEmpty {
                    Divider()
                        .padding(.horizontal, 12)

                    overviewSectionHeader(title: "Artifacts", count: controller.sessionArtifacts.count)

                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(visibleArtifacts) { artifact in
                            artifactRow(artifact)
                        }
                        if controller.sessionArtifacts.count > 4 {
                            Button(showAllArtifacts ? "Show less" : "See all") {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    showAllArtifacts.toggle()
                                }
                            }
                            .buttonStyle(.plain)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                        }
                    }
                    .padding(.bottom, 8)
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(red: 0.08, green: 0.11, blue: 0.14, opacity: 0.46))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
        .sheet(isPresented: $showContextSheet) {
            VStack(spacing: 0) {
                HStack {
                    Text("Session & Context")
                        .font(.headline)
                    Spacer()
                    Button("Done") { showContextSheet = false }
                        .buttonStyle(.settingsPillProminent)
                }
                .padding(12)
                Divider()
                ContextPane(state: state, controller: controller)
            }
            .frame(width: 420, height: 520)
        }
    }

    private func overviewNavRow(
        icon: String,
        title: String,
        badge: String? = nil,
        showsChevron: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                HugeIcon(name: icon, size: 15)
                    .foregroundStyle(.secondary)
                    .frame(width: 18, alignment: .center)

                Text(title)
                    .font(.system(size: 13))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Spacer(minLength: 0)

                if let badge {
                    Text(badge)
                        .font(.system(size: 11, weight: .medium).monospacedDigit())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(.quaternary.opacity(0.6), in: Capsule())
                }

                if showsChevron {
                    HugeIcon(name: "arrow-right-01", size: 13)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    private func overviewSectionHeader(title: String, count: Int) -> some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            Text("\(count)")
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 1)
                .background(.quaternary.opacity(0.6), in: Capsule())

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private func subagentRow(_ subagent: MuseSubagentInfo) -> some View {
        Button {
            state.openSubagentInInspector(subagent)
        } label: {
            HStack(spacing: 8) {
                subagentStatusIcon(subagent.status)
                    .frame(width: 16, height: 16, alignment: .center)

                Text(subagent.title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(subagent.summary ?? subagent.title)
    }

    @ViewBuilder
    private func subagentStatusIcon(_ status: MuseSubagentInfo.Status) -> some View {
        switch status {
        case .waiting, .running:
            ProgressView()
                .controlSize(.mini)
        case .completed:
            HugeIcon(name: "checkmark-circle-01", size: 13)
                .foregroundStyle(.green)
        case .failed:
            HugeIcon(name: "cancel-circle", size: 13)
                .foregroundStyle(.red)
        }
    }

    private func backgroundTaskRow(_ task: MuseBackgroundTaskInfo) -> some View {
        Button {
            if let toolId = task.toolCallId {
                state.openInInspector(toolId: toolId)
            } else {
                state.openInInspector(toolId: task.id)
            }
        } label: {
            HStack(spacing: 8) {
                if task.status == .running {
                    ProgressView().controlSize(.mini)
                        .frame(width: 16, height: 16)
                } else if task.status == .failed {
                    HugeIcon(name: "cancel-circle", size: 13)
                        .foregroundStyle(.red)
                        .frame(width: 16, height: 16)
                } else {
                    HugeIcon(name: "terminal", size: 13)
                        .foregroundStyle(.secondary)
                        .frame(width: 16, height: 16)
                }

                Text(task.title)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(task.detail ?? task.title)
    }

    private func artifactRow(_ artifact: MuseArtifactInfo) -> some View {
        Button {
            if artifact.kind == .plan {
                state.openPlanInInspector(title: artifact.title, content: artifact.preview ?? artifact.title)
            } else if let path = artifact.path {
                let resolved = (path as NSString).isAbsolutePath
                    ? path
                    : (controller.projectPath as NSString).appendingPathComponent(path)
                state.openInInspector(path: resolved)
            } else if let toolId = artifact.toolCallId {
                state.openInInspector(toolId: toolId)
            }
        } label: {
            HStack(spacing: 8) {
                HugeIcon(name: artifact.kind == .plan ? "task-add-01" : "note-01", size: 14)
                    .foregroundStyle(.secondary)
                    .frame(width: 16, height: 16, alignment: .center)

                Text(artifact.title)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(artifact.path ?? artifact.title)
    }
}

struct MuseAgentMessagesCard: View {
    @Bindable var state: AppState
    var controller: PiSessionController
    var initiallyExpanded: Bool = false

    @State private var targetRecipient: String = ""
    @State private var messageDraft: String = ""
    @State private var isSending = false
    @State private var isManuallyExpanded = false

    private var isExpanded: Bool {
        !controller.agentMessages.isEmpty || isManuallyExpanded || initiallyExpanded
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header (collapses body when there are 0 messages unless expanded by the user)
            HStack(spacing: 6) {
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        isManuallyExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 6) {
                        HugeIcon(name: "message-multiple-01", size: 14)
                            .foregroundStyle(Color.accentColor)

                        Text("Muse Agent Messages")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.primary)

                        Text("\(controller.agentMessages.count)")
                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.quaternary.opacity(0.6), in: Capsule())

                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()

                let peerSessions = state.projects.flatMap(\.sessions).filter {
                    $0.sessionId != nil && $0.sessionId != controller.sessionId
                }
                if !peerSessions.isEmpty {
                    Menu {
                        ForEach(peerSessions) { peer in
                            Button(peer.displayName) {
                                targetRecipient = peer.sessionId ?? peer.displayName
                                isManuallyExpanded = true
                            }
                        }
                    } label: {
                        HugeIcon(name: "user-multiple", size: 13)
                            .foregroundStyle(.secondary)
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Pick a target Muse session")
                }

                Button {
                    Task { await controller.refreshMuseTelemetry() }
                } label: {
                    HugeIcon(name: "refresh", size: 13)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help("Refresh agent messages")

                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        isManuallyExpanded.toggle()
                    }
                } label: {
                    HugeIcon(name: isExpanded ? "arrow-up-01" : "arrow-down-01", size: 12)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help(isExpanded ? "Collapse Muse Agent Messages" : "Expand to send a Muse agent message")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            if isExpanded {
                Divider()
                    .padding(.horizontal, 12)

                // Message feed (only shown when messages exist)
                if !controller.agentMessages.isEmpty {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(controller.agentMessages) { msg in
                                agentMessageRow(msg)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                    }
                    .frame(maxWidth: .infinity, maxHeight: 160)

                    Divider()
                }

                // Inline Compose Bar for `muse session-message send`
                VStack(spacing: 5) {
                    HStack(spacing: 6) {
                        Text("To:")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                        TextField(
                            "target session id or name",
                            text: $targetRecipient
                        )
                        .textFieldStyle(.plain)
                        .font(.caption2.monospaced())
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 6)

                    HStack(spacing: 6) {
                        TextField("Send Muse agent message…", text: $messageDraft)
                            .textFieldStyle(.plain)
                            .font(.caption)
                            .onSubmit { sendAgentMessage() }

                        Button {
                            sendAgentMessage()
                        } label: {
                            if isSending {
                                ProgressView().controlSize(.mini)
                            } else {
                                HugeIcon(name: "arrow-up-01", size: 12)
                                    .foregroundStyle(.white)
                                    .frame(width: 20, height: 20)
                                    .background(
                                        Circle().fill(canSend ? AppTheme.accentBlue : Color.secondary.opacity(0.35))
                                    )
                            }
                        }
                        .buttonStyle(.plain)
                        .disabled(!canSend || isSending)
                        .help("Send via muse session-message send")
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 7)
                }
                .background(AppTheme.background.opacity(0.5))
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color(red: 0.08, green: 0.11, blue: 0.14, opacity: 0.46))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
    }

    private var resolvedRecipient: String {
        targetRecipient.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canSend: Bool {
        !messageDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !resolvedRecipient.isEmpty
    }

    private func sendAgentMessage() {
        let body = messageDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = resolvedRecipient
        guard !body.isEmpty, !target.isEmpty else { return }
        messageDraft = ""
        isSending = true
        Task {
            let result = await controller.sendAgentMessage(target: target, body: body)
            isSending = false
            if !result.success {
                state.showToast("Could not send agent message: \(result.detail)")
            }
        }
    }

    private func agentMessageRow(_ msg: MuseAgentMessageInfo) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                HugeIcon(
                    name: msg.direction == .incoming ? "arrow-left-01" : "arrow-up-right-01",
                    size: 11
                )
                .foregroundStyle(msg.direction == .incoming ? Color.accentColor : Color.secondary)

                Text(msg.sender)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text("→")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)

                Text(msg.target)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 0)

                if let status = msg.deliveryPolicy {
                    Text(status)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary.opacity(0.6), in: Capsule())
                }
            }

            Text(msg.body)
                .font(.caption)
                .foregroundStyle(.primary)
                .lineLimit(4)
                .textSelection(.enabled)
        }
        .padding(7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(AppTheme.background.opacity(0.65))
        )
    }
}

// MARK: - Muse Extensions / Skills Pane

struct MuseExtensionsPane: View {
    var controller: PiSessionController
    @State private var skills = MuseSkillsService.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Muse Skills & Extensions")
                    .font(.callout.weight(.semibold))
                StatusPill(text: "\(skills.skills.count)", tint: .secondary)
                Spacer(minLength: 0)
                Button {
                    Task { await skills.refresh(cwd: controller.projectPath) }
                } label: {
                    HugeIcon(name: "refresh")
                }
                .buttonStyle(.borderless)
                .help("Reload skills from muse skills list")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)

            Divider()

            if skills.isLoading && skills.skills.isEmpty {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if skills.skills.isEmpty {
                EmptyStateView(
                    systemImage: "puzzle",
                    title: "No Muse skills found",
                    message: "Install skills in ~/.config/muse/skills or .muse/skills."
                )
            } else {
                List {
                    ForEach(skills.skills) { skill in
                        HStack(alignment: .top, spacing: 10) {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(skill.name)
                                        .font(.callout.weight(.medium))
                                    StatusPill(text: skill.scope, tint: .secondary)
                                    StatusPill(
                                        text: skill.activation,
                                        tint: skill.isEnabled ? .accentColor : .secondary
                                    )
                                }
                                Text(skill.description)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(3)
                                Text(skill.path.abbreviatingHomeDirectory)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer(minLength: 8)
                            Toggle("", isOn: Binding(
                                get: { skill.isEnabled },
                                set: { _ in
                                    Task { await skills.toggle(skill: skill, cwd: controller.projectPath) }
                                }
                            ))
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .labelsHidden()
                        }
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.inset)
            }
        }
        .task {
            await skills.refresh(cwd: controller.projectPath)
        }
    }
}

// MARK: - Muse Subagent Detail Pane

struct MuseSubagentDetailView: View {
    @Bindable var state: AppState
    var subagent: MuseSubagentInfo
    var controller: PiSessionController

    @State private var childItems: [TranscriptItem] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                InspectorSection(title: "Subagent", systemImage: "user-multiple") {
                    KeyValueRow(key: "Title", value: subagent.title)
                    KeyValueRow(key: "Role", value: subagent.role)
                    KeyValueRow(key: "Status", value: subagent.status.rawValue)
                    KeyValueRow(key: "Subagent ID", value: subagent.id, isMonospaced: true)
                    if let sessionId = subagent.childSessionId {
                        KeyValueRow(key: "Child Session ID", value: sessionId, isMonospaced: true)
                    }
                    if let sessionPath = subagent.sessionFilePath {
                        KeyValueRow(key: "Session File", value: sessionPath.abbreviatingHomeDirectory, isMonospaced: true)
                    }
                }

                if !subagent.objective.isEmpty {
                    InspectorSection(title: "Objective", systemImage: "note-01") {
                        Text(subagent.objective)
                            .font(.callout)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let summary = subagent.summary, !summary.isEmpty {
                    InspectorSection(title: "Result / Summary", systemImage: "checkmark-circle-01") {
                        Text(summary)
                            .font(.callout)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if !childItems.isEmpty {
                    InspectorSection(title: "Subagent Transcript (\(childItems.count))", systemImage: "message-multiple-01") {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(childItems.suffix(20)) { item in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.kind == .user ? "Prompt" : (item.kind == .toolCall ? (item.toolName ?? "Tool") : "Subagent"))
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                    Text(item.text.isEmpty ? (item.toolOutput ?? "") : item.text)
                                        .font(.caption)
                                        .lineLimit(6)
                                        .textSelection(.enabled)
                                }
                                .padding(6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
                            }
                        }
                    }
                }
            }
            .padding(12)
        }
        .task(id: subagent.id) {
            if let filePath = subagent.sessionFilePath {
                let summary = await PiSessionHistoryReader().summary(at: filePath)
                childItems = TranscriptBuilder.items(messages: summary.messages)
            }
        }
    }
}

// MARK: - Notifications

/// The notification list, shown where an artifact would be when the content
/// header's bell is on. It is the same data `PiSessionController` already keeps;
/// the panel only draws it and lets the user dismiss entries.
struct NotificationsPanel: View {
    @Bindable var state: AppState

    private var controller: PiSessionController? { state.activeController }
    private var notifications: [ExtensionNotification] { controller?.notifications ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            header
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Mirrors `ArtifactHeader` and the conversation header, with the title left
    /// and actions right on the same titlebar-height row.
    private var header: some View {
        HStack(spacing: 8) {
            HugeIcon(name: "notification-01")
                .imageScale(.small)
                .foregroundStyle(.secondary)
                .frame(width: 16, alignment: .center)

            Text("Notifications")
                .font(Typography.body)
                .lineLimit(1)

            Spacer(minLength: 0)

            if !notifications.isEmpty {
                Button("Clear All") { controller?.dismissAllNotifications() }
                    .font(.caption)
                    .buttonStyle(.borderless)
                    .help("Dismiss every notification in this session")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .background(AppTheme.background)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 1)
        }
    }

    @ViewBuilder
    private var content: some View {
        if notifications.isEmpty {
            EmptyStateView(
                systemImage: "notification-circle",
                title: "No notifications",
                message: "Messages Pi extensions send with `notify` appear here instead of over the conversation."
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(notifications.reversed()) { notification in
                        row(notification)
                        Divider().padding(.leading, 38)
                    }
                }
            }
            .background(AppTheme.background)
        }
    }

    private func row(_ notification: ExtensionNotification) -> some View {
        HStack(alignment: .top, spacing: 9) {
            HugeIcon(name: notification.level.systemImage)
                .imageScale(.small)
                .foregroundStyle(tint(notification.level))
                .frame(width: 16, alignment: .center)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(notification.message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                HStack(spacing: 6) {
                    if let source = notification.sourceName {
                        Text(source)
                    }
                    Text(Format.relativeTime(notification.timestamp))
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 8)

            Button {
                controller?.dismissNotification(notification.id)
            } label: {
                HugeIcon(name: "cancel-circle")
                    .font(.caption2)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.tertiary)
            .help("Dismiss")
            .accessibilityLabel("Dismiss notification")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .accessibilityElement(children: .combine)
    }

    private func tint(_ level: ExtensionNotification.Level) -> Color {
        switch level {
        case .info: return .accentColor
        case .warning: return .orange
        case .error: return .red
        }
    }
}

/// The right panel's header: what is open, and where it lives. A file's path is
/// the title; a call with no file gets its own name instead. It uses the main
/// header's padding, background and bottom rule so the two columns meet cleanly.
struct ArtifactHeader: View {
    var artifact: AppState.InspectorArtifact
    var controller: PiSessionController
    @Binding var wrapsText: Bool
    var onBackToOverview: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            if let onBackToOverview {
                Button(action: onBackToOverview) {
                    HStack(spacing: 3) {
                        HugeIcon(name: "arrow-left-01", size: 13)
                        Text("Overview")
                            .font(.caption.weight(.medium))
                    }
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.quaternary.opacity(0.45), in: Capsule())
                }
                .buttonStyle(.plain)
                .help("Back to Overview")
            }

            HugeIcon(name: systemImage)
                .imageScale(.small)
                .foregroundStyle(.secondary)
                .frame(width: 16, alignment: .center)

            Text(title)
                .font(Typography.body)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(title)

            Spacer(minLength: 0)

            Menu {
                Toggle(isOn: $wrapsText) {
                    Label("Text Wrap", huge: "text-align-left")
                }
            } label: {
                HugeIcon(name: "settings-02")
                    .imageScale(.medium)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Viewer settings")
            .accessibilityLabel("Viewer settings")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .background(AppTheme.background)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(height: 1)
        }
    }

    /// The file the artifact is about, when it has one.
    private var path: String? {
        switch artifact {
        case .file(let path, _): return path
        case .change(let path): return path
        case .tool(let id):
            guard let item = item(id), item.kind == .toolCall else { return nil }
            return item.toolFilePath
        case .review, .files, .extensions, .subagent, .plan:
            return nil
        }
    }

    private var title: String {
        if let path { return path.abbreviatingHomeDirectory }
        switch artifact {
        case .file(let path, _), .change(let path):
            return (path as NSString).lastPathComponent
        case .tool(let id):
            guard let item = item(id) else { return "Tool" }
            if item.kind == .toolCall {
                return item.commandText == nil ? (item.toolName ?? "Tool") : "Command"
            }
            return item.toolName ?? "Tool result"
        case .review:
            return "Review Changes"
        case .files:
            return "Project Files"
        case .extensions:
            return "Extensions"
        case .subagent(let subagent):
            return subagent.title
        case .plan(let title, _):
            return title
        }
    }

    private var systemImage: String {
        switch artifact {
        case .change, .review: return "edit-02"
        case .file: return "note-01"
        case .files: return "folder-02"
        case .extensions: return "puzzle"
        case .subagent: return "user-multiple"
        case .plan: return "task-add-01"
        case .tool(let id):
            guard let item = item(id) else { return "wrench-01" }
            return QuietFamily.of(item)?.systemImage ?? "wrench-01"
        }
    }

    private func item(_ id: String) -> TranscriptItem? {
        controller.items.first { $0.id == id || $0.toolCallId == id }
            ?? controller.allItems.first { $0.id == id || $0.toolCallId == id }
    }
}

/// The body of the panel: the selected call, file, or diff, with all the room the
/// column has.
struct ArtifactContentView: View {
    @Bindable var state: AppState
    var artifact: AppState.InspectorArtifact
    var controller: PiSessionController
    var wrapsText: Bool

    var body: some View {
        switch artifact {
        case .tool(let id):
            if let item = controller.items.first(where: { $0.id == id || $0.toolCallId == id })
                ?? controller.allItems.first(where: { $0.id == id || $0.toolCallId == id }) {
                InspectorToolArtifactView(item: item, wrapsText: wrapsText)
            } else {
                EmptyStateView(
                    systemImage: "folder-open",
                    title: "Not available",
                    message: "This call is no longer part of the conversation."
                )
            }
        case .file(let path, let line):
            FileArtifactView(path: path, line: line, wrapsText: wrapsText)
        case .change(let path):
            ChangeArtifactView(path: path, controller: controller, wrapsText: wrapsText)
        case .review:
            ChangesPane(state: state, controller: controller)
        case .files:
            FilesPane(state: state, controller: controller)
        case .extensions:
            MuseExtensionsPane(controller: controller)
        case .subagent(let subagent):
            MuseSubagentDetailView(state: state, subagent: subagent, controller: controller)
        case .plan(_, let content):
            ScrollView {
                MarkdownView(text: content, isStreaming: false)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(AppTheme.background)
        }
    }
}

/// A file on disk, in the same numbered, highlighted viewer the file browser used.
struct FileArtifactView: View {
    var path: String
    var line: Int?
    var wrapsText: Bool

    @State private var preview: FilePreview?

    var body: some View {
        Group {
            if let preview {
                if let error = preview.error {
                    BannerView(level: .error, title: "Cannot preview this file", message: error, onDismiss: nil)
                        .padding(12)
                    Spacer(minLength: 0)
                } else {
                    CodeViewer(
                        text: preview.text,
                        language: preview.language,
                        highlightLine: line,
                        wrapsText: wrapsText
                    )
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: path) { preview = FilePreviewLoader.load(path: path) }
    }
}

/// A file the agent changed, as a working-tree diff. It is resolved against the
/// same lists the Changes pane used — the session's own writes first, then git —
/// so a path Pi reported relative to the project still finds its status.
struct ChangeArtifactView: View {
    var path: String
    var controller: PiSessionController
    var wrapsText: Bool

    @State private var diff: String?
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading {
                ProgressView().controlSize(.small).padding(16)
            } else if let diff, !diff.isEmpty {
                DiffView(diff: diff, wrapsText: wrapsText)
            } else {
                EmptyStateView(
                    systemImage: "note-01",
                    title: "No text diff",
                    message: "This file is binary, untracked, or unchanged on disk. Open the edit call itself to see the change Pi made."
                )
            }
        }
        .task(id: path) { await load() }
    }

    private func load() async {
        isLoading = true
        diff = await controller.diff(for: resolvedChange())
        isLoading = false
    }

    private func resolvedChange() -> GitFileChange {
        let absolute = path.isAbsolutePath
            ? path
            : (controller.projectPath as NSString).appendingPathComponent(path)
        let candidates = controller.git.changes + controller.recentFileChanges.map {
            GitFileChange(path: $0.path, oldPath: nil, status: $0.kind.gitStatus, isStaged: false,
                          additions: $0.additions, deletions: $0.deletions)
        }
        if let match = candidates.first(where: { $0.path == path || $0.path == absolute }) {
            return match
        }
        return GitFileChange(path: path, oldPath: nil, status: .modified, isStaged: false,
                             additions: nil, deletions: nil)
    }
}

// MARK: - Changes

struct ChangesPane: View {
    @Bindable var state: AppState
    var controller: PiSessionController

    @State private var selectedPath: String?
    @State private var diffText: String?
    @State private var isLoadingDiff = false
    @State private var showsSessionChanges = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .task(id: selectedPath) { await loadDiff() }
        .onAppear { applyRequestedSelection() }
        // The selection lives here, not in the tool card, so a request from the
        // transcript has to be matched against this pane's own change list —
        // Pi reports paths relative to the project and the list may hold either
        // form.
        .onChange(of: state.selectedChangePath) { _, _ in applyRequestedSelection() }
    }

    private func applyRequestedSelection() {
        guard let requested = state.selectedChangePath else { return }
        let match = changes.first { change in
            change.path == requested || absolutePath(for: change) == requested
        }
        selectedPath = match?.path ?? requested
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Source", selection: $showsSessionChanges) {
                Text("Session").tag(true)
                Text("Git").tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            HStack(spacing: 8) {
                if let branch = controller.git.branch {
                    Label(branch, huge: "git-branch")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                DiffStatView(additions: additions, deletions: deletions)
                Spacer(minLength: 0)
                Button {
                    Task { await refresh() }
                } label: {
                    HugeIcon(name: "refresh")
                }
                .buttonStyle(.borderless)
                .help("Refresh changes")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private var content: some View {
        if changes.isEmpty {
            EmptyStateView(
                systemImage: showsSessionChanges ? "checkmark-circle-01" : "checkmark-circle-01",
                title: showsSessionChanges ? "No files touched yet" : "Working tree clean",
                message: showsSessionChanges
                    ? "Files Pi edits during this session appear here."
                    : "Nothing to commit in this project."
            )
        } else {
            VStack(spacing: 0) {
                List(selection: $selectedPath) {
                    ForEach(changes) { change in
                        ChangeRow(change: change, occurrences: occurrences[change.path] ?? 1)
                            .tag(change.path)
                    }
                }
                .listStyle(.inset)
                .frame(minHeight: 140)

                Divider()
                diffView
            }
        }
    }

    @ViewBuilder
    private var diffView: some View {
        if let selectedPath, let change = changes.first(where: { $0.path == selectedPath }) {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text(change.path)
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    CopyButton(text: diffText ?? "")
                    Button {
                        state.openInInspector(path: absolutePath(for: change))
                    } label: {
                        HugeIcon(name: "note-01")
                    }
                    .buttonStyle(.borderless)
                    .help("Show this file in the Files tab")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)

                if isLoadingDiff {
                    ProgressView().controlSize(.small).padding(10)
                } else if let diffText, !diffText.isEmpty {
                    DiffView(diff: diffText)
                } else {
                    Text("No text diff available (binary file, untracked file, or no changes on disk).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(10)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        } else {
            Text("Select a file to see its diff.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Data

    private var changes: [GitFileChange] {
        if showsSessionChanges {
            return sessionChanges
        }
        return controller.git.changes
    }

    /// Files Pi wrote during this session. Reads are intentionally excluded: a
    /// "changes" list that includes reads is not a changes list.
    private var sessionChanges: [GitFileChange] {
        let writes = controller.recentFileChanges.filter { $0.kind != .read }
        let gitByPath = Dictionary(controller.git.changes.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        var seen: Set<String> = []
        var result: [GitFileChange] = []
        for fileChange in writes.reversed() {
            guard !seen.contains(fileChange.path) else { continue }
            seen.insert(fileChange.path)
            if let match = gitByPath[fileChange.path] {
                var merged = match
                if merged.additions == nil { merged.additions = fileChange.additions }
                if merged.deletions == nil { merged.deletions = fileChange.deletions }
                result.append(merged)
            } else {
                result.append(GitFileChange(
                    path: fileChange.path,
                    oldPath: nil,
                    status: fileChange.kind.gitStatus,
                    isStaged: false,
                    additions: fileChange.additions,
                    deletions: fileChange.deletions
                ))
            }
        }
        return result.sorted { $0.path < $1.path }
    }

    private var occurrences: [String: Int] {
        var counts: [String: Int] = [:]
        for change in controller.recentFileChanges where change.kind != .read {
            counts[change.path, default: 0] += 1
        }
        return counts
    }

    private var additions: Int? {
        let values = changes.compactMap(\.additions)
        return values.isEmpty ? nil : values.reduce(0, +)
    }

    private var deletions: Int? {
        let values = changes.compactMap(\.deletions)
        return values.isEmpty ? nil : values.reduce(0, +)
    }

    private func absolutePath(for change: GitFileChange) -> String {
        (change.path as NSString).isAbsolutePath
            ? change.path
            : (controller.projectPath as NSString).appendingPathComponent(change.path)
    }

    private func refresh() async {
        await controller.refreshGit()
        await loadDiff()
    }

    private func loadDiff() async {
        guard let selectedPath, let change = changes.first(where: { $0.path == selectedPath }) else {
            diffText = nil
            return
        }
        isLoadingDiff = true
        diffText = await controller.diff(for: change)
        isLoadingDiff = false
    }
}

struct ChangeRow: View {
    var change: GitFileChange
    var occurrences: Int = 1

    var body: some View {
        HStack(spacing: 8) {
            Text(change.status.rawValue)
                .font(.caption.monospaced().weight(.semibold))
                .foregroundStyle(statusColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(fileName)
                    .font(.callout)
                    .lineLimit(1)
                Text(directory)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 0)
            DiffStatView(additions: change.additions, deletions: change.deletions)
            if change.isStaged {
                HugeIcon(name: "seal")
                    .imageScale(.small)
                    .foregroundStyle(.tertiary)
                    .help("Staged")
            }
            if occurrences > 1 {
                Text("×\(occurrences)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
                    .help("Pi touched this file \(occurrences) times this session")
            }
        }
        .padding(.vertical, 1)
        .help(change.status.label)
    }

    private var fileName: String { (change.path as NSString).lastPathComponent }
    private var directory: String { (change.path as NSString).deletingLastPathComponent }

    private var statusColor: Color {
        switch change.status {
        case .added, .untracked: return .green
        case .deleted: return .red
        case .conflicted: return .orange
        case .renamed, .copied: return .blue
        default: return .secondary
        }
    }
}

// MARK: - Diff rendering

struct DiffView: View {
    var diff: String
    var wrapsText = false

    var body: some View {
        GeometryReader { geometry in
            ScrollView(wrapsText ? .vertical : [.vertical, .horizontal]) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(lines) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 0) {
                            Text(line.oldLine.map { String($0) } ?? "")
                                .frame(width: 42, alignment: .trailing)
                                .padding(.trailing, 8)
                                .foregroundStyle(.tertiary)
                                .background(line.gutterBackground)

                            Text(line.newLine.map { String($0) } ?? "")
                                .frame(width: 42, alignment: .trailing)
                                .padding(.trailing, 8)
                                .foregroundStyle(.tertiary)
                                .background(line.gutterBackground)

                            Text(line.marker)
                                .frame(width: 20, alignment: .center)
                                .foregroundStyle(line.markerColor)

                            Text(line.text)
                                .foregroundStyle(line.foreground)
                                .fixedSize(horizontal: !wrapsText, vertical: false)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.trailing, 12)
                        }
                        .font(Typography.codeBlockCompact)
                        .frame(maxWidth: .infinity, minHeight: 19, alignment: .leading)
                        .background(line.background)
                        .textSelection(.enabled)
                    }
                }
                .frame(minWidth: geometry.size.width, alignment: .leading)
            }
        }
        .background(AppTheme.background)
    }

    private var lines: [GitDiffLine] { InspectorArtifactRendering.parseDiff(diff) }
}
