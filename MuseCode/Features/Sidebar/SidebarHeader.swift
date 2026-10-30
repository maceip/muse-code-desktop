//
//  SidebarHeader.swift
//  PiCode
//
//  The sidebar's title line: the harness new chats run on, as a menu, then
//  search on the trailing edge.
//

import SwiftUI

struct SidebarHeader: View {
    @Bindable var state: AppState
    var onOpenPalette: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            harnessMenu
            Spacer(minLength: 0)
            headerButton("search-01", help: "Search sessions and commands (⇧⌘P)", action: onOpenPalette)
        }
        .padding(.leading, SidebarStyle.trafficLightColumn - 2)
        .padding(.trailing, SidebarStyle.sidebarMargin)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }

    /// Muse title in the sidebar header — clicking starts a new empty chat session.
    private var harnessMenu: some View {
        Button {
            state.isSettingsPresented = false
            Task { await state.newChatInCurrentProject() }
        } label: {
            Text(state.activeHarness.displayName)
                .font(.system(size: 17, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 160, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help("Muse Code — New empty chat session (⌘N)")
    }

    private func headerButton(_ systemImage: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HugeIcon(name: systemImage)
                .font(.system(size: 14, weight: .regular))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
        .accessibilityLabel(help)
    }
}
