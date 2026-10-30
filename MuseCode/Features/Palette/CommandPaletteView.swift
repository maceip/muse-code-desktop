//
//  CommandPaletteView.swift
//  PiCode
//
//  One palette for commands, projects, and sessions, plus the inline Titlebar
//  Search Autocomplete & Suggestion Dropdown (`MuseSearchSuggestionService` +
//  `TitlebarSearchDropdownView`).
//

import AppKit
import SwiftUI

// MARK: - Search Autocomplete & Suggestion Service (`AOL Search History.jpg`)

struct MuseSearchSuggestion: Identifiable, Equatable {
    enum Kind: Equatable {
        case querySuggestion
        case command(PaletteCommand)
        case project(ProjectGroup)
    }

    var id: String
    var queryText: String
    var typedPrefix: String
    var completionSuffix: String
    var subtitle: String?
    var kind: Kind = .querySuggestion
}

struct MuseInlineAutocomplete: Equatable {
    var typedPrefix: String
    var completionSuffix: String
    var topHitTitle: String?
    var fullCompletionText: String

    var displayHighlightText: String {
        if let topHitTitle, !topHitTitle.isEmpty {
            return "\(completionSuffix) — \(topHitTitle)"
        }
        return completionSuffix
    }
}

struct MuseSearchTopHit: Identifiable, Equatable {
    enum Target: Equatable {
        case session(project: ProjectGroup, session: SessionRef)
        case project(ProjectGroup)
        case command(PaletteCommand)
    }

    var id: String
    var title: String
    var subtitle: String
    var iconName: String
    var isSystemSymbol: Bool = false
    var target: Target
}

@Observable
@MainActor
final class MuseSearchSuggestionService {
    static let shared = MuseSearchSuggestionService()

    private(set) var recentQueries: [String] = []
    private let historyURL: URL

    init(historyURL: URL? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        self.historyURL = historyURL ?? base
            .appendingPathComponent("PiCode", isDirectory: true)
            .appendingPathComponent("search-history.json")
        loadHistory()
    }

    func recordSearch(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        recentQueries.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        recentQueries.insert(trimmed, at: 0)
        if recentQueries.count > 50 {
            recentQueries = Array(recentQueries.prefix(50))
        }
        MuseRollingKeywordIndex.shared.ingestLiveUserText(trimmed, source: "muse")
        saveHistory()
    }

    /// Computes the #1 Top Hit for the current query across sessions, projects, and commands.
    func topHit(
        for rawQuery: String,
        projects: [ProjectGroup],
        matchingSessions: [(project: ProjectGroup, session: SessionRef)]
    ) -> MuseSearchTopHit? {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = query.lowercased()

        if query.isEmpty {
            // When query is empty, show the most recently updated session as Top Hit
            let allSessions = projects.flatMap { proj in
                proj.sessions.map { (project: proj, session: $0) }
            }.sorted { $0.session.updatedAt > $1.session.updatedAt }
            if let first = allSessions.first {
                return MuseSearchTopHit(
                    id: "top-session-\(first.session.id)",
                    title: first.session.displayName,
                    subtitle: first.project.name,
                    iconName: "globe",
                    isSystemSymbol: true,
                    target: .session(project: first.project, session: first.session)
                )
            }
            return nil
        }

        // 1. Prefer a session whose title or firstUserMessage starts with or contains the query
        if let bestSession = matchingSessions.first(where: {
            $0.session.displayName.lowercased().hasPrefix(lower)
        }) ?? matchingSessions.first {
            return MuseSearchTopHit(
                id: "top-session-\(bestSession.session.id)",
                title: bestSession.session.displayName,
                subtitle: bestSession.project.name,
                iconName: "globe",
                isSystemSymbol: true,
                target: .session(project: bestSession.project, session: bestSession.session)
            )
        }

        // 2. Or a matching project
        if let proj = projects.first(where: {
            $0.name.lowercased().hasPrefix(lower) || $0.name.lowercased().contains(lower)
        }) {
            return MuseSearchTopHit(
                id: "top-project-\(proj.id)",
                title: proj.name,
                subtitle: proj.displayPath,
                iconName: "folder-02",
                isSystemSymbol: false,
                target: .project(proj)
            )
        }

        // 3. Or a matching PaletteCommand
        if let cmd = PaletteCommand.allCases.first(where: {
            $0.title.lowercased().contains(lower)
        }) {
            return MuseSearchTopHit(
                id: "top-cmd-\(cmd.id)",
                title: cmd.title,
                subtitle: cmd.group.label,
                iconName: cmd.systemImage,
                isSystemSymbol: false,
                target: .command(cmd)
            )
        }

        return nil
    }

    /// Generates up to `limit` ranked `Muse Suggestions` backed by `MuseRollingKeywordIndex`
    /// (low-energy, low-compute lazy rolling keyword matcher over Muse, Claude, and Codex transcripts).
    func suggestions(
        for rawQuery: String,
        projects: [ProjectGroup],
        matchingSessions: [(project: ProjectGroup, session: SessionRef)] = [],
        limit: Int = 6
    ) -> [MuseSearchSuggestion] {
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()

        let rollingIndex = MuseRollingKeywordIndex.shared
        guard rollingIndex.isServiceAvailable else {
            // Background keyword service is unavailable/down: return empty suggestions so
            // TitlebarSearchDropdownView gracefully falls back to listing window-known sessions.
            return []
        }

        if trimmed.isEmpty {
            // Default suggestions when search field is first focused with empty text:
            // surface recent searches + top recurring Muse Keywords from local transcript history,
            // with starter fallbacks for a brand-new install with zero history.
            let topRolling = rollingIndex.matchKeywords(for: "", limit: limit + 4)
            var pool: [(phrase: String, subtitle: String?)] = []
            for r in recentQueries.prefix(2) {
                pool.append((r, "recent"))
            }
            for match in topRolling {
                let badge = Self.formatKeywordSubtitle(match)
                pool.append((match.phrase, badge))
            }
            for proj in projects {
                for session in proj.sessions.prefix(2) {
                    let clean = Self.cleanPhrase(from: session.displayName)
                    if !clean.isEmpty { pool.append((clean, nil)) }
                }
            }
            if pool.count < limit {
                for starter in [
                    ("new session", "starter"),
                    ("clone git repository", "starter"),
                    ("open project folder", "starter"),
                    ("light mode", "starter"),
                    ("java", "starter"),
                    ("kotlin", "starter")
                ] {
                    pool.append(starter)
                }
            }
            var seen: Set<String> = []
            var results: [MuseSearchSuggestion] = []
            for item in pool {
                let key = item.phrase.lowercased()
                guard !key.isEmpty, !seen.contains(key) else { continue }
                seen.insert(key)
                results.append(
                    MuseSearchSuggestion(
                        id: "sug-\(key)",
                        queryText: item.phrase,
                        typedPrefix: "",
                        completionSuffix: item.phrase,
                        subtitle: item.subtitle
                    )
                )
                if results.count >= limit { break }
            }
            return results
        }

        // Query the low-compute rolling keyword matcher for similar strings, prefix matches,
        // and co-occurring / semantic neighbor keywords (e.g. "java" -> "kotlin").
        let rollingMatches = rollingIndex.matchKeywords(for: trimmed, limit: limit * 2)

        struct RawCandidate {
            var phrase: String
            var subtitle: String?
        }

        var primaryCandidates: [RawCandidate] = []
        var neighborCandidates: [RawCandidate] = []
        var prefixCandidates: [RawCandidate] = []
        var similarCandidates: [RawCandidate] = []

        // 1. Exact query itself is always candidate #1 (matching `aol` at top of Muse Suggestions in `AOL Search History.jpg`)
        let exactMatch = rollingMatches.first { $0.phrase.lowercased() == lower }
        primaryCandidates.append(RawCandidate(
            phrase: trimmed,
            subtitle: exactMatch.map(Self.formatKeywordSubtitle)
        ))

        // 2. If typing `aol`, preserve the explicit `AOL Search History.jpg` reference completions first
        if lower == "aol" || lower.hasPrefix("aol ") {
            let aolExpansions = [
                "aol",
                "aol mail",
                "aol email",
                "aol login",
                "aol mail login",
                "aol news"
            ]
            for exp in aolExpansions where exp.hasPrefix(lower) {
                prefixCandidates.append(RawCandidate(phrase: exp, subtitle: nil))
            }
        }

        // 3. Recent search queries
        for recent in recentQueries {
            let rLower = recent.lowercased()
            if rLower.hasPrefix(lower) && rLower != lower {
                prefixCandidates.append(RawCandidate(phrase: recent, subtitle: "recent"))
            } else if rLower.contains(lower) && rLower != lower {
                similarCandidates.append(RawCandidate(phrase: recent, subtitle: "recent"))
            }
        }

        // 4. Rolling Muse Keywords calculated across local Muse chat history
        //    plus semantic/co-occurring neighbors (e.g. typing "java" surfaces "kotlin")
        for match in rollingMatches {
            let mLower = match.phrase.lowercased()
            guard mLower != lower else { continue }
            let badge = Self.formatKeywordSubtitle(match)
            if match.isAssociatedNeighbor {
                neighborCandidates.append(RawCandidate(phrase: match.phrase, subtitle: badge))
            } else if mLower.hasPrefix(lower) {
                prefixCandidates.append(RawCandidate(phrase: match.phrase, subtitle: badge))
            } else {
                similarCandidates.append(RawCandidate(phrase: match.phrase, subtitle: badge))
            }
        }

        // 5. Project names & commands
        for project in projects {
            let pName = project.name.lowercased()
            if pName.hasPrefix(lower) && pName != lower {
                prefixCandidates.append(RawCandidate(phrase: project.name, subtitle: "project"))
            }
        }
        for cmd in PaletteCommand.allCases {
            let cTitle = cmd.title.lowercased().replacingOccurrences(of: "…", with: "")
            if cTitle.hasPrefix(lower) && cTitle != lower {
                prefixCandidates.append(RawCandidate(phrase: cTitle, subtitle: nil))
            } else if cTitle.contains(lower) {
                similarCandidates.append(RawCandidate(phrase: cTitle, subtitle: nil))
            }
        }

        // Interleave primary + top prefix matches + associated neighbors (like "kotlin" for "java") + similar matches
        var orderedCandidates: [RawCandidate] = []
        orderedCandidates.append(contentsOf: primaryCandidates)
        if lower == "aol" || lower.hasPrefix("aol ") {
            orderedCandidates.append(contentsOf: prefixCandidates)
            orderedCandidates.append(contentsOf: neighborCandidates)
            orderedCandidates.append(contentsOf: similarCandidates)
        } else {
            orderedCandidates.append(contentsOf: prefixCandidates.prefix(2))
            orderedCandidates.append(contentsOf: neighborCandidates.prefix(2))
            orderedCandidates.append(contentsOf: prefixCandidates.dropFirst(2))
            orderedCandidates.append(contentsOf: similarCandidates)
            orderedCandidates.append(contentsOf: neighborCandidates.dropFirst(2))
        }

        // 7. Contextual fallback expansions if the query is completely novel and has < limit matches
        let activeProj = projects.first?.name.lowercased() ?? "project"
        let fallbackExpansions = [
            "\(trimmed) session",
            "\(trimmed) in \(activeProj)",
            "\(trimmed) files",
            "\(trimmed) changes",
            "\(trimmed) implementation",
            "\(trimmed) fix"
        ]

        var seen: Set<String> = []
        var output: [MuseSearchSuggestion] = []

        for candidate in orderedCandidates {
            let normalized = candidate.phrase.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = normalized.lowercased()
            guard !key.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)

            let typedPart: String
            let suffixPart: String
            if key.hasPrefix(lower) {
                typedPart = trimmed
                let dropCount = min(trimmed.count, normalized.count)
                suffixPart = String(normalized.dropFirst(dropCount))
            } else {
                typedPart = ""
                suffixPart = normalized
            }

            output.append(
                MuseSearchSuggestion(
                    id: "sug-\(key)",
                    queryText: normalized,
                    typedPrefix: typedPart,
                    completionSuffix: suffixPart,
                    subtitle: candidate.subtitle
                )
            )
            if output.count >= limit { break }
        }

        // Only add contextual fallback expansions if the rolling keyword index actually matched at least one term
        if output.count < limit && !rollingMatches.isEmpty {
            for exp in fallbackExpansions {
                let normalized = exp.trimmingCharacters(in: .whitespacesAndNewlines)
                let key = normalized.lowercased()
                guard !key.isEmpty, !seen.contains(key) else { continue }
                seen.insert(key)
                let dropCount = min(trimmed.count, normalized.count)
                output.append(
                    MuseSearchSuggestion(
                        id: "sug-\(key)",
                        queryText: normalized,
                        typedPrefix: trimmed,
                        completionSuffix: String(normalized.dropFirst(dropCount)),
                        subtitle: nil
                    )
                )
                if output.count >= limit { break }
            }
        }

        // If no rolling keywords, no recent queries, and no session completions matched `trimmed`
        // (e.g. unmatchable gibberish query), return empty so the dropdown gracefully defaults
        // to showing the current sessions known to the app window.
        if output.count == 1 && rollingMatches.isEmpty && exactMatch == nil && lower != "aol" {
            return []
        }

        return output
    }

    private static func formatKeywordSubtitle(_ match: MuseKeywordMatch) -> String {
        let src = match.sources.first ?? "muse"
        if match.isAssociatedNeighbor {
            return match.hitCount > 1 ? "related · \(src) · \(match.hitCount)×" : "related · \(src)"
        }
        if match.hitCount > 1 {
            return "\(src) · \(match.hitCount)×"
        }
        return src
    }

    /// Computes the inline autocomplete suffix + top hit headline for the titlebar search field.
    func inlineAutocomplete(
        for rawQuery: String,
        projects: [ProjectGroup],
        matchingSessions: [(project: ProjectGroup, session: SessionRef)]
    ) -> MuseInlineAutocomplete? {
        let trimmed = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let lower = trimmed.lowercased()

        let top = topHit(for: trimmed, projects: projects, matchingSessions: matchingSessions)
        let list = suggestions(for: trimmed, projects: projects, matchingSessions: matchingSessions, limit: 6)

        // Find the first suggestion that extends `trimmed` with a non-empty suffix
        if let bestHit = top,
           bestHit.title.lowercased().hasPrefix(lower),
           bestHit.title.count > trimmed.count {
            let suffix = String(bestHit.title.dropFirst(trimmed.count))
            return MuseInlineAutocomplete(
                typedPrefix: rawQuery,
                completionSuffix: suffix,
                topHitTitle: bestHit.subtitle,
                fullCompletionText: bestHit.title
            )
        }

        if let firstExtended = list.first(where: { !$0.completionSuffix.isEmpty && !$0.typedPrefix.isEmpty }) {
            return MuseInlineAutocomplete(
                typedPrefix: rawQuery,
                completionSuffix: firstExtended.completionSuffix,
                topHitTitle: top?.title,
                fullCompletionText: firstExtended.queryText
            )
        }

        if let firstSimilar = list.dropFirst().first(where: { $0.queryText.lowercased() != lower }) {
            return MuseInlineAutocomplete(
                typedPrefix: rawQuery,
                completionSuffix: " → \(firstSimilar.queryText)",
                topHitTitle: top?.title,
                fullCompletionText: firstSimilar.queryText
            )
        }

        if let top {
            return MuseInlineAutocomplete(
                typedPrefix: rawQuery,
                completionSuffix: "",
                topHitTitle: top.title,
                fullCompletionText: top.title
            )
        }

        return nil
    }

    // MARK: - Phrase Extraction Helpers

    private static func cleanPhrase(from text: String) -> String {
        let singleLine = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let words = singleLine.split(whereSeparator: { $0.isWhitespace })
        return words.prefix(5).joined(separator: " ")
    }

    private static func extractCompletions(matchingPrefix prefix: String, from text: String) -> [String] {
        let words = text
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
        guard !words.isEmpty else { return [] }

        var results: [String] = []
        let joined = words.joined(separator: " ")
        if joined.hasPrefix(prefix), joined != prefix {
            let phraseWords = joined.split(separator: " ").prefix(4)
            results.append(phraseWords.joined(separator: " "))
        }

        for idx in words.indices {
            let slice = words[idx..<min(words.endIndex, idx + 4)].joined(separator: " ")
            if slice.hasPrefix(prefix), slice != prefix {
                for len in 1...min(4, words.endIndex - idx) {
                    let sub = words[idx..<(idx + len)].joined(separator: " ")
                    if sub.hasPrefix(prefix), sub.count > prefix.count {
                        results.append(sub)
                    }
                }
            }
        }
        return results
    }

    // MARK: - Persistence

    private func loadHistory() {
        guard let data = try? Data(contentsOf: historyURL),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return
        }
        recentQueries = decoded
    }

    private func saveHistory() {
        let snapshot = recentQueries
        let url = historyURL
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if let data = try? JSONEncoder().encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}

// MARK: - Titlebar Inline Search Field & Translucent Dropdown (`AOL Search History.jpg`)

/// Search icon glyph rendered inside the leading edge of the Titlebar Search Pill.
struct MuseSearchBrandGlyph: View {
    var isActive: Bool

    var body: some View {
        HugeIcon(name: "search-01", size: 13)
            .foregroundStyle(.secondary)
            .frame(width: 15, height: 15)
    }
}

/// Floating translucent search dropdown anchored directly beneath the centered Titlebar Search Pill
/// (`AOL Search History.jpg`), featuring:
/// 1. Top Hit row
/// 2. `Muse Suggestions` powered by `MuseSearchSuggestionService`
/// 3. `Switch to Session` matching sessions with one-click session switching
struct TitlebarSearchDropdownView: View {
    @Bindable var state: AppState
    var onRunCommand: (PaletteCommand) -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var hoveredItemID: String?
    @State private var escapeEventMonitor: Any?

    private var suggestionService: MuseSearchSuggestionService { .shared }

    /// Direct session matches before falling back to `state.windowKnownSessions`.
    private var directMatchingSessions: [(project: ProjectGroup, session: SessionRef)] {
        let allKnown = state.windowKnownSessions
        let q = state.paletteQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        if !state.paletteResults.isEmpty {
            return Array(state.paletteResults.prefix(5))
        }
        let lower = q.lowercased()
        let rollingCandidates = MuseRollingKeywordIndex.shared
            .matchKeywords(for: q, limit: 2)
            .map { $0.phrase.lowercased() }
        let searchTerms = ([lower] + rollingCandidates).filter { !$0.isEmpty }

        var direct: [(project: ProjectGroup, session: SessionRef)] = []
        var seenSessionIDs: Set<String> = []
        for term in searchTerms {
            for entry in allKnown where !seenSessionIDs.contains(entry.session.id) {
                if entry.session.displayName.lowercased().contains(term)
                    || (entry.session.firstUserMessage?.lowercased().contains(term) ?? false)
                    || entry.project.name.lowercased().contains(term) {
                    seenSessionIDs.insert(entry.session.id)
                    direct.append(entry)
                }
            }
            if direct.count >= 5 { break }
        }
        return direct
    }

    /// True when the dropdown is operating in degraded service fallback mode:
    /// 1. Background keyword service is unavailable/crashed (`!isServiceAvailable`), OR
    /// 2. The user typed a query that matched zero Muse Keywords and zero sessions directly
    ///    (falling back to listing window-known sessions), OR
    /// 3. There is no saved session history on disk while falling back to ephemeral window sessions.
    var isDegradedFallbackMode: Bool {
        degradedFallbackExplanation != nil
    }

    /// Human-readable explanation displayed next to the tiny connection-lost icon at the top
    /// of the dropdown whenever degraded service fallback mode is active.
    var degradedFallbackExplanation: String? {
        if !MuseRollingKeywordIndex.shared.isServiceAvailable {
            return "Degraded fallback mode · Keyword service connection lost — listing window sessions"
        }
        let q = state.paletteQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            let rollingMatches = MuseRollingKeywordIndex.shared.matchKeywords(for: q, limit: 4)
            if rollingMatches.isEmpty && directMatchingSessions.isEmpty {
                return "Degraded fallback mode · No matching keywords — listing window sessions"
            }
        }
        if state.projects.isEmpty && MuseRollingKeywordIndex.shared.stats.totalKeywords == 0 && !state.windowKnownSessions.isEmpty {
            return "Degraded fallback mode · No saved session history — listing window sessions"
        }
        return nil
    }

    /// Sessions to display in `switch to session`:
    /// - Searches `state.windowKnownSessions` (persisted project sessions + any active
    ///   in-memory controller sessions in the window) using both the raw query and
    ///   rolling keyword matches.
    /// - If no session directly matches the query (or when the keyword service is unavailable
    ///   or there is no transcript history), gracefully defaults to listing the current
    ///   sessions known to the app window so the dropdown always survives and stays useful.
    var matchingSessions: [(project: ProjectGroup, session: SessionRef)] {
        let allKnown = state.windowKnownSessions
        let q = state.paletteQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if !q.isEmpty {
            let direct = directMatchingSessions
            if !direct.isEmpty {
                return Array(direct.prefix(5))
            }
            // Fallback: default to listing current sessions known to the window
            return Array(allKnown.prefix(4))
        } else {
            return Array(allKnown.prefix(4))
        }
    }

    static let dropdownWidth: CGFloat = 400

    private var topHit: MuseSearchTopHit? {
        suggestionService.topHit(
            for: state.paletteQuery,
            projects: state.projects,
            matchingSessions: matchingSessions
        )
    }

    var suggestions: [MuseSearchSuggestion] {
        suggestionService.suggestions(
            for: state.paletteQuery,
            projects: state.projects,
            matchingSessions: matchingSessions,
            limit: 2
        )
    }

    /// Flat list of selectable row IDs for keyboard Up/Down arrow navigation:
    /// 1. Top Hit
    /// 2. Previous Sessions (`switch to session`) at the top
    /// 3. Keyword Suggestions (`Muse Suggestions`, max 2 rows) at the bottom
    var selectableRowIDs: [String] {
        var ids: [String] = []
        let sessions = matchingSessions
        if let hit = suggestionService.topHit(for: state.paletteQuery, projects: state.projects, matchingSessions: sessions) {
            ids.append(hit.id)
        }
        ids.append(contentsOf: sessions.map { "switch-\($0.session.id)" })
        let sugs = suggestionService.suggestions(for: state.paletteQuery, projects: state.projects, matchingSessions: sessions, limit: 2)
        ids.append(contentsOf: sugs.map(\.id))
        return ids
    }

    var body: some View {
        let sessions = matchingSessions
        let hit = suggestionService.topHit(
            for: state.paletteQuery,
            projects: state.projects,
            matchingSessions: sessions
        )
        let sugs = suggestionService.suggestions(
            for: state.paletteQuery,
            projects: state.projects,
            matchingSessions: sessions,
            limit: 2
        )
        let fallbackExplanation = degradedFallbackExplanation
        var rowIDs: [String] = []
        if let hit { rowIDs.append(hit.id) }
        rowIDs.append(contentsOf: sessions.map { "switch-\($0.session.id)" })
        rowIDs.append(contentsOf: sugs.map(\.id))

        let clampedSelected = rowIDs.isEmpty ? -1 : min(max(0, state.paletteSelectedIndex), rowIDs.count - 1)
        let activeRowID: String? = (clampedSelected >= 0 && clampedSelected < rowIDs.count) ? rowIDs[clampedSelected] : nil

        return VStack(alignment: .leading, spacing: 0) {
            // 0. Degraded Service Fallback Mode Banner (tiny connection-lost icon + explanation)
            if let fallbackExplanation {
                degradedFallbackBanner(explanation: fallbackExplanation)
                Divider()
                    .overlay(Color.white.opacity(colorScheme == .dark ? 0.10 : 0.25))
            }

            // 1. Top Hit Row
            if let hit {
                topHitRow(hit, isSelected: activeRowID == hit.id || hoveredItemID == hit.id)
                Divider()
                    .overlay(Color.white.opacity(colorScheme == .dark ? 0.10 : 0.25))
            }

            // 2. Previous Sessions Chat Interactivity (`switch to session`) at the TOP
            if !sessions.isEmpty {
                Text("switch to session")
                    .font(.system(size: 11.5, weight: .regular, design: .monospaced))
                    .foregroundStyle(Color.primary.opacity(0.70))
                    .padding(.horizontal, 12)
                    .padding(.top, 7)
                    .padding(.bottom, 4)
                    .help("switch to session")
                    .accessibilityLabel("switch to session")

                VStack(alignment: .leading, spacing: 2) {
                    ForEach(sessions, id: \.session.id) { entry in
                        let rowID = "switch-\(entry.session.id)"
                        switchToSessionRow(
                            project: entry.project,
                            session: entry.session,
                            rowID: rowID,
                            isSelected: activeRowID == rowID || hoveredItemID == rowID
                        )
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            } else if sugs.isEmpty && hit == nil {
                Button {
                    state.closePalette()
                    Task { await state.newChatInCurrentProject() }
                } label: {
                    HStack(spacing: 10) {
                        HugeIcon(name: "bubble-chat-add", size: 14)
                            .foregroundStyle(Color.secondary)
                            .frame(width: 20, height: 20)
                        Text("Start a new chat session")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.primary)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }

            // 3. Keyword Suggestions (`Muse Suggestions`, max 2 rows) at the BOTTOM
            if !sugs.isEmpty {
                if !sessions.isEmpty {
                    Divider()
                        .overlay(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.20))
                }
                let keywordStats = MuseRollingKeywordIndex.shared.stats
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Text("Muse")
                        .font(.system(size: 13.5, weight: .bold, design: .serif))
                        .foregroundStyle(Color.primary.opacity(0.68))
                    Text("Suggestions")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.secondary.opacity(0.85))
                    Spacer(minLength: 8)
                    if keywordStats.totalKeywords > 0 {
                        Text("\(keywordStats.totalKeywords) keywords")
                            .font(.system(size: 10, weight: .regular, design: .monospaced))
                            .foregroundStyle(Color.secondary.opacity(0.60))
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 7)
                .padding(.bottom, 3)
                .help("Muse Suggestions")
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Muse Suggestions")

                VStack(alignment: .leading, spacing: 2) {
                    ForEach(sugs) { suggestion in
                        suggestionRow(
                            suggestion,
                            isSelected: activeRowID == suggestion.id || hoveredItemID == suggestion.id
                        )
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 7)
            }
        }
        .frame(width: Self.dropdownWidth)
        .background(
            ZStack {
                VisualEffectDropdownMaterial(tooltip: fallbackExplanation)
                if colorScheme == .dark {
                    Color(white: 0.14, opacity: 0.86)
                } else {
                    Color(white: 0.97, opacity: 0.90)
                }
            }
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    colorScheme == .dark ? Color.white.opacity(0.22) : Color.black.opacity(0.12),
                    lineWidth: 1
                )
        )
        .shadow(color: .black.opacity(0.32), radius: 22, x: 0, y: 12)
        .onAppear {
            if escapeEventMonitor == nil {
                escapeEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
                    if event.keyCode == 53, state.isPalettePresented {
                        state.closePalette()
                        return nil
                    }
                    return event
                }
            }
        }
        .onDisappear {
            if let monitor = escapeEventMonitor {
                NSEvent.removeMonitor(monitor)
                escapeEventMonitor = nil
            }
        }
    }

    // MARK: - Rows

    private func degradedFallbackBanner(explanation: String) -> some View {
        Button {
            MuseRollingKeywordIndex.shared.isServiceAvailable = true
            MuseRollingKeywordIndex.shared.startLazyRollingScanIfNeeded(projects: state.projects)
            state.updatePaletteQuery()
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "wifi.slash")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.orange)
                    .frame(width: 15, height: 15)
                    .background(
                        Circle()
                            .fill(Color.orange.opacity(colorScheme == .dark ? 0.18 : 0.14))
                    )

                Text(explanation)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(colorScheme == .dark ? Color.white.opacity(0.84) : Color.primary.opacity(0.82))
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Color.orange.opacity(colorScheme == .dark ? 0.10 : 0.08)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(explanation)
        .accessibilityLabel(explanation)
    }

    private func topHitRow(_ hit: MuseSearchTopHit, isSelected: Bool) -> some View {
        Button {
            activateTopHit(hit)
        } label: {
            HStack(spacing: 10) {
                Group {
                    if hit.isSystemSymbol {
                        Image(systemName: hit.iconName)
                            .font(.system(size: 14, weight: .medium))
                    } else {
                        HugeIcon(name: hit.iconName, size: 15)
                    }
                }
                .foregroundStyle(isSelected ? Color.white : Color.secondary)
                .frame(width: 20, height: 20)

                VStack(alignment: .leading, spacing: 1) {
                    Text(hit.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                        .lineLimit(1)
                    Text(hit.subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.82) : Color.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(
                        isSelected
                            ? Color(red: 0.43, green: 0.25, blue: 0.46)
                            : Color.white.opacity(colorScheme == .dark ? 0.08 : 0.45)
                    )
            )
            .padding(6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hoveredItemID = inside ? hit.id : (hoveredItemID == hit.id ? nil : hoveredItemID)
        }
    }

    private func suggestionRow(_ suggestion: MuseSearchSuggestion, isSelected: Bool) -> some View {
        Button {
            activateSuggestion(suggestion)
        } label: {
            HStack(spacing: 10) {
                HugeIcon(name: "search-01", size: 14)
                    .foregroundStyle(isSelected ? Color.white : Color.primary.opacity(0.75))
                    .frame(width: 20, height: 20)

                HStack(spacing: 0) {
                    if !suggestion.typedPrefix.isEmpty {
                        Text(suggestion.typedPrefix)
                            .font(.system(size: 13, weight: .regular))
                            .foregroundStyle(isSelected ? Color.white : Color.primary)
                    }
                    Text(suggestion.completionSuffix)
                        .font(.system(size: 13, weight: suggestion.typedPrefix.isEmpty ? .regular : .semibold))
                        .foregroundStyle(
                            isSelected
                                ? Color.white.opacity(0.92)
                                : (suggestion.typedPrefix.isEmpty ? Color.primary : Color.primary.opacity(0.68))
                        )
                }
                .lineLimit(1)

                Spacer(minLength: 8)

                if let subtitle = suggestion.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.system(size: 10.5, weight: .regular, design: .monospaced))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.75) : Color.secondary.opacity(0.65))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color(red: 0.43, green: 0.25, blue: 0.46) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hoveredItemID = inside ? suggestion.id : (hoveredItemID == suggestion.id ? nil : hoveredItemID)
        }
    }

    private func switchToSessionRow(
        project: ProjectGroup,
        session: SessionRef,
        rowID: String,
        isSelected: Bool
    ) -> some View {
        Button {
            activateSession(session)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "square.on.square")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(isSelected ? Color.white : Color.secondary)
                    .frame(width: 22, height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(isSelected ? Color.white.opacity(0.18) : Color.primary.opacity(0.08))
                    )

                VStack(alignment: .leading, spacing: 1) {
                    Text(session.displayName)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(isSelected ? Color.white : Color.primary)
                        .lineLimit(1)
                    Text("\(project.name) · Opened Session in \(project.name)")
                        .font(.system(size: 11))
                        .foregroundStyle(isSelected ? Color.white.opacity(0.80) : Color.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color(red: 0.43, green: 0.25, blue: 0.46) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            hoveredItemID = inside ? rowID : (hoveredItemID == rowID ? nil : hoveredItemID)
        }
    }

    // MARK: - Actions

    func activateCurrentlySelected() {
        let rowIDs = selectableRowIDs
        guard !rowIDs.isEmpty else { return }
        let idx = min(max(0, state.paletteSelectedIndex), rowIDs.count - 1)
        let targetID = rowIDs[idx]

        if let topHit, topHit.id == targetID {
            activateTopHit(topHit)
            return
        }
        if let sug = suggestions.first(where: { $0.id == targetID }) {
            activateSuggestion(sug)
            return
        }
        if let match = matchingSessions.first(where: { "switch-\($0.session.id)" == targetID }) {
            activateSession(match.session)
            return
        }
    }

    func activateTopHit(_ hit: MuseSearchTopHit) {
        if !state.paletteQuery.isEmpty {
            suggestionService.recordSearch(state.paletteQuery)
        }
        state.closePalette()
        switch hit.target {
        case .session(_, let session):
            Task { await state.open(session: session) }
        case .project(let project):
            Task { await state.open(project: project) }
        case .command(let cmd):
            onRunCommand(cmd)
        }
    }

    func activateSuggestion(_ suggestion: MuseSearchSuggestion) {
        suggestionService.recordSearch(suggestion.queryText)
        state.paletteQuery = suggestion.queryText
        state.updatePaletteQuery()
        state.closePalette()

        // Check if suggestion matches a command directly
        if let cmd = PaletteCommand.allCases.first(where: {
            $0.title.lowercased().replacingOccurrences(of: "…", with: "") == suggestion.queryText.lowercased()
        }) {
            onRunCommand(cmd)
            return
        }
        // Check if suggestion matches a known session title/prompt
        let lower = suggestion.queryText.lowercased()
        if let matched = state.windowKnownSessions.first(where: {
            $0.session.displayName.lowercased().contains(lower)
                || ($0.session.firstUserMessage?.lowercased().contains(lower) ?? false)
        }) {
            Task { await state.open(session: matched.session) }
            return
        }
    }

    func activateSession(_ session: SessionRef) {
        if !state.paletteQuery.isEmpty {
            suggestionService.recordSearch(state.paletteQuery)
        }
        state.closePalette()
        Task { await state.open(session: session) }
    }
}

private struct VisualEffectDropdownMaterial: NSViewRepresentable {
    var tooltip: String? = nil

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .popover
        v.blendingMode = .withinWindow
        v.state = .active
        v.toolTip = tooltip
        v.setAccessibilityLabel(tooltip)
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.toolTip = tooltip
        nsView.setAccessibilityLabel(tooltip)
    }
}

struct CommandPaletteView: View {
    @Bindable var state: AppState
    var onRun: (PaletteCommand) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var isFieldFocused: Bool
    @State private var selectedIndex = 0

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()
            results
        }
        .frame(width: 560, height: 420)
        .onAppear {
            state.openPalette()
            isFieldFocused = true
        }
        .onDisappear { state.closePalette() }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            HugeIcon(name: "command")
                .foregroundStyle(.secondary)
            TextField("Run a command, or search projects and chats", text: $state.paletteQuery)
                .textFieldStyle(.plain)
                .font(.title3)
                .focused($isFieldFocused)
                .onSubmit(runSelected)
                .onChange(of: state.paletteQuery) { _, _ in
                    selectedIndex = 0
                    state.updatePaletteQuery()
                }
                .onMoveCommand { direction in
                    switch direction {
                    case .up: move(-1)
                    case .down: move(1)
                    default: break
                    }
                }

            Button {
                state.closePalette()
                dismiss()
            } label: {
                HugeIcon(name: "cancel-circle")
                    .imageScale(.medium)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Close")
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var results: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if !commands.isEmpty {
                        sectionHeader("Commands")
                        ForEach(Array(commands.enumerated()), id: \.element) { offset, command in
                            row(
                                index: offset,
                                systemImage: command.systemImage,
                                title: command.title,
                                subtitle: command.group.label,
                                shortcut: command.shortcutHint,
                                isEnabled: isEnabled(command)
                            ) {
                                state.closePalette()
                                dismiss()
                                onRun(command)
                            }
                            .id(offset)
                        }
                    }

                    if !state.paletteProjectResults.isEmpty {
                        sectionHeader("Projects")
                        ForEach(Array(state.paletteProjectResults.enumerated()), id: \.offset) { offset, project in
                            let index = commands.count + offset
                            row(
                                index: index,
                                systemImage: "folder-02",
                                title: project.name,
                                subtitle: project.displayPath,
                                shortcut: nil,
                                isEnabled: true
                            ) {
                                state.closePalette()
                                dismiss()
                                Task { await state.open(project: project) }
                            }
                            .id(index)
                        }
                    }

                    if !state.paletteResults.isEmpty {
                        sectionHeader("Sessions")
                        ForEach(Array(state.paletteResults.enumerated()), id: \.offset) { offset, result in
                            let index = commands.count + state.paletteProjectResults.count + offset
                            row(
                                index: index,
                                systemImage: "message-01",
                                title: result.session.displayName,
                                subtitle: result.project.name + " · " + Format.relativeTime(result.session.updatedAt),
                                shortcut: nil,
                                isEnabled: true
                            ) {
                                state.closePalette()
                                dismiss()
                                Task { await state.open(session: result.session) }
                            }
                            .id(index)
                        }
                    }

                    if commands.isEmpty && state.paletteProjectResults.isEmpty && state.paletteResults.isEmpty {
                        Text(state.paletteQuery.isEmpty ? "Type to filter." : "No matches.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(14)
                    }
                }
            }
            .onChange(of: selectedIndex) { _, newValue in
                withAnimation(.easeOut(duration: 0.1)) { proxy.scrollTo(newValue, anchor: .center) }
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }

    private func row(
        index: Int,
        systemImage: String,
        title: String,
        subtitle: String?,
        shortcut: String?,
        isEnabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                HugeIcon(name: systemImage)
                    .frame(width: 18)
                    .foregroundStyle(.secondary)
                Text(title)
                    .lineLimit(1)
                    .fontWeight(.thin)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if let shortcut {
                    Text(shortcut)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(index == selectedIndex ? Color.accentColor.opacity(0.16) : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
    }

    // MARK: - Data

    /// Commands filtered by the query. An empty query shows the useful subset
    /// rather than every command, so the palette is never a wall of text.
    private var commands: [PaletteCommand] {
        let query = state.paletteQuery.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return PaletteCommand.allCases }
        return PaletteCommand.allCases.filter { command in
            command.title.lowercased().contains(query)
                || command.group.label.lowercased().contains(query)
        }
    }

    private func isEnabled(_ command: PaletteCommand) -> Bool {
        if command.requiresSession && state.activeController == nil { return false }
        if command.requiresIdleAgent && state.isActiveSessionBusy { return false }
        return true
    }

    private var totalCount: Int {
        commands.count + state.paletteProjectResults.count + state.paletteResults.count
    }

    private func move(_ delta: Int) {
        guard totalCount > 0 else { return }
        selectedIndex = (selectedIndex + delta + totalCount) % totalCount
    }

    private func runSelected() {
        guard totalCount > 0 else { return }
        let index = min(selectedIndex, totalCount - 1)
        if index < commands.count {
            let command = commands[index]
            guard isEnabled(command) else { return }
            state.closePalette()
            dismiss()
            onRun(command)
        } else if index < commands.count + state.paletteProjectResults.count {
            let project = state.paletteProjectResults[index - commands.count]
            state.closePalette()
            dismiss()
            Task { await state.open(project: project) }
        } else {
            let session = state.paletteResults[index - commands.count - state.paletteProjectResults.count].session
            state.closePalette()
            dismiss()
            Task { await state.open(session: session) }
        }
    }
}
