//
//  AgentRuntime.swift
//  PiCode
//
//  Transport-neutral contract between a session controller and the Muse CLI
//  runtime.
//

import Foundation

enum AgentRuntimeError: LocalizedError {
    case notRunning
    case unsupported(command: String, harness: String)
    case processExited(code: Int32, stderr: String)
    case commandFailed(command: String, message: String)

    var errorDescription: String? {
        switch self {
        case .notRunning:
            return "The agent process is not running."
        case .unsupported(let command, let harness):
            return "\(harness) does not support `\(command)`."
        case .processExited(let code, let stderr):
            let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty
                ? "The agent exited with status \(code)."
                : "The agent exited with status \(code): \(trimmed.oneLinePreview(limit: 240))"
        case .commandFailed(let command, let message):
            return "`\(command)` failed: \(message)"
        }
    }
}

/// A live connection to one coding-agent session.
///
/// Implementations may run a long-lived child process or spawn one process per
/// turn (`muse exec --json`). Either way, the controller talks to this type and
/// never to `Process` directly.
protocol AgentRuntime: AnyObject, Sendable {
    var descriptor: HarnessDescriptor { get }

    var onEvent: ((PiEvent, JSONValue) -> Void)? { get set }
    var onExit: ((Int32, Process.TerminationReason) -> Void)? { get set }
    var onStderr: ((String) -> Void)? { get set }
    var onProtocolError: ((String) -> Void)? { get set }
    var onResponseWithoutID: ((RPCResponse) -> Void)? { get set }
    var onPayloadRecord: ((String) -> Void)? { get set }
    var recordsPayloads: Bool { get set }

    /// Async pre-start hook for adapters that load existing history off the main actor.
    func prepare() async
    func start() throws
    func stop()
    func send(_ command: RPCCommand, timeout: TimeInterval) async throws -> RPCResponse
    func sendRaw(_ payload: JSONValue)
}

extension AgentRuntime {
    func prepare() async {}
}

enum AgentRuntimeFactory {
    static func make(
        descriptor: HarnessDescriptor,
        installation: HarnessInstallation,
        projectPath: String,
        sessionFile: String?,
        systemPrompt: String?,
        model: String?,
        trustArguments: [String],
        extraArguments: [String],
        environment: [String: String]
    ) -> any AgentRuntime {
        MuseRuntime(
            descriptor: descriptor,
            installation: installation,
            projectPath: projectPath,
            sessionFile: sessionFile,
            systemPrompt: systemPrompt,
            model: model,
            trustArguments: trustArguments,
            extraArguments: extraArguments,
            environment: environment
        )
    }
}
