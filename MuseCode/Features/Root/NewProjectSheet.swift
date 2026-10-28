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
