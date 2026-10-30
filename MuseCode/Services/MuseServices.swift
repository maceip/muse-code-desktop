//
//  MuseServices.swift
//  PiCode
//
//  Native wrappers around Muse CLI subcommands:
//   - `muse usage --json` (credit / allowance battery tracker)
//   - `muse voice transcribe <file>` (built-in STT)
//   - `muse skills list / enable / disable` (Extensions browser)
//   - `muse session-message list / send` (Muse Agent Messages)
//

import AVFoundation
import Foundation
import Observation
import Speech

// MARK: - Credit & Allowance Battery Tracker (`muse usage --json`)

struct MuseAllowanceWindow: Equatable, Sendable {
    var usedPercent: Double
    var resetsAt: Date?

    var remainingPercent: Double {
        max(0.0, min(100.0, 100.0 - usedPercent))
    }
}

struct MuseUsageSnapshot: Equatable, Sendable {
    var tier: String?
    var asOf: Date?
    var window: MuseAllowanceWindow?
    var weekly: MuseAllowanceWindow?
    var allowanceRemainingPercent: Double?
    var allowanceSummary: String?
    var reason: String?
    var hint: String?
    var fetchedAt: Date = Date()
}

@Observable
@MainActor
final class MuseUsageService {
    static let shared = MuseUsageService()

    private(set) var latestSnapshot: MuseUsageSnapshot?
    private(set) var isRefreshing = false

    /// Returns the server-reported allowance remaining percentage (`0...100`)
    /// from `muse usage --json` (or live `muse exec --json` allowance events),
    /// or `nil` when the server reports `"allowance": null`.
    var allowancePercentage: Int? {
        guard let allowance = latestSnapshot?.allowanceRemainingPercent else { return nil }
        return max(0, min(100, Int(allowance.rounded())))
    }

    /// Parses a full `muse usage --json` response object (`schemaVersion`, `allowance`, `reason`, `hint`).
    static func parseUsageResponse(_ json: JSONValue, fetchedAt: Date = Date()) -> MuseUsageSnapshot {
        if let allowance = json["allowance"], !allowance.isNull {
            var snapshot = parseAllowanceObject(allowance, fetchedAt: fetchedAt)
            snapshot.reason = json.string("reason")
            snapshot.hint = json.string("hint")
            return snapshot
        }
        return MuseUsageSnapshot(
            tier: nil,
            asOf: nil,
            window: nil,
            weekly: nil,
            allowanceRemainingPercent: nil,
            allowanceSummary: nil,
            reason: json.string("reason"),
            hint: json.string("hint"),
            fetchedAt: fetchedAt
        )
    }

    /// Parses a `RunUsageAllowance` object (`tier`, `asOfMs`/`as_of_ms`, `window`, `weekly`).
    static func parseAllowanceObject(_ allowance: JSONValue, fetchedAt: Date = Date()) -> MuseUsageSnapshot {
        let tier = allowance.string("tier")
        let asOf: Date? = {
            if let ms = allowance.double("asOfMs") ?? allowance.double("as_of_ms"), ms > 0 {
                return Date(timeIntervalSince1970: ms / 1000.0)
            }
            return nil
        }()

        func parseWindow(_ obj: JSONValue?) -> MuseAllowanceWindow? {
            guard let obj, !obj.isNull else { return nil }
            let used: Double?
            if let u = obj.double("usedPercent") ?? obj.double("used_percent") {
                used = max(0.0, min(100.0, u))
            } else if let rem = obj.double("remainingPercent") ?? obj.double("remaining_percent") {
                used = max(0.0, min(100.0, 100.0 - rem))
            } else {
                used = nil
            }
            guard let used else { return nil }
            let resetsAt: Date? = {
                if let ms = obj.double("resetsAtMs") ?? obj.double("resets_at_ms"), ms > 0 {
                    return Date(timeIntervalSince1970: ms / 1000.0)
                }
                return nil
            }()
            return MuseAllowanceWindow(usedPercent: used, resetsAt: resetsAt)
        }

        let window = parseWindow(allowance["window"])
        let weekly = parseWindow(allowance["weekly"])

        var remainingPercent: Double?
        if let window, let weekly {
            remainingPercent = min(window.remainingPercent, weekly.remainingPercent)
        } else if let window {
            remainingPercent = window.remainingPercent
        } else if let weekly {
            remainingPercent = weekly.remainingPercent
        } else if let rem = allowance.double("remaining_percent") ?? allowance.double("remainingPercent") {
            remainingPercent = max(0.0, min(100.0, rem))
        } else if let used = allowance.double("used_percent") ?? allowance.double("usedPercent") {
            remainingPercent = max(0.0, min(100.0, 100.0 - used))
        } else if let rem = allowance.double("remaining"), let limit = allowance.double("limit"), limit > 0 {
            remainingPercent = max(0.0, min(100.0, (rem / limit) * 100.0))
        }

        var parts: [String] = []
        if let window {
            parts.append("5h window: \(Int(window.remainingPercent.rounded()))% left")
        }
        if let weekly {
            parts.append("Weekly: \(Int(weekly.remainingPercent.rounded()))% left")
        }
        let summary: String?
        if !parts.isEmpty {
            summary = parts.joined(separator: " · ")
        } else {
            summary = allowance.string("summary") ?? tier
        }

        return MuseUsageSnapshot(
            tier: tier,
            asOf: asOf,
            window: window,
            weekly: weekly,
            allowanceRemainingPercent: remainingPercent,
            allowanceSummary: summary,
            reason: nil,
            hint: nil,
            fetchedAt: fetchedAt
        )
    }

    func ingestAllowanceJSON(_ allowance: JSONValue) {
        guard !allowance.isNull else { return }
        let parsed = Self.parseAllowanceObject(allowance)
        if parsed.allowanceRemainingPercent != nil || parsed.window != nil || parsed.weekly != nil {
            latestSnapshot = parsed
        }
    }

    func refresh(installation: PiInstallation?) async {
        guard !isRefreshing else { return }
        guard let resolved = await Self.resolveInstallation(installation) else { return }
        let executable = resolved.executableURL
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { return }

        isRefreshing = true
        defer { isRefreshing = false }

        let env = PiDiscoveryService.launchEnvironment(
            executable: executable,
            shellPath: resolved.shellPath
        )
        let result = await PiDiscoveryService().run(
            executable: executable,
            arguments: ["usage", "--json"],
            directory: URL(fileURLWithPath: NSHomeDirectory()),
            environment: env
        )
        let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = output.data(using: .utf8),
              let json = try? JSONCoding.decode(data) else {
            return
        }

        latestSnapshot = Self.parseUsageResponse(json, fetchedAt: Date())
    }

    private static var cachedDiscoveredInstallation: PiInstallation?

    static func resolveInstallation(_ provided: PiInstallation?) async -> PiInstallation? {
        if let provided { return provided }
        if let cached = cachedDiscoveredInstallation,
           FileManager.default.isExecutableFile(atPath: cached.executableURL.path) {
            return cached
        }
        if case .found(let found) = await PiDiscoveryService().discover() {
            cachedDiscoveredInstallation = found
            return found
        }
        return nil
    }
}

// MARK: - Quick-Switching Speech-to-Text Router (`muse voice transcribe` + macOS System `SFSpeechRecognizer` Backup)

enum MuseVoiceSTTRouterMode: String, CaseIterable, Identifiable, Sendable {
    /// Uses `muse voice transcribe` when healthy, and automatically fails over to macOS System Speech Recognition (`SFSpeechRecognizer`) if Muse is down, unreachable, or times out.
    case autoMuseWithSystemBackup = "auto"
    /// Uses `muse voice transcribe` exclusively.
    case museOnly = "muse"
    /// Uses macOS System Speech Recognition (`SFSpeechRecognizer`) exclusively.
    case systemOnly = "system"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .autoMuseWithSystemBackup:
            return "Auto (Muse → System Backup)"
        case .museOnly:
            return "Muse STT Only (muse voice transcribe)"
        case .systemOnly:
            return "macOS System STT (On-Device)"
        }
    }

    var shortLabel: String {
        switch self {
        case .autoMuseWithSystemBackup:
            return "Auto Backup"
        case .museOnly:
            return "Muse STT"
        case .systemOnly:
            return "System STT"
        }
    }
}

enum MuseVoiceSTTBackend: String, CaseIterable, Identifiable, Sendable {
    case museCLI = "muse"
    case macOSSystem = "system"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .museCLI:
            return "Muse STT"
        case .macOSSystem:
            return "System STT"
        }
    }
}

@Observable
@MainActor
final class MuseVoiceSTTService: NSObject, AVAudioRecorderDelegate {
    static let shared = MuseVoiceSTTService()
    static let routerModeDefaultsKey = "voiceSTTRouterMode"
    static let museOutageCooldownSeconds: TimeInterval = 60.0

    private(set) var isRecording = false
    private(set) var isTranscribing = false
    private(set) var recordingDuration: TimeInterval = 0
    /// Normalized live microphone voice energy (`0.0...1.0`) sampled from `AVAudioRecorder` meters
    /// to drive the 3D Liquid Glass Voice Orb `mic interactivity` plasma flare states.
    private(set) var audioLevel: Double = 0.0
    /// Most recent voice transcription phrase (displayed in the subcontainer voice row matching `Untitled 9.jpg`).
    var lastTranscript: String?
    private(set) var lastError: String?

    /// Persisted speech-to-text routing mode (`auto` = Muse with automatic macOS System backup, `muse`, or `system`).
    var routerMode: MuseVoiceSTTRouterMode {
        didSet {
            UserDefaults.standard.set(routerMode.rawValue, forKey: Self.routerModeDefaultsKey)
        }
    }
    /// Which STT backend produced the most recent transcript (`.museCLI` or `.macOSSystem`).
    private(set) var lastUsedBackend: MuseVoiceSTTBackend?
    /// `true` when the router was in `.autoMuseWithSystemBackup` mode and automatically failed over to macOS System STT because Muse was down/unreachable.
    private(set) var didFallbackToSystem = false
    /// Diagnostic reason from the last Muse STT failure when failover to macOS System STT triggered.
    private(set) var lastMuseFailureReason: String?
    /// Circuit-breaker timestamp while Muse STT is down so consecutive voice utterances route directly to macOS System STT without waiting on a dead Muse endpoint.
    private(set) var museCircuitOpenUntil: Date?

    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var timerTask: Task<Void, Never>?
    private var activeTranscriptionID = UUID()
    private var pendingInstallation: PiInstallation?
    private var pendingOnTranscribed: (@MainActor (String) -> Void)?

    override init() {
        let raw = UserDefaults.standard.string(forKey: Self.routerModeDefaultsKey) ?? ""
        self.routerMode = MuseVoiceSTTRouterMode(rawValue: raw) ?? .autoMuseWithSystemBackup
        super.init()
    }

    /// Returns `true` if Muse STT recently failed and the temporary failover circuit breaker is open.
    func isMuseCircuitOpen(at date: Date = Date()) -> Bool {
        guard let until = museCircuitOpenUntil else { return false }
        return date < until
    }

    /// Returns the backend that will handle the next transcription request at `date`.
    func activePrimaryBackend(at date: Date = Date()) -> MuseVoiceSTTBackend {
        switch routerMode {
        case .systemOnly:
            return .macOSSystem
        case .museOnly:
            return .museCLI
        case .autoMuseWithSystemBackup:
            return isMuseCircuitOpen(at: date) ? .macOSSystem : .museCLI
        }
    }

    /// Human-readable status badge for the composer / settings UI.
    var routerBadgeText: String {
        switch routerMode {
        case .systemOnly:
            return "System STT"
        case .museOnly:
            return "Muse STT"
        case .autoMuseWithSystemBackup:
            if isMuseCircuitOpen() || didFallbackToSystem {
                return "System Backup"
            }
            if let last = lastUsedBackend {
                return last == .macOSSystem ? "System Backup" : "Muse STT"
            }
            return "Auto Backup"
        }
    }

    /// Detailed router status description for tooltips and Settings.
    var routerStatusDescription: String {
        switch routerMode {
        case .systemOnly:
            return "Using macOS System Speech Recognition (On-Device)"
        case .museOnly:
            return "Using Muse CLI (`muse voice transcribe`) only"
        case .autoMuseWithSystemBackup:
            if isMuseCircuitOpen() {
                let reason = lastMuseFailureReason ?? "Muse STT unreachable"
                return "Muse STT down (\(reason)) — routed to macOS System STT backup"
            }
            if didFallbackToSystem {
                return "Last utterance failed over to macOS System STT backup"
            }
            return "Auto-routing: Muse STT primary with instant macOS System STT backup"
        }
    }

    /// Sets the router mode and resets any stale outage circuit breaker when switching back to Muse.
    func setRouterMode(_ mode: MuseVoiceSTTRouterMode) {
        routerMode = mode
        if mode == .museOnly {
            museCircuitOpenUntil = nil
            didFallbackToSystem = false
            lastMuseFailureReason = nil
        } else if mode == .systemOnly {
            didFallbackToSystem = false
        }
    }

    /// Immediately switches active transcription to macOS System STT (either by tripping the backup circuit in Auto mode or switching from Muse Only to Auto Backup).
    func switchToSystemBackupNow(reason: String = "Manual quick-switch to System STT") {
        if routerMode == .museOnly {
            routerMode = .autoMuseWithSystemBackup
        }
        lastMuseFailureReason = reason
        didFallbackToSystem = true
        museCircuitOpenUntil = Date().addingTimeInterval(Self.museOutageCooldownSeconds)
    }

    /// Clears the Muse outage circuit breaker so the next recording probes `muse voice transcribe` immediately.
    func retryMuseSTTNow() {
        if routerMode == .systemOnly {
            routerMode = .autoMuseWithSystemBackup
        }
        museCircuitOpenUntil = nil
        didFallbackToSystem = false
        lastMuseFailureReason = nil
    }

    /// Cycles through the STT router modes for one-click quick switching.
    func cycleRouterMode() {
        switch routerMode {
        case .autoMuseWithSystemBackup:
            setRouterMode(.systemOnly)
        case .systemOnly:
            setRouterMode(.museOnly)
        case .museOnly:
            setRouterMode(.autoMuseWithSystemBackup)
        }
    }

    func toggleRecording(installation: PiInstallation?, onTranscribed: @escaping @MainActor (String) -> Void) async {
        if isRecording {
            await stopAndTranscribe(installation: installation ?? pendingInstallation, onTranscribed: onTranscribed)
        } else if isTranscribing {
            cancel()
        } else {
            await startRecording(installation: installation, onTranscribed: onTranscribed)
        }
    }

    func stopAndTranscribeUsingPending(installation: PiInstallation?) async {
        guard isRecording else { return }
        let callback = pendingOnTranscribed ?? { _ in }
        await stopAndTranscribe(installation: installation ?? pendingInstallation, onTranscribed: callback)
    }

    func cancel() {
        activeTranscriptionID = UUID()
        timerTask?.cancel()
        timerTask = nil
        pendingInstallation = nil
        pendingOnTranscribed = nil
        recorder?.stop()
        recorder = nil
        if let url = recordingURL {
            recordingURL = nil
            try? FileManager.default.removeItem(at: url)
        }
        isRecording = false
        isTranscribing = false
        audioLevel = 0.0
    }

    func startRecording(
        installation: PiInstallation? = nil,
        onTranscribed: (@MainActor (String) -> Void)? = nil
    ) async {
        lastError = nil
        pendingInstallation = installation
        pendingOnTranscribed = onTranscribed
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        guard granted else {
            lastError = "Microphone access was denied in System Settings ▸ Privacy & Security ▸ Microphone."
            return
        }

        let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("muse-voice-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsFloatKey: false
        ]

        do {
            let newRecorder = try AVAudioRecorder(url: tempURL, settings: settings)
            newRecorder.delegate = self
            newRecorder.isMeteringEnabled = true
            newRecorder.prepareToRecord()
            guard newRecorder.record() else {
                lastError = "Could not start microphone capture."
                return
            }
            recorder = newRecorder
            recordingURL = tempURL
            isRecording = true
            recordingDuration = 0
            audioLevel = 0.0
            timerTask?.cancel()
            timerTask = Task { [weak self] in
                let start = Date()
                var noiseFloorDb: Double = -48.0
                var speechFramesHeard: Int = 0
                var lastSpeechTime: Date?
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 33_000_000)
                    guard let self, self.isRecording else { break }
                    let now = Date()
                    let elapsed = now.timeIntervalSince(start)
                    self.recordingDuration = elapsed
                    if let rec = self.recorder {
                        rec.updateMeters()
                        let avgDb = Double(rec.averagePower(forChannel: 0))
                        let peakDb = Double(rec.peakPower(forChannel: 0))
                        let combinedDb = avgDb * 0.50 + peakDb * 0.50
                        // Track ambient room noise floor gently when quiet so speech syllables pop cleanly
                        if combinedDb < noiseFloorDb + 3.0 {
                            noiseFloorDb = max(-58.0, min(-36.0, noiseFloorDb * 0.92 + combinedDb * 0.08))
                        }
                        // Map (noiseFloor + 2 dB) ... (noiseFloor + 26 dB) -> 0.0 ... 1.0
                        let rawLevel = max(0.0, min(1.0, (combinedDb - (noiseFloorDb + 2.0)) / 24.0))
                        let shaped = pow(rawLevel, 0.82)
                        // Snappy syllabic attack, smooth conversational release
                        if shaped > self.audioLevel {
                            self.audioLevel = self.audioLevel * 0.22 + shaped * 0.78
                        } else {
                            self.audioLevel = self.audioLevel * 0.72 + shaped * 0.28
                        }

                        // Voice Activity Detection (VAD) endpointing (`Und 9.jpg` -> `Untitled 9.jpg`):
                        // Once the user has spoken (`>= 6` frames of speech energy after the orb settles)
                        // and then pauses for 1.15s of silence, automatically stop and transcribe!
                        if elapsed > 0.30 {
                            if shaped >= 0.15 {
                                speechFramesHeard += 1
                                lastSpeechTime = now
                            } else if speechFramesHeard >= 6,
                                      let lastSpeech = lastSpeechTime,
                                      now.timeIntervalSince(lastSpeech) >= 1.15 {
                                let inst = self.pendingInstallation
                                let callback = self.pendingOnTranscribed
                                await self.stopAndTranscribe(installation: inst) { text in
                                    callback?(text)
                                }
                                break
                            }
                        }
                    }
                }
            }
        } catch {
            lastError = "Could not initialize audio recorder: \(error.localizedDescription)"
        }
    }

    func stopAndTranscribe(installation: PiInstallation?, onTranscribed: (@MainActor (String) -> Void)? = nil) async {
        timerTask?.cancel()
        timerTask = nil
        let effectiveInstallation = installation ?? pendingInstallation
        let effectiveCallback = onTranscribed ?? pendingOnTranscribed
        pendingInstallation = nil
        pendingOnTranscribed = nil
        recorder?.stop()
        recorder = nil
        audioLevel = 0.0

        guard let url = recordingURL else {
            isRecording = false
            isTranscribing = false
            return
        }
        recordingURL = nil
        let runID = UUID()
        activeTranscriptionID = runID
        // Set `isTranscribing = true` BEFORE `isRecording = false` so observers never see both as false while starting STT.
        isTranscribing = true
        isRecording = false
        defer {
            if activeTranscriptionID == runID {
                isTranscribing = false
            }
            try? FileManager.default.removeItem(at: url)
        }

        // Allow CoreAudio's AudioQueue to finish flushing the trailing PCM buffer and updating the WAV RIFF header chunk sizes.
        try? await Task.sleep(nanoseconds: 65_000_000)
        guard activeTranscriptionID == runID else { return }

        if let transcript = await transcribeFile(at: url, installation: effectiveInstallation, runID: runID),
           activeTranscriptionID == runID,
           !transcript.isEmpty {
            effectiveCallback?(transcript)
        }
    }

    func transcribeFile(at fileURL: URL, installation: PiInstallation?, runID: UUID? = nil) async -> String? {
        let effectiveID = runID ?? UUID()
        if runID == nil {
            activeTranscriptionID = effectiveID
            isTranscribing = true
        }
        lastError = nil
        defer {
            if runID == nil && activeTranscriptionID == effectiveID {
                isTranscribing = false
            }
        }

        switch routerMode {
        case .systemOnly:
            let sys = await Self.transcribeWithSystemSpeech(at: fileURL)
            guard activeTranscriptionID == effectiveID else { return nil }
            if let text = sys.transcript?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                lastUsedBackend = .macOSSystem
                didFallbackToSystem = false
                lastTranscript = Self.normalizedVoiceDisplayQuote(from: text)
                return text
            }
            lastError = sys.error ?? "macOS System STT returned no speech text."
            return nil

        case .museOnly:
            let muse = await Self.transcribeWithMuseCLI(at: fileURL, installation: installation, timeout: 15.0)
            guard activeTranscriptionID == effectiveID else { return nil }
            if let text = muse.transcript?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                lastUsedBackend = .museCLI
                didFallbackToSystem = false
                museCircuitOpenUntil = nil
                lastMuseFailureReason = nil
                lastTranscript = Self.normalizedVoiceDisplayQuote(from: text)
                return text
            }
            lastError = muse.error ?? "Muse STT returned no speech text."
            return nil

        case .autoMuseWithSystemBackup:
            // 1. If the Muse outage circuit breaker is currently open, route directly to macOS System STT
            //    with zero timeout penalty so consecutive voice clips transcribe immediately.
            if isMuseCircuitOpen() {
                let sys = await Self.transcribeWithSystemSpeech(at: fileURL)
                guard activeTranscriptionID == effectiveID else { return nil }
                if let text = sys.transcript?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                    lastUsedBackend = .macOSSystem
                    didFallbackToSystem = true
                    lastTranscript = Self.normalizedVoiceDisplayQuote(from: text)
                    return text
                }
                // If System STT unexpectedly failed while circuit was open, probe Muse CLI as a recovery attempt.
                let museRecovery = await Self.transcribeWithMuseCLI(at: fileURL, installation: installation, timeout: 6.0)
                guard activeTranscriptionID == effectiveID else { return nil }
                if let text = museRecovery.transcript?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                    lastUsedBackend = .museCLI
                    didFallbackToSystem = false
                    museCircuitOpenUntil = nil
                    lastMuseFailureReason = nil
                    lastTranscript = Self.normalizedVoiceDisplayQuote(from: text)
                    return text
                }
                lastError = sys.error ?? museRecovery.error ?? "Both macOS System STT and Muse STT failed."
                return nil
            }

            // 2. Primary route: attempt Muse STT with a fast failover timeout (5.5s).
            let muse = await Self.transcribeWithMuseCLI(at: fileURL, installation: installation, timeout: 5.5)
            guard activeTranscriptionID == effectiveID else { return nil }
            if let text = muse.transcript?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                lastUsedBackend = .museCLI
                didFallbackToSystem = false
                museCircuitOpenUntil = nil
                lastMuseFailureReason = nil
                lastTranscript = Self.normalizedVoiceDisplayQuote(from: text)
                return text
            }

            // 3. Muse is down, unreachable, timed out, or returned an error — trip the circuit breaker
            //    and immediately transcribe the exact same audio clip using macOS System Speech Recognition!
            let failureReason = muse.error ?? "Muse STT returned no speech text"
            lastMuseFailureReason = failureReason
            museCircuitOpenUntil = Date().addingTimeInterval(Self.museOutageCooldownSeconds)

            let sys = await Self.transcribeWithSystemSpeech(at: fileURL)
            guard activeTranscriptionID == effectiveID else { return nil }
            if let text = sys.transcript?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                lastUsedBackend = .macOSSystem
                didFallbackToSystem = true
                lastError = nil
                lastTranscript = Self.normalizedVoiceDisplayQuote(from: text)
                return text
            }

            let sysReason = sys.error ?? "macOS System STT returned no speech text"
            lastError = "Muse STT failed (\(failureReason)); System STT backup also failed (\(sysReason))."
            return nil
        }
    }

    static func transcribeWithMuseCLI(
        at fileURL: URL,
        installation: PiInstallation?,
        timeout: TimeInterval = 15.0
    ) async -> (transcript: String?, error: String?) {
        guard let resolved = await MuseUsageService.resolveInstallation(installation) else {
            return (nil, "Muse CLI executable not found.")
        }
        let executable = resolved.executableURL
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            return (nil, "Muse CLI executable not found at \(executable.path).")
        }

        let env = PiDiscoveryService.launchEnvironment(
            executable: executable,
            shellPath: resolved.shellPath
        )
        let result = await PiDiscoveryService().run(
            executable: executable,
            arguments: ["voice", "transcribe", fileURL.path],
            directory: URL(fileURLWithPath: NSHomeDirectory()),
            environment: env,
            timeout: timeout
        )
        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.exitCode == 0, !stdout.isEmpty {
            return (stdout, nil)
        }
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let reason = stderr.isEmpty ? "Muse STT exited with status \(result.exitCode)" : stderr
        return (nil, reason)
    }

    static func requestSystemSpeechAuthorization() async -> SFSpeechRecognizerAuthorizationStatus {
        let current = SFSpeechRecognizer.authorizationStatus()
        if current != .notDetermined {
            return current
        }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status)
            }
        }
    }

    static func transcribeWithSystemSpeech(
        at fileURL: URL,
        timeout: TimeInterval = 10.0
    ) async -> (transcript: String?, error: String?) {
        let authStatus = await requestSystemSpeechAuthorization()
        switch authStatus {
        case .authorized:
            break
        case .denied:
            return (nil, "macOS Speech Recognition permission denied in System Settings ▸ Privacy & Security ▸ Speech Recognition.")
        case .restricted:
            return (nil, "macOS Speech Recognition is restricted on this Mac.")
        case .notDetermined:
            return (nil, "macOS Speech Recognition authorization was not granted.")
        @unknown default:
            return (nil, "Unknown macOS Speech Recognition authorization state.")
        }

        let recognizer: SFSpeechRecognizer? = {
            if let current = SFSpeechRecognizer(locale: Locale.current), current.isAvailable {
                return current
            }
            if let enUS = SFSpeechRecognizer(locale: Locale(identifier: "en-US")), enUS.isAvailable {
                return enUS
            }
            return SFSpeechRecognizer(locale: Locale.current)
                ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
                ?? SFSpeechRecognizer()
        }()

        guard let recognizer else {
            return (nil, "macOS SFSpeechRecognizer is unavailable for the current locale.")
        }

        if recognizer.supportsOnDeviceRecognition {
            let onDevice = await runSingleSystemRecognitionRequest(
                recognizer: recognizer,
                fileURL: fileURL,
                requiresOnDevice: true,
                timeout: timeout
            )
            if let text = onDevice.transcript, !text.isEmpty {
                return (text, nil)
            }
        }

        return await runSingleSystemRecognitionRequest(
            recognizer: recognizer,
            fileURL: fileURL,
            requiresOnDevice: false,
            timeout: timeout
        )
    }

    private static func runSingleSystemRecognitionRequest(
        recognizer: SFSpeechRecognizer,
        fileURL: URL,
        requiresOnDevice: Bool,
        timeout: TimeInterval
    ) async -> (transcript: String?, error: String?) {
        await withCheckedContinuation { continuation in
            let lock = NSLock()
            var didResume = false
            var latestPartial = ""
            var taskRef: SFSpeechRecognitionTask?

            func finish(transcript: String?, error: String?) {
                lock.lock()
                if didResume {
                    lock.unlock()
                    return
                }
                didResume = true
                let taskToCancel = taskRef
                taskRef = nil
                lock.unlock()
                taskToCancel?.cancel()
                continuation.resume(returning: (transcript, error))
            }

            let request = SFSpeechURLRecognitionRequest(url: fileURL)
            request.shouldReportPartialResults = true
            if requiresOnDevice && recognizer.supportsOnDeviceRecognition {
                request.requiresOnDeviceRecognition = true
            }

            let watchdog = DispatchWorkItem {
                lock.lock()
                let partial = latestPartial.trimmingCharacters(in: .whitespacesAndNewlines)
                lock.unlock()
                if !partial.isEmpty {
                    finish(transcript: partial, error: nil)
                } else {
                    finish(transcript: nil, error: "macOS System STT timed out.")
                }
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout, execute: watchdog)

            let startedTask = recognizer.recognitionTask(with: request) { result, error in
                if let result {
                    let formatted = result.bestTranscription.formattedString.trimmingCharacters(in: .whitespacesAndNewlines)
                    lock.lock()
                    if !formatted.isEmpty {
                        latestPartial = formatted
                    }
                    lock.unlock()
                    if result.isFinal {
                        watchdog.cancel()
                        let finalText = formatted.isEmpty ? latestPartial : formatted
                        if !finalText.isEmpty {
                            finish(transcript: finalText, error: nil)
                        } else {
                            finish(transcript: nil, error: "macOS System STT returned empty text.")
                        }
                        return
                    }
                }
                if let error {
                    watchdog.cancel()
                    lock.lock()
                    let fallbackPartial = latestPartial.trimmingCharacters(in: .whitespacesAndNewlines)
                    lock.unlock()
                    if !fallbackPartial.isEmpty {
                        finish(transcript: fallbackPartial, error: nil)
                    } else {
                        finish(transcript: nil, error: error.localizedDescription)
                    }
                }
            }

            lock.lock()
            if didResume {
                lock.unlock()
                startedTask.cancel()
            } else {
                taskRef = startedTask
                lock.unlock()
            }
        }
    }

    /// Normalizes a raw STT transcript (e.g. `"Talk about food."`) into the lowercase
    /// conversational quote string shown in the subcontainer voice row (`"talk about food"` in `Untitled 9.jpg`).
    static func normalizedVoiceDisplayQuote(from raw: String) -> String {
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = cleaned.last, [".", ",", "!", "?"].contains(last) {
            cleaned.removeLast()
        }
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return raw.trimmingCharacters(in: .whitespacesAndNewlines) }
        return cleaned.lowercased()
    }
}

// MARK: - Muse Skills & Extensions (`muse skills list / enable / disable`)

struct MuseSkillItem: Identifiable, Equatable, Sendable {
    var id: String { "\(scope):\(name)" }
    var name: String
    var scope: String
    var activation: String
    var description: String
    var path: String

    var isEnabled: Bool {
        activation == "on" || activation == "enabled" || activation == "user-invocable-only"
    }
}

@Observable
@MainActor
final class MuseSkillsService {
    static let shared = MuseSkillsService()

    private(set) var skills: [MuseSkillItem] = []
    private(set) var isLoading = false

    func refresh(cwd: String, installation: PiInstallation? = nil) async {
        isLoading = true
        defer { isLoading = false }
        skills = await Self.loadSkills(workspace: cwd, installation: installation)
    }

    func toggle(skill: MuseSkillItem, cwd: String, installation: PiInstallation? = nil) async {
        _ = await Self.setSkillEnabled(skill, enabled: !skill.isEnabled, workspace: cwd, installation: installation)
        await refresh(cwd: cwd, installation: installation)
    }

    static func loadSkills(workspace: String?, installation: PiInstallation?) async -> [MuseSkillItem] {
        guard let resolved = await MuseUsageService.resolveInstallation(installation) else { return [] }
        let executable = resolved.executableURL
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { return [] }

        var args = ["skills", "list"]
        if let workspace, !workspace.isEmpty {
            args += ["--workspace", workspace, "--trust-workspace"]
        }
        let env = PiDiscoveryService.launchEnvironment(
            executable: executable,
            shellPath: resolved.shellPath
        )
        let result = await PiDiscoveryService().run(
            executable: executable,
            arguments: args,
            directory: workspace.map { URL(fileURLWithPath: $0) } ?? URL(fileURLWithPath: NSHomeDirectory()),
            environment: env
        )
        let lines = result.stdout.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        var items: [MuseSkillItem] = []
        for line in lines.dropFirst() {
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard cols.count >= 5 else { continue }
            items.append(MuseSkillItem(
                name: cols[0],
                scope: cols[1],
                activation: cols[2],
                description: cols[3],
                path: cols[4]
            ))
        }
        return items
    }

    static func setSkillEnabled(_ skill: MuseSkillItem, enabled: Bool, workspace: String?, installation: PiInstallation?) async -> Bool {
        guard let resolved = await MuseUsageService.resolveInstallation(installation) else { return false }
        let executable = resolved.executableURL
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { return false }

        var args = ["skills", enabled ? "enable" : "disable", skill.name, "--scope", skill.scope]
        if let workspace, !workspace.isEmpty {
            args += ["--workspace", workspace, "--trust-workspace"]
        }
        let env = PiDiscoveryService.launchEnvironment(
            executable: executable,
            shellPath: resolved.shellPath
        )
        let result = await PiDiscoveryService().run(
            executable: executable,
            arguments: args,
            directory: workspace.map { URL(fileURLWithPath: $0) } ?? URL(fileURLWithPath: NSHomeDirectory()),
            environment: env
        )
        return result.exitCode == 0
    }
}

// MARK: - Muse Cross-Session Agent Messaging (`muse session-message`)

enum MuseSessionMessageService {
    static func listMessages(installation: PiInstallation?) async -> [MuseAgentMessageInfo] {
        guard let resolved = await MuseUsageService.resolveInstallation(installation) else {
            return []
        }
        let executable = resolved.executableURL
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            return []
        }

        let env = PiDiscoveryService.launchEnvironment(
            executable: executable,
            shellPath: resolved.shellPath
        )
        let result = await PiDiscoveryService().run(
            executable: executable,
            arguments: ["session-message", "list", "--json"],
            directory: URL(fileURLWithPath: NSHomeDirectory()),
            environment: env
        )
        guard result.exitCode == 0 else { return [] }
        let out = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = out.data(using: .utf8),
              let json = try? JSONCoding.decode(data) else {
            return []
        }
        let records = json.array("messages") ?? json.array("items") ?? (json.arrayValue ?? [])
        return records.compactMap { item in
            let id = item.string("message_id") ?? item.string("id") ?? UUID().uuidString
            let body = item.string("body") ?? item.string("text") ?? ""
            guard !body.isEmpty else { return nil }
            let sender = item.string("sender") ?? item.string("sender_session_name") ?? item.string("sender_session_id") ?? "peer"
            let target = item.string("target") ?? item.string("target_session_id") ?? "session"
            let policy = item.string("status") ?? item.string("delivery_policy")
            return MuseAgentMessageInfo(
                id: id,
                direction: .incoming,
                sender: sender,
                target: target,
                workspaceLabel: item.string("workspace_label"),
                body: body,
                timestamp: nil,
                deliveryPolicy: policy
            )
        }
    }

    static func sendMessage(target: String, body: String, installation: PiInstallation?) async -> (success: Bool, detail: String) {
        guard let resolved = await MuseUsageService.resolveInstallation(installation) else {
            return (false, "Muse CLI executable not found.")
        }
        let executable = resolved.executableURL
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            return (false, "Muse CLI executable not found.")
        }

        let env = PiDiscoveryService.launchEnvironment(
            executable: executable,
            shellPath: resolved.shellPath
        )

        return await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = executable
            process.arguments = ["session-message", "send", "--target", target, "--json"]
            var merged = ProcessInfo.processInfo.environment
            for (k, v) in env { merged[k] = v }
            process.environment = merged

            let stdinPipe = Pipe()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardInput = stdinPipe
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            var outData = Data()
            var errData = Data()
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                outData = (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data()
                group.leave()
            }
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                errData = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()
                group.leave()
            }

            let watchdog = DispatchWorkItem {
                if process.isRunning {
                    process.terminate()
                    try? stdoutPipe.fileHandleForReading.close()
                    try? stderrPipe.fileHandleForReading.close()
                }
            }
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 10.0, execute: watchdog)

            do {
                try process.run()
                if let data = body.data(using: .utf8) {
                    try? stdinPipe.fileHandleForWriting.write(contentsOf: data)
                }
                try? stdinPipe.fileHandleForWriting.close()
                process.waitUntilExit()
                watchdog.cancel()
                _ = group.wait(timeout: .now() + 2)
                let out = String(data: outData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let err = String(data: errData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if process.terminationStatus == 0 {
                    return (true, out.isEmpty ? "Sent to \(target)" : out)
                }
                return (false, err.isEmpty ? out : err)
            } catch {
                watchdog.cancel()
                return (false, error.localizedDescription)
            }
        }.value
    }
}
