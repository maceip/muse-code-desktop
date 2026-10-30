//
//  RootView.swift
//  PiCode
//
//  Window layout: an icon rail on the window chrome, then one rounded card
//  holding the sessions sidebar, the conversation and the contextual inspector.
//
//  The panes are laid out here rather than through `NavigationSplitView`, so
//  the card is one surface set into the chrome: the sidebar folds away inside
//  it and the inspector opens inside it, and neither moves the other.
//

import SwiftUI

/// The window's frame: the band the traffic lights sit in, and the inset of
/// the content card from the window's edges.
enum WindowChromeMetrics {
    /// The unified toolbar's band. The traffic lights are centred in it, and the
    /// content card starts just under it.
    static let titlebarHeight: CGFloat = 40
    static let titlebarRowCenter: CGFloat = 19
    /// The card's inset from the window's trailing and bottom edges.
    static let cardInset: CGFloat = 6
    static let cardCornerRadius: CGFloat = 12
    /// Where the sidebar toggle starts: just past the traffic lights.
    static let sidebarToggleLeading: CGFloat = 84
}

struct RootView: View {
    @Bindable var state: AppState

    @Environment(\.colorScheme) private var colorScheme
    @State private var isSidebarVisible = true
    @State private var sidebarWidth: CGFloat = 268
    @State private var sidebarWidthAtDragStart: CGFloat?
    @State private var composerFocusTick = 0
    @State private var sheet: RootSheet?
    @State private var inspectorWidth: CGFloat = 328
    @State private var inspectorWidthAtDragStart: CGFloat?
    @State private var detailPaneSize: CGSize = CGSize(width: 1147, height: 820)

    private var showsAppRail: Bool {
        !isSidebarVisible || state.isSettingsPresented
    }

    var body: some View {
        HStack(spacing: 0) {
            if showsAppRail {
                AppRail(
                    state: state,
                    onOpenPalette: openPalette,
                    onOpenSettings: { state.openSettings(tab: state.settingsTab) }
                )
                .transition(.move(edge: .leading).combined(with: .opacity))
            }
            Group {
                if state.isSettingsPresented {
                    settingsCard
                } else {
                    contentCard
                }
            }
                .padding(.leading, showsAppRail ? 0 : WindowChromeMetrics.cardInset)
                .padding(.trailing, WindowChromeMetrics.cardInset)
                .padding(.bottom, WindowChromeMetrics.cardInset)
        }
        .animation(.easeInOut(duration: 0.2), value: showsAppRail)
        .padding(.top, WindowChromeMetrics.titlebarHeight)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            ZStack {
                WindowVibrancy()
                AppTheme.chrome
            }
        }
        .overlay(alignment: .top) { titlebarControlsBar }
        .ignoresSafeArea()
        .toolbarBackground(.hidden, for: .windowToolbar)
        .task {
            if state.phase == .starting { await state.launch() }
            #if DEBUG
            Task { await DebugRenderBench.runIfRequested(state: state) }
            if let wanted = ProcessInfo.processInfo.environment["PICODE_OPEN_SESSION"] {
                // The index fills in asynchronously; wait for the session to show up.
                // Let the restored session settle first so it does not replace this one.
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                for _ in 0..<80 {
                    if let session = state.projects.lazy.flatMap(\.sessions)
                        .first(where: { $0.filePath?.hasSuffix(wanted) == true || $0.sessionId == wanted }) {
                        await state.open(session: session)
                        break
                    }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
            }
            if ProcessInfo.processInfo.environment["PICODE_SNAPSHOT_ACTION"] == "newChat" {
                if let project = state.projects.first?.path {
                    await state.startNewSession(projectPath: project)
                }
            }
            #endif
        }
        .onDisappear {
            state.isInspectorVisible = false
            state.isNotificationsVisible = false
        }
        .onChange(of: state.commandTick) { _, _ in
            if let command = state.lastCommand { perform(command) }
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .palette:
                CommandPaletteView(state: state) { command in
                    self.sheet = nil
                    perform(command)
                }
            case .rename(let current):
                RenameSessionSheet(state: state, session: nil, currentName: current) { self.sheet = nil }
            case .renameChat(let session):
                RenameSessionSheet(state: state, session: session, currentName: session.displayName) { self.sheet = nil }
            case .compact:
                CompactSessionSheet(state: state) { self.sheet = nil }
            case .fork:
                ForkSessionSheet(state: state) { self.sheet = nil }
            case .delete(let session):
                DeleteSessionSheet(state: state, session: session) { self.sheet = nil }
            case .projectSettings(let project):
                ProjectSettingsSheet(state: state, project: project) { self.sheet = nil }
            case .newProject(let path):
                NewProjectSheet(state: state, path: path) { self.sheet = nil }
            case .cloneRepository:
                CloneRepositorySheet(state: state) { self.sheet = nil }
            case .createProjectFolder:
                CreateProjectFolderSheet(state: state) { self.sheet = nil }
            }
        }
        .onChange(of: state.pendingProjectSettings) { _, project in
            guard let project else { return }
            state.pendingProjectSettings = nil
            sheet = .projectSettings(project)
        }
        .onChange(of: state.pendingSessionRename) { _, session in
            guard let session else { return }
            state.pendingSessionRename = nil
            sheet = .renameChat(session)
        }
        .onChange(of: state.pendingNewProjectPath) { _, path in
            guard let path else { return }
            sheet = .newProject(path)
        }
        .onChange(of: state.pendingCloneRepository) { _, requested in
            guard requested else { return }
            state.pendingCloneRepository = false
            sheet = .cloneRepository
        }
        .onChange(of: state.pendingCreateProjectFolder) { _, requested in
            guard requested else { return }
            state.pendingCreateProjectFolder = false
            sheet = .createProjectFolder
        }
        .overlay(alignment: .bottom) { toast }
        .overlay(alignment: .top) { errorBanner.padding(.top, WindowChromeMetrics.titlebarHeight) }
        .overlay(alignment: .top) {
            ZStack(alignment: .top) {
                if state.isPalettePresented && !state.isSettingsPresented {
                    Color.black.opacity(0.001)
                        .ignoresSafeArea()
                        .onTapGesture {
                            state.closePalette()
                        }

                    TitlebarSearchDropdownView(state: state, onRunCommand: perform)
                        .padding(.top, WindowChromeMetrics.titlebarRowCenter + TitlebarIconButton.size / 2 + 4)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .ignoresSafeArea()
            .animation(.easeOut(duration: 0.11), value: state.isPalettePresented)
            .zIndex(90)
        }
        .overlay { ExtensionDialogHost(state: state) }
    }

    private func openPalette() {
        withAnimation(.easeOut(duration: 0.12)) {
            state.openPalette()
        }
    }

    // MARK: - Card

    /// The sidebar and the detail pane, set into the window chrome as one
    /// rounded card. The sidebar is a pane of the card rather than a split-view
    /// column, so it folds away without the card moving.
    private var contentCard: some View {
        HStack(spacing: 0) {
            if isSidebarVisible {
                SidebarView(
                    state: state,
                    onOpenPalette: openPalette,
                    onOpenSettings: { state.openSettings(tab: state.settingsTab) }
                )
                .frame(width: sidebarWidth)
                .layoutPriority(1)
                .transition(.move(edge: .leading).combined(with: .opacity))

                paneDivider { translation in
                    if sidebarWidthAtDragStart == nil { sidebarWidthAtDragStart = sidebarWidth }
                    let start = sidebarWidthAtDragStart ?? sidebarWidth
                    sidebarWidth = min(380, max(220, start + translation))
                } onEnded: {
                    sidebarWidthAtDragStart = nil
                }
            }
            detailPane
                .frame(minWidth: 0, maxWidth: .infinity)
                // Opaque, unlike the chrome and the sidebar around it: the
                // transcript keeps full contrast over the window's vibrancy.
                .background(AppTheme.background)
        }
        .clipShape(RoundedRectangle(cornerRadius: WindowChromeMetrics.cardCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: WindowChromeMetrics.cardCornerRadius, style: .continuous)
                .stroke(AppTheme.cardStroke, lineWidth: 1)
        )
        .animation(.easeInOut(duration: 0.2), value: isSidebarVisible)
    }

    /// Settings take the card's place, so they replace the window's content
    /// rather than float over it. The rail stays, as the way back.
    private var settingsCard: some View {
        SettingsView(state: state)
            .clipShape(RoundedRectangle(cornerRadius: WindowChromeMetrics.cardCornerRadius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: WindowChromeMetrics.cardCornerRadius, style: .continuous)
                    .stroke(AppTheme.cardStroke, lineWidth: 1)
            )
    }

    /// A one-point rule between two panes that can be dragged to resize them.
    private func paneDivider(
        onChanged: @escaping (CGFloat) -> Void,
        onEnded: @escaping () -> Void
    ) -> some View {
        SplitPaneResizeHandle(
            width: 1,
            hitInset: -3,
            fill: AppTheme.cardStroke,
            onChanged: onChanged,
            onEnded: onEnded
        )
    }

    // MARK: - Titlebar

    /// Coordinated titlebar bar that positions the leading navigation controls,
    /// centered search pill, and trailing panel toggles within a single geometry
    /// pass so narrow windows or wide sidebars never cause the session title and
    /// search pill to collide.
    @ViewBuilder
    private var titlebarControlsBar: some View {
        if !state.isSettingsPresented {
            let buttonTop = WindowChromeMetrics.titlebarRowCenter - TitlebarIconButton.size / 2
            GeometryReader { geo in
                let totalW = max(320, geo.size.width)
                let leadingX = controlsLeading
                let trailingReserve: CGFloat = 82
                // Compute responsive search pill width based on available center clearance
                let idealSearchW: CGFloat = min(230, max(136, (totalW - leadingX - trailingReserve) * 0.32))
                let expandedSearchW: CGFloat = min(310, max(240, (totalW - leadingX - trailingReserve) * 0.42))
                let activeSearchW: CGFloat = state.isPalettePresented ? expandedSearchW : idealSearchW
                let centerLeftEdge = (totalW - activeSearchW) * 0.5
                // Max space available for the leading controls + title before reaching the search pill
                let maxLeadingWidth = max(96, centerLeftEdge - leadingX - 12)

                ZStack(alignment: .topLeading) {
                    HStack(spacing: 6) {
                        TitlebarIconButton(
                            systemImage: "layout-align-left",
                            help: isSidebarVisible ? "Hide sidebar (⌃⌘S)" : "Show sidebar (⌃⌘S)",
                            isActive: isSidebarVisible
                        ) {
                            toggleSidebar()
                        }

                        if isSidebarVisible {
                            Color.clear
                                .frame(width: 5, height: 18)
                        }

                        HStack(spacing: 2) {
                            TitlebarIconButton(systemImage: "arrow-left-01", help: "Back", isEnabled: state.canGoBack) {
                                Task { await state.goBack() }
                            }
                            if state.canGoForward {
                                TitlebarIconButton(systemImage: "arrow-right-01", help: "Forward", isEnabled: state.canGoForward) {
                                    Task { await state.goForward() }
                                }
                            }
                        }

                        if state.phase == .ready, let controller = state.activeController {
                            titlebarTitle(controller)
                                .layoutPriority(-1)
                        }

                        Spacer(minLength: 0)
                    }
                    .frame(width: maxLeadingWidth, alignment: .leading)
                    .clipped()
                    .padding(.leading, leadingX)
                    .padding(.top, buttonTop)
                    .animation(.easeInOut(duration: 0.2), value: isSidebarVisible)
                    .animation(.easeOut(duration: 0.12), value: state.isPalettePresented)

                    if state.phase == .ready {
                        TitlebarSearchPill(
                            state: state,
                            width: activeSearchW,
                            onOpenPalette: openPalette,
                            onRunCommand: perform
                        )
                        .padding(.top, buttonTop)
                        .frame(width: totalW, alignment: .top)
                        .animation(.easeOut(duration: 0.12), value: state.isPalettePresented)
                        .zIndex(100)
                    }

                    if state.phase == .ready, state.activeController != nil {
                        HStack(spacing: 8) {
                            TitlebarNotificationsButton(state: state)

                            TitlebarIconButton(
                                systemImage: "layout-align-right",
                                help: state.isInspectorVisible ? "Hide floating panel (⌥⌘I)" : "Show floating panel (⌥⌘I)",
                                isActive: state.isInspectorVisible && !state.isNotificationsVisible
                            ) {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    state.toggleInspector()
                                }
                            }
                        }
                        .padding(.trailing, WindowChromeMetrics.cardInset + 8)
                        .padding(.top, buttonTop)
                        .frame(width: totalW, alignment: .topTrailing)
                    }
                }
            }
            .frame(height: WindowChromeMetrics.titlebarHeight)
        }
    }

    /// Where the titlebar controls start: when the sidebar is expanded, the
    /// sidebar toggle button sits on the trailing edge of the sidebar (just
    /// inside its right border), with the divider aligned to `cardInset + sidebarWidth`.
    private var controlsLeading: CGFloat {
        if isSidebarVisible {
            return WindowChromeMetrics.cardInset + sidebarWidth - TitlebarIconButton.size - 8
        }
        return WindowChromeMetrics.sidebarToggleLeading
    }

    /// The conversation's own title when it has one — its name, else the opening
    /// message the sidebar shows — and the project's name only before either exists.
    private func headerTitle(for controller: PiSessionController) -> String {
        if let name = controller.sessionName, !name.trimmingCharacters(in: .whitespaces).isEmpty {
            return name
        }
        if let session = fallbackDeletionCandidate, session.isNamed || session.firstUserMessage?.isEmpty == false {
            return session.displayName
        }
        return controller.projectName
    }

    private func titlebarTitle(_ controller: PiSessionController) -> some View {
        HStack(spacing: 7) {
            HugeIcon(name: "folder-02")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            Text(headerTitle(for: controller))
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.leading, 4)
        .allowsHitTesting(false)
    }

    // MARK: - Detail pane

    /// The conversation and the right inspector panel (`Overview` + `Muse Agent Messages`)
    /// sit side-by-side in their own columns so the right panel never overlaps the
    /// chat transcript or the composer box.
    private var detailPane: some View {
        HStack(alignment: .top, spacing: 0) {
            detail
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)

            if state.isInspectorVisible {
                HStack(alignment: .top, spacing: 0) {
                    SplitPaneResizeHandle(
                        width: 6,
                        hitInset: 0,
                        fill: Color.clear,
                        onChanged: { translation in
                            if inspectorWidthAtDragStart == nil {
                                inspectorWidthAtDragStart = inspectorWidth
                            }
                            let startingWidth = inspectorWidthAtDragStart ?? inspectorWidth
                            inspectorWidth = min(480, max(280, startingWidth - translation))
                        },
                        onEnded: {
                            inspectorWidthAtDragStart = nil
                        }
                    )

                    VStack(spacing: 0) {
                        let isLightInspector = AppTheme.isLightGlass(
                            colorScheme: colorScheme,
                            chatBackground: state.preferences.chatBackground
                        )
                        InspectorView(state: state)
                            .frame(width: inspectorWidth)
                            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .stroke(
                                        isLightInspector ? Color.white.opacity(0.84) : Color.white.opacity(0.22),
                                        lineWidth: 1
                                    )
                            )
                            .shadow(
                                color: isLightInspector
                                    ? Color(red: 0.08, green: 0.24, blue: 0.14).opacity(0.14)
                                    : .black.opacity(0.26),
                                radius: 14,
                                x: 0,
                                y: 6
                            )
                            .fixedSize(horizontal: false, vertical: state.inspectorArtifact == nil && !state.isNotificationsVisible)

                        if state.inspectorArtifact == nil && !state.isNotificationsVisible {
                            Spacer(minLength: 0)
                        }
                    }
                    .padding(.top, 10)
                    .padding(.trailing, 12)
                    .padding(.bottom, 12)
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .clipped()
        .background {
            GeometryReader { geo in
                MuseChatBackgroundView(style: state.preferences.chatBackground)
                    .onAppear {
                        if geo.size.width > 10 && geo.size.height > 10 {
                            detailPaneSize = geo.size
                        }
                    }
                    .onChange(of: geo.size) { _, newSize in
                        if newSize.width > 10 && newSize.height > 10 {
                            detailPaneSize = newSize
                        }
                    }
            }
        }
        .coordinateSpace(name: "picode-session-pane")
        .environment(\.sessionPaneSize, detailPaneSize)
        .environment(\.chatBackground, state.preferences.chatBackground)
        .environment(\.hasRootChatBackground, true)
        .environment(
            \.colorScheme,
            AppTheme.isLightGlass(colorScheme: colorScheme, chatBackground: state.preferences.chatBackground)
                ? .light
                : .dark
        )
        .animation(.easeInOut(duration: 0.22), value: state.isInspectorVisible)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var detail: some View {
        switch state.phase {
        case .starting:
            LaunchingView()
        case .needsPi:
            PiSetupView(state: state)
        case .ready:
            if let controller = state.activeController {
                VStack(spacing: 0) {
                    SessionView(state: state, controller: controller, composerFocusTick: composerFocusTick)
                    if state.isTerminalVisible {
                        TerminalPanel(state: state, controller: controller)
                    }
                }
            } else {
                WelcomeView(state: state)
            }
        }
    }

    /// The menu command (⌃⌘S) and the command palette share one toggle, so the
    /// two cannot disagree about which way the sidebar is going.
    ///
    /// Animated here rather than only on the card, so the titlebar — which is
    /// drawn over the window chrome, outside the card — moves with the sidebar:
    /// the title slides between its two leading positions and the column rule
    /// fades with the pane it belongs to.
    private func toggleSidebar() {
        withAnimation(.easeInOut(duration: 0.2)) {
            isSidebarVisible.toggle()
        }
    }

    // MARK: - Overlays

    @ViewBuilder
    private var toast: some View {
        if let toast = state.toast {
            Text(toast)
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().stroke(.separator))
                .padding(.bottom, 18)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    @ViewBuilder
    private var errorBanner: some View {
        if let message = state.errorBanner {
            BannerView(
                level: .error,
                title: "Something went wrong",
                message: message,
                onDismiss: { state.errorBanner = nil }
            )
            .padding(.top, 8)
            .frame(maxWidth: 620)
        }
    }

    // MARK: - Command dispatch

    private func perform(_ command: PaletteCommand) {
        let controller = state.activeController
        switch command {
        case .newSession:
            Task { await state.newChatInCurrentProject() }

        case .addProject:
            Task { await state.addProject() }

        case .cloneRepository:
            state.presentCloneRepository()

        case .newProjectFolder:
            state.presentCreateProjectFolder()

        case .refreshSessions:
            Task { await state.refreshIndex() }

        case .renameSession:
            guard let controller else { return }
            sheet = .rename(controller.sessionName ?? controller.displayTitle)

        case .exportSession:
            Task { await exportSession(controller) }

        case .deleteSession:
            guard let session = state.sessionPendingDeletion ?? fallbackDeletionCandidate else { return }
            state.sessionPendingDeletion = nil
            if state.preferences.confirmBeforeDeletingSessions {
                sheet = .delete(session)
            } else {
                state.delete(session: session)
            }

        case .focusComposer:
            composerFocusTick += 1

        case .interrupt:
            Task { await controller?.interrupt() }

        case .abortRun:
            Task { await controller?.abort() }

        case .cycleModel:
            Task { await controller?.cycleModel() }

        case .cycleThinkingLevel:
            Task { await controller?.cycleThinkingLevel() }

        case .toggleInspector:
            state.toggleInspector()

        case .toggleTerminal:
            state.toggleTerminal()

        case .toggleSidebar:
            toggleSidebar()

        case .copyTranscript:
            guard let controller else { return }
            state.copyToPasteboard(TranscriptExporter.plainText(controller.items))

        case .copyLastResponse:
            guard let controller else { return }
            if let text = controller.lastAssistantText, !text.isEmpty {
                state.copyToPasteboard(text)
            } else if let text = controller.items.last(where: { $0.kind == .assistant })?.text {
                state.copyToPasteboard(text)
            }

        case .openInTerminal:
            let path = controller?.projectPath ?? state.selectedProjectPath
            if let path { state.openTerminal(at: path) }

        case .openInVSCode:
            let path = controller?.projectPath ?? state.selectedProjectPath
            if let path { openProjectInVSCode(path) }

        case .revealInFinder:
            let path = controller?.projectPath ?? state.selectedProjectPath
            if let path { WorkspaceLauncher.reveal(path) }

        case .revealPiDirectory:
            let sessions = PiPaths.sessionsDirectory
            try? FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
            WorkspaceLauncher.reveal(PiPaths.agentDirectory.path)

        case .openSettings:
            state.openSettings(tab: state.settingsTab)

        case .showPiSetup:
            state.isOnboardingPresented = true

        case .checkForPiUpdates:
            Task {
                await state.launch()
                if let installation = state.installation {
                    state.showToast("Muse \(installation.version) at \(installation.displayPath)")
                }
            }
        }
    }

    /// The session a menu-driven delete applies to when no row was right-clicked.
    private var fallbackDeletionCandidate: SessionRef? {
        guard let sessionFile = state.activeController?.sessionFile else { return nil }
        return state.selectedProject?.sessions.first { $0.filePath == sessionFile }
    }

    /// Opens a project folder in VS Code (or a compatible fork), telling the user
    /// when no compatible editor is installed rather than failing silently — the
    /// workspace menu offers it as a one-click action, so a click that does
    /// nothing looks like a bug.
    private func openProjectInVSCode(_ path: String) {
        if !WorkspaceLauncher.openInVSCode(at: path) {
            state.showToast("Visual Studio Code isn't installed. Open the folder with another editor.")
        }
    }

    private func exportSession(_ controller: PiSessionController?) async {
        guard let controller else { return }
        let suggested = "\(controller.displayTitle.replacingOccurrences(of: "/", with: "-")).html"
        guard let path = WorkspaceLauncher.chooseSaveLocation(suggestedName: suggested, allowedType: "html") else { return }
        if let output = await controller.exportHTML(to: path) {
            state.showToast("Exported to \(output.abbreviatingHomeDirectory)")
        }
    }
}

/// Sheets that need a value or an action from the current session.
enum RootSheet: Identifiable {
    case palette
    case rename(String)
    case renameChat(SessionRef)
    case compact
    case fork
    case delete(SessionRef)
    case projectSettings(ProjectGroup)
    case newProject(String)
    case cloneRepository
    case createProjectFolder

    var id: String {
        switch self {
        case .palette: return "palette"
        case .rename: return "rename"
        case .renameChat(let session): return "rename-\(session.id)"
        case .compact: return "compact"
        case .fork: return "fork"
        case .delete(let session): return "delete-\(session.id)"
        case .projectSettings(let project): return "project-settings-\(project.id)"
        case .newProject(let path): return "new-project-\(path)"
        case .cloneRepository: return "clone-repository"
        case .createProjectFolder: return "create-project-folder"
        }
    }
}

/// Stateful split-pane resize divider that tracks both hover and active drag state
/// so the `resizeLeftRight` cursor never gets stuck on the global `NSCursor` stack
/// when a pane collapses or when the pointer slips off the divider mid-drag.
struct SplitPaneResizeHandle: View {
    var width: CGFloat
    var hitInset: CGFloat
    var fill: Color
    var onChanged: (CGFloat) -> Void
    var onEnded: () -> Void

    @State private var isHovering = false
    @State private var isDragging = false
    @State private var hasPushedCursor = false

    var body: some View {
        Rectangle()
            .fill(fill)
            .frame(width: width)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle().inset(by: hitInset))
            .onHover { inside in
                isHovering = inside
                syncCursor()
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isDragging {
                            isDragging = true
                            syncCursor()
                        }
                        onChanged(value.translation.width)
                    }
                    .onEnded { _ in
                        isDragging = false
                        onEnded()
                        syncCursor()
                    }
            )
            .onDisappear {
                isHovering = false
                isDragging = false
                if hasPushedCursor {
                    hasPushedCursor = false
                    NSCursor.pop()
                }
            }
    }

    private func syncCursor() {
        let shouldShowResize = isHovering || isDragging
        if shouldShowResize && !hasPushedCursor {
            hasPushedCursor = true
            NSCursor.resizeLeftRight.push()
        } else if !shouldShowResize && hasPushedCursor {
            hasPushedCursor = false
            NSCursor.pop()
        }
    }
}

/// A plain glyph button for the titlebar band: dimmed until hovered, full ink
/// while its panel is open.
struct TitlebarIconButton: View {
    static let size: CGFloat = 26

    var systemImage: String
    var help: String
    var isActive: Bool = false
    var isEnabled: Bool = true
    var action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            // The rail's glyph size, so the titlebar's icons match the
            // outer left menu's.
            HugeIcon(name: systemImage, size: AppRailMetrics.iconSize)
                .frame(width: Self.size, height: Self.size)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHovering ? AppTheme.railSelection.opacity(0.6) : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.35)
        .foregroundStyle(isActive || isHovering ? Color.primary : Color.secondary)
        .onHover { isHovering = $0 && isEnabled }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The titlebar's notification toggle: the same chrome as `TitlebarIconButton`,
/// with an unread dot while notifications are waiting.
struct TitlebarNotificationsButton: View {
    @Bindable var state: AppState

    @State private var isHovering = false

    var body: some View {
        Button {
            state.toggleNotifications()
        } label: {
            HugeIcon(name: "notification-01", size: AppRailMetrics.iconSize)
                .frame(width: TitlebarIconButton.size, height: TitlebarIconButton.size)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isHovering ? AppTheme.railSelection.opacity(0.6) : .clear)
                )
                .overlay(alignment: .topTrailing) {
                    if state.unreadNotificationCount > 0 {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 6, height: 6)
                            .offset(x: -3, y: 3)
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .foregroundStyle(state.isShowingNotifications ? Color.primary : Color.secondary)
        .onHover { isHovering = $0 }
        .help(state.isShowingNotifications ? "Hide notifications" : "Show notifications")
        .accessibilityLabel(state.unreadNotificationCount > 0
            ? "Notifications, \(state.unreadNotificationCount) unread"
            : "Notifications")
    }
}

/// Centered Smart Search Bar Pill in the titlebar (`AOL Search History.jpg`).
/// - When idle (`!state.isPalettePresented`): compact search pill with `Search…` and `⇧⌘P`.
/// - When active (`state.isPalettePresented`): expands into an inline autocomplete search bar
///   with the Muse `M` glyph, inline highlighted completion suffix + top hit headline, and
///   keyboard navigation (`↑`, `↓`, `Tab`, `Return`, `Escape`) driving `TitlebarSearchDropdownView`.
struct TitlebarSearchPill: View {
    var state: AppState? = nil
    var width: CGFloat = 240
    var onOpenPalette: () -> Void
    var onRunCommand: ((PaletteCommand) -> Void)? = nil

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false
    @FocusState private var isSearchFieldFocused: Bool

    private var isActive: Bool {
        state?.isPalettePresented == true
    }

    private var inlineAutocomplete: MuseInlineAutocomplete? {
        guard let state, isActive else { return nil }
        let q = state.paletteQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }
        return MuseSearchSuggestionService.shared.inlineAutocomplete(
            for: state.paletteQuery,
            projects: state.projects,
            matchingSessions: state.paletteResults
        )
    }

    var body: some View {
        HStack(spacing: 7) {
            HugeIcon(name: "search-01", size: 13)
                .foregroundStyle(.secondary)
                .frame(width: 15, height: 15)

            if let state, isActive {
                @Bindable var bindableState = state
                ZStack(alignment: .leading) {
                    if let auto = inlineAutocomplete, !auto.displayHighlightText.isEmpty {
                        HStack(spacing: 0) {
                            Text(bindableState.paletteQuery)
                                .font(.system(size: 13, weight: .regular))
                                .opacity(0)
                            Text(auto.displayHighlightText)
                                .font(.system(size: 12.5, weight: .regular))
                                .foregroundStyle(Color.secondary)
                                .lineLimit(1)
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(
                                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                                        .fill(Color.primary.opacity(0.08))
                                )
                            Spacer(minLength: 0)
                        }
                        .allowsHitTesting(false)
                    }

                    TextField("Search sessions, projects, or commands…", text: $bindableState.paletteQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(Color.primary)
                        .focused($isSearchFieldFocused)
                        .onChange(of: bindableState.paletteQuery) { _, _ in
                            if !state.isPalettePresented {
                                withAnimation(.spring(response: 0.24, dampingFraction: 0.86)) {
                                    state.isPalettePresented = true
                                }
                            }
                            state.updatePaletteQuery()
                        }
                        .onSubmit {
                            let dropdown = TitlebarSearchDropdownView(
                                state: state,
                                onRunCommand: { cmd in onRunCommand?(cmd) }
                            )
                            dropdown.activateCurrentlySelected()
                        }
                        .onMoveCommand { direction in
                            let dropdown = TitlebarSearchDropdownView(
                                state: state,
                                onRunCommand: { cmd in onRunCommand?(cmd) }
                            )
                            let count = dropdown.selectableRowIDs.count
                            guard count > 0 else { return }
                            switch direction {
                            case .down:
                                state.paletteSelectedIndex = (state.paletteSelectedIndex + 1) % count
                            case .up:
                                state.paletteSelectedIndex = (state.paletteSelectedIndex - 1 + count) % count
                            case .right:
                                if let auto = inlineAutocomplete, !auto.fullCompletionText.isEmpty {
                                    state.paletteQuery = auto.fullCompletionText
                                    state.updatePaletteQuery()
                                }
                            default:
                                break
                            }
                        }
                        .onExitCommand {
                            state.closePalette()
                        }
                        .onAppear {
                            isSearchFieldFocused = true
                        }
                }

                if !bindableState.paletteQuery.isEmpty {
                    Button {
                        state.paletteQuery = ""
                        state.updatePaletteQuery()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.secondary.opacity(0.75))
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Button(action: onOpenPalette) {
                    HStack(spacing: 6) {
                        Text("Search…")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        if width >= 170 {
                            Text("⇧⌘P")
                                .font(.system(size: 10.5, weight: .medium, design: .rounded))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .help("Search sessions, projects, and commands (⇧⌘P)")
                .accessibilityLabel("Search")
            }
        }
        .padding(.horizontal, 12)
        .frame(width: width, height: TitlebarIconButton.size)
        .background(
            Capsule(style: .continuous)
                .fill(
                    isActive
                        ? (colorScheme == .dark ? Color(white: 0.17, opacity: 0.96) : Color(white: 0.98, opacity: 0.96))
                        : (isHovering ? AppTheme.railSelection.opacity(0.65) : AppTheme.railSelection.opacity(0.32))
                )
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(
                    Color.primary.opacity(isActive ? 0.26 : (isHovering ? 0.34 : 0.20)),
                    lineWidth: 1
                )
        )
        .shadow(color: .black.opacity(isActive ? 0.12 : 0.0), radius: 6, x: 0, y: 2)
        .contentShape(Capsule())
        .onTapGesture {
            if !isActive {
                onOpenPalette()
            }
        }
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: width)
        .animation(.easeOut(duration: 0.12), value: isActive)
        .onChange(of: isActive) { _, active in
            isSearchFieldFocused = active
        }
    }
}
