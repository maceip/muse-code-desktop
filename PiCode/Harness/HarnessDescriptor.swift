//
//  HarnessDescriptor.swift
//  PiCode
//
//  Static catalog entry describing how to discover and launch the Muse CLI.
//

import Foundation

struct HarnessInstallMethod: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable {
        case npm
        case bun
        case pnpm
        case pip
        case brew
        case script
    }

    var id: String { "\(kind.rawValue):\(command)" }
    var kind: Kind
    var label: String
    var command: String
    var shellScript: String

    init(kind: Kind, label: String, command: String, shellScript: String? = nil) {
        self.kind = kind
        self.label = label
        self.command = command
        self.shellScript = shellScript ?? command
    }
}

struct HarnessDescriptor: Identifiable, Hashable, Sendable {
    var id: HarnessID
    var displayName: String
    var tagline: String
    var binaryName: String
    var versionArguments: [String]
    var installMethods: [HarnessInstallMethod]
    var capabilities: HarnessCapabilities
    var documentationURL: URL?
    var fallbackBinaries: [String]
    var hasAdapter: Bool = true
    var supportNote: String? = nil

    var primaryInstallCommand: String? { installMethods.first?.command }

    /// Muse is the built-in runtime and is never uninstalled from the app.
    var isBuiltIn: Bool { true }
}

extension HarnessDescriptor {
    static func descriptor(for id: HarnessID) -> HarnessDescriptor {
        museDescriptor
    }

    static let museDescriptor: HarnessDescriptor = {
        return HarnessDescriptor(
            id: .museCode,
            displayName: "Muse",
            tagline: "Meta's Muse Code CLI, driven over `muse exec --json`.",
            binaryName: "muse",
            versionArguments: ["--version"],
            installMethods: [],
            capabilities: [
                .streamingText,
                .toolCalls,
                .toolStreamingOutput,
                .thinking,
                .abort,
                .sessions,
                .sessionTree,
                .modelCatalog,
                .thinkingLevels,
                .trust,
                .bash,
                .completionSignal
            ],
            documentationURL: nil,
            fallbackBinaries: [],
            hasAdapter: true,
            supportNote: "Driven over `muse exec --json`, with sessions indexed from `~/.local/share/muse/sessions` and configuration in `~/.config/muse`."
        )
    }()

    static let all: [HarnessDescriptor] = [museDescriptor]
}
