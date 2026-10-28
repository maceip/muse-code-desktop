//
//  PreferencesStore.swift
//  PiCode
//
//  PiCode-owned preferences. Nothing here changes Pi configuration: Pi settings
//  stay in `~/.pi/agent`.
//

import Foundation
import SwiftUI
import Observation

@Observable
@MainActor
final class PreferencesStore {
    enum Appearance: String, CaseIterable, Identifiable {
        case system
        case light
        case dark

        var id: String { rawValue }
        /// `nil` follows the system.
        var colorScheme: ColorScheme? {
            switch self {
            case .system: return nil
            case .light: return .light
            case .dark: return .dark
            }
        }
        var label: String {
            switch self {
            case .system: return "System"
            case .light: return "Light"
            case .dark: return "Dark"
            }
        }
    }

    enum SendKey: String, CaseIterable, Identifiable {
        case returnKey
        case commandReturn

        var id: String { rawValue }
        var label: String {
            switch self {
            case .returnKey: return "Return sends, Shift-Return adds a line"
            case .commandReturn: return "Command-Return sends, Return adds a line"
            }
        }
    }

    var appearance: Appearance
    var sendKey: SendKey
    var showInspector: Bool
    var showSidebar: Bool
    /// Whether the embedded terminal panel is open under the conversation.
    /// A window-level layout fact, so it is remembered like the two panels above.
    var showTerminal: Bool
    var defaultThinkingLevel: String?
    var defaultModelQualifiedID: String?
    /// Last model selected in each harness. Model identifiers are not portable:
    /// the same provider can expose different ids in Pi, OMP, or another agent.
    var defaultModelByHarness: [String: String]
    /// Harness new sessions use unless the project or the user chooses another.
    var defaultHarnessID: HarnessID
    var confirmBeforeDeletingSessions: Bool
    var notificationsEnabled: Bool
    var recordRPCPayloads: Bool
    var extraLaunchArguments: String
    var pinnedProjects: Set<String>
    var pinnedSessions: Set<String>
    /// Session ids whose sidebar entry was dismissed. Never deletes the file.
    var hiddenSessions: Set<String>
    /// Projects whose chats the sidebar shows. The sidebar starts as a list of
    /// projects — one is folded until the user opens it — so this stores the
    /// *expanded* set: an absent path means folded, and the empty default is every
    /// project closed. A decoration like a pin: it hides rows, it never touches a
    /// session file.
    var expandedProjects: Set<String>
    var lastProjectPath: String?
    var reducedMotionOverride: Bool?
    /// How many screens of transcript stay built above and below the viewport.
    /// Rows further away are swapped for empty space of the same height.
    var transcriptOffscreenScreens: Int
    static let transcriptOffscreenScreenChoices = [2, 3, 4, 5, 6, 8]
    /// PiCode-only per-project settings (name, launch folder, system prompt),
    /// keyed by canonical project path. Stored as JSON in `UserDefaults` rather
    /// than as three parallel arrays so the three fields can never drift apart.
    private(set) var projectSettingsByPath: [String: ProjectSettings]
    /// User-selected session icons from `Assets.xcassets/SessionIcons`, keyed by `session.id`.
    private(set) var sessionIconsByKey: [String: String]
    /// User-selected 4–5 character session shorthand labels, keyed by `session.id`.
    private(set) var sessionShorthandsByKey: [String: String]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        appearance = Appearance(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .system
        sendKey = SendKey(rawValue: defaults.string(forKey: Keys.sendKey) ?? "") ?? .returnKey
        showInspector = defaults.object(forKey: Keys.showInspector) as? Bool ?? true
        showSidebar = defaults.object(forKey: Keys.showSidebar) as? Bool ?? true
        showTerminal = defaults.object(forKey: Keys.showTerminal) as? Bool ?? false
        defaultThinkingLevel = defaults.string(forKey: Keys.defaultThinkingLevel)
        let legacyPiModel = defaults.string(forKey: Keys.defaultModel)
        defaultModelQualifiedID = legacyPiModel
        var storedModels = defaults.dictionary(forKey: Keys.defaultModelsByHarness) as? [String: String] ?? [:]
        if storedModels[HarnessID.pi.rawValue] == nil, let legacyPiModel {
            storedModels[HarnessID.pi.rawValue] = legacyPiModel
        }
        defaultModelByHarness = storedModels
        defaultHarnessID = HarnessID(rawValue: defaults.string(forKey: Keys.defaultHarness) ?? "") ?? .pi
        confirmBeforeDeletingSessions = defaults.object(forKey: Keys.confirmDelete) as? Bool ?? true
        notificationsEnabled = defaults.object(forKey: Keys.notifications) as? Bool ?? false
        recordRPCPayloads = defaults.bool(forKey: Keys.recordPayloads)
        extraLaunchArguments = defaults.string(forKey: Keys.extraArguments) ?? ""
        pinnedProjects = Set(defaults.stringArray(forKey: Keys.pinnedProjects) ?? [])
        pinnedSessions = Set(defaults.stringArray(forKey: Keys.pinnedSessions) ?? [])
        hiddenSessions = Set(defaults.stringArray(forKey: Keys.hiddenSessions) ?? [])
        expandedProjects = Set(defaults.stringArray(forKey: Keys.expandedProjects) ?? [])
        lastProjectPath = defaults.string(forKey: Keys.lastProject)
        reducedMotionOverride = defaults.object(forKey: Keys.reducedMotion) as? Bool
        transcriptOffscreenScreens = defaults.object(forKey: Keys.transcriptOffscreenScreens) as? Int ?? 2
        if let data = defaults.data(forKey: Keys.projectSettings) {
            projectSettingsByPath = (try? JSONDecoder.piCode.decode([String: ProjectSettings].self, from: data)) ?? [:]
        } else {
            projectSettingsByPath = [:]
        }
        sessionIconsByKey = defaults.dictionary(forKey: Keys.sessionIcons) as? [String: String] ?? [:]
        sessionShorthandsByKey = defaults.dictionary(forKey: Keys.sessionShorthands) as? [String: String] ?? [:]
    }

    func persist() {
        defaults.set(appearance.rawValue, forKey: Keys.appearance)
        defaults.set(sendKey.rawValue, forKey: Keys.sendKey)
        defaults.set(showInspector, forKey: Keys.showInspector)
        defaults.set(showSidebar, forKey: Keys.showSidebar)
        defaults.set(showTerminal, forKey: Keys.showTerminal)
        defaults.set(defaultThinkingLevel, forKey: Keys.defaultThinkingLevel)
        defaults.set(defaultModelQualifiedID, forKey: Keys.defaultModel)
        defaults.set(defaultModelByHarness, forKey: Keys.defaultModelsByHarness)
        defaults.set(defaultHarnessID.rawValue, forKey: Keys.defaultHarness)
        defaults.set(confirmBeforeDeletingSessions, forKey: Keys.confirmDelete)
        defaults.set(notificationsEnabled, forKey: Keys.notifications)
        defaults.set(recordRPCPayloads, forKey: Keys.recordPayloads)
        defaults.set(extraLaunchArguments, forKey: Keys.extraArguments)
        defaults.set(Array(pinnedProjects), forKey: Keys.pinnedProjects)
        defaults.set(Array(pinnedSessions), forKey: Keys.pinnedSessions)
        defaults.set(Array(hiddenSessions), forKey: Keys.hiddenSessions)
        defaults.set(Array(expandedProjects), forKey: Keys.expandedProjects)
        defaults.set(lastProjectPath, forKey: Keys.lastProject)
        defaults.set(transcriptOffscreenScreens, forKey: Keys.transcriptOffscreenScreens)
        defaults.set(reducedMotionOverride, forKey: Keys.reducedMotion)
        if projectSettingsByPath.isEmpty {
            defaults.removeObject(forKey: Keys.projectSettings)
        } else if let data = try? JSONEncoder.piCode.encode(projectSettingsByPath) {
            defaults.set(data, forKey: Keys.projectSettings)
        }
        defaults.set(sessionIconsByKey, forKey: Keys.sessionIcons)
        defaults.set(sessionShorthandsByKey, forKey: Keys.sessionShorthands)
    }

    // MARK: - Per-session Icon & Shorthand

    func customSessionIcon(for session: SessionRef) -> String? {
        sessionIconsByKey[session.id]
    }

    func resolvedSessionIcon(for session: SessionRef) -> String {
        if let custom = sessionIconsByKey[session.id],
           SessionIconCatalog.all.contains(where: { $0.id == custom }) {
            return custom
        }
        return SessionIconCatalog.defaultIcon(for: session)
    }

    func setSessionIcon(_ iconID: String?, for session: SessionRef) {
        if let iconID, !iconID.isEmpty {
            sessionIconsByKey[session.id] = iconID
        } else {
            sessionIconsByKey.removeValue(forKey: session.id)
        }
        persist()
    }

    func customSessionShorthand(for session: SessionRef) -> String? {
        sessionShorthandsByKey[session.id]
    }

    func resolvedSessionShorthand(for session: SessionRef) -> String {
        if let custom = sessionShorthandsByKey[session.id]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !custom.isEmpty {
            return String(custom.prefix(5)).uppercased()
        }
        return SessionIconCatalog.defaultShorthand(for: session)
    }

    func setSessionShorthand(_ shorthand: String?, for session: SessionRef) {
        let trimmed = shorthand?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            sessionShorthandsByKey[session.id] = String(trimmed.prefix(5)).uppercased()
        } else {
            sessionShorthandsByKey.removeValue(forKey: session.id)
        }
        persist()
    }

    // MARK: - Per-project settings

    func projectSettings(for path: String) -> ProjectSettings {
        projectSettingsByPath[path] ?? ProjectSettings()
    }

    /// Replaces a project's settings. Empty settings are removed rather than
    /// stored as blanks, so “no settings” has one representation.
    func setProjectSettings(_ settings: ProjectSettings, for path: String) {
        if settings.isEmpty {
            projectSettingsByPath.removeValue(forKey: path)
        } else {
            projectSettingsByPath[path] = settings
        }
        persist()
    }

    func persistAppearance() {
        defaults.set(appearance.rawValue, forKey: Keys.appearance)
    }

    private enum Keys {
        static let appearance = "appearance"
        static let sendKey = "sendKey"
        static let showInspector = "showInspector"
        static let showSidebar = "showSidebar"
        static let showTerminal = "showTerminal"
        static let defaultThinkingLevel = "defaultThinkingLevel"
        static let defaultModel = "defaultModel"
        static let defaultModelsByHarness = "defaultModelByHarness"
        static let defaultHarness = "defaultHarnessID"
        static let confirmDelete = "confirmBeforeDeletingSessions"
        static let notifications = "notificationsEnabled"
        static let recordPayloads = "recordRPCPayloads"
        static let extraArguments = "extraLaunchArguments"
        static let pinnedProjects = "pinnedProjects"
        static let pinnedSessions = "pinnedSessions"
        static let hiddenSessions = "hiddenSessions"
        static let expandedProjects = "expandedProjects"
        static let lastProject = "lastProjectPath"
        static let reducedMotion = "reducedMotionOverride"
        static let transcriptOffscreenScreens = "transcriptKeptScreens"
        static let projectSettings = "projectSettings"
        static let sessionIcons = "sessionIconsByKey"
        static let sessionShorthands = "sessionShorthandsByKey"
    }
}

// MARK: - Curated Session Icon Set (`Assets.xcassets/SessionIcons`) & 4–5 Char Shorthand

enum SessionIconCatalog {
    struct Entry: Identifiable, Equatable {
        let id: String
        let label: String
    }

    static let all: [Entry] = [
        Entry(id: "session-code", label: "Code"),
        Entry(id: "session-spark", label: "Agent"),
        Entry(id: "session-terminal", label: "Terminal"),
        Entry(id: "session-layers", label: "UI & Layers"),
        Entry(id: "session-bug", label: "Debug & Fix"),
        Entry(id: "session-git", label: "Git & Branch"),
        Entry(id: "session-rocket", label: "Build & Ship"),
        Entry(id: "session-shield", label: "Audit & Test"),
        Entry(id: "session-cpu", label: "System & CPU"),
        Entry(id: "session-database", label: "Data & Store"),
        Entry(id: "session-globe", label: "Web & Net"),
        Entry(id: "session-bolt", label: "Fast Task"),
        Entry(id: "session-cube", label: "Module"),
        Entry(id: "session-compass", label: "Explore"),
        Entry(id: "session-flame", label: "Performance"),
        Entry(id: "session-lock", label: "Security")
    ]

    /// Picks a deterministic default icon from `Assets.xcassets/SessionIcons` for a session.
    static func defaultIcon(for session: SessionRef) -> String {
        let lower = session.displayName.lowercased()
        if lower.contains("bug") || lower.contains("fix") || lower.contains("error") || lower.contains("crash") {
            return "session-bug"
        }
        if lower.contains("git") || lower.contains("merge") || lower.contains("rebase") || lower.contains("branch") || lower.contains("remote") {
            return "session-git"
        }
        if lower.contains("ui") || lower.contains("view") || lower.contains("panel") || lower.contains("sidebar") || lower.contains("icon") || lower.contains("design") || lower.contains("screenshot") {
            return "session-layers"
        }
        if lower.contains("test") || lower.contains("audit") || lower.contains("verify") || lower.contains("fake") {
            return "session-shield"
        }
        if lower.contains("build") || lower.contains("deploy") || lower.contains("release") || lower.contains("launch") {
            return "session-rocket"
        }
        if lower.contains("dns") || lower.contains("web") || lower.contains("http") || lower.contains("net") || lower.contains("mail") {
            return "session-globe"
        }
        if lower.contains("db") || lower.contains("sql") || lower.contains("data") || lower.contains("disk") || lower.contains("store") {
            return "session-database"
        }
        if lower.contains("ssh") || lower.contains("cli") || lower.contains("bash") || lower.contains("shell") || lower.contains("server") {
            return "session-terminal"
        }
        if lower.contains("auth") || lower.contains("trust") || lower.contains("lock") || lower.contains("security") {
            return "session-lock"
        }
        if lower.contains("perf") || lower.contains("fast") || lower.contains("speed") {
            return "session-flame"
        }
        // Deterministic fallback across all 16 icons in Assets.xcassets/SessionIcons
        var hash: UInt64 = 5381
        for byte in session.id.utf8 {
            hash = ((hash << 5) &+ hash) &+ UInt64(byte)
        }
        return all[Int(hash % UInt64(all.count))].id
    }

    private static let stopWords: Set<String> = [
        "the", "a", "an", "in", "on", "at", "to", "for", "of", "with", "from", "by",
        "and", "or", "but", "is", "are", "was", "were", "be", "been", "this", "that",
        "these", "those", "it", "its", "my", "our", "your", "we", "you", "i", "me",
        "please", "can", "could", "would", "should", "need", "make", "do", "deal",
        "ok", "okay", "hey", "hi", "ensure", "when", "see", "pretty", "big", "just",
        "users", "mac", "documents", "following", "changes", "update", "replace"
    ]

    /// Generates a readable 4–5 character shorthand string for a session.
    static func defaultShorthand(for session: SessionRef) -> String {
        let raw = session.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let tokens = raw
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { token in
                guard token.count >= 2 else { return false }
                let lower = token.lowercased()
                if stopWords.contains(lower) { return false }
                // Skip pure timestamps/numbers like "2026", "10", "28", "13"
                if token.allSatisfy(\.isNumber) { return false }
                return true
            }

        if let first = tokens.first {
            let upper = first.uppercased()
            if (4...5).contains(upper.count) {
                return upper
            }
            if upper.count > 5 {
                return abbreviateWord(upper)
            }
            // First token is 2–3 chars; combine with second token if available
            if tokens.count >= 2 {
                let combined = (upper + tokens[1].uppercased())
                return String(combined.prefix(5))
            }
            return upper.padding(toLength: min(4, max(upper.count, 4)), withPad: " ", startingAt: 0)
                .trimmingCharacters(in: .whitespaces)
        }

        // Fallback to project directory name (4–5 chars)
        let proj = URL(fileURLWithPath: session.cwd).lastPathComponent.uppercased()
            .filter { $0.isLetter || $0.isNumber }
        if proj.count >= 4 {
            return String(proj.prefix(5))
        }
        return proj.isEmpty ? "MUSE" : proj
    }

    private static func abbreviateWord(_ word: String) -> String {
        // Common developer stems look cleanest as their first 5 characters (e.g. BUILD, MERGE, TACHO, PANEL, MODEL, SUPER)
        let commonPrefixes = ["BUILD", "MERGE", "REBAS", "REFAC", "AUDIT", "CLEAN", "SCRN", "SDBAR", "PANEL", "MODEL", "AGENT", "VOICE", "TACHO", "REMOT", "CLOUD", "SERVR", "THEME", "SETUP", "DEBUG"]
        for prefix in commonPrefixes where word.hasPrefix(prefix.prefix(4)) {
            return String(word.prefix(5))
        }
        return String(word.prefix(5))
    }
}
