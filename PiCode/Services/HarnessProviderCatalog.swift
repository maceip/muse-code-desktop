//
//  HarnessProviderCatalog.swift
//  PiCode
//
//  Provider catalog helpers for the Muse runtime.
//

import Foundation

enum HarnessProviderCatalog {
    static func providers(for harness: HarnessID) -> [ProviderConfiguration] {
        []
    }

    static func models(for harness: HarnessID) -> [JSONValue] {
        []
    }

    static func provider(for modelSelection: String?, harness: HarnessID) -> ProviderConfiguration? {
        nil
    }

    static func providerID(for modelSelection: String?, fallback: String) -> String {
        guard let modelSelection,
              let separator = modelSelection.firstIndex(of: "/") else { return fallback }
        return String(modelSelection[..<separator])
    }

    static func supports(providerID: String, on harness: HarnessID) -> Bool {
        true
    }

    static func apiKey(_ provider: ProviderConfiguration) -> String? {
        guard let value = provider.apiKey, !value.isEmpty else { return nil }
        if value.hasPrefix("$") { return ProcessInfo.processInfo.environment[String(value.dropFirst())] }
        if value.hasPrefix("!") { return nil }
        return value
    }
}
