//
//  ProviderRegistry.swift
//  PiCode
//
//  Stub provider registry for the Muse-only build (Muse manages its own model
//  catalog in ~/.local/share/muse/model-catalog).
//

import Foundation

enum ProviderRegistry {
    static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent("PiCode", isDirectory: true)
            .appendingPathComponent("providers.json")
    }

    static func providers() -> [ProviderConfiguration] {
        []
    }

    static func save(_ providers: [ProviderConfiguration]) throws {
        // Muse manages its own model catalog.
    }

    static func synchronize(_ providers: [ProviderConfiguration],
                            with harnesses: Set<HarnessID>) throws {
        // Muse manages its own model catalog.
    }
}
