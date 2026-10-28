//
//  SessionTitleService.swift
//  PiCode
//
//  Generates a short session title from the user's opening prompt.
//

import Foundation

enum SessionTitleService {
    static let maxTitleLength = 60
    static let maxFallbackWords = 6
    static let maxFallbackLength = 48

    static func generate(
        for prompt: String,
        installation: PiInstallation,
        harness: HarnessDescriptor = HarnessDescriptor.descriptor(for: .museCode),
        directory: String,
        model: String?
    ) async -> String? {
        fallback(for: prompt)
    }

    static func sanitize(_ raw: String) -> String? {
        let lines = raw
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard var line = lines.first else { return nil }

        let quoteChars = CharacterSet(charactersIn: "\"'“”‘’`")
        line = line.trimmingCharacters(in: quoteChars.union(.whitespacesAndNewlines))
        while let last = line.last, ".!?:;,".contains(last) {
            line.removeLast()
        }
        line = line.trimmingCharacters(in: quoteChars.union(.whitespacesAndNewlines))
        guard !line.isEmpty else { return nil }

        if line.count > maxTitleLength {
            line = String(line.prefix(maxTitleLength)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return line.isEmpty ? nil : line
    }

    static func fallback(for prompt: String) -> String? {
        var text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.hasPrefix("/") {
            text.removeFirst()
        }
        let words = text
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .prefix(maxFallbackWords)
            .map(String.init)
        guard !words.isEmpty else { return nil }
        var combined = words.joined(separator: " ")
        if combined.count > maxFallbackLength {
            combined = String(combined.prefix(maxFallbackLength)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return combined.isEmpty ? nil : combined
    }
}
