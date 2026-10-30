//
//  SetupViews.swift
//  PiCode
//
//  Launch-state and Muse CLI setup screens.
//

import SwiftUI

struct LaunchingView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
                .controlSize(.regular)
            Text("Starting Muse…")
                .font(.headline)
            Text("Resolving your Muse CLI installation and indexing existing sessions.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct WelcomeView: View {
    @Bindable var state: AppState

    var body: some View {
        VStack(spacing: 22) {
            BuildPromptHero(projectName: state.selectedProject?.name)
            Button(state.selectedProject == nil ? "Open a project folder" : "New chat") {
                if let project = state.selectedProject?.path {
                    Task { await state.startNewSession(projectPath: project) }
                } else {
                    Task { await state.addProject() }
                }
            }
            .buttonStyle(.settingsPillProminent)
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            guard state.selectedSessionKey == nil, let path = state.landingProjectPath else { return }
            await state.startNewSession(projectPath: path)
        }
    }
}

struct BuildPromptHero: View {
    var projectName: String?

    var body: some View {
        title
            .font(.system(size: 21, weight: .medium))
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 24)
    }

    private var title: Text {
        guard let projectName else { return Text("What should we build?") }
        return Text("What should we build in ")
            + Text(projectName).underline(true, pattern: .dot, color: .secondary)
            + Text("?")
    }
}

struct PiSetupView: View {
    @Bindable var state: AppState
    var asSheet: Bool = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top, spacing: 14) {
                    HugeIcon(
                        name: state.installation != nil ? "checkmark-circle-01" : "wrench-01"
                    )
                    .font(.system(size: 32))
                    .foregroundStyle(state.installation != nil ? .green : Color.accentColor)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(state.installation != nil ? "Muse is Installed" : "Muse CLI Required")
                            .font(.title2.weight(.semibold))
                        Text("Pie wraps your local `muse` CLI binary directly and reads sessions from `\(PiPaths.sessionsDirectory.path.abbreviatingHomeDirectory)`.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                if let installation = state.installation {
                    GroupBox("Detected Muse Executable") {
                        VStack(alignment: .leading, spacing: 6) {
                            KeyValueRow(key: "Executable", value: installation.displayPath, isMonospaced: true)
                            KeyValueRow(key: "Version", value: installation.version, isMonospaced: true)
                            KeyValueRow(key: "Resolved via", value: installation.origin)
                            KeyValueRow(key: "Login shell", value: installation.shell ?? "—", isMonospaced: true)
                            KeyValueRow(key: "Config folder", value: PiPaths.agentDirectory.path.abbreviatingHomeDirectory, isMonospaced: true)
                            KeyValueRow(key: "Sessions folder", value: PiPaths.sessionsDirectory.path.abbreviatingHomeDirectory, isMonospaced: true)
                        }
                        .padding(6)
                    }
                } else {
                    GroupBox("Muse was not found") {
                        VStack(alignment: .leading, spacing: 8) {
                            if let detail = state.discoveryDetail {
                                Text(detail)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            if !state.searchedPaths.isEmpty {
                                Text("Searched locations:")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(state.searchedPaths.map(\.abbreviatingHomeDirectory).joined(separator: "\n"))
                                    .font(Typography.codeBlockCompact)
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                GroupBox("Muse CLI Quick Reference") {
                    VStack(alignment: .leading, spacing: 10) {
                        InstallStep(
                            number: 1,
                            title: "Ensure `muse` is on your shell PATH",
                            command: "muse --version"
                        )
                        InstallStep(
                            number: 2,
                            title: "Authenticate with your Meta Muse account",
                            command: "muse login"
                        )
                    }
                    .padding(6)
                }

                HStack {
                    Button {
                        Task { await state.retryDiscovery() }
                    } label: {
                        Label("Check Again", huge: "refresh")
                    }
                    .buttonStyle(.borderedProminent)

                    Button("Open Terminal") {
                        _ = WorkspaceLauncher.openTerminal(at: NSHomeDirectory())
                    }

                    Button("Reveal Config Folder") {
                        WorkspaceLauncher.reveal(PiPaths.agentDirectory.path)
                    }

                    Spacer()

                    if asSheet {
                        Button("Done") { dismiss() }
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
            .padding(28)
            .frame(maxWidth: 640, alignment: .leading)
        }
        .frame(minWidth: asSheet ? 580 : nil, minHeight: asSheet ? 440 : nil)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct InstallStep: View {
    var number: Int
    var title: String
    var command: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("\(number). \(title)")
                .font(.subheadline.weight(.medium))
            HStack {
                Text(command)
                    .font(Typography.codeBlock)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                CopyButton(text: command)
            }
        }
    }
}

struct CommandLineRow: View {
    var command: String

    var body: some View {
        HStack(spacing: 8) {
            Text(command)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 6)
            CopyButton(text: command, help: "Copy command")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 7))
    }
}
