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
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.chatBackground) private var chatBackground

    var isGlassSurface: Bool = true

    private var isLightGlass: Bool {
        AppTheme.isLightGlass(colorScheme: colorScheme, chatBackground: chatBackground)
    }

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

    /// All registered project folders plus the current chat's folder, so newly added
    /// or cloned folders with zero sessions are always selectable in the dropdown.
    private var projectItems: [ContextPickerItem] {
        let current = CanonicalPath.of(controller.projectPath)
        var seen: Set<String> = []
        var items: [ContextPickerItem] = []

        for project in state.projects {
            let path = CanonicalPath.of(project.path)
            guard !seen.contains(path) else { continue }
            seen.insert(path)
            items.append(
                ContextPickerItem(
                    id: path,
                    title: project.name,
                    subtitle: path.abbreviatingHomeDirectory,
                    systemImage: "folder-02",
                    isSelected: path == current
                )
            )
        }

        if !seen.contains(current) {
            items.insert(
                ContextPickerItem(
                    id: current,
                    title: controller.projectName,
                    subtitle: current.abbreviatingHomeDirectory,
                    systemImage: "folder-02",
                    isSelected: true
                ),
                at: 0
            )
        }
        return items
    }

    private var projectPicker: some View {
        ContextPickerPopover(
            searchPrompt: "Search projects",
            heading: "Projects",
            items: projectItems,
            actions: [
                ContextPickerAction(title: "Open Folder…", systemImage: "folder-add") {
                    Task { await state.addProject() }
                },
                ContextPickerAction(title: "Clone Git Repository…", systemImage: "git-branch") {
                    state.presentCloneRepository()
                },
                ContextPickerAction(title: "New Project Folder…", systemImage: "add-01") {
                    state.presentCreateProjectFolder()
                }
            ],
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
                    .foregroundStyle(isGlassSurface ? AppTheme.glassSecondaryText(isLight: isLightGlass) : Color.secondary)
                Text(title)
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(isGlassSurface ? AppTheme.glassPrimaryText(isLight: isLightGlass) : Color.primary.opacity(0.85))
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
