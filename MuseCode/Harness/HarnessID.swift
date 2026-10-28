//
//  HarnessID.swift
//  PiCode
//
//  Stable identifier for the Muse Code CLI runtime.
//

import Foundation

enum HarnessID: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case museCode = "muse-code"

    /// Compatibility alias so legacy call sites resolve to Muse Code.
    static let pi: HarnessID = .museCode

    var id: String { rawValue }

    init?(rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return nil }
        self = .museCode
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        _ = try? container.decode(String.self)
        self = .museCode
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(Self.museCode.rawValue)
    }

    /// Short human-facing product name.
    var displayName: String {
        "Muse"
    }

    /// CLI command name users type in a terminal.
    var cliName: String {
        "muse"
    }

    /// Whether a session runtime adapter is wired up for this harness.
    var hasAdapter: Bool {
        true
    }
}
