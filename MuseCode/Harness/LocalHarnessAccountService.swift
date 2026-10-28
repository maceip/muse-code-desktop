//
//  LocalHarnessAccountService.swift
//  PiCode
//
//  Inspects the local Meta Muse account status (`~/.config/muse/auth.json` and
//  `~/.config/muse/settings.json`).
//

import Foundation

enum LocalHarnessAccountService {
    static func status(
        for descriptor: HarnessDescriptor,
        installation: HarnessInstallation
    ) async -> LocalHarnessAccountStatus {
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
                detail: "Connected to Meta Muse\(modelDetail). Credentials stored in \(authURL.path.abbreviatingHomeDirectory)."
            )
        }

        return LocalHarnessAccountStatus(
            kind: .signedOut,
            title: "Not signed in",
            detail: "Run `muse login` in your terminal to authenticate with Meta Muse."
        )
    }

    static func loginCommand(for id: HarnessID) -> String {
        "muse login"
    }
}
