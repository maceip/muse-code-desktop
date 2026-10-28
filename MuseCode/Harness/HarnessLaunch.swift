//
//  HarnessLaunch.swift
//  PiCode
//
//  Builds the command-line invocation for a Muse session.
//

import Foundation

enum HarnessLaunch {
    static func sessionModeArguments(for id: HarnessID) -> [String] {
        ["exec", "--json"]
    }

    static func arguments(
        for descriptor: HarnessDescriptor,
        sessionFile: String?,
        modelOverride: String?,
        systemPrompt: String?,
        trustArguments: [String],
        extraArguments: [String]
    ) -> [String] {
        var arguments = sessionModeArguments(for: descriptor.id)
        if let sessionFile {
            arguments += ["--session-id", sessionFile]
        }
        if let modelOverride, !modelOverride.isEmpty {
            arguments += ["--model", modelOverride]
        }
        for flag in trustArguments + extraArguments where !arguments.contains(flag) {
            arguments.append(flag)
        }
        return arguments
    }
}
