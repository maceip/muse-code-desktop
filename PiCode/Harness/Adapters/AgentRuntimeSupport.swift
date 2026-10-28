//
//  AgentRuntimeSupport.swift
//  PiCode
//
//  Shared plumbing for adapters that translate a CLI harness into the app's
//  canonical command/event surface: a buffered conversation, Pi-shaped message
//  construction, and default responses for the commands answered from local state.
//

import Foundation

/// Base class for a harness adapter. It owns the canonical message buffer, the
/// event callbacks, and the commands that need no harness round-trip. Subclasses
/// implement the process and the harness-specific `send` cases.
class BufferedAgentRuntime: AgentRuntime, @unchecked Sendable {
    let descriptor: HarnessDescriptor
    let installation: HarnessInstallation
    let projectPath: String
    let systemPrompt: String?
    let sessionFile: String?
    var modelOverride: String?
    let extraArguments: [String]
    let environment: [String: String]

    var onEvent: ((PiEvent, JSONValue) -> Void)?
    var onExit: ((Int32, Process.TerminationReason) -> Void)?
    var onStderr: ((String) -> Void)?
    var onProtocolError: ((String) -> Void)?
    var onResponseWithoutID: ((RPCResponse) -> Void)?
    var onPayloadRecord: ((String) -> Void)?
    var recordsPayloads = false

    // MARK: Canonical conversation

    /// Canonical messages so the controller's `get_messages` path rebuilds the
    /// transcript uniformly.
    var messages: [PiMessage] = []
    var stateFields = StateFields()

    struct StateFields {
        var sessionFile: String?
        var sessionId: String?
        var sessionName: String?
        var model: PiModel?
        var thinkingLevel: String?
        var isStreaming = false
        var messageCount = 0
    }

    init(descriptor: HarnessDescriptor,
         installation: HarnessInstallation,
         projectPath: String,
         sessionFile: String?,
         systemPrompt: String?,
         model: String?,
         extraArguments: [String],
         environment: [String: String]) {
        self.descriptor = descriptor
        self.installation = installation
        self.projectPath = projectPath
        self.sessionFile = sessionFile
        self.systemPrompt = systemPrompt
        self.modelOverride = model
        self.extraArguments = extraArguments
        self.environment = environment
    }

    // MARK: Lifecycle (subclasses override)

    func prepare() async {
        guard let sessionFile, messages.isEmpty else { return }
        let summary = await Task.detached(priority: .userInitiated) {
            MuseSessionHistory.loadSummary(at: sessionFile)
        }.value
        guard messages.isEmpty else { return }
        messages = summary.messages
        stateFields.sessionId = summary.sessionId ?? sessionFile
        stateFields.sessionFile = sessionFile
        stateFields.sessionName = summary.sessionName
        stateFields.messageCount = messages.count
    }

    func start() throws {
        throw AgentRuntimeError.unsupported(command: "start", harness: descriptor.displayName)
    }

    func stop() {}

    /// Adapters with no fire-and-forget channel simply ignore it.
    func sendRaw(_ payload: JSONValue) {}

    // MARK: Command dispatch

    func send(_ command: RPCCommand, timeout: TimeInterval) async throws -> RPCResponse {
        switch command {
        case .getState:
            return response(command, data: stateData())
        case .getMessages:
            return response(command, data: .object(["messages": .array(messages.map(\.raw))]))
        case .getLastAssistantText:
            let text = messages.last(where: { $0.isAssistant })?.textContent
            return response(command, data: .object(["text": text.map(JSONValue.string) ?? .null]))
        case .getAvailableThinkingLevels:
            return response(command, data: .object(["levels": .array(thinkingLevelNames.map { .string($0) })]))
        case .setThinkingLevel(let level):
            stateFields.thinkingLevel = level
            return response(command)
        case .setSessionName(let name):
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            stateFields.sessionName = trimmed.isEmpty ? nil : trimmed
            return response(command)
        default:
            throw AgentRuntimeError.unsupported(command: command.name, harness: descriptor.displayName)
        }
    }

    var thinkingLevelNames: [String] { [] }

    /// The bare model id a CLI flag expects, with any `provider/` prefix removed.
    var cliModelName: String? {
        guard let modelOverride, !modelOverride.isEmpty else { return nil }
        if let slash = modelOverride.firstIndex(of: "/") {
            return String(modelOverride[modelOverride.index(after: slash)...])
        }
        return modelOverride
    }

    // MARK: Responses

    func response(_ command: RPCCommand, data: JSONValue? = nil) -> RPCResponse {
        var object: [String: JSONValue] = [
            "type": .string("response"),
            "command": .string(command.name),
            "success": .bool(true)
        ]
        if let data { object["data"] = data }
        let response = RPCResponse(json: .object(object))
        if recordsPayloads {
            onPayloadRecord?("← \(JSONScanner.serialize(.object(object)))")
        }
        return response
    }

    func stateData() -> JSONValue {
        var object: [String: JSONValue] = [
            "isStreaming": .bool(stateFields.isStreaming),
            "isCompacting": .bool(false),
            "messageCount": .number(Double(stateFields.messageCount)),
            "pendingMessageCount": .number(0)
        ]
        if let value = stateFields.sessionFile { object["sessionFile"] = .string(value) }
        if let value = stateFields.sessionId { object["sessionId"] = .string(value) }
        if let value = stateFields.sessionName { object["sessionName"] = .string(value) }
        if let value = stateFields.thinkingLevel { object["thinkingLevel"] = .string(value) }
        if let model = stateFields.model { object["model"] = model.jsonValue }
        return .object(object)
    }

    // MARK: Event emission

    func emit(_ event: PiEvent) {
        onEvent?(event, .null)
    }

    func emit(_ events: [PiEvent]) {
        for event in events { emit(event) }
    }

    // MARK: Canonical message construction + event pairs

    func recordUser(_ text: String) {
        messages.append(PiMessage(raw: AgentWire.userMessage(text)))
        stateFields.messageCount = messages.count
    }

    func beginAssistant(model: String?, provider: String?, sessionId: String? = nil) {
        if let sessionId { stateFields.sessionId = sessionId }
        stateFields.isStreaming = true
        emit(.agentStart)
        emit(.messageStart(AgentWire.assistantMessage(text: "", model: model, provider: provider)))
    }

    func streamText(_ delta: String, index: Int = 0) {
        guard !delta.isEmpty else { return }
        emit(.messageUpdate(usage: nil, delta: .textDelta(contentIndex: index, delta: delta)))
    }

    func streamThinking(_ delta: String, index: Int = 0) {
        guard !delta.isEmpty else { return }
        emit(.messageUpdate(usage: nil,
                            delta: .thinkingDelta(contentIndex: index, delta: delta)))
    }

    func endAssistant(text: String, model: String?, provider: String?, usage: PiUsage? = nil) {
        let message = AgentWire.assistantMessage(text: text, model: model, provider: provider, usage: usage)
        messages.append(message)
        stateFields.messageCount = messages.count
        stateFields.isStreaming = false
        emit(.messageEnd(message))
        emit(.agentEnd(messages: [message], willRetry: false))
    }

    func startTool(id: String, name: String, arguments: JSONValue?) {
        emit(.toolExecutionStart(toolCallId: id, toolName: name, args: arguments))
    }

    func updateTool(id: String, name: String, output: String) {
        emit(.toolExecutionUpdate(toolCallId: id,
                                  toolName: name,
                                  partialResult: AgentWire.toolResult(text: output, isError: false)))
    }

    func endTool(id: String, name: String, output: String, isError: Bool) {
        emit(.toolExecutionEnd(toolCallId: id,
                               toolName: name,
                               result: AgentWire.toolResult(text: output, isError: isError),
                               isError: isError))
        messages.append(PiMessage(raw: AgentWire.toolResultMessage(id: id, name: name, output: output, isError: isError)))
        stateFields.messageCount = messages.count
    }

    func recordTool(id: String, name: String, output: String, isError: Bool) {
        endTool(id: id, name: name, output: output, isError: isError)
    }

    func fail(_ message: String) {
        stateFields.isStreaming = false
        emit(.unknown(type: "error"))
        onStderr?(message)
    }
}

// MARK: - Canonical wire builders

enum AgentWire {
    static func userMessage(_ text: String, timestamp: Date = Date()) -> JSONValue {
        .object([
            "role": .string("user"),
            "content": .string(text),
            "timestamp": .number(timestamp.timeIntervalSince1970 * 1000)
        ])
    }

    static func assistantMessage(text: String,
                                 thinking: String? = nil,
                                 toolCalls: [(id: String, name: String, arguments: JSONValue)] = [],
                                 model: String? = nil,
                                 provider: String? = nil,
                                 usage: PiUsage? = nil,
                                 stopReason: String? = "end_turn",
                                 errorMessage: String? = nil,
                                 timestamp: Date = Date()) -> PiMessage {
        var blocks: [JSONValue] = []
        if let thinking, !thinking.isEmpty {
            blocks.append(.object([
                "type": .string("thinking"),
                "thinking": .string(thinking)
            ]))
        }
        if !text.isEmpty {
            blocks.append(.object([
                "type": .string("text"),
                "text": .string(text)
            ]))
        }
        for call in toolCalls {
            blocks.append(.object([
                "type": .string("toolCall"),
                "id": .string(call.id),
                "name": .string(call.name),
                "arguments": call.arguments
            ]))
        }
        var object: [String: JSONValue] = [
            "role": .string("assistant"),
            "content": .array(blocks),
            "timestamp": .number(timestamp.timeIntervalSince1970 * 1000)
        ]
        if let model { object["model"] = .string(model) }
        if let provider { object["provider"] = .string(provider) }
        if let stopReason { object["stopReason"] = .string(stopReason) }
        if let errorMessage { object["errorMessage"] = .string(errorMessage) }
        if let usage {
            object["usage"] = .object([
                "input": .number(Double(usage.input)),
                "output": .number(Double(usage.output)),
                "cacheRead": .number(Double(usage.cacheRead)),
                "cacheWrite": .number(Double(usage.cacheWrite)),
                "totalTokens": .number(Double(usage.totalTokens)),
                "cost": .object(["total": .number(usage.cost)])
            ])
        }
        return PiMessage(raw: .object(object))
    }

    static func toolResultMessage(id: String,
                                  name: String,
                                  output: String,
                                  isError: Bool,
                                  timestamp: Date = Date()) -> JSONValue {
        .object([
            "role": .string("toolResult"),
            "toolCallId": .string(id),
            "toolName": .string(name),
            "content": .array([
                .object([
                    "type": .string("text"),
                    "text": .string(output)
                ])
            ]),
            "isError": .bool(isError),
            "timestamp": .number(timestamp.timeIntervalSince1970 * 1000)
        ])
    }

    static func toolResult(text: String, isError: Bool) -> PiToolResult {
        PiToolResult(json: .object([
            "content": .array([
                .object([
                    "type": .string("text"),
                    "text": .string(text)
                ])
            ]),
            "isError": .bool(isError)
        ]))
    }

    static func model(id: String,
                      name: String,
                      provider: String,
                      reasoning: Bool = false,
                      thinkingEfforts: [String] = [],
                      images: Bool = true,
                      contextWindow: Int? = nil,
                      maxTokens: Int? = nil) -> JSONValue {
        var object: [String: JSONValue] = [
            "id": .string(id),
            "name": .string(name),
            "provider": .string(provider),
            "reasoning": .bool(reasoning),
            "thinking": .object(["efforts": .array(thinkingEfforts.map(JSONValue.string))]),
            "thinkingEfforts": .array(thinkingEfforts.map(JSONValue.string)),
            "input": .array(images ? [.string("text"), .string("image")] : [.string("text")])
        ]
        if let contextWindow { object["contextWindow"] = .number(Double(contextWindow)) }
        if let maxTokens { object["maxTokens"] = .number(Double(maxTokens)) }
        return .object(object)
    }
}

extension PiModel {
    init(id: String, provider: String, name: String, reasoning: Bool = false, images: Bool = false) {
        self.id = id
        self.name = name
        self.provider = provider
        self.api = nil
        self.baseURL = nil
        self.reasoning = reasoning
        self.thinkingEfforts = []
        self.input = images ? ["text", "image"] : ["text"]
        self.contextWindow = nil
        self.maxTokens = nil
        self.cost = PiModelCost(json: nil)
    }

    var jsonValue: JSONValue {
        .object([
            "id": .string(id),
            "name": .string(name),
            "provider": .string(provider),
            "reasoning": .bool(reasoning),
            "input": .array(input.map { .string($0) })
        ])
    }
}
