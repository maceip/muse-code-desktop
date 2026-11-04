//
//  LocalHarnessAccountService.swift
//  PiCode
//
//  Inspects the local Muse account status (`~/.config/muse/auth.json` and
//  `~/.config/muse/settings.json`).
//

import Foundation

enum LocalHarnessAccountService {
    static func status(
        for descriptor: HarnessDescriptor,
        installation: HarnessInstallation
    ) async -> LocalHarnessAccountStatus {
        if installation.origin == "built-in" {
            return LocalHarnessAccountStatus(
                kind: .subscription,
                title: "Built-in Local Agent Active",
                detail: "Running on-device workspace inspection, NaturalLanguage/FoundationModels synthesis, and Safari Bridge without requiring an external account."
            )
        }

        let authURL = PiPaths.authFile
        let settingsURL = PiPaths.settingsFile

        if let data = try? Data(contentsOf: authURL),
           let json = try? JSONCoding.decode(data),
           case .object(let dict) = json,
           !dict.isEmpty {
            let model = (try? Data(contentsOf: settingsURL))
                .flatMap { try? JSONCoding.decode($0) }?
                .string("model")
            let modelDetail = model.map { " (\($0))" } ?? ""
            return LocalHarnessAccountStatus(
                kind: .subscription,
                title: "Authenticated",
                detail: "Connected to Muse CLI\(modelDetail). Credentials stored in \(authURL.path.abbreviatingHomeDirectory)."
            )
        }

        return LocalHarnessAccountStatus(
            kind: .signedOut,
            title: "Local Workspace Mode",
            detail: "Optional: run `muse login` in your terminal to connect an external Muse CLI session."
        )
    }

    static func loginCommand(for id: HarnessID) -> String {
        "muse login"
    }
}
