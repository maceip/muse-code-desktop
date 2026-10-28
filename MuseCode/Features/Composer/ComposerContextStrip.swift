//
//  ComposerContextStrip.swift
//  PiCode
//
//  The strip tucked behind the top of an empty chat's composer: where the
//  prompt will run — the project folder and the git branch. Both are dropdowns.
//  (A "Local / cloud" chip belongs here once there is a cloud to pick.)
//

import SwiftUI

struct ComposerContextStrip: View {
    @Bindable var state: AppState
    var controller: PiSessionController

    @State private var showsProjects = false
    @State private var showsBranches = false
    @State private var branches: [String] = []

    var isGlassSurface: Bool = true

    var body: some View {
        HStack(spacing: 20) {
            chip("folder-02", controller.projectName, help: controller.projectPath.abbreviatingHomeDirectory) {
                showsProjects.toggle()
            }
            .popover(isPresented: $showsProjects, arrowEdge: .top) { projectPicker }

            if controller.git.isRepository, let branch = controller.git.branch {
                chip("git-branch", branch, help: "Current git branch") {
                    showsBranches.toggle()
                }
                .popover(isPresented: $showsBranches, arrowEdge: .top) { branchPicker(current: branch) }
            }
        }
        .frame(height: 28)
    }

    // MARK: - Projects

    /// Folders that already have a chat on this chat's harness, plus the folder
    /// the chat is in.
    private var projectItems: [ContextPickerItem] {
        let harnessID = controller.harness.id
        let current = CanonicalPath.of(controller.projectPath)
        return state.projects
            .filter { $0.path == current || $0.sessions.contains { $0.harnessID == harnessID } }
            .map { ContextPickerItem(id: $0.path, title: $0.name, systemImage: "folder-02",
                                     isSelected: $0.path == current) }
    }

    private var projectPicker: some View {
        ContextPickerPopover(
            searchPrompt: "Search projects",
            heading: nil,
            items: projectItems,
            actions: [ContextPickerAction(title: "New project", systemImage: "add-01") {
                Task { await state.addProject() }
            }],
            onSelect: { item in
                guard item.id != CanonicalPath.of(controller.projectPath) else { return }
                Task { await state.startNewSession(projectPath: item.id, harnessOverride: controller.harness) }
            },
            onDismiss: { showsProjects = false }
        )
    }

    // MARK: - Branches

    private func branchPicker(current: String) -> some View {
        let dirty = controller.git.changes.count
        let items = branches.map { name in
            ContextPickerItem(
                id: name, title: name,
                subtitle: name == current && dirty > 0 ? "Uncommitted: \(dirty) file\(dirty == 1 ? "" : "s")" : nil,
                systemImage: "git-branch",
                isSelected: name == current)
        }
        return ContextPickerPopover(
            searchPrompt: "Search \(controller.projectName) branches",
            heading: "Branches",
            items: items,
            onSelect: { item in
                guard item.id != current else { return }
                Task {
                    if let error = await controller.switchBranch(to: item.id) {
                        state.present(error: "Could not switch to \(item.id): \(error)")
                    }
                }
            },
            onDismiss: { showsBranches = false }
        )
        .task { branches = await controller.branches() }
    }

    private func chip(_ systemImage: String, _ title: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                HugeIcon(name: systemImage, size: 15)
                    .foregroundStyle(isGlassSurface ? Color.white.opacity(0.82) : Color.secondary)
                Text(title)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(isGlassSurface ? Color.white.opacity(0.95) : Color.primary.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(help)
    }
}
