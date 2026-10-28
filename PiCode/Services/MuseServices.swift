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

// MARK: - Credit & Allowance Battery Tracker (`muse usage --json`)

struct MuseUsageSnapshot: Equatable, Sendable {
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
    /// from `muse usage --json`, or `nil` when the server reports no allowance
    /// (`"allowance": null`). Never fabricates a percentage from local context.
    var allowancePercentage: Int? {
        guard let allowance = latestSnapshot?.allowanceRemainingPercent else { return nil }
        return max(0, min(100, Int(allowance.rounded())))
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

        var remainingPercent: Double?
        var summary: String?
        if let allowance = json["allowance"], !allowance.isNull {
            if let rem = allowance.double("remaining_percent") ?? allowance.double("remainingPercent") {
                remainingPercent = rem
            } else if let used = allowance.double("used_percent") ?? allowance.double("usedPercent") {
                remainingPercent = max(0, 100.0 - used)
            } else if let rem = allowance.double("remaining"), let limit = allowance.double("limit"), limit > 0 {
                remainingPercent = max(0, min(100, (rem / limit) * 100.0))
            }
            summary = allowance.string("summary") ?? allowance.string("tier")
        }

        latestSnapshot = MuseUsageSnapshot(
            allowanceRemainingPercent: remainingPercent,
            allowanceSummary: summary,
            reason: json.string("reason"),
            hint: json.string("hint"),
            fetchedAt: Date()
        )
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

// MARK: - Built-in Speech-to-Text (`muse voice transcribe`)

@Observable
@MainActor
final class MuseVoiceSTTService: NSObject, AVAudioRecorderDelegate {
    static let shared = MuseVoiceSTTService()

    private(set) var isRecording = false
    private(set) var isTranscribing = false
    private(set) var recordingDuration: TimeInterval = 0
    private(set) var lastError: String?

    private var recorder: AVAudioRecorder?
    private var recordingURL: URL?
    private var timerTask: Task<Void, Never>?

    func toggleRecording(installation: PiInstallation?, onTranscribed: @escaping @MainActor (String) -> Void) async {
        if isRecording {
            await stopAndTranscribe(installation: installation, onTranscribed: onTranscribed)
        } else {
            await startRecording()
        }
    }

    func startRecording() async {
        lastError = nil
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
            guard newRecorder.record() else {
                lastError = "Could not start microphone capture."
                return
            }
            recorder = newRecorder
            recordingURL = tempURL
            isRecording = true
            recordingDuration = 0
            timerTask?.cancel()
            timerTask = Task { [weak self] in
                let start = Date()
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 200_000_000)
                    guard let self, self.isRecording else { break }
                    self.recordingDuration = Date().timeIntervalSince(start)
                }
            }
        } catch {
            lastError = "Could not initialize audio recorder: \(error.localizedDescription)"
        }
    }

    func stopAndTranscribe(installation: PiInstallation?, onTranscribed: @escaping @MainActor (String) -> Void) async {
        timerTask?.cancel()
        timerTask = nil
        recorder?.stop()
        recorder = nil
        isRecording = false

        guard let url = recordingURL else { return }
        recordingURL = nil
        defer { try? FileManager.default.removeItem(at: url) }

        if let transcript = await transcribeFile(at: url, installation: installation), !transcript.isEmpty {
            onTranscribed(transcript)
        }
    }

    func transcribeFile(at fileURL: URL, installation: PiInstallation?) async -> String? {
        guard let resolved = await MuseUsageService.resolveInstallation(installation) else {
            lastError = "Muse CLI executable not found."
            return nil
        }
        let executable = resolved.executableURL
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            lastError = "Muse CLI executable not found."
            return nil
        }

        isTranscribing = true
        lastError = nil
        defer { isTranscribing = false }

        let env = PiDiscoveryService.launchEnvironment(
            executable: executable,
            shellPath: resolved.shellPath
        )
        let result = await PiDiscoveryService().run(
            executable: executable,
            arguments: ["voice", "transcribe", fileURL.path],
            directory: URL(fileURLWithPath: NSHomeDirectory()),
            environment: env
        )
        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.exitCode == 0, !stdout.isEmpty {
            return stdout
        }
        let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        lastError = stderr.isEmpty ? "Muse STT returned no speech text." : stderr
        return nil
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

            do {
                try process.run()
                if let data = body.data(using: .utf8) {
                    stdinPipe.fileHandleForWriting.write(data)
                }
                try? stdinPipe.fileHandleForWriting.close()
                process.waitUntilExit()
                let out = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let err = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if process.terminationStatus == 0 {
                    return (true, out.isEmpty ? "Sent to \(target)" : out)
                }
                return (false, err.isEmpty ? out : err)
            } catch {
                return (false, error.localizedDescription)
            }
        }.value
    }
}
