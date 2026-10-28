//
//  AppRail.swift
//  MuseCode
//
//  The narrow icon rail on the window's leading edge when the sidebar is collapsed:
//  - Top: Muse app icon (replaces the + and search buttons in rail mode)
//  - Middle: Session tiles with a customizable icon from `Assets.xcassets/SessionIcons`
//    and a 4–5 character shorthand string
//  - Bottom: Settings gear button (no ellipsis menu)
//

import AppKit
import SwiftUI

enum AppRailMetrics {
    static let width: CGFloat = 56
    static let buttonSize: CGFloat = 40
    static let iconSize: CGFloat = 17
}

struct AppRail: View {
    @Bindable var state: AppState
    var onOpenPalette: () -> Void
    var onOpenSettings: () -> Void

    /// Recent sessions across all projects so the collapsed rail shows clickable
    /// session icons + 4–5 char shorthands when the sidepanel is hidden.
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
            MuseAppRailHeaderButton {
                state.isSettingsPresented = false
                Task { await state.newChatInCurrentProject() }
            }

            Rectangle()
                .fill(AppTheme.cardStroke)
                .frame(width: 24, height: 1)
                .padding(.vertical, 2)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 6) {
                    ForEach(railSessions) { session in
                        SessionRailButton(
                            state: state,
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
        .padding(.top, 4)
        .frame(width: AppRailMetrics.width)
        .frame(maxHeight: .infinity)
    }
}

/// Top brand icon in `AppRail` mode (replaces the old `+` and `Search` buttons).
struct MuseAppRailHeaderButton: View {
    var action: () -> Void
    @State private var isHovering = false

    private var appIconImage: NSImage {
        if let icon = NSApp.applicationIconImage, icon.size.width > 0 {
            return icon
        }
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let iconURL = repoRoot
            .appendingPathComponent("Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png")
        if let diskIcon = NSImage(contentsOf: iconURL) {
            return diskIcon
        }
        return NSImage()
    }

    var body: some View {
        Button(action: action) {
            Image(nsImage: appIconImage)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .frame(width: 36, height: 36)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .scaleEffect(isHovering ? 1.04 : 1.0)
                .animation(.easeOut(duration: 0.14), value: isHovering)
                .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onHover { isHovering = $0 }
        .help("Muse — New chat (⌘N)")
        .accessibilityLabel("Muse")
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
            .focusEffectDisabled()
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
        .focusEffectDisabled()
        .opacity(isEnabled ? 1 : 0.45)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A session tile in the collapsed `AppRail`: renders the session's icon from
/// `Assets.xcassets/SessionIcons` and a 4–5 character shorthand string, with an
/// interactive popover & context menu so the user can pick any icon from the set
/// or customize the 4–5 character shorthand.
struct SessionRailButton: View {
    @Bindable var state: AppState
    var session: SessionRef
    var isSelected: Bool
    var isRunning: Bool
    var action: () -> Void

    @State private var isHovering = false
    @State private var isCustomizePopoverPresented = false

    private var iconName: String {
        state.preferences.resolvedSessionIcon(for: session)
    }

    private var shorthand: String {
        state.preferences.resolvedSessionShorthand(for: session)
    }

    var body: some View {
        Button(action: action) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if isRunning {
                        ProgressView().controlSize(.small)
                    } else {
                        VStack(spacing: 2) {
                            HugeIcon(name: iconName, size: 15)
                            Text(shorthand)
                                .font(.system(size: 8.5, weight: .bold, design: .rounded).monospaced())
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)
                                .padding(.horizontal, 2)
                        }
                    }
                }
                .foregroundStyle(isSelected ? Color.white : (isHovering ? Color.primary : Color.secondary))
                .frame(width: 44, height: AppRailMetrics.buttonSize)
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
        .focusEffectDisabled()
        .onHover { isHovering = $0 }
        .help("\(session.displayName) (\(shorthand)) — Right-click to change icon or shorthand")
        .accessibilityLabel("Session: \(session.displayName) (\(shorthand))")
        .contextMenu {
            Button {
                isCustomizePopoverPresented = true
            } label: {
                Label("Choose Icon & Shorthand…", huge: iconName)
            }

            Menu("Quick Icon") {
                ForEach(SessionIconCatalog.all) { entry in
                    Button {
                        state.preferences.setSessionIcon(entry.id, for: session)
                    } label: {
                        Label(entry.label, huge: entry.id)
                    }
                }
            }

            Divider()

            SessionRowMenu(state: state, session: session, isEphemeral: session.isEphemeral)
        }
        .popover(isPresented: $isCustomizePopoverPresented, arrowEdge: .trailing) {
            SessionBadgePickerPopover(
                state: state,
                session: session,
                isPresented: $isCustomizePopoverPresented
            )
        }
    }
}

/// Interactive popover allowing the user to pick a session icon from
/// `Assets.xcassets/SessionIcons` and customize the 4–5 character shorthand string.
struct SessionBadgePickerPopover: View {
    @Bindable var state: AppState
    var session: SessionRef
    @Binding var isPresented: Bool

    @State private var shorthandDraft: String = ""

    private var selectedIcon: String {
        state.preferences.resolvedSessionIcon(for: session)
    }

    private let columns = Array(repeating: GridItem(.fixed(42), spacing: 8), count: 4)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Session Icon & Shorthand")
                    .font(.system(size: 12.5, weight: .semibold))
                Spacer()
                Button("Reset") {
                    state.preferences.setSessionIcon(nil, for: session)
                    state.preferences.setSessionShorthand(nil, for: session)
                    shorthandDraft = state.preferences.resolvedSessionShorthand(for: session)
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Shorthand (4–5 chars)")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    TextField("4–5 chars", text: $shorthandDraft)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .onChange(of: shorthandDraft) { _, newValue in
                            let cleaned = String(newValue.uppercased().filter { $0.isLetter || $0.isNumber }.prefix(5))
                            if cleaned != newValue {
                                shorthandDraft = cleaned
                            }
                            state.preferences.setSessionShorthand(cleaned, for: session)
                        }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Icon Set")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)

                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(SessionIconCatalog.all) { entry in
                        let isSelected = selectedIcon == entry.id
                        Button {
                            state.preferences.setSessionIcon(entry.id, for: session)
                        } label: {
                            VStack(spacing: 2) {
                                HugeIcon(name: entry.id, size: 17)
                            }
                            .foregroundStyle(isSelected ? Color.white : Color.primary)
                            .frame(width: 40, height: 36)
                            .background(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(isSelected ? AppTheme.accentBlue : AppTheme.railSelection.opacity(0.35))
                            )
                            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                        }
                        .buttonStyle(.plain)
                        .help(entry.label)
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 220)
        .onAppear {
            shorthandDraft = state.preferences.resolvedSessionShorthand(for: session)
        }
    }
}
