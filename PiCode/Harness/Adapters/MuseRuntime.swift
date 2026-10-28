//
//  MuseRuntime.swift
//  PiCode
//
//  Drives Meta's Muse Code CLI over `muse exec --json` and reads its local
//  session store (`~/.local/share/muse/sessions`), model catalog
//  (`~/.local/share/muse/model-catalog`), and user settings (`~/.config/muse`).
//

import Foundation

final class MuseRuntime: BufferedAgentRuntime, @unchecked Sendable {
    static let efforts = ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]

    let trustArguments: [String]
    private var currentTask: Process?
    private var currentSessionID: String?
    private var selectedModel: String
    private var selectedThinkingLevel: String
    private var entries: [JSONValue] = []

    private var currentText = ""
    private var currentThinking = ""
    private var currentTurnModel: String?
    private var activeToolNames: [String: String] = [:]
    private var turnToolCalls: [(id: String, name: String, arguments: JSONValue)] = []

    private var usageTotals = PiUsage.zero
    private var userMessages = 0
    private var assistantMessages = 0
    private var toolCalls = 0

    override init(descriptor: HarnessDescriptor,
                  installation: HarnessInstallation,
                  projectPath: String,
                  sessionFile: String?,
                  systemPrompt: String?,
                  model: String?,
                  extraArguments: [String],
                  environment: [String: String]) {
        self.trustArguments = []
        let configured = Self.readUserSettings()
        self.selectedModel = Self.normalizeModelID(model) ?? configured.model ?? "muse-wonder-full-1.0"
        self.selectedThinkingLevel = configured.reasoningEffort ?? "high"
        super.init(
            descriptor: descriptor,
            installation: installation,
            projectPath: projectPath,
            sessionFile: sessionFile,
            systemPrompt: systemPrompt,
            model: model,
            extraArguments: extraArguments,
            environment: environment
        )
        self.currentSessionID = Self.extractSessionUUID(from: sessionFile)
        stateFields.sessionId = currentSessionID
        stateFields.sessionFile = sessionFile
        stateFields.thinkingLevel = selectedThinkingLevel
        stateFields.model = resolveModelObject(for: selectedModel)
    }

    init(descriptor: HarnessDescriptor,
         installation: HarnessInstallation,
         projectPath: String,
         sessionFile: String?,
         systemPrompt: String?,
         model: String?,
         trustArguments: [String],
         extraArguments: [String],
         environment: [String: String]) {
        self.trustArguments = trustArguments
        let configured = Self.readUserSettings()
        self.selectedModel = Self.normalizeModelID(model) ?? configured.model ?? "muse-wonder-full-1.0"
        self.selectedThinkingLevel = configured.reasoningEffort ?? "high"
        super.init(
            descriptor: descriptor,
            installation: installation,
            projectPath: projectPath,
            sessionFile: sessionFile,
            systemPrompt: systemPrompt,
            model: model,
            extraArguments: extraArguments,
            environment: environment
        )
        self.currentSessionID = Self.extractSessionUUID(from: sessionFile)
        stateFields.sessionId = currentSessionID
        stateFields.sessionFile = sessionFile
        stateFields.thinkingLevel = selectedThinkingLevel
        stateFields.model = resolveModelObject(for: selectedModel)
    }

    override var thinkingLevelNames: [String] { Self.efforts }

    override func prepare() async {
        guard let sessionFile, messages.isEmpty else { return }
        let summary = await Task.detached(priority: .userInitiated) {
            MuseSessionHistory.loadSummary(at: sessionFile)
        }.value
        guard messages.isEmpty else { return }
        applyLoadedSummary(summary, filePath: sessionFile)
    }

    private func applyLoadedSummary(_ summary: MuseSessionHistory.Summary, filePath: String) {
        messages = summary.messages
        entries = summary.entries
        if let sid = summary.sessionId, !sid.isEmpty {
            currentSessionID = sid
            stateFields.sessionId = sid
        }
        stateFields.sessionFile = filePath
        if let customTitle = SessionCatalogMetadata.title(for: SessionRef(
            id: filePath,
            sessionId: currentSessionID,
            filePath: filePath,
            name: summary.sessionName,
            cwd: summary.cwd ?? projectPath,
            createdAt: summary.createdAt ?? Date(),
            updatedAt: summary.updatedAt ?? Date(),
            messageCount: summary.messageCount,
            firstUserMessage: summary.firstUserMessage,
            parentSession: nil,
            harnessID: .museCode
        )), !customTitle.isEmpty {
            stateFields.sessionName = customTitle
        } else if let name = summary.sessionName, !name.isEmpty {
            stateFields.sessionName = name
        }
        if let modelId = summary.modelId, !modelId.isEmpty {
            selectedModel = modelId
            stateFields.model = resolveModelObject(for: modelId)
        }
        usageTotals = summary.usage
        userMessages = messages.filter(\.isUser).count
        assistantMessages = messages.filter(\.isAssistant).count
        toolCalls = messages.reduce(0) { count, msg in
            count + msg.content.filter { $0.kind == .toolCall }.count
        }
        stateFields.messageCount = messages.count
    }

    override func start() throws {
        // `muse exec --json` spawns one process per turn.
    }

    override func stop() {
        currentTask?.terminate()
        currentTask = nil
    }

    override func send(_ command: RPCCommand, timeout: TimeInterval) async throws -> RPCResponse {
        if recordsPayloads {
            onPayloadRecord?("→ \(JSONScanner.serialize(command.json(id: "muse")))")
        }
        switch command {
        case .prompt(let message, _, _),
             .steer(let message, _),
             .followUp(let message, _):
            recordUser(message)
            userMessages += 1
            appendRuntimeEntry(message: AgentWire.userMessage(message))
            Task.detached { [weak self] in
                await self?.runTurn(prompt: message)
            }
            return response(command)

        case .abort:
            stop()
            stateFields.isStreaming = false
            emit(.agentSettled)
            return response(command)

        case .getAvailableModels:
            return response(command, data: .object(["models": .array(availableModels())]))

        case .setModel(_, let modelId):
            selectedModel = Self.normalizeModelID(modelId) ?? modelId
            let configured = Self.readUserSettings()
            if let perModelEffort = configured.modelEfforts[selectedModel] {
                selectedThinkingLevel = perModelEffort
                stateFields.thinkingLevel = perModelEffort
            }
            stateFields.model = resolveModelObject(for: selectedModel)
            return response(command, data: .object(["model": stateFields.model?.jsonValue ?? .null]))

        case .cycleModel:
            let models = availableModels().compactMap(PiModel.init(json:))
            guard !models.isEmpty else { return response(command, data: .object(["model": .null])) }
            let currentIdx = models.firstIndex(where: { $0.id == selectedModel }) ?? -1
            let next = models[(currentIdx + 1) % models.count]
            selectedModel = next.id
            stateFields.model = next
            return response(command, data: .object(["model": next.jsonValue]))

        case .setThinkingLevel(let level):
            selectedThinkingLevel = level
            stateFields.thinkingLevel = level
            return response(command)

        case .cycleThinkingLevel:
            let current = Self.efforts.firstIndex(of: selectedThinkingLevel) ?? 0
            let next = Self.efforts[(current + 1) % Self.efforts.count]
            selectedThinkingLevel = next
            stateFields.thinkingLevel = next
            return response(command, data: .object(["level": .string(next)]))

        case .getCommands:
            return response(command, data: .object(["commands": .array([])]))

        case .getSessionStats:
            return response(command, data: statsJSON())

        case .getEntries(let since):
            let leafId = entries.last?.string("id")
            let slice: [JSONValue]
            if let since, let idx = entries.firstIndex(where: { $0.string("id") == since }) {
                slice = Array(entries.dropFirst(idx + 1))
            } else {
                slice = entries
            }
            var data: [String: JSONValue] = ["entries": .array(slice)]
            if let leafId { data["leafId"] = .string(leafId) }
            return response(command, data: .object(data))

        case .getTree:
            let parsedEntries = entries.map(PiSessionEntry.init(json:))
            let leafId = parsedEntries.last?.id
            let nodes = PiTreeNode.buildTree(from: parsedEntries, leafId: leafId)
            var data: [String: JSONValue] = [
                "tree": .array(nodes.map { Self.encodeTreeNode($0) })
            ]
            if let leafId { data["leafId"] = .string(leafId) }
            return response(command, data: .object(data))

        case .getForkMessages:
            let forkMsgs: [JSONValue] = entries.compactMap { entry in
                guard entry.string("type") == "message",
                      let msg = entry["message"],
                      msg.string("role") == "user",
                      let id = entry.string("id") else { return nil }
                let text = PiMessage(raw: msg).textContent
                return .object([
                    "entryId": .string(id),
                    "text": .string(text)
                ])
            }
            return response(command, data: .object(["messages": .array(forkMsgs)]))

        case .newSession:
            messages.removeAll()
            entries.removeAll()
            currentSessionID = nil
            stateFields.sessionId = nil
            stateFields.sessionFile = nil
            stateFields.sessionName = nil
            stateFields.messageCount = 0
            usageTotals = PiUsage.zero
            userMessages = 0
            assistantMessages = 0
            toolCalls = 0
            return response(command, data: .object(["cancelled": .bool(false)]))

        case .switchSession(let path):
            let summary = await Task.detached(priority: .userInitiated) {
                MuseSessionHistory.loadSummary(at: path)
            }.value
            messages.removeAll()
            entries.removeAll()
            applyLoadedSummary(summary, filePath: path)
            return response(command, data: .object(["cancelled": .bool(false)]))

        case .setSessionName(let name):
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            stateFields.sessionName = trimmed.isEmpty ? nil : trimmed
            if let filePath = stateFields.sessionFile {
                let ref = SessionRef(
                    id: filePath,
                    sessionId: currentSessionID,
                    filePath: filePath,
                    name: stateFields.sessionName,
                    cwd: projectPath,
                    createdAt: Date(),
                    updatedAt: Date(),
                    messageCount: stateFields.messageCount,
                    firstUserMessage: nil,
                    parentSession: nil,
                    harnessID: .museCode
                )
                SessionCatalogMetadata.rename(ref, to: trimmed)
            }
            return response(command)

        case .bash(let bashCommand):
            let result = await runLocalBash(bashCommand)
            return response(command, data: .object([
                "output": .string(result.output),
                "exitCode": .number(Double(result.exitCode)),
                "cancelled": .bool(false),
                "truncated": .bool(false)
            ]))

        case .abortBash, .clearQueue, .abortRetry:
            return response(command)

        default:
            return try await super.send(command, timeout: timeout)
        }
    }

    // MARK: - Turn Execution

    private func runTurn(prompt: String) async {
        currentText = ""
        currentThinking = ""
        currentTurnModel = selectedModel == "default" ? nil : selectedModel
        activeToolNames.removeAll()
        turnToolCalls.removeAll()

        var arguments = [
            "exec",
            "--json",
            "--workspace", projectPath,
            "--yolo",
            "--disable-sandbox",
            "--disable-approval",
            "--approval-mode", "never",
            "--parallel-tool-calls",
            "--subagent-worktree-isolation",
            "--trust-workspace"
        ]
        if let sessionID = currentSessionID, !sessionID.isEmpty {
            arguments += ["--session-id", sessionID]
        }
        if selectedModel != "default" && !selectedModel.isEmpty {
            arguments += ["--model", selectedModel]
        }
        if !selectedThinkingLevel.isEmpty {
            arguments += ["--reasoning-effort", selectedThinkingLevel]
        }
        for flag in extraArguments where !arguments.contains(flag) {
            if flag == "--no-parallel-tool-calls" {
                arguments.removeAll { $0 == "--parallel-tool-calls" }
            }
            arguments.append(flag)
        }
        arguments += ["--", prompt]

        let process = Process()
        process.executableURL = installation.executableURL
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: projectPath)
        var merged = ProcessInfo.processInfo.environment
        for (key, value) in environment { merged[key] = value }
        process.environment = merged

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        currentTask = process

        beginAssistant(model: currentTurnModel ?? selectedModel, provider: "meta", sessionId: currentSessionID)

        final class StreamCapture: @unchecked Sendable {
            let lock = NSLock()
            var decoder = LineAccumulator()
            var stderrText = ""
        }
        let capture = StreamCapture()

        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            guard let self else { return }
            capture.lock.lock()
            let lines = capture.decoder.append(chunk)
            capture.lock.unlock()
            for line in lines {
                self.consume(line: line)
            }
        }

        stderr.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            capture.lock.lock()
            capture.stderrText += text
            capture.lock.unlock()
            self?.onStderr?(text)
        }

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            fail("Could not run muse: \(error.localizedDescription)")
            emit(.agentSettled)
            return
        }

        stdout.fileHandleForReading.readabilityHandler = nil
        stderr.fileHandleForReading.readabilityHandler = nil
        let remaining = stdout.fileHandleForReading.readDataToEndOfFile()
        if !remaining.isEmpty {
            let lines = capture.lock.withLock {
                capture.decoder.append(remaining)
            }
            for line in lines {
                consume(line: line)
            }
        }
        currentTask = nil

        let capturedStderr = capture.lock.withLock {
            capture.stderrText
        }

        if process.terminationStatus != 0 && currentText.isEmpty && turnToolCalls.isEmpty {
            let detail = capturedStderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if !detail.isEmpty {
                fail(detail)
            }
        }

        if !currentText.isEmpty || !currentThinking.isEmpty || !turnToolCalls.isEmpty || messages.last?.isAssistant != true {
            let finalMessage = AgentWire.assistantMessage(
                text: currentText,
                thinking: currentThinking.isEmpty ? nil : currentThinking,
                toolCalls: turnToolCalls,
                model: currentTurnModel ?? selectedModel,
                provider: "meta"
            )
            messages.append(finalMessage)
            appendRuntimeEntry(message: finalMessage.raw)
            assistantMessages += 1
            stateFields.messageCount = messages.count
            stateFields.isStreaming = false
            emit(.messageEnd(finalMessage))
            emit(.agentEnd(messages: [finalMessage], willRetry: false))
        } else {
            stateFields.isStreaming = false
            if let lastAssistant = messages.last {
                emit(.agentEnd(messages: [lastAssistant], willRetry: false))
            }
        }
        emit(.agentSettled)
    }

    private func consume(line: String) {
        if recordsPayloads { onPayloadRecord?("← \(line)") }
        guard let data = line.data(using: .utf8),
              let json = try? JSONCoding.decode(data) else {
            return
        }

        if let sid = json.string("session_id"), !sid.isEmpty {
            currentSessionID = sid
            stateFields.sessionId = sid
            if stateFields.sessionFile == nil, let resolvedPath = Self.findSessionFilePath(forSessionID: sid) {
                stateFields.sessionFile = resolvedPath
            }
        }

        guard let type = json.string("type") else { return }
        switch type {
        case "session.ready":
            emit(.turnStart)

        case "run.started":
            stateFields.isStreaming = true

        case "run.reasoning.delta", "run.thinking.delta":
            if let delta = json.string("delta"), !delta.isEmpty {
                currentThinking += delta
                streamThinking(delta)
            }

        case "run.assistant_message.delta":
            if let delta = json.string("delta"), !delta.isEmpty {
                currentText += delta
                streamText(delta)
            }

        case "run.assistant_message":
            if let text = json.string("text"), !text.isEmpty {
                if currentText.isEmpty {
                    currentText = text
                    streamText(text)
                } else if !currentText.hasSuffix(text) {
                    let addition = "\n\n" + text
                    currentText += addition
                    streamText(addition)
                }
            }

        case "run.tool_calls":
            if let calls = json.array("tool_calls"), !calls.isEmpty {
                var batchCalls: [(id: String, name: String, arguments: JSONValue)] = []
                for call in calls {
                    let id = call.string("call_id") ?? call.string("id") ?? UUID().uuidString
                    let name = call.string("name") ?? "tool"
                    let args: JSONValue
                    if let argsString = call.string("args"),
                       let decoded = try? JSONCoding.decode(Data(argsString.utf8)) {
                        args = decoded
                    } else if let argsObj = call["args"], !argsObj.isNull {
                        args = argsObj
                    } else {
                        args = .object([:])
                    }
                    activeToolNames[id] = name
                    batchCalls.append((id: id, name: name, arguments: args))
                    toolCalls += 1
                }
                let stepMessage = AgentWire.assistantMessage(
                    text: currentText,
                    thinking: currentThinking.isEmpty ? nil : currentThinking,
                    toolCalls: batchCalls,
                    model: currentTurnModel ?? selectedModel,
                    provider: "meta",
                    stopReason: "tool_use"
                )
                messages.append(stepMessage)
                appendRuntimeEntry(message: stepMessage.raw)
                assistantMessages += 1
                stateFields.messageCount = messages.count
                emit(.messageEnd(stepMessage))
                currentText = ""
                currentThinking = ""
                turnToolCalls.removeAll()
                for call in batchCalls {
                    startTool(id: call.id, name: call.name, arguments: call.arguments)
                }
            }

        case "task.started":
            if let id = json.string("tool_call_id") ?? json.string("task_id") {
                let name = activeToolNames[id] ?? json.string("kind") ?? "tool"
                activeToolNames[id] = name
                let command = json.string("command")
                let args: JSONValue? = command.map { .object(["command": .string($0)]) }
                if !messages.contains(where: { msg in msg.content.contains(where: { $0.toolCallId == id }) }) &&
                   !turnToolCalls.contains(where: { $0.id == id }) {
                    turnToolCalls.append((id: id, name: name, arguments: args ?? .object([:])))
                    toolCalls += 1
                    startTool(id: id, name: name, arguments: args)
                }
            }

        case "task.output":
            if let id = json.string("tool_call_id") ?? json.string("task_id"),
               let chunk = json.string("chunk"), !chunk.isEmpty {
                let name = activeToolNames[id] ?? "tool"
                updateTool(id: id, name: name, output: chunk)
            }

        case "run.tool_results":
            if let results = json.array("results") {
                for res in results {
                    let id = res.string("tool_call_id") ?? UUID().uuidString
                    let name = activeToolNames[id] ?? "tool"
                    let rawText = res.string("text") ?? ""
                    let (output, isError) = Self.extractToolOutput(from: rawText)
                    endTool(id: id, name: name, output: output, isError: isError)
                    appendRuntimeEntry(message: AgentWire.toolResultMessage(id: id, name: name, output: output, isError: isError))
                }
                emit(.messageStart(AgentWire.assistantMessage(text: "", model: currentTurnModel ?? selectedModel, provider: "meta")))
            }

        case "run.model.completed":
            if let model = json.string("model"), !model.isEmpty {
                currentTurnModel = model
                selectedModel = model
                stateFields.model = resolveModelObject(for: model)
            }
            if let usage = json["usage"] {
                let input = usage.int("input_tokens") ?? 0
                let output = usage.int("output_tokens") ?? 0
                let cached = usage.int("cached_tokens") ?? usage.int("cache_read_tokens") ?? 0
                let cacheWrite = usage.int("cache_write_tokens") ?? 0
                usageTotals.input += input
                usageTotals.output += output
                usageTotals.cacheRead += cached
                usageTotals.cacheWrite += cacheWrite
                usageTotals.totalTokens += input + output
            }

        case "run.completed":
            if stateFields.sessionFile == nil, let sid = currentSessionID,
               let resolvedPath = Self.findSessionFilePath(forSessionID: sid) {
                stateFields.sessionFile = resolvedPath
            }
            emit(.turnEnd(message: nil, toolResults: []))

        default:
            break
        }
    }

    // MARK: - Helpers

    private func appendRuntimeEntry(message: JSONValue) {
        let id = "muse-live-\(entries.count + 1)"
        var entryObj: [String: JSONValue] = [
            "id": .string(id),
            "type": .string("message"),
            "timestamp": .string(ISO8601DateFormatter().string(from: Date())),
            "message": message
        ]
        if let parentId = entries.last?.string("id") {
            entryObj["parentId"] = .string(parentId)
        }
        entries.append(.object(entryObj))
    }

    private func resolveModelObject(for id: String) -> PiModel? {
        let normalized = Self.normalizeModelID(id) ?? id
        let catalog = availableModels().compactMap(PiModel.init(json:))
        if let match = catalog.first(where: { $0.id == normalized }) {
            return match
        }
        return PiModel(json: AgentWire.model(
            id: normalized,
            name: normalized == "default" ? "Muse (Default)" : normalized,
            provider: "meta",
            reasoning: true,
            thinkingEfforts: Self.efforts,
            images: false,
            contextWindow: 1_007_997,
            maxTokens: 128_000
        ))
    }

    private func availableModels() -> [JSONValue] {
        let userSettings = Self.readUserSettings()
        var models: [JSONValue] = []
        var seen = Set<String>()

        if let catalogFiles = try? FileManager.default.contentsOfDirectory(
            at: PiPaths.modelCatalogDirectory,
            includingPropertiesForKeys: nil
        ) {
            for file in catalogFiles where file.pathExtension == "json" {
                guard let data = try? Data(contentsOf: file),
                      let json = try? JSONCoding.decode(data),
                      let rows = json.array("rows") else { continue }
                for row in rows {
                    guard let modelId = row.string("model_id"), !modelId.isEmpty else { continue }
                    if row["supports_image_generation"]?.boolValue == true { continue }
                    let visibility = row.string("visibility") ?? "visible"
                    let isContributor = modelId.hasSuffix("-contributor")
                    if visibility == "hidden" && !(isContributor && userSettings.contributorModeEnabled) {
                        continue
                    }
                    guard seen.insert(modelId).inserted else { continue }
                    let label = row.string("display_label") ?? modelId
                    let provider = row.string("provider_id") ?? "meta"
                    let contextLimit = row.int("context_limit")
                    let outputLimit = row.int("output_limit")
                    let efforts = row.array("reasoning_effort_variants")?
                        .compactMap { $0.string("tier") } ?? Self.efforts
                    models.append(AgentWire.model(
                        id: modelId,
                        name: label,
                        provider: provider,
                        reasoning: !efforts.isEmpty,
                        thinkingEfforts: efforts.isEmpty ? Self.efforts : efforts,
                        images: false,
                        contextWindow: contextLimit,
                        maxTokens: outputLimit
                    ))
                }
            }
        }

        let fallbacks: [(id: String, name: String)] = [
            ("muse-wonder-full-1.0", "muse-wonder-full-1.0"),
            ("muse-wonder-1.0", "muse-wonder-1.0"),
            ("muse-spark-1.3", "muse-spark-1.3"),
            ("muse-spark-1.2", "muse-spark-1.2")
        ]
        for item in fallbacks where seen.insert(item.id).inserted {
            models.append(AgentWire.model(
                id: item.id,
                name: item.name,
                provider: "meta",
                reasoning: true,
                thinkingEfforts: Self.efforts,
                images: false,
                contextWindow: 1_007_997,
                maxTokens: 128_000
            ))
        }

        if !selectedModel.isEmpty, seen.insert(selectedModel).inserted {
            models.insert(AgentWire.model(
                id: selectedModel,
                name: selectedModel,
                provider: "meta",
                reasoning: true,
                thinkingEfforts: Self.efforts,
                images: false,
                contextWindow: 1_007_997,
                maxTokens: 128_000
            ), at: 0)
        }

        return models
    }

    private func statsJSON() -> JSONValue {
        let contextWindow = stateFields.model?.contextWindow ?? 1_007_997
        let usedTokens = usageTotals.totalTokens
        let percent = contextWindow > 0 ? min(100.0, (Double(usedTokens) / Double(contextWindow)) * 100.0) : 0.0
        var object: [String: JSONValue] = [
            "userMessages": .number(Double(userMessages)),
            "assistantMessages": .number(Double(assistantMessages)),
            "toolCalls": .number(Double(toolCalls)),
            "toolResults": .number(Double(toolCalls)),
            "totalMessages": .number(Double(messages.count)),
            "tokens": .object([
                "input": .number(Double(usageTotals.input)),
                "output": .number(Double(usageTotals.output)),
                "cacheRead": .number(Double(usageTotals.cacheRead)),
                "cacheWrite": .number(Double(usageTotals.cacheWrite)),
                "total": .number(Double(usageTotals.totalTokens))
            ]),
            "cost": .number(usageTotals.cost),
            "contextUsage": .object([
                "tokens": .number(Double(usedTokens)),
                "contextWindow": .number(Double(contextWindow)),
                "percent": .number(percent)
            ])
        ]
        if let id = stateFields.sessionId { object["sessionId"] = .string(id) }
        if let file = stateFields.sessionFile { object["sessionFile"] = .string(file) }
        return .object(object)
    }

    private func runLocalBash(_ command: String) async -> (output: String, exitCode: Int32) {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let result = await PiDiscoveryService().run(
            executable: URL(fileURLWithPath: shell),
            arguments: ["-lc", command],
            directory: URL(fileURLWithPath: projectPath),
            environment: environment
        )
        let combined = [result.stdout, result.stderr]
            .filter { !$0.isEmpty }
            .joined(separator: result.stdout.hasSuffix("\n") || result.stdout.isEmpty ? "" : "\n")
        return (combined, result.exitCode)
    }

    private static func extractToolOutput(from rawText: String) -> (output: String, isError: Bool) {
        if rawText.first == "{",
           let decoded = try? JSONCoding.decode(Data(rawText.utf8)),
           case .object(let dict) = decoded {
            let exitCode = dict["exit_code"]?.intValue
            let status = dict["terminal_status"]?.stringValue
            let isError = (exitCode != nil && exitCode != 0)
                || status == "failed"
                || status == "error"
                || dict["is_error"]?.boolValue == true
            if let output = dict["output"]?.stringValue {
                return (output, isError)
            }
        }
        return (rawText, false)
    }

    private static func normalizeModelID(_ raw: String?) -> String? {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        if let slash = raw.firstIndex(of: "/") {
            return String(raw[raw.index(after: slash)...])
        }
        return raw
    }

    static func extractSessionUUID(from sessionFile: String?) -> String? {
        guard let sessionFile, !sessionFile.isEmpty else { return nil }
        if !sessionFile.contains("/") && !sessionFile.hasSuffix(".jsonl") {
            return sessionFile
        }
        let url = URL(fileURLWithPath: sessionFile)
        if url.lastPathComponent == "session.jsonl" {
            let parent = url.deletingLastPathComponent().lastPathComponent
            return parent.isEmpty ? nil : parent
        }
        let name = url.deletingPathExtension().lastPathComponent
        if let lastPart = name.split(separator: "_").last {
            return String(lastPart)
        }
        return name
    }

    private static func findSessionFilePath(forSessionID sessionID: String) -> String? {
        let root = PiPaths.sessionsDirectory
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }
        for case let url as URL in enumerator {
            if url.lastPathComponent == "session.jsonl",
               url.deletingLastPathComponent().lastPathComponent == sessionID {
                return url.path
            }
        }
        return nil
    }

    private struct UserSettings {
        var model: String?
        var reasoningEffort: String?
        var modelEfforts: [String: String] = [:]
        var contributorModeEnabled: Bool = false
    }

    private static func readUserSettings() -> UserSettings {
        guard let data = try? Data(contentsOf: PiPaths.settingsFile),
              let json = try? JSONCoding.decode(data) else {
            return UserSettings()
        }
        var efforts: [String: String] = [:]
        if case .object(let dict)? = json["model_reasoning_efforts"] {
            for (k, v) in dict {
                if let str = v.stringValue { efforts[k] = str }
            }
        }
        return UserSettings(
            model: json.string("model"),
            reasoningEffort: json.string("reasoning_effort"),
            modelEfforts: efforts,
            contributorModeEnabled: json.bool("contributor_mode_enabled") ?? false
        )
    }

    private static func encodeTreeNode(_ node: PiTreeNode) -> JSONValue {
        var obj: [String: JSONValue] = [
            "entry": node.entry.raw,
            "children": .array(node.children.map { encodeTreeNode($0) })
        ]
        if let label = node.label { obj["label"] = .string(label) }
        return .object(obj)
    }
}
