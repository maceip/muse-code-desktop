//
//  SessionIndex.swift
//  PiCode
//
//  Builds the project and session list from Muse's own session directory
//  (`~/.local/share/muse/sessions`).
//

import Foundation

enum PiPaths {
    /// Muse's configuration directory. Defaults to `~/.config/muse`, with
    /// `MUSE_HOME` / `PI_CODING_AGENT_DIR` overrides supported.
    static var agentDirectory: URL {
        let env = ProcessInfo.processInfo.environment
        if let raw = env["MUSE_HOME"] ?? env["PI_CODING_AGENT_DIR"] {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return expandAndStandardize(trimmed)
            }
        }
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".config/muse", isDirectory: true)
            .standardizedFileURL
    }

    /// Muse's shared data directory (`~/.local/share/muse`).
    static var dataDirectory: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".local/share/muse", isDirectory: true)
            .standardizedFileURL
    }

    /// Muse's cached model catalog directory (`~/.local/share/muse/model-catalog`).
    static var modelCatalogDirectory: URL {
        dataDirectory.appendingPathComponent("model-catalog", isDirectory: true)
    }

    /// Muse's session root directory. Defaults to `~/.local/share/muse/sessions`
    /// unless overridden by environment or `settings.json`.
    static var sessionsDirectory: URL {
        let env = ProcessInfo.processInfo.environment
        if let raw = env["MUSE_SESSION_DIR"] ?? env["PI_CODING_AGENT_SESSION_DIR"],
           let url = validAbsoluteDirectoryURL(raw) {
            return url
        }
        if let configured = configuredSessionDirectory() {
            return configured
        }
        if env["MUSE_HOME"] != nil || env["PI_CODING_AGENT_DIR"] != nil {
            return agentDirectory
                .appendingPathComponent("sessions", isDirectory: true)
                .standardizedFileURL
        }
        return dataDirectory
            .appendingPathComponent("sessions", isDirectory: true)
            .standardizedFileURL
    }

    static var settingsFile: URL {
        agentDirectory.appendingPathComponent("settings.json")
    }

    static var trustFile: URL {
        agentDirectory.appendingPathComponent("trust.json")
    }

    static var authFile: URL {
        agentDirectory.appendingPathComponent("auth.json")
    }

    static var approvalPolicyFile: URL {
        agentDirectory.appendingPathComponent("approval-policy.json")
    }

    static var modelsFile: URL {
        agentDirectory.appendingPathComponent("models.json")
    }

    static var keybindingsFile: URL {
        agentDirectory.appendingPathComponent("keybindings.json")
    }

    private static func configuredSessionDirectory() -> URL? {
        guard let data = try? Data(contentsOf: settingsFile),
              let json = try? JSONCoding.decode(data),
              let raw = json.string("sessionDir")
        else { return nil }
        return validAbsoluteDirectoryURL(raw)
    }

    private static func validAbsoluteDirectoryURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.hasPrefix("/") || trimmed.hasPrefix("~") else {
            return nil
        }
        return expandAndStandardize(trimmed)
    }

    private static func expandAndStandardize(_ path: String) -> URL {
        let expanded: String
        if path == "~" {
            expanded = NSHomeDirectory()
        } else if path.hasPrefix("~/") {
            expanded = NSHomeDirectory() + "/" + path.dropFirst(2)
        } else {
            expanded = (path as NSString).expandingTildeInPath
        }
        return URL(fileURLWithPath: expanded, isDirectory: true).standardizedFileURL
    }
}

struct SessionIndex {
    private static let cacheLock = NSLock()
    private static var cachedRefs: [String: (mtime: Date, size: Int, ref: SessionRef?)] = [:]

    /// Returns all top-level session directories containing valid sessions.
    func sessionDirectories() -> [URL] {
        let urls = sessionFileURLs()
        var seen = Set<String>()
        var dirs: [URL] = []
        for url in urls {
            let dir = url.deletingLastPathComponent()
            if seen.insert(dir.path).inserted {
                dirs.append(dir)
            }
        }
        return dirs
    }

    /// Returns all valid `.jsonl` session files under `PiPaths.sessionsDirectory`,
    /// excluding `/subagent/` logs and non-session sidecar streams.
    func sessionFileURLs() -> [URL] {
        let root = PiPaths.sessionsDirectory
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path),
              let enumerator = fm.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey, .contentModificationDateKey, .fileSizeKey],
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }

        var candidates: [URL] = []
        for case let url as URL in enumerator {
            if url.lastPathComponent == "subagent" {
                enumerator.skipDescendants()
                continue
            }
            guard url.pathExtension == "jsonl",
                  !url.path.contains("/subagent/") else { continue }
            if loadSessionRef(at: url) != nil {
                candidates.append(url)
            }
        }
        return candidates
    }

    func loadAllProjects() async -> [ProjectGroup] {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let refs = self.loadAllSessions()
                continuation.resume(returning: self.group(refs))
            }
        }
    }

    func loadAllSessions() -> [SessionRef] {
        let files = sessionFileURLs()
        return files.compactMap { loadSessionRef(at: $0) }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    func group(_ sessions: [SessionRef]) -> [ProjectGroup] {
        var byPath: [String: [SessionRef]] = [:]
        for session in sessions {
            let canonical = CanonicalPath.of(session.cwd)
            byPath[canonical, default: []].append(session)
        }
        return byPath.map { path, list in
            let sorted = list.sorted { $0.updatedAt > $1.updatedAt }
            let name = URL(fileURLWithPath: path).lastPathComponent
            return ProjectGroup(
                id: path,
                path: path,
                name: name.isEmpty ? path : name,
                sessions: sorted
            )
        }
        .sorted { $0.mostRecentActivity > $1.mostRecentActivity }
    }

    func loadSessionRef(at url: URL) -> SessionRef? {
        let path = url.path
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey, .fileSizeKey])
        let mtime = values?.contentModificationDate ?? Date.distantPast
        let size = values?.fileSize ?? 0

        Self.cacheLock.lock()
        if let hit = Self.cachedRefs[path], hit.mtime == mtime, hit.size == size {
            Self.cacheLock.unlock()
            if var ref = hit.ref {
                if let customTitle = SessionCatalogMetadata.title(for: ref), !customTitle.isEmpty {
                    ref.name = customTitle
                }
                return ref
            }
            return nil
        }
        Self.cacheLock.unlock()

        let parsed = Self.parseSessionFile(at: url, mtime: mtime, ctime: values?.creationDate)
        Self.cacheLock.lock()
        Self.cachedRefs[path] = (mtime: mtime, size: size, ref: parsed)
        Self.cacheLock.unlock()

        if var ref = parsed {
            if let customTitle = SessionCatalogMetadata.title(for: ref), !customTitle.isEmpty {
                ref.name = customTitle
            }
            return ref
        }
        return nil
    }

    private static func parseSessionFile(at url: URL, mtime: Date, ctime: Date?) -> SessionRef? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), !data.isEmpty else {
            return nil
        }
        let lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        guard let firstSlice = lines.first,
              let firstJSON = try? JSONCoding.decode(Data(firstSlice)) else {
            return nil
        }

        // 1. Native Muse session.jsonl format
        if firstJSON.string("payload_type") != nil || firstJSON.string("retained_frame") != nil || firstJSON.string("retained_marker") != nil {
            var sessionId: String? = url.deletingLastPathComponent().lastPathComponent
            var sessionName: String?
            var cwd: String?
            var createdAt: Date?
            var updatedAt: Date?
            var firstUserMessage: String?
            var messageCount = 0

            func inspect(_ record: JSONValue) {
                if let streamId = record.object("stream")?.string("id"), !streamId.isEmpty {
                    sessionId = streamId
                }
                if let us = record.int("recorded_at").map(Int64.init) ?? (record["recorded_at"]?.doubleValue.map { Int64($0) }),
                   us > 0 {
                    let date = Date(timeIntervalSince1970: Double(us) / 1_000_000.0)
                    if createdAt == nil { createdAt = date }
                    updatedAt = date
                }
                guard let payloadType = record.string("payload_type"),
                      let payload = record["payload"] else { return }

                switch payloadType {
                case "runtime.session.metadata":
                    if let rec = payload["record"] {
                        if let ws = rec.string("workspace_root"), !ws.isEmpty { cwd = ws }
                        if let sid = rec.string("session_id"), !sid.isEmpty { sessionId = sid }
                    }
                case "runtime.session.route_facts":
                    if let rec = payload["record"] {
                        if cwd == nil, let path = rec.string("cwd"), !path.isEmpty { cwd = path }
                        if let sid = rec.string("session_id"), !sid.isEmpty { sessionId = sid }
                    }
                case "session.name.changed":
                    if let newName = payload.string("new_name")?.trimmingCharacters(in: .whitespacesAndNewlines),
                       !newName.isEmpty {
                        sessionName = newName
                    }
                case "runtime.session":
                    guard payload.string("kind") == "run",
                          let event = payload["event"],
                          let eventKind = event.string("kind") else { return }
                    if eventKind == "started" {
                        if let prompt = event.string("prompt")?.trimmingCharacters(in: .whitespacesAndNewlines),
                           !prompt.isEmpty {
                            messageCount += 1
                            if firstUserMessage == nil {
                                firstUserMessage = prompt.oneLinePreview(limit: 160)
                            }
                        }
                    } else if eventKind == "assistant_message_committed" {
                        if let text = event.string("text")?.trimmingCharacters(in: .whitespacesAndNewlines),
                           !text.isEmpty {
                            messageCount += 1
                        }
                    }
                default:
                    break
                }
            }

            for line in lines {
                guard let record = try? JSONCoding.decode(Data(line)) else { continue }
                if let children = record.array("children") {
                    for child in children {
                        if let recordJSON = child.string("record_json"),
                           let nested = try? JSONCoding.decode(Data(recordJSON.utf8)) {
                            inspect(nested)
                        }
                    }
                } else {
                    inspect(record)
                }
            }

            guard let resolvedCwd = cwd, !resolvedCwd.isEmpty else {
                return nil
            }

            return SessionRef(
                id: url.path,
                sessionId: sessionId,
                filePath: url.path,
                name: sessionName,
                cwd: CanonicalPath.of(resolvedCwd),
                createdAt: createdAt ?? ctime ?? mtime,
                updatedAt: updatedAt ?? mtime,
                messageCount: messageCount,
                firstUserMessage: firstUserMessage,
                parentSession: nil,
                harnessID: .museCode
            )
        }

        // 2. Fallback for standard header JSONL (e.g. synthetic test fixtures)
        guard firstJSON.string("type") == "session",
              let cwd = firstJSON.string("cwd"), !cwd.isEmpty else {
            return nil
        }

        let sessionId = firstJSON.string("id")
        let parentSession = firstJSON.string("parentSession")
        let headerDate = firstJSON.string("timestamp").flatMap { ISO8601DateFormatter().date(from: $0) }
        var sessionName: String?
        var firstUserMessage: String?
        var messageCount = 0

        for line in lines.dropFirst() {
            guard let record = try? JSONCoding.decode(Data(line)) else { continue }
            switch record.string("type") {
            case "session_info":
                if let name = record.string("name")?.trimmingCharacters(in: .whitespacesAndNewlines) {
                    sessionName = name.isEmpty ? nil : name
                }
            case "message":
                guard let message = record["message"] else { continue }
                let role = message.string("role")
                if role == "user" || role == "assistant" {
                    messageCount += 1
                }
                if role == "user", firstUserMessage == nil {
                    let msg = PiMessage(raw: message)
                    let text = msg.textContent.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !text.isEmpty {
                        firstUserMessage = text.oneLinePreview(limit: 160)
                    }
                }
            default:
                break
            }
        }

        return SessionRef(
            id: url.path,
            sessionId: sessionId,
            filePath: url.path,
            name: sessionName,
            cwd: CanonicalPath.of(cwd),
            createdAt: headerDate ?? ctime ?? mtime,
            updatedAt: mtime,
            messageCount: messageCount,
            firstUserMessage: firstUserMessage,
            parentSession: parentSession,
            harnessID: .museCode
        )
    }

    // MARK: - Search

    /// Local substring search across names, project paths, and prompt text.
    func search(_ query: String, in projects: [ProjectGroup]) -> [ProjectGroup] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return projects }
        return projects.compactMap { project in
            var project = project
            let projectMatches = project.name.lowercased().contains(needle)
                || project.path.lowercased().contains(needle)
            let sessions = project.sessions.filter { ref in
                projectMatches
                    || (ref.name ?? "").lowercased().contains(needle)
                    || (ref.firstUserMessage ?? "").lowercased().contains(needle)
            }
            guard projectMatches || !sessions.isEmpty else { return nil }
            project.sessions = sessions
            return project
        }
    }
}

/// Canonical path helper. Uses `resolvingSymlinksInPath` so a project reached
/// through a symlink groups with the same sessions Muse recorded.
enum CanonicalPath {
    static func of(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
    }
}
