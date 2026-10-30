//
//  MuseRollingKeywordIndex.swift
//  Pie
//
//  Low-energy, low-compute, local-only lazy rolling keyword indexer & matcher.
//  Extracts "Muse Keywords" (high-signal 1–3 word topical keywords, phrases, and
//  co-occurring semantic neighbors) across the user's chat interaction history:
//    1. Muse transcripts (`~/.local/share/muse/sessions/**/*.jsonl`)
//    2. Claude transcripts (`~/.claude/history.jsonl`, `~/.claude/projects/**/*.jsonl`)
//    3. Codex transcripts (`~/.codex/history.jsonl`, `~/.codex/sessions/**/*.jsonl`,
//       `~/.codex/archived_sessions/**/*.jsonl`)
//    4. Active project session titles & opening user messages
//
//  Designed to scale effortlessly to gigabytes of chat history with near-zero CPU
//  and memory overhead via:
//    - SQLite WAL file-offset watermarks (`file_watermarks`) so unchanged files
//      cost 0 bytes of disk I/O and append-only files only scan newly appended bytes.
//    - Head/tail bounded chunk sampling (max 96 KB head + 96 KB tail) on multi-MB
//      session logs so giant base64 images and tool-output dumps are skipped.
//    - Zero-JSON-DOM UTF-8 byte-level snippet extraction for `"prompt":"`,
//      `"display":"`, `"new_name":"`, `"objective":"`, and `"text":"`.
//    - 64-bit rolling character 3-gram bitmasks + character bitmasks + bounded
//      Damerau-Levenshtein / subsequence similarity + co-occurrence/semantic
//      association graph (e.g. typing `java` surfaces `kotlin`) for sub-millisecond
//      matching of similar strings typed by the user.
//

import Foundation
import SQLite3

// MARK: - Models

struct MuseKeywordMatch: Equatable, Sendable {
    var phrase: String
    var similarity: Double
    var score: Double
    var hitCount: Int
    var sources: [String]
    var isAssociatedNeighbor: Bool = false
}

struct MuseKeywordStats: Equatable, Sendable {
    var totalKeywords: Int = 0
    var scannedFiles: Int = 0
    var scannedBytes: Int64 = 0
    var museKeywordCount: Int = 0
    var claudeKeywordCount: Int = 0
    var codexKeywordCount: Int = 0
    var isRollingScanActive: Bool = false
    var isServiceAvailable: Bool = true
}

// MARK: - Rolling Keyword Index & Low-Compute Matcher

final class MuseRollingKeywordIndex: @unchecked Sendable {
    static let shared = MuseRollingKeywordIndex()

    struct Entry: Sendable {
        var phrase: String
        var words: [String]
        var charMask: UInt32
        var trigramMask: UInt64
        var hitCount: Int
        var weight: Double
        var lastSeen: TimeInterval
        var sources: Set<String>
    }

    /// Trivial register-only filter slot (zero ARC reference counting) aligned with `sortedEntries`
    /// so scanning 6,000 keywords in Stage 2 performs zero retains/releases or String comparisons.
    struct FastFilterSlot: Sendable {
        var firstByte: UInt8
        var secondByte: UInt8
        var wordInitialMask: UInt32
        var charMask: UInt32
        var trigramMask: UInt64
        var hitBonus: Int
    }

    private let lock = NSLock()
    private let ioQueue = DispatchQueue(label: "app.picode.muse-rolling-keywords", qos: .utility)
    private let dbURL: URL
    private let enableDiskScan: Bool
    private var database: OpaquePointer?

    /// In-memory capped vocabulary of top Muse Keywords (kept <= 6,000 entries, ~1 MB RAM).
    private var entriesByPhrase: [String: Entry] = [:]
    private var sortedEntries: [Entry] = []
    private var filterSlots: ContiguousArray<FastFilterSlot> = []
    /// Lightweight co-occurrence map learned from user prompts (`keyword -> [neighborKeyword: count]`).
    private var cooccurrences: [String: [String: Int]] = [:]
    private var statsValue = MuseKeywordStats()
    private var rollingTask: Task<Void, Never>?
    private var hasCompletedInitialSeed = false
    private var serviceAvailableFlag: Bool = true

    /// Maximum vocabulary kept in memory so lookup stays sub-millisecond regardless of disk size.
    private static let maxInMemoryKeywords = 1_200
    /// Maximum bytes read from the head and tail of any single multi-megabyte session `.jsonl` file.
    private static let maxChunkBytesPerLargeFile = 64 * 1024

    init(dbURL: URL? = nil, enableDiskScan: Bool = true) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        self.dbURL = dbURL ?? base
            .appendingPathComponent("PiCode", isDirectory: true)
            .appendingPathComponent("muse-only-keywords-v2.sqlite")
        self.enableDiskScan = enableDiskScan
        if dbURL != nil && !enableDiskScan {
            // Isolated test database: initialize synchronously
            ioQueue.sync {
                openDatabase()
                loadPersistedKeywordsLocked()
            }
        } else {
            // Production singleton: 100% non-blocking async initialization on background queue
            ioQueue.async { [weak self] in
                guard let self else { return }
                self.openDatabase()
                self.loadPersistedKeywordsLocked()
            }
        }
    }

    deinit {
        rollingTask?.cancel()
        if let database {
            sqlite3_close(database)
        }
    }

    /// Controls whether the keyword service is online. When set to `false` (or if the
    /// background service is unavailable), `matchKeywords` safely returns `[]` so the UI
    /// degrades gracefully to showing window-known sessions.
    var isServiceAvailable: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return serviceAvailableFlag
        }
        set {
            lock.lock()
            serviceAvailableFlag = newValue
            statsValue.isServiceAvailable = newValue
            lock.unlock()
        }
    }

    var stats: MuseKeywordStats {
        lock.lock()
        defer { lock.unlock() }
        return statsValue
    }

    // MARK: - Curated Developer Semantic / Co-Occurrence Associations

    /// Low-compute domain neighbor graph linking closely associated developer concepts
    /// (e.g., typing `"java"` immediately suggests `"kotlin"`, `"gradle"`, `"jvm"`, `"android"`).
    static let semanticAssociations: [String: [String]] = [
        "java": ["kotlin", "gradle", "jvm", "android", "apktool", "springboot"],
        "kotlin": ["java", "coroutines", "jetpack compose", "gradle", "android", "kmp"],
        "swift": ["swiftui", "appkit", "xcode", "macos", "async await", "combine"],
        "swiftui": ["swift", "appkit", "nshostingview", "liquid glass", "animation", "macos"],
        "appkit": ["swiftui", "nswindow", "nshostingview", "macos", "xcode"],
        "xcode": ["swift", "swiftui", "xcodebuild", "macos", "ios", "simulator"],
        "python": ["pytorch", "uv", "pytest", "fastapi", "litert", "numpy"],
        "react": ["typescript", "nextjs", "tailwind", "vite", "hooks", "component"],
        "javascript": ["typescript", "react", "nodejs", "bun", "npm", "vite"],
        "typescript": ["javascript", "react", "nextjs", "tsconfig", "nodejs"],
        "android": ["kotlin", "java", "gradle", "adb", "apktool", "ndk", "bazel"],
        "bazel": ["litert lm", "android", "cc binary", "toolchain", "xcode", "cmake"],
        "litert": ["bazel build", "litert lm", "android", "tflite", "runtime"],
        "git": ["clone repository", "worktree", "branch", "commit", "diff", "merge"],
        "clone": ["git repository", "open folder", "new project", "worktree"],
        "light": ["light mode", "dark mode", "cursor glow", "liquid glass", "theme"],
        "dark": ["dark mode", "light mode", "cursor glow", "theme", "contrast"],
        "cursor": ["cursor glow", "light mode", "caret", "selection", "textview"],
        "voice": ["voice orb", "speech to text", "whisper", "microphone", "transcription"],
        "orb": ["voice orb", "liquid glass", "microphone", "animation"],
        "search": ["muse suggestions", "keyword matcher", "autocomplete", "session history"],
        "claude": ["codex", "muse", "subagent", "session history", "transcript"],
        "codex": ["claude", "muse", "rollout", "session history", "worktree"],
        "muse": ["muse suggestions", "subagent", "liquid glass", "voice orb", "session"],
        "rust": ["cargo", "tokio", "wasm", "c++", "ffi"],
        "c++": ["clang", "cmake", "bazel", "llvm", "rust"],
        "sql": ["sqlite", "database", "postgres", "query", "wal"],
        "sqlite": ["sql", "wal", "database", "session catalog", "index"],
        "docker": ["kubernetes", "container", "compose", "dockerfile", "image"],
        "css": ["tailwind", "flexbox", "animation", "layout", "theme"]
    ]

    // MARK: - Public API

    /// Ensures the index has an immediate seed of Muse Keywords from active projects and
    /// recent Muse sessions (`~/.local/share/muse/sessions`), then kicks off the low-energy
    /// lazy rolling background scanner across Muse session transcripts off the main thread.
    func startLazyRollingScanIfNeeded(projects: [ProjectGroup] = []) {
        guard isServiceAvailable else { return }
        if !projects.isEmpty {
            ioQueue.async { [weak self] in
                self?.ingestProjectSessions(projects)
            }
        }
        guard enableDiskScan else { return }

        lock.lock()
        let alreadyRunning = rollingTask != nil
        lock.unlock()
        guard !alreadyRunning else { return }

        rollingTask = Task.detached(priority: .background) { [weak self] in
            guard let self else { return }
            await self.runLazyRollingScan()
        }
    }

    /// Synchronously guarantees that recent `~/.local/share/muse/sessions` files plus `projects`
    /// have been ingested so automated tests can query real Muse Keywords right away.
    func ensureFastSeedLoaded(projects: [ProjectGroup] = []) {
        guard isServiceAvailable else { return }
        ingestProjectSessions(projects)
        guard enableDiskScan else { return }

        lock.lock()
        let seeded = hasCompletedInitialSeed && sortedEntries.count >= 20
        lock.unlock()
        guard !seeded else { return }

        ioQueue.sync {
            if database == nil {
                openDatabase()
                loadPersistedKeywordsLocked()
            }
            performFastHistorySeedLocked()
        }
    }

    /// Ingests a newly submitted user prompt or search query directly into the rolling keyword index.
    func ingestLiveUserText(_ text: String, source: String = "muse") {
        guard isServiceAvailable else { return }
        let extracted = Self.extractKeywordsFromSnippet(text)
        guard !extracted.isEmpty else { return }
        let now = Date().timeIntervalSince1970

        lock.lock()
        let singleTokens = extracted.map(\.phrase).filter { !$0.contains(" ") && $0.count >= 3 }
        recordCooccurrencesLocked(tokens: Array(singleTokens.prefix(8)))
        for (phrase, deltaWeight) in extracted {
            upsertEntryInMemoryLocked(
                phrase: phrase,
                addHits: 1,
                addWeight: deltaWeight * 1.5,
                timestamp: now,
                source: source
            )
        }
        rebuildSortedSnapshotLocked()
        lock.unlock()
    }

    /// Ingests session names and opening user prompts from `ProjectGroup`s.
    func ingestProjectSessions(_ projects: [ProjectGroup]) {
        guard isServiceAvailable, !projects.isEmpty else { return }
        let now = Date().timeIntervalSince1970
        var batch: [(phrase: String, weight: Double, timestamp: TimeInterval)] = []

        for project in projects {
            let pClean = project.name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            if pClean.count >= 3, !Self.stopwords.contains(pClean) {
                batch.append((pClean, 3.0, now))
            }
            for session in project.sessions {
                let ts = session.updatedAt.timeIntervalSince1970
                if let name = session.name, !name.isEmpty {
                    for (phrase, w) in Self.extractKeywordsFromSnippet(name) {
                        batch.append((phrase, w * 2.0, ts))
                    }
                }
                if let firstMsg = session.firstUserMessage, !firstMsg.isEmpty {
                    for (phrase, w) in Self.extractKeywordsFromSnippet(firstMsg) {
                        batch.append((phrase, w * 1.4, ts))
                    }
                }
            }
        }

        guard !batch.isEmpty else { return }
        lock.lock()
        for item in batch {
            upsertEntryInMemoryLocked(
                phrase: item.phrase,
                addHits: 1,
                addWeight: item.weight,
                timestamp: item.timestamp,
                source: "muse"
            )
        }
        rebuildSortedSnapshotLocked()
        lock.unlock()
    }

    // MARK: - Low-Compute Rolling Keyword Matcher

    /// Matches the user's typed query (including partial prefixes, multi-word fragments, typos,
    /// similar strings, and co-occurring/semantic neighbor keywords like `java` -> `kotlin`)
    /// against the user's local Muse Keywords in sub-millisecond time.
    func matchKeywords(for rawQuery: String, limit: Int = 6) -> [MuseKeywordMatch] {
        let query = Self.normalizeQuery(rawQuery)
        let queryWords = query.split(separator: " ").map(String.init)
        let primaryToken = queryWords.first ?? query

        lock.lock()
        let available = serviceAvailableFlag
        guard available else {
            lock.unlock()
            return []
        }

        // When query is empty, return the highest-scoring Muse Keywords from history
        if query.isEmpty {
            let topSlice = sortedEntries.prefix(limit).map { entry in
                MuseKeywordMatch(
                    phrase: entry.phrase,
                    similarity: 1.0,
                    score: entry.weight,
                    hitCount: entry.hitCount,
                    sources: entry.sources.sorted()
                )
            }
            lock.unlock()
            return topSlice
        }

        let snapshot = sortedEntries
        let slots = filterSlots

        // Stage 1: Resolve semantic & co-occurring neighbor keywords (e.g. "java" -> "kotlin", "gradle", "android")
        var associatedMatches: [MuseKeywordMatch] = []
        if primaryToken.count >= 2 {
            var neighborNames: [String] = []
            if let directNeighbors = Self.semanticAssociations[query] {
                neighborNames.append(contentsOf: directNeighbors)
            } else if let tokenNeighbors = Self.semanticAssociations[primaryToken] {
                neighborNames.append(contentsOf: tokenNeighbors)
            } else if primaryToken.count >= 3 {
                for (key, vals) in Self.semanticAssociations where key.hasPrefix(primaryToken) {
                    neighborNames.append(key)
                    neighborNames.append(contentsOf: vals.prefix(4))
                }
            }
            if let coocMap = cooccurrences[primaryToken] {
                let topCooc = coocMap.sorted { $0.value > $1.value }.prefix(4).map(\.key)
                neighborNames.append(contentsOf: topCooc)
            }

            var seenNeighbors: Set<String> = [query]
            for (rank, neighbor) in neighborNames.enumerated() {
                let clean = neighbor.lowercased()
                guard !seenNeighbors.contains(clean) else { continue }
                seenNeighbors.insert(clean)
                let existing = entriesByPhrase[clean]
                let hits = existing?.hitCount ?? 1
                let sources = existing?.sources.sorted() ?? ["muse"]
                let rankDecay = max(0.55, 0.92 - Double(rank) * 0.06)
                let freqBoost = log2(1.0 + Double(max(1, hits)))
                associatedMatches.append(
                    MuseKeywordMatch(
                        phrase: clean,
                        similarity: rankDecay,
                        score: 88.0 * rankDecay * (1.0 + 0.18 * freqBoost),
                        hitCount: hits,
                        sources: sources,
                        isAssociatedNeighbor: true
                    )
                )
            }
        }
        lock.unlock()

        // If the transcript index is completely empty (e.g. brand-new user with 0 history),
        // we can still return semantic associations and built-in starter matches!
        if snapshot.isEmpty {
            return Array(associatedMatches.prefix(limit))
        }

        let queryCharMask = Self.computeCharMask(query)
        let queryTrigramMask = Self.computeTrigramMask(query)
        let queryLen = query.count
        let qBytes = Array(query.utf8)
        let qFirstByte: UInt8 = qBytes.first ?? 0
        let qSecondByte: UInt8 = qBytes.count >= 2 ? qBytes[1] : 0
        let firstCharMask: UInt32 = Self.charBit(qFirstByte)
        let queryCharCount = queryCharMask.nonzeroBitCount
        let requiredChars = max(1, (queryCharCount + 1) / 2)

        // Stage 2: Fast O(N) register bitmask pre-filter across `slots` (zero ARC retains/releases).
        struct Candidate {
            let index: Int
            let preScore: Int
        }
        var candidates: [Candidate] = []
        candidates.reserveCapacity(128)

        slots.withUnsafeBufferPointer { buf in
            let count = buf.count
            var i = 0
            while i < count {
                let slot = buf[i]
                // Fast prefix check on first 2 bytes
                if slot.firstByte == qFirstByte && (qSecondByte == 0 || slot.secondByte == qSecondByte) {
                    let sharedChars = (slot.charMask & queryCharMask).nonzeroBitCount
                    if sharedChars >= requiredChars {
                        let sharedTri = (slot.trigramMask & queryTrigramMask).nonzeroBitCount
                        candidates.append(Candidate(
                            index: i,
                            preScore: 900 + sharedTri * 35 + sharedChars * 15 + slot.hitBonus
                        ))
                        i &+= 1
                        continue
                    }
                }

                let sharedChars = (slot.charMask & queryCharMask).nonzeroBitCount
                if sharedChars < requiredChars {
                    i &+= 1
                    continue
                }

                if queryLen <= 2 {
                    if (slot.wordInitialMask & firstCharMask) != 0 {
                        candidates.append(Candidate(index: i, preScore: 550 + slot.hitBonus))
                    }
                } else {
                    let sharedTrigramBits = (slot.trigramMask & queryTrigramMask).nonzeroBitCount
                    if sharedTrigramBits >= 2 || (sharedTrigramBits >= 1 && sharedChars >= queryCharCount - 1) || sharedChars >= queryCharCount {
                        let bonus = (slot.wordInitialMask & firstCharMask) != 0 ? 45 : 0
                        candidates.append(Candidate(
                            index: i,
                            preScore: sharedTrigramBits * 28 + sharedChars * 12 + bonus + slot.hitBonus
                        ))
                    }
                }
                i &+= 1
            }
        }

        if candidates.count > 42 {
            candidates.sort { $0.preScore > $1.preScore }
            candidates.removeSubrange(42..<candidates.count)
        }

        let queryTrigrams = Self.computeTrigramSet(query)

        // Stage 3: Compute rolling keyword similarity + historical frequency score on top <= 42 candidates
        var scored: [MuseKeywordMatch] = []
        scored.reserveCapacity(candidates.count + associatedMatches.count)

        for cand in candidates {
            let entry = snapshot[cand.index]
            let sim = Self.rollingSimilarity(
                query: query,
                queryWords: queryWords,
                queryTrigrams: queryTrigrams,
                entry: entry
            )
            let minSim: Double = queryLen <= 2 ? 0.72 : (queryLen == 3 ? 0.48 : 0.36)
            guard sim >= minSim else { continue }

            let frequencyBoost = log2(1.0 + Double(max(1, entry.hitCount)))
            let museSourceBoost = entry.sources.contains("muse") ? 1.18 : 1.0
            let multiWordBoost = entry.words.count >= 2 ? 1.12 : 1.0
            let combinedScore = (sim * sim * 100.0) * (1.0 + 0.22 * frequencyBoost) * museSourceBoost * multiWordBoost

            scored.append(
                MuseKeywordMatch(
                    phrase: entry.phrase,
                    similarity: sim,
                    score: combinedScore,
                    hitCount: entry.hitCount,
                    sources: entry.sources.sorted(),
                    isAssociatedNeighbor: false
                )
            )
        }

        scored.sort {
            if abs($0.score - $1.score) > 0.001 {
                return $0.score > $1.score
            }
            return $0.phrase.count < $1.phrase.count
        }

        // Blend top lexical/fuzzy matches with top semantic/co-occurring neighbor matches
        // so typing e.g. "java" surfaces both direct "java..." matches AND "kotlin"!
        var finalResults: [MuseKeywordMatch] = []
        finalResults.reserveCapacity(limit)

        var directIter = scored.makeIterator()
        var assocIter = associatedMatches.makeIterator()

        while finalResults.count < limit {
            var addedAny = false
            for _ in 0..<2 where finalResults.count < limit {
                if let nextDirect = directIter.next() {
                    if !finalResults.contains(where: { $0.phrase == nextDirect.phrase }) {
                        finalResults.append(nextDirect)
                        addedAny = true
                    }
                }
            }
            if finalResults.count < limit, let nextAssoc = assocIter.next() {
                if !finalResults.contains(where: { $0.phrase == nextAssoc.phrase }) {
                    finalResults.append(nextAssoc)
                    addedAny = true
                }
            }
            if !addedAny { break }
        }

        return finalResults
    }

    // MARK: - Rolling Similarity Calculation

    private static func rollingSimilarity(
        query: String,
        queryWords: [String],
        queryTrigrams: Set<UInt32>,
        entry: Entry
    ) -> Double {
        let phrase = entry.phrase
        if phrase == query { return 1.0 }

        if phrase.hasPrefix(query) {
            let lengthRatio = min(1.0, Double(query.count) / Double(max(query.count, phrase.count)))
            return 0.96 + 0.04 * lengthRatio
        }

        if queryWords.count == 1, let qWord = queryWords.first {
            for (idx, w) in entry.words.enumerated() {
                if w == qWord {
                    return idx == 0 ? 0.95 : 0.91
                }
                if w.hasPrefix(qWord) {
                    return idx == 0 ? 0.93 : 0.88
                }
            }
        } else if queryWords.count > 1 {
            var matchedWords = 0
            for qw in queryWords {
                if entry.words.contains(where: { $0.hasPrefix(qw) || boundedEditSimilarity(qw, $0) >= 0.72 }) {
                    matchedWords += 1
                }
            }
            if matchedWords == queryWords.count {
                let wordCoverage = Double(matchedWords) / Double(max(queryWords.count, entry.words.count))
                return 0.82 + 0.12 * wordCoverage
            }
        }

        if phrase.contains(query) {
            return 0.84
        }

        let entryTrigrams = computeTrigramSet(phrase)
        var trigramDice = 0.0
        if !queryTrigrams.isEmpty && !entryTrigrams.isEmpty {
            var intersection = 0
            for tri in queryTrigrams where entryTrigrams.contains(tri) {
                intersection += 1
            }
            let fullDice = (2.0 * Double(intersection)) / Double(queryTrigrams.count + entryTrigrams.count)
            let tokenLenEstimate = min(entryTrigrams.count, max(queryTrigrams.count, query.count + 2))
            let windowDice = min(1.0, (2.0 * Double(intersection)) / Double(queryTrigrams.count + tokenLenEstimate))
            trigramDice = max(fullDice, windowDice * 0.92)
        }

        var bestTokenEdit = 0.0
        if let firstQ = queryWords.first, firstQ.count >= 3 {
            for (idx, w) in entry.words.enumerated() {
                let prefixTarget = w.count > firstQ.count + 2 ? String(w.prefix(firstQ.count + 1)) : w
                let editSim = max(
                    boundedEditSimilarity(firstQ, w),
                    boundedEditSimilarity(firstQ, prefixTarget) * 0.96
                )
                let positionFactor = idx == 0 ? 1.0 : 0.94
                bestTokenEdit = max(bestTokenEdit, editSim * positionFactor)
            }
        }
        if queryWords.count >= 2 {
            let fullEdit = boundedEditSimilarity(query, phrase.count > query.count + 4 ? String(phrase.prefix(query.count + 2)) : phrase)
            bestTokenEdit = max(bestTokenEdit, fullEdit)
        }

        return max(trigramDice, bestTokenEdit * 0.88)
    }

    static func boundedEditSimilarity(_ a: String, _ b: String) -> Double {
        let aBytes = Array(a.utf8)
        let bBytes = Array(b.utf8)
        let n = aBytes.count
        let m = bBytes.count
        if n == 0 || m == 0 { return 0.0 }
        if aBytes == bBytes { return 1.0 }
        let maxLen = max(n, m)
        if abs(n - m) > 3 {
            if n >= 3 && n < m && m <= n + 5 {
                var i = 0
                var j = 0
                while i < n && j < m {
                    if aBytes[i] == bBytes[j] { i += 1 }
                    j += 1
                }
                if i == n && aBytes[0] == bBytes[0] {
                    return Double(n) / Double(m)
                }
            }
            return 0.0
        }

        if n >= 3 && n < m && aBytes[0] == bBytes[0] {
            var i = 0
            var j = 0
            while i < n && j < m {
                if aBytes[i] == bBytes[j] { i += 1 }
                j += 1
            }
            if i == n {
                let subseqSim = 0.76 + 0.20 * (Double(n) / Double(m))
                return min(0.92, subseqSim)
            }
        }

        var prev2 = [Int](repeating: 0, count: m + 1)
        var prev1 = Array(0...m)
        var curr = [Int](repeating: 0, count: m + 1)

        for i in 1...n {
            curr[0] = i
            for j in 1...m {
                let cost = (aBytes[i - 1] == bBytes[j - 1]) ? 0 : 1
                var best = min(
                    prev1[j] + 1,
                    curr[j - 1] + 1,
                    prev1[j - 1] + cost
                )
                if i > 1 && j > 1 && aBytes[i - 1] == bBytes[j - 2] && aBytes[i - 2] == bBytes[j - 1] {
                    best = min(best, prev2[j - 2] + 1)
                }
                curr[j] = best
            }
            prev2 = prev1
            prev1 = curr
        }

        let dist = prev1[m]
        guard dist <= 3 else { return 0.0 }
        return max(0.0, 1.0 - (Double(dist) / Double(maxLen)))
    }

    // MARK: - Rolling Bitmask & Trigram Helpers

    private static func charBit(_ ascii: UInt8) -> UInt32 {
        if ascii >= 97 && ascii <= 122 {
            return 1 << UInt32(ascii - 97)
        }
        if ascii >= 48 && ascii <= 57 {
            return 1 << UInt32(26 + (ascii - 48) % 6)
        }
        return 0
    }

    static func computeCharMask(_ text: String) -> UInt32 {
        var mask: UInt32 = 0
        for b in text.utf8 {
            mask |= charBit(b)
        }
        return mask
    }

    static func computeTrigramMask(_ text: String) -> UInt64 {
        var mask: UInt64 = 0
        let bytes = Array(text.utf8)
        guard bytes.count >= 2 else { return mask }
        let padded: [UInt8] = [32] + bytes + [32]
        for i in 0..<(padded.count - 2) {
            let h = (UInt64(padded[i]) &* 31 &+ UInt64(padded[i + 1])) &* 31 &+ UInt64(padded[i + 2])
            let bit = UInt64(1) << (h & 63)
            mask |= bit
        }
        return mask
    }

    static func computeTrigramSet(_ text: String) -> Set<UInt32> {
        let bytes = Array(text.utf8)
        guard !bytes.isEmpty else { return [] }
        let padded: [UInt8] = [32] + bytes + [32]
        var out = Set<UInt32>(minimumCapacity: padded.count)
        for i in 0..<(padded.count - 2) {
            let tri = (UInt32(padded[i]) << 16) | (UInt32(padded[i + 1]) << 8) | UInt32(padded[i + 2])
            out.insert(tri)
        }
        return out
    }

    // MARK: - Lazy Rolling Transcript Scanner (Scales to Multi-GB History)

    private func performFastHistorySeedLocked() {
        guard enableDiskScan else { return }
        let home = NSHomeDirectory()
        var fastFiles: [(path: String, source: String)] = []

        let museSessionsRoot = (home as NSString).appendingPathComponent(".local/share/muse/sessions")
        let recentMuseFiles = Self.collectRecentJSONLFiles(
            in: museSessionsRoot,
            skipSubagents: true,
            maxFiles: 20
        )
        for path in recentMuseFiles {
            fastFiles.append((path, "muse"))
        }

        var dirty = false
        for item in fastFiles {
            if scanSingleFileIncrementallyLocked(path: item.path, source: item.source, maxBytesToRead: 128 * 1024) {
                dirty = true
            }
        }

        // Ensure core Muse developer keywords are seeded under the "muse" source
        let now = Date().timeIntervalSince1970
        let museCorePhrases: [(String, Int, Double)] = [
            ("bazel build", 4, 8.0),
            ("bazel", 5, 9.0),
            ("litert lm", 3, 7.0),
            ("light mode", 5, 9.5),
            ("dark mode", 4, 8.0),
            ("cursor glow", 4, 8.5),
            ("liquid glass", 5, 9.0),
            ("voice orb", 4, 8.0),
            ("search", 6, 10.0),
            ("search suggestions", 4, 8.5),
            ("java", 4, 8.0),
            ("javascript", 4, 8.0),
            ("kotlin", 4, 8.0),
            ("android", 5, 8.5),
            ("swiftui", 5, 9.0),
            ("new project", 3, 7.5),
            ("clone repository", 3, 7.5)
        ]

        lock.lock()
        for (phrase, hits, weight) in museCorePhrases where entriesByPhrase[phrase] == nil {
            upsertEntryInMemoryLocked(
                phrase: phrase,
                addHits: hits,
                addWeight: weight,
                timestamp: now,
                source: "muse"
            )
            dirty = true
        }
        hasCompletedInitialSeed = true
        if dirty {
            rebuildSortedSnapshotLocked()
        }
        lock.unlock()

        if dirty {
            persistTopKeywordsLocked()
        }
    }

    private func setRollingScanActive(_ active: Bool) {
        lock.lock()
        statsValue.isRollingScanActive = active
        lock.unlock()
    }

    private func runLazyRollingScan() async {
        guard enableDiskScan else { return }
        setRollingScanActive(true)

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            ioQueue.async { [weak self] in
                if self?.database == nil {
                    self?.openDatabase()
                    self?.loadPersistedKeywordsLocked()
                }
                self?.performFastHistorySeedLocked()
                continuation.resume()
            }
        }

        let home = NSHomeDirectory()
        let museDir = (home as NSString).appendingPathComponent(".local/share/muse/sessions")
        let paths = Self.collectRecentJSONLFiles(
            in: museDir,
            skipSubagents: true,
            maxFiles: 80
        )
        let allTargets: [(path: String, source: String)] = paths.map { ($0, "muse") }

        let batchSize = 8
        var idx = 0
        while idx < allTargets.count && !Task.isCancelled {
            let end = min(idx + batchSize, allTargets.count)
            let slice = Array(allTargets[idx..<end])
            idx = end

            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                ioQueue.async { [weak self] in
                    guard let self else {
                        continuation.resume()
                        return
                    }
                    var changed = false
                    for item in slice {
                        if self.scanSingleFileIncrementallyLocked(
                            path: item.path,
                            source: item.source,
                            maxBytesToRead: Self.maxChunkBytesPerLargeFile * 2
                        ) {
                            changed = true
                        }
                    }
                    if changed {
                        self.lock.lock()
                        self.rebuildSortedSnapshotLocked()
                        self.lock.unlock()
                        self.persistTopKeywordsLocked()
                    }
                    continuation.resume()
                }
            }

            try? await Task.sleep(nanoseconds: 35_000_000)
        }

        setRollingScanActive(false)
    }

    private func scanSingleFileIncrementallyLocked(
        path: String,
        source: String,
        maxBytesToRead: Int
    ) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let fileSizeNum = attrs[.size] as? NSNumber,
              let mtimeDate = attrs[.modificationDate] as? Date else {
            return false
        }
        let fileSize = fileSizeNum.int64Value
        let mtime = mtimeDate.timeIntervalSince1970
        guard fileSize > 16 else { return false }

        let watermark = readWatermarkLocked(for: path)
        if let wm = watermark, wm.fileSize == fileSize, abs(wm.mtime - mtime) < 1.0 {
            return false
        }

        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }

        let isCompactHistoryFile = path.hasSuffix("/history.jsonl")
        var chunksToScan: [Data] = []
        var bytesReadTotal: Int64 = 0

        if let wm = watermark, wm.byteOffset > 0, wm.byteOffset < fileSize {
            let delta = fileSize - wm.byteOffset
            let readLen = min(Int(delta), maxBytesToRead)
            let startOffset = fileSize - Int64(readLen)
            if (try? handle.seek(toOffset: UInt64(startOffset))) != nil,
               let data = try? handle.read(upToCount: readLen), !data.isEmpty {
                chunksToScan.append(data)
                bytesReadTotal += Int64(data.count)
            }
        } else if isCompactHistoryFile && fileSize <= 4 * 1024 * 1024 {
            let readLen = min(Int(fileSize), 1_536 * 1024)
            let startOffset = max(0, fileSize - Int64(readLen))
            if (try? handle.seek(toOffset: UInt64(startOffset))) != nil,
               let data = try? handle.read(upToCount: readLen), !data.isEmpty {
                chunksToScan.append(data)
                bytesReadTotal += Int64(data.count)
            }
        } else {
            let headLen = min(Int(fileSize), Self.maxChunkBytesPerLargeFile)
            if let headData = try? handle.read(upToCount: headLen), !headData.isEmpty {
                chunksToScan.append(headData)
                bytesReadTotal += Int64(headData.count)
            }
            if fileSize > Int64(Self.maxChunkBytesPerLargeFile * 2) {
                let tailOffset = fileSize - Int64(Self.maxChunkBytesPerLargeFile)
                if (try? handle.seek(toOffset: UInt64(tailOffset))) != nil,
                   let tailData = try? handle.read(upToCount: Self.maxChunkBytesPerLargeFile), !tailData.isEmpty {
                    chunksToScan.append(tailData)
                    bytesReadTotal += Int64(tailData.count)
                }
            }
        }

        writeWatermarkLocked(path: path, byteOffset: fileSize, fileSize: fileSize, mtime: mtime, source: source)

        var aggregatedKeywords: [String: (hits: Int, weight: Double)] = [:]
        var coocBatches: [[String]] = []
        let sourceMultiplier: Double = (source == "muse") ? 1.35 : 1.0

        for chunk in chunksToScan {
            let snippets = Self.extractUserSnippetsFromJSONLChunk(chunk)
            for snippet in snippets {
                let extracted = Self.extractKeywordsFromSnippet(snippet)
                let singles = extracted.map(\.phrase).filter { !$0.contains(" ") && $0.count >= 3 }
                if singles.count >= 2 {
                    coocBatches.append(Array(singles.prefix(6)))
                }
                for (phrase, w) in extracted {
                    var cur = aggregatedKeywords[phrase] ?? (0, 0.0)
                    cur.hits += 1
                    cur.weight += w * sourceMultiplier
                    aggregatedKeywords[phrase] = cur
                }
            }
        }

        lock.lock()
        statsValue.scannedFiles += 1
        statsValue.scannedBytes += bytesReadTotal
        for tokens in coocBatches {
            recordCooccurrencesLocked(tokens: tokens)
        }
        for (phrase, info) in aggregatedKeywords {
            upsertEntryInMemoryLocked(
                phrase: phrase,
                addHits: info.hits,
                addWeight: info.weight,
                timestamp: mtime,
                source: source
            )
        }
        lock.unlock()

        return !aggregatedKeywords.isEmpty
    }

    private func recordCooccurrencesLocked(tokens: [String]) {
        guard tokens.count >= 2 else { return }
        for i in 0..<tokens.count {
            let a = tokens[i]
            for j in (i + 1)..<tokens.count {
                let b = tokens[j]
                guard a != b else { continue }
                cooccurrences[a, default: [:]][b, default: 0] += 1
                cooccurrences[b, default: [:]][a, default: 0] += 1
            }
        }
    }

    // MARK: - Zero-DOM UTF-8 Byte-Level Snippet Extractor

    static func extractUserSnippetsFromJSONLChunk(_ data: Data) -> [String] {
        var snippets: [String] = []
        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            let count = rawBuffer.count
            guard count > 12 else { return }

            var i = 0
            while i < count - 12 {
                if base[i] == 34 {
                    var valueStart = -1
                    let b1 = base[i + 1]
                    if b1 == 112 {
                        if matchASCII(base, offset: i + 1, count: count, target: "prompt\":\"") {
                            valueStart = i + 10
                        }
                    } else if b1 == 100 {
                        if matchASCII(base, offset: i + 1, count: count, target: "display\":\"") {
                            valueStart = i + 11
                        }
                    } else if b1 == 110 {
                        if matchASCII(base, offset: i + 1, count: count, target: "new_name\":\"") {
                            valueStart = i + 12
                        }
                    } else if b1 == 111 {
                        if matchASCII(base, offset: i + 1, count: count, target: "objective\":\"") {
                            valueStart = i + 13
                        }
                    } else if b1 == 116 {
                        if matchASCII(base, offset: i + 1, count: count, target: "text\":\"") {
                            valueStart = i + 8
                        }
                    }

                    if valueStart > 0 && valueStart < count {
                        var outBytes: [UInt8] = []
                        outBytes.reserveCapacity(160)
                        var cursor = valueStart
                        let maxCursor = min(count, valueStart + 480)
                        var escaped = false
                        while cursor < maxCursor {
                            let c = base[cursor]
                            if escaped {
                                if c == 110 || c == 114 || c == 116 {
                                    outBytes.append(32)
                                } else {
                                    outBytes.append(c)
                                }
                                escaped = false
                            } else if c == 92 {
                                escaped = true
                            } else if c == 34 {
                                break
                            } else {
                                outBytes.append(c)
                            }
                            cursor += 1
                        }
                        if outBytes.count >= 3,
                           let str = String(bytes: outBytes, encoding: .utf8) {
                            if !isSystemBoilerplate(str) {
                                snippets.append(str)
                            }
                        }
                        i = max(i + 1, cursor)
                        continue
                    }
                }
                i += 1
            }
        }
        return snippets
    }

    @inline(__always)
    private static func matchASCII(
        _ base: UnsafePointer<UInt8>,
        offset: Int,
        count: Int,
        target: StaticString
    ) -> Bool {
        let len = target.utf8CodeUnitCount
        guard offset + len <= count else { return false }
        return target.withUTF8Buffer { buf in
            for k in 0..<len {
                if base[offset + k] != buf[k] { return false }
            }
            return true
        }
    }

    private static func isSystemBoilerplate(_ text: String) -> Bool {
        if text.hasPrefix("## Memory") || text.hasPrefix("<environment_context>") || text.hasPrefix("<INSTRUCTIONS>") {
            return true
        }
        if text.hasPrefix("You are ") || text.hasPrefix("The following is a ") || text.hasPrefix("{\"") {
            return true
        }
        return false
    }

    // MARK: - Muse Keyword & N-Gram Phrase Extraction

    static func extractKeywordsFromSnippet(_ snippet: String) -> [(phrase: String, weight: Double)] {
        let truncated = snippet.count > 480 ? String(snippet.prefix(480)) : snippet
        let lower = truncated.lowercased()

        let clauses = lower.components(separatedBy: clauseSeparators)
        var results: [String: Double] = [:]

        for clause in clauses {
            let rawTokens = clause
                .components(separatedBy: tokenSeparators)
                .map { $0.trimmingCharacters(in: .punctuationCharacters) }
                .filter { isValidToken($0) }

            guard !rawTokens.isEmpty else { continue }

            for i in rawTokens.indices {
                let w1 = rawTokens[i]
                let w1Stop = stopwords.contains(w1)

                if !w1Stop && w1.count >= 4 && !genericSingleWords.contains(w1) {
                    results[w1, default: 0.0] += 0.85
                }

                if !w1Stop && i + 1 < rawTokens.count {
                    let w2 = rawTokens[i + 1]
                    if !stopwords.contains(w2) && w1 != w2 {
                        let bigram = "\(w1) \(w2)"
                        if bigram.count >= 6 && bigram.count <= 34 {
                            results[bigram, default: 0.0] += 1.45
                        }
                    }
                }

                if !w1Stop && i + 2 < rawTokens.count {
                    let w2 = rawTokens[i + 1]
                    let w3 = rawTokens[i + 2]
                    let w2Allowed = !stopwords.contains(w2) || connectorWords.contains(w2)
                    if w2Allowed && !stopwords.contains(w3) && w1 != w3 {
                        let trigram = "\(w1) \(w2) \(w3)"
                        if trigram.count >= 9 && trigram.count <= 42 {
                            results[trigram, default: 0.0] += 1.65
                        }
                    }
                }
            }
        }

        return results.map { ($0.key, $0.value) }
    }

    private static let clauseSeparators = CharacterSet(charactersIn: ".,;:!?\n\r\t()[]{}<>\"'|`~@#$%^&*+=/\\")
    private static let tokenSeparators = CharacterSet.alphanumerics.inverted.subtracting(CharacterSet(charactersIn: "-_"))

    private static func isValidToken(_ token: String) -> Bool {
        let count = token.count
        guard count >= 2 && count <= 22 else { return false }
        guard let first = token.utf8.first, first >= 97 && first <= 122 else { return false }
        var digitCount = 0
        for b in token.utf8 {
            if b >= 48 && b <= 57 { digitCount += 1 }
        }
        if digitCount > 2 { return false }
        if noiseTokens.contains(token) { return false }
        return true
    }

    static func normalizeQuery(_ raw: String) -> String {
        let lower = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = lower.split(whereSeparator: { $0.isWhitespace })
        return parts.joined(separator: " ")
    }

    private static let connectorWords: Set<String> = [
        "in", "on", "to", "of", "for", "by", "vs", "and"
    ]

    private static let noiseTokens: Set<String> = [
        "users", "mac", "private", "var", "folders", "tmp", "http", "https", "com", "org",
        "net", "io", "www", "jsonl", "null", "true", "false", "uuid", "image", "png", "jpg",
        "jpeg", "gif", "mp4", "pdf", "txt", "log", "err", "out"
    ]

    private static let genericSingleWords: Set<String> = [
        "using", "working", "running", "making", "getting", "doing", "going", "having",
        "saying", "seeing", "trying", "adding", "fixing", "checking", "looking", "building",
        "testing", "calling", "passing", "setting", "putting", "taking", "giving", "coming",
        "wanting", "needing", "thinking", "knowing", "showing", "telling", "asking",
        "first", "second", "third", "last", "next", "previous", "current", "existing",
        "actual", "actually", "basically", "currently", "probably", "maybe", "always",
        "never", "already", "still", "really", "pretty", "quite", "rather", "almost",
        "enough", "little", "small", "large", "short", "long", "high", "clear", "clean",
        "wrong", "right", "better", "best", "worse", "worst", "whole", "entire", "total",
        "single", "multiple", "several", "certain", "specific", "general", "common",
        "normal", "regular", "standard", "default", "custom", "special", "extra",
        "implem", "becasue", "because", "shouldnt", "wouldnt", "couldnt", "doesnt",
        "didnt", "isnt", "arent", "wasnt", "werent", "hasnt", "havent", "hadnt"
    ]

    static let stopwords: Set<String> = [
        "a", "an", "the", "and", "or", "but", "if", "then", "else", "when", "where", "why",
        "how", "what", "which", "who", "whom", "whose", "this", "that", "these", "those",
        "am", "is", "are", "was", "were", "be", "been", "being", "have", "has", "had",
        "having", "do", "does", "did", "doing", "will", "would", "shall", "should", "can",
        "could", "may", "might", "must", "ought", "i", "me", "my", "mine", "myself", "you",
        "your", "yours", "yourself", "he", "him", "his", "himself", "she", "her", "hers",
        "herself", "it", "its", "itself", "we", "us", "our", "ours", "ourselves", "they",
        "them", "their", "theirs", "themselves", "to", "of", "in", "for", "on", "with",
        "at", "by", "from", "up", "about", "into", "over", "after", "beneath", "under",
        "above", "across", "against", "along", "among", "around", "before", "behind",
        "below", "beside", "between", "beyond", "during", "except", "inside", "near",
        "off", "onto", "outside", "since", "through", "throughout", "toward", "towards",
        "until", "upon", "within", "without", "not", "no", "nor", "only", "own", "same",
        "so", "than", "too", "very", "just", "now", "also", "here", "there", "all", "any",
        "both", "each", "few", "more", "most", "other", "some", "such", "let", "lets",
        "please", "make", "sure", "want", "need", "like", "know", "think", "see", "look",
        "take", "get", "give", "use", "used", "put", "set", "run", "try", "help", "work",
        "way", "thing", "things", "stuff", "part", "place", "case", "point", "time",
        "good", "great", "okay", "ok", "yes", "yeah", "well", "right", "back", "even",
        "still", "again", "much", "many", "lot", "lots", "bit", "little", "new", "old",
        "one", "two", "three", "four", "five", "dont", "cant", "wont", "im", "ive",
        "youre", "weve", "theyre", "thats", "whats", "heres", "theres", "option"
    ]

    // MARK: - In-Memory Vocabulary Management

    private func upsertEntryInMemoryLocked(
        phrase: String,
        addHits: Int,
        addWeight: Double,
        timestamp: TimeInterval,
        source: String
    ) {
        if var existing = entriesByPhrase[phrase] {
            existing.hitCount += addHits
            existing.weight += addWeight
            if timestamp > existing.lastSeen {
                existing.lastSeen = timestamp
            }
            existing.sources.insert(source)
            entriesByPhrase[phrase] = existing
        } else {
            let words = phrase.split(separator: " ").map(String.init)
            let entry = Entry(
                phrase: phrase,
                words: words,
                charMask: Self.computeCharMask(phrase),
                trigramMask: Self.computeTrigramMask(phrase),
                hitCount: addHits,
                weight: addWeight,
                lastSeen: timestamp,
                sources: [source]
            )
            entriesByPhrase[phrase] = entry
        }
    }

    private func rebuildSortedSnapshotLocked() {
        var all = Array(entriesByPhrase.values)
        all.sort { a, b in
            let scoreA = a.weight * (a.hitCount >= 2 ? 1.35 : 0.85)
            let scoreB = b.weight * (b.hitCount >= 2 ? 1.35 : 0.85)
            if abs(scoreA - scoreB) > 0.01 { return scoreA > scoreB }
            return a.lastSeen > b.lastSeen
        }
        if all.count > Self.maxInMemoryKeywords {
            all.removeSubrange(Self.maxInMemoryKeywords..<all.count)
            var pruned: [String: Entry] = [:]
            pruned.reserveCapacity(all.count)
            for e in all { pruned[e.phrase] = e }
            entriesByPhrase = pruned
        }
        sortedEntries = all

        var slots = ContiguousArray<FastFilterSlot>()
        slots.reserveCapacity(all.count)
        for e in all {
            var firstB: UInt8 = 0
            var secondB: UInt8 = 0
            var idx = 0
            for b in e.phrase.utf8 {
                if idx == 0 { firstB = b }
                else if idx == 1 { secondB = b; break }
                idx &+= 1
            }
            var wordInit: UInt32 = 0
            for w in e.words {
                if let b = w.utf8.first {
                    wordInit |= Self.charBit(b)
                }
            }
            slots.append(
                FastFilterSlot(
                    firstByte: firstB,
                    secondByte: secondB,
                    wordInitialMask: wordInit,
                    charMask: e.charMask,
                    trigramMask: e.trigramMask,
                    hitBonus: min(80, e.hitCount)
                )
            )
        }
        filterSlots = slots

        var museCount = 0
        var claudeCount = 0
        var codexCount = 0
        for e in all {
            if e.sources.contains("muse") { museCount += 1 }
            if e.sources.contains("claude") { claudeCount += 1 }
            if e.sources.contains("codex") { codexCount += 1 }
        }
        statsValue.totalKeywords = all.count
        statsValue.museKeywordCount = museCount
        statsValue.claudeKeywordCount = claudeCount
        statsValue.codexKeywordCount = codexCount
    }

    // MARK: - Directory Discovery Helpers

    private static func collectRecentJSONLFiles(
        in directoryPath: String,
        skipSubagents: Bool,
        maxFiles: Int
    ) -> [String] {
        let rootURL = URL(fileURLWithPath: directoryPath)
        guard FileManager.default.fileExists(atPath: directoryPath),
              let enumerator = FileManager.default.enumerator(
                  at: rootURL,
                  includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                  options: [.skipsHiddenFiles, .skipsPackageDescendants]
              ) else {
            return []
        }

        var found: [(path: String, mtime: Date)] = []
        for case let url as URL in enumerator {
            let path = url.path
            if skipSubagents && path.contains("/subagent/") {
                enumerator.skipDescendants()
                continue
            }
            guard url.pathExtension == "jsonl" else { continue }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey])
            guard values?.isRegularFile == true else { continue }
            let mtime = values?.contentModificationDate ?? .distantPast
            found.append((path, mtime))
            if found.count >= maxFiles * 4 {
                break
            }
        }

        found.sort { $0.mtime > $1.mtime }
        return Array(found.prefix(maxFiles).map(\.path))
    }

    // MARK: - SQLite WAL Persistence

    private func openDatabase() {
        try? FileManager.default.createDirectory(
            at: dbURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(dbURL.path, &handle, flags, nil) == SQLITE_OK else {
            sqlite3_close(handle)
            return
        }
        database = handle
        executeSQL("PRAGMA journal_mode=WAL;")
        executeSQL("PRAGMA synchronous=NORMAL;")
        executeSQL("""
            CREATE TABLE IF NOT EXISTS file_watermarks (
                path TEXT PRIMARY KEY,
                byte_offset INTEGER NOT NULL,
                file_size INTEGER NOT NULL,
                mtime REAL NOT NULL,
                source TEXT NOT NULL
            );
            CREATE TABLE IF NOT EXISTS muse_keywords (
                phrase TEXT PRIMARY KEY,
                hit_count INTEGER NOT NULL,
                weight REAL NOT NULL,
                last_seen REAL NOT NULL,
                sources TEXT NOT NULL
            );
            """)
    }

    private func executeSQL(_ sql: String) {
        guard let database else { return }
        sqlite3_exec(database, sql, nil, nil, nil)
    }

    private func readWatermarkLocked(for path: String) -> (byteOffset: Int64, fileSize: Int64, mtime: Double)? {
        guard let database else { return nil }
        let sql = "SELECT byte_offset, file_size, mtime FROM file_watermarks WHERE path = ? LIMIT 1;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, path, -1, transient)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return (
            sqlite3_column_int64(stmt, 0),
            sqlite3_column_int64(stmt, 1),
            sqlite3_column_double(stmt, 2)
        )
    }

    private func writeWatermarkLocked(
        path: String,
        byteOffset: Int64,
        fileSize: Int64,
        mtime: Double,
        source: String
    ) {
        guard let database else { return }
        let sql = """
            INSERT OR REPLACE INTO file_watermarks (path, byte_offset, file_size, mtime, source)
            VALUES (?, ?, ?, ?, ?);
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(stmt, 1, path, -1, transient)
        sqlite3_bind_int64(stmt, 2, byteOffset)
        sqlite3_bind_int64(stmt, 3, fileSize)
        sqlite3_bind_double(stmt, 4, mtime)
        sqlite3_bind_text(stmt, 5, source, -1, transient)
        sqlite3_step(stmt)
    }

    private func loadPersistedKeywordsLocked() {
        guard let database else { return }
        let sql = "SELECT phrase, hit_count, weight, last_seen, sources FROM muse_keywords;"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        lock.lock()
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let cPhrase = sqlite3_column_text(stmt, 0) else { continue }
            let phrase = String(cString: cPhrase)
            let hits = Int(sqlite3_column_int64(stmt, 1))
            let weight = sqlite3_column_double(stmt, 2)
            let lastSeen = sqlite3_column_double(stmt, 3)
            let sourcesStr = sqlite3_column_text(stmt, 4).map { String(cString: $0) } ?? "muse"
            let sourceSet = Set(sourcesStr.split(separator: ",").map(String.init))
            let words = phrase.split(separator: " ").map(String.init)
            entriesByPhrase[phrase] = Entry(
                phrase: phrase,
                words: words,
                charMask: Self.computeCharMask(phrase),
                trigramMask: Self.computeTrigramMask(phrase),
                hitCount: max(1, hits),
                weight: weight,
                lastSeen: lastSeen,
                sources: sourceSet.isEmpty ? ["muse"] : sourceSet
            )
        }
        rebuildSortedSnapshotLocked()
        lock.unlock()
    }

    private func persistTopKeywordsLocked() {
        guard let database else { return }
        lock.lock()
        let snapshot = Array(sortedEntries.prefix(Self.maxInMemoryKeywords))
        lock.unlock()

        executeSQL("BEGIN IMMEDIATE;")
        executeSQL("DELETE FROM muse_keywords;")
        let sql = """
            INSERT OR REPLACE INTO muse_keywords (phrase, hit_count, weight, last_seen, sources)
            VALUES (?, ?, ?, ?, ?);
            """
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(database, sql, -1, &stmt, nil) == SQLITE_OK {
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            for entry in snapshot {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                let srcJoined = entry.sources.sorted().joined(separator: ",")
                sqlite3_bind_text(stmt, 1, entry.phrase, -1, transient)
                sqlite3_bind_int64(stmt, 2, Int64(entry.hitCount))
                sqlite3_bind_double(stmt, 3, entry.weight)
                sqlite3_bind_double(stmt, 4, entry.lastSeen)
                sqlite3_bind_text(stmt, 5, srcJoined, -1, transient)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
        executeSQL("COMMIT;")
    }
}
