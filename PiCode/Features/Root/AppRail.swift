//
//  AppRail.swift
//  PiCode
//
//  The narrow icon rail on the window's leading edge: the app's destinations
//  (home, history, packages, more), and the user's own badge at the bottom,
//  which opens Settings.
//
//  It is drawn on the window chrome rather than inside the content card, so it
//  reads as the window's frame and stays put when the sidebar folds away.
//

import SwiftUI

enum AppRailMetrics {
    static let width: CGFloat = 52
    static let buttonSize: CGFloat = 36
    static let iconSize: CGFloat = 17
}

struct AppRail: View {
    @Bindable var state: AppState
    var onOpenPalette: () -> Void
    var onOpenSettings: () -> Void

    /// Recent sessions across all projects so the collapsed rail shows clickable
    /// icons for sessions when the sidepanel is hidden.
    private var railSessions: [SessionRef] {
        var result: [SessionRef] = []
        if let controller = state.activeController,
           controller.sessionFile == nil,
           let key = state.selectedSessionKey,
           key.hasPrefix("new:") {
            result.append(SessionRef(
                id: controller.draftKey,
                sessionId: controller.sessionId,
                filePath: nil,
                name: controller.sessionName ?? controller.projectName,
                cwd: controller.projectPath,
                createdAt: Date(),
                updatedAt: Date(),
                messageCount: controller.items.count,
                firstUserMessage: controller.items.first(where: { $0.kind == .user })?.text,
                parentSession: nil,
                isPinned: false,
                isEphemeral: true,
                harnessID: controller.harness.id
            ))
        }
        let persisted = state.projects
            .flatMap(\.sessions)
            .sorted { lhs, rhs in
                if lhs.isPinned != rhs.isPinned { return lhs.isPinned }
                return lhs.updatedAt > rhs.updatedAt
            }
        result.append(contentsOf: persisted.prefix(12))
        return result
    }

    var body: some View {
        VStack(spacing: 8) {
            RailButton(
                systemImage: "add-01",
                help: "New chat (⌘N)",
                isSelected: false
            ) {
                state.isSettingsPresented = false
                Task { await state.newChatInCurrentProject() }
            }

            RailButton(
                systemImage: "search-01",
                help: "Search sessions and commands (⇧⌘P)",
                isSelected: false,
                action: onOpenPalette
            )

            Rectangle()
                .fill(AppTheme.cardStroke)
                .frame(width: 22, height: 1)
                .padding(.vertical, 2)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 6) {
                    ForEach(railSessions) { session in
                        SessionRailButton(
                            session: session,
                            isSelected: !state.isSettingsPresented && state.selectedSessionKey == session.controllerKey,
                            isRunning: state.isRunning(session)
                        ) {
                            state.isSettingsPresented = false
                            Task { await state.open(session: session) }
                        }
                    }
                }
                .padding(.vertical, 2)
            }

            Spacer(minLength: 0)

            moreMenu

            UpdateButton(updater: state.updater)

            RailButton(
                systemImage: "settings-02",
                help: state.isUpdatingAnything ? "Settings — updating…" : "Settings",
                isSelected: state.isSettingsPresented,
                isLoading: state.isUpdatingAnything,
                action: onOpenSettings
            )
            .padding(.bottom, 14)
        }
        .padding(.top, 2)
        .frame(width: AppRailMetrics.width)
        .frame(maxHeight: .infinity)
    }

    /// The commands that are about the app rather than about a chat.
    private var moreMenu: some View {
        Menu {
            Button(PaletteCommand.addProject.title) { state.run(.addProject) }
            Button(PaletteCommand.refreshSessions.title) { state.run(.refreshSessions) }
            Divider()
            Button(PaletteCommand.revealPiDirectory.title) { state.run(.revealPiDirectory) }
            Button(PaletteCommand.checkForPiUpdates.title) { state.run(.checkForPiUpdates) }
            Divider()
            Button("Settings…", action: onOpenSettings)
        } label: {
            // A menu's label is snapshotted as a template image, so the glyph is
            // wrapped in `Text` to survive it (see `ProjectRow`).
            Text(hugeIconImage("more-horizontal"))
                .font(.system(size: AppRailMetrics.iconSize, weight: .regular))
                .frame(width: AppRailMetrics.buttonSize, height: AppRailMetrics.buttonSize)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .foregroundStyle(.secondary)
        .help("More")
    }
}

/// Shown above Settings when a newer release exists: a white download glyph on a
/// blue circle. Click downloads, installs and relaunches.
struct UpdateButton: View {
    var updater: AppUpdater

    var body: some View {
        if let release = updater.release {
            Button(action: updater.install) {
                ZStack {
                    Circle().fill(Color.blue)
                    switch updater.state {
                    case .downloading(_, let progress):
                        Circle()
                            .trim(from: 0, to: max(progress, 0.03))
                            .stroke(Color.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .frame(width: 18, height: 18)
                    case .installing:
                        ProgressView().controlSize(.small).colorScheme(.dark)
                    default:
                        HugeIcon(name: "arrow-down-01", size: AppRailMetrics.iconSize)
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: AppRailMetrics.buttonSize, height: AppRailMetrics.buttonSize)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(updater.isBusy)
            .padding(.bottom, 8)
            .help(helpText(release))
            .accessibilityLabel("Update to \(release.version)")
        }
    }

    private func helpText(_ release: AppUpdater.Release) -> String {
        switch updater.state {
        case .downloading(_, let p): "Downloading \(release.version)… \(Int(p * 100))%"
        case .installing: "Installing \(release.version)…"
        case .failed(_, let message): "Update failed: \(message). Click to retry."
        default: "Update to \(release.version) — click to install and restart"
        }
    }
}

/// One rail destination: a glyph in a rounded square that fills when selected
/// and on hover.
struct RailButton: View {
    var systemImage: String
    var help: String
    var isSelected: Bool
    /// Swaps the glyph for a spinner while background work runs.
    var isLoading = false
    var action: () -> Void

    @State private var isHovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Group {
                if isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    HugeIcon(name: systemImage, size: AppRailMetrics.iconSize)
                }
            }
                .foregroundStyle(isSelected ? Color.primary : Color.secondary)
                .frame(width: AppRailMetrics.buttonSize, height: AppRailMetrics.buttonSize)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(isSelected ? AppTheme.railSelection
                              : (isHovering && isEnabled ? AppTheme.railSelection.opacity(0.6) : .clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A session icon in the collapsed AppRail when the sidebar is hidden.
struct SessionRailButton: View {
    var session: SessionRef
    var isSelected: Bool
    var isRunning: Bool
    var action: () -> Void

    @State private var isHovering = false

    private var badgeInitials: String {
        let raw = session.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = raw
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        if words.count >= 2,
           let first = words[0].first,
           let second = words[1].first {
            return String([first, second]).uppercased()
        }
        let prefix = String(raw.prefix(2)).uppercased()
        return prefix.isEmpty ? "M" : prefix
    }

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if isRunning {
                        ProgressView().controlSize(.small)
                    } else {
                        VStack(spacing: 1) {
                            HugeIcon(name: session.isPinned ? "bookmark-02" : "message-multiple-01", size: 14)
                            Text(badgeInitials)
                                .font(.system(size: 8.5, weight: .semibold, design: .rounded))
                                .lineLimit(1)
                        }
                    }
                }
                .foregroundStyle(isSelected ? Color.white : (isHovering ? Color.primary : Color.secondary))
                .frame(width: AppRailMetrics.buttonSize, height: AppRailMetrics.buttonSize)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(isSelected ? AppTheme.accentBlue
                              : (isHovering ? AppTheme.railSelection.opacity(0.65) : AppTheme.railSelection.opacity(0.22)))
                )

                if isRunning {
                    Circle()
                        .fill(AppTheme.accentBlue)
                        .frame(width: 7, height: 7)
                        .offset(x: -2, y: -2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(session.displayName)
        .accessibilityLabel("Session: \(session.displayName)")
    }
}
