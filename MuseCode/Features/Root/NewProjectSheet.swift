//
//  NewProjectSheet.swift
//  PiCode
//
//  The harness / provider / model chooser shown when a project is opened for the
//  first time. The choice is stored per project, so a repo can run on Pi while
//  another runs on a different harness.
//

import SwiftUI

struct NewProjectSheet: View {
    @Bindable var state: AppState
    var path: String
    var onDone: () -> Void

    @State private var model: String
    @State private var modelText: String

    init(state: AppState, path: String, onDone: @escaping () -> Void) {
        self.state = state
        self.path = path
        self.onDone = onDone
        let settings = state.preferences.projectSettings(for: CanonicalPath.of(path))
        _model = State(initialValue: settings.modelID ?? "")
        _modelText = State(initialValue: settings.modelID ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            Form {
                Section("Project") {
                    LabeledContent("Folder") {
                        Text(path.abbreviatingHomeDirectory)
                            .font(.caption.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }

                Section("Model") {
                    if !modelOptions.isEmpty {
                        LabeledContent("Model") {
                            Dropdown(
                                selection: $model,
                                options: [.init(label: "Muse's default", value: "")]
                                    + modelOptions.map { .init(label: $0, value: $0) }
                            )
                        }
                    } else {
                        TextField("Model", text: $modelText, prompt: Text("meta/muse-wonder-full-1.0"))
                            .font(.system(.caption, design: .monospaced))
                        Text("Leave blank to use Muse's default model and switch models in the composer.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onDone() }
                    .buttonStyle(.settingsPill)
                Button("Create Chat") { create() }
                    .buttonStyle(.settingsPillProminent)
            }
            .padding(12)
        }
        .frame(width: 480, height: 320)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("New project")
                .font(.headline)
            Text("Configure how Muse runs in this folder.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }

    private var modelOptions: [String] {
        guard let controller = state.activeController else { return [] }
        return controller.availableModels.map(\.qualifiedID).sorted()
    }

    private func create() {
        let descriptor = state.activeHarness
        let chosenModel: String?
        if !model.isEmpty {
            chosenModel = model
        } else if !modelText.trimmingCharacters(in: .whitespaces).isEmpty {
            chosenModel = modelText.trimmingCharacters(in: .whitespaces)
        } else {
            chosenModel = nil
        }
        Task {
            await state.createProject(
                path: path,
                harness: descriptor,
                provider: nil,
                model: chosenModel
            )
            onDone()
        }
    }
}

/// Sheet for cloning a remote or local Git repository into a new project folder and opening a chat in it.
struct CloneRepositorySheet: View {
    @Bindable var state: AppState
    var onDone: () -> Void

    @State private var repositoryURL = ""
    @State private var parentDirectory: String
    @State private var folderName = ""
    @State private var folderNameManuallyEdited = false
    @State private var branch = ""
    @State private var isCloning = false
    @State private var errorMessage: String?

    init(state: AppState, onDone: @escaping () -> Void) {
        self.state = state
        self.onDone = onDone
        let defaultParent: String
        if let current = state.activeController?.projectPath ?? state.selectedProjectPath,
           current != CanonicalPath.of(NSHomeDirectory()) {
            defaultParent = (current as NSString).deletingLastPathComponent
        } else {
            let docs = (NSHomeDirectory() as NSString).appendingPathComponent("Documents")
            defaultParent = FileManager.default.fileExists(atPath: docs) ? docs : NSHomeDirectory()
        }
        _parentDirectory = State(initialValue: defaultParent)
    }

    private var destinationPreview: String {
        let cleanFolder = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanFolder.isEmpty else { return parentDirectory.abbreviatingHomeDirectory }
        return ((parentDirectory as NSString).appendingPathComponent(cleanFolder)).abbreviatingHomeDirectory
    }

    private var canClone: Bool {
        !isCloning
            && !repositoryURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !parentDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Clone Git Repository")
                    .font(.headline)
                Text("Clone a repository into a folder and start a Muse session in it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .help("Clone Git Repository")
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Clone Git Repository")

            Divider()

            Form {
                Section("Repository") {
                    TextField(
                        "Repository URL",
                        text: $repositoryURL,
                        prompt: Text("https://github.com/owner/repo.git or owner/repo")
                    )
                    .font(.system(.body, design: .monospaced))
                    .onChange(of: repositoryURL) { _, newValue in
                        errorMessage = nil
                        if !folderNameManuallyEdited {
                            folderName = GitStatusService.suggestedFolderName(from: newValue)
                        }
                    }

                    TextField(
                        "Branch (optional)",
                        text: $branch,
                        prompt: Text("Default branch")
                    )
                    .font(.system(.caption, design: .monospaced))
                }

                Section("Destination") {
                    LabeledContent("Parent Folder") {
                        HStack(spacing: 8) {
                            Text(parentDirectory.abbreviatingHomeDirectory)
                                .font(.caption.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button("Choose…") {
                                if let chosen = WorkspaceLauncher.chooseDirectory(prompt: "Choose Parent Folder") {
                                    parentDirectory = chosen
                                    errorMessage = nil
                                }
                            }
                            .controlSize(.small)
                        }
                    }

                    TextField(
                        "Folder Name",
                        text: $folderName,
                        prompt: Text("my-project")
                    )
                    .font(.system(.body, design: .monospaced))
                    .onChange(of: folderName) { _, newValue in
                        errorMessage = nil
                        let suggested = GitStatusService.suggestedFolderName(from: repositoryURL)
                        if !newValue.isEmpty && newValue != suggested {
                            folderNameManuallyEdited = true
                        } else if newValue.isEmpty {
                            folderNameManuallyEdited = false
                        }
                    }

                    LabeledContent("Path") {
                        Text(destinationPreview)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(isCloning)

            Divider()

            HStack(spacing: 10) {
                if isCloning {
                    ProgressView()
                        .controlSize(.small)
                    Text("Cloning repository…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", role: .cancel) {
                    onDone()
                }
                .buttonStyle(.settingsPill)
                .disabled(isCloning)

                Button("Clone & Open") {
                    performClone()
                }
                .buttonStyle(.settingsPillProminent)
                .disabled(!canClone)
                .help("Clone & Open")
                .accessibilityLabel("Clone & Open")
            }
            .padding(12)
        }
        .frame(width: 500, height: 390)
    }

    private func performClone() {
        guard canClone else { return }
        isCloning = true
        errorMessage = nil
        Task {
            let result = await state.cloneAndOpenRepository(
                url: repositoryURL,
                parentDirectory: parentDirectory,
                folderName: folderName,
                branch: branch
            )
            isCloning = false
            switch result {
            case .success:
                onDone()
            case .failure(let err):
                errorMessage = err.message
            }
        }
    }
}

/// Sheet for creating a new project directory (optionally running `git init`) and opening a chat in it.
struct CreateProjectFolderSheet: View {
    @Bindable var state: AppState
    var onDone: () -> Void

    @State private var parentDirectory: String
    @State private var folderName = ""
    @State private var initializeGit = true
    @State private var isCreating = false
    @State private var errorMessage: String?

    init(state: AppState, onDone: @escaping () -> Void) {
        self.state = state
        self.onDone = onDone
        let defaultParent: String
        if let current = state.activeController?.projectPath ?? state.selectedProjectPath,
           current != CanonicalPath.of(NSHomeDirectory()) {
            defaultParent = (current as NSString).deletingLastPathComponent
        } else {
            let docs = (NSHomeDirectory() as NSString).appendingPathComponent("Documents")
            defaultParent = FileManager.default.fileExists(atPath: docs) ? docs : NSHomeDirectory()
        }
        _parentDirectory = State(initialValue: defaultParent)
    }

    private var destinationPreview: String {
        let cleanFolder = folderName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanFolder.isEmpty else { return parentDirectory.abbreviatingHomeDirectory }
        return ((parentDirectory as NSString).appendingPathComponent(cleanFolder)).abbreviatingHomeDirectory
    }

    private var canCreate: Bool {
        !isCreating
            && !folderName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !folderName.contains("/")
            && !parentDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("New Project Folder")
                    .font(.headline)
                Text("Create a new folder and start a Muse session in it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .help("New Project Folder")
            .accessibilityElement(children: .combine)
            .accessibilityLabel("New Project Folder")

            Divider()

            Form {
                Section("Location") {
                    LabeledContent("Parent Folder") {
                        HStack(spacing: 8) {
                            Text(parentDirectory.abbreviatingHomeDirectory)
                                .font(.caption.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button("Choose…") {
                                if let chosen = WorkspaceLauncher.chooseDirectory(prompt: "Choose Parent Folder") {
                                    parentDirectory = chosen
                                    errorMessage = nil
                                }
                            }
                            .controlSize(.small)
                        }
                    }

                    TextField("Folder Name", text: $folderName, prompt: Text("my-new-project"))
                        .font(.system(.body, design: .monospaced))
                        .onChange(of: folderName) { _, _ in errorMessage = nil }

                    LabeledContent("Path") {
                        Text(destinationPreview)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }

                Section("Git") {
                    Toggle("Initialize Git repository (git init)", isOn: $initializeGit)
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .formStyle(.grouped)
            .disabled(isCreating)

            Divider()

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { onDone() }
                    .buttonStyle(.settingsPill)
                    .disabled(isCreating)

                Button("Create & Open") {
                    performCreate()
                }
                .buttonStyle(.settingsPillProminent)
                .disabled(!canCreate)
                .help("Create & Open")
                .accessibilityLabel("Create & Open")
            }
            .padding(12)
        }
        .frame(width: 480, height: 340)
    }

    private func performCreate() {
        guard canCreate else { return }
        isCreating = true
        errorMessage = nil
        Task {
            let result = await state.createNewProjectFolder(
                parentDirectory: parentDirectory,
                folderName: folderName,
                initializeGit: initializeGit
            )
            isCreating = false
            switch result {
            case .success:
                onDone()
            case .failure(let err):
                errorMessage = err.message
            }
        }
    }
}
