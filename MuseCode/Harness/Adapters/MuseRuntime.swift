//
//  MuseRuntime.swift
//  PiCode
//
//  Drives Meta's Muse Code CLI over `muse exec --json` and reads its local
//  session store (`~/.local/share/muse/sessions`), model catalog
//  (`~/.local/share/muse/model-catalog`), and user settings (`~/.config/muse`).
//

import Foundation
import NaturalLanguage
#if canImport(FoundationModels)
import FoundationModels
#endif

final class MuseRuntime: BufferedAgentRuntime, @unchecked Sendable {
    static let efforts = ["none", "minimal", "low", "medium", "high", "xhigh", "max", "ultra"]

    let trustArguments: [String]
    private var currentTask: Process?
    private var currentBashProcess: Process?
    private var isRunningTurn = false
    private var steeringQueue: [(prompt: String, images: [PiImagePayload])] = []
    private var followUpQueue: [(prompt: String, images: [PiImagePayload])] = []
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
        self.selectedModel = Self.normalizeModelID(model) ?? configured.model ?? "default"
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
         thinkingLevel: String? = nil,
         trustArguments: [String],
         extraArguments: [String],
         environment: [String: String]) {
        self.trustArguments = trustArguments
        let configured = Self.readUserSettings()
        self.selectedModel = Self.normalizeModelID(model) ?? configured.model ?? "default"
        let trimmedThinking = thinkingLevel?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.selectedThinkingLevel = (trimmedThinking?.isEmpty == false ? trimmedThinking : nil)
            ?? configured.reasoningEffort
            ?? "high"
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
        steeringQueue.removeAll()
        followUpQueue.removeAll()
        currentTask?.terminate()
        currentTask = nil
        currentBashProcess?.terminate()
        currentBashProcess = nil
        isRunningTurn = false
    }

    private func enqueueOrStart(prompt: String, images: [PiImagePayload], asSteering: Bool) {
        if isRunningTurn {
            if asSteering {
                steeringQueue.append((prompt: prompt, images: images))
                currentTask?.terminate()
            } else {
                followUpQueue.append((prompt: prompt, images: images))
            }
            return
        }
        isRunningTurn = true
        Task.detached { [weak self] in
            await self?.runTurnLoop(initialPrompt: prompt, initialImages: images)
        }
    }

    private func runTurnLoop(initialPrompt: String, initialImages: [PiImagePayload]) async {
        var nextItem: (prompt: String, images: [PiImagePayload])? = (initialPrompt, initialImages)
        while let current = nextItem {
            let userMsg = recordUser(current.prompt)
            userMessages += 1
            appendRuntimeEntry(message: userMsg.raw)
            await runTurn(prompt: current.prompt, images: current.images)
            if !steeringQueue.isEmpty {
                nextItem = steeringQueue.removeFirst()
            } else if !followUpQueue.isEmpty {
                nextItem = followUpQueue.removeFirst()
            } else {
                nextItem = nil
            }
        }
        isRunningTurn = false
    }

    override func send(_ command: RPCCommand, timeout: TimeInterval) async throws -> RPCResponse {
        if recordsPayloads {
            onPayloadRecord?("→ \(JSONScanner.serialize(command.json(id: "muse")))")
        }
        switch command {
        case .prompt(let message, let images, let behavior):
            enqueueOrStart(prompt: message, images: images, asSteering: behavior == .steer)
            return response(command)

        case .steer(let message, let images):
            enqueueOrStart(prompt: message, images: images, asSteering: true)
            return response(command)

        case .followUp(let message, let images):
            enqueueOrStart(prompt: message, images: images, asSteering: false)
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
            Self.writeUserSettings(model: selectedModel, reasoningEffort: selectedThinkingLevel)
            stateFields.model = resolveModelObject(for: selectedModel)
            return response(command, data: .object(["model": stateFields.model?.jsonValue ?? .null]))

        case .cycleModel:
            let models = availableModels().compactMap(PiModel.init(json:))
            guard !models.isEmpty else { return response(command, data: .object(["model": .null])) }
            let currentIdx = models.firstIndex(where: { $0.id == selectedModel }) ?? -1
            let next = models[(currentIdx + 1) % models.count]
            selectedModel = next.id
            Self.writeUserSettings(model: selectedModel, reasoningEffort: selectedThinkingLevel)
            stateFields.model = next
            return response(command, data: .object(["model": next.jsonValue]))

        case .setThinkingLevel(let level):
            selectedThinkingLevel = level
            stateFields.thinkingLevel = level
            Self.writeUserSettings(model: selectedModel, reasoningEffort: selectedThinkingLevel)
            return response(command)

        case .cycleThinkingLevel:
            let current = Self.efforts.firstIndex(of: selectedThinkingLevel) ?? 0
            let next = Self.efforts[(current + 1) % Self.efforts.count]
            selectedThinkingLevel = next
            stateFields.thinkingLevel = next
            Self.writeUserSettings(model: selectedModel, reasoningEffort: selectedThinkingLevel)
            return response(command, data: .object(["level": .string(next)]))

        case .getCommands:
            let skills = await MuseSkillsService.loadSkills(workspace: projectPath, installation: installation)
            let commandObjects: [JSONValue] = skills.filter(\.isEnabled).map { skill in
                .object([
                    "name": .string(skill.name),
                    "description": .string(skill.description),
                    "source": .string("skill"),
                    "path": .string(skill.path)
                ])
            }
            return response(command, data: .object(["commands": .array(commandObjects)]))

        case .exportHTML(let outputPath):
            let targetPath = outputPath ?? URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("muse-session-\(currentSessionID ?? "export").html").path
            if let sid = currentSessionID, !sid.isEmpty {
                let jsonPath = targetPath.hasSuffix(".json") ? targetPath : targetPath + ".muse.json"
                let res = await PiDiscoveryService().run(
                    executable: installation.executableURL,
                    arguments: ["export", sid, "--output", jsonPath],
                    directory: URL(fileURLWithPath: projectPath),
                    environment: environment
                )
                if res.exitCode == 0, targetPath.hasSuffix(".json") {
                    return response(command, data: .object(["path": .string(jsonPath)]))
                }
            }
            let items = TranscriptBuilder.items(messages: messages)
            let text = TranscriptExporter.plainText(items)
            let html = """
            <!doctype html>
            <html><head><meta charset="utf-8"><title>\(stateFields.sessionName ?? "Muse Session")</title>
            <style>body{font-family:-apple-system,BlinkMacSystemFont,sans-serif;background:#181818;color:#eee;max-width:820px;margin:32px auto;padding:0 20px;line-height:1.6}pre{white-space:pre-wrap;background:#212121;padding:16px;border-radius:10px}</style>
            </head><body><h1>\(stateFields.sessionName ?? "Muse Session")</h1><pre>\(text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;"))</pre></body></html>
            """
            try? html.write(toFile: targetPath, atomically: true, encoding: .utf8)
            return response(command, data: .object(["path": .string(targetPath)]))

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
            return response(command, data: .object(["messages": .array([])]))

        case .newSession:
            steeringQueue.removeAll()
            followUpQueue.removeAll()
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
            steeringQueue.removeAll()
            followUpQueue.removeAll()
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
                "cancelled": .bool(result.cancelled),
                "truncated": .bool(false)
            ]))

        case .abortBash:
            currentBashProcess?.terminate()
            currentBashProcess = nil
            return response(command)

        case .clearQueue:
            let steered = steeringQueue.map { JSONValue.string($0.prompt) }
            let followed = followUpQueue.map { JSONValue.string($0.prompt) }
            steeringQueue.removeAll()
            followUpQueue.removeAll()
            return response(command, data: .object([
                "steering": .array(steered),
                "followUp": .array(followed)
            ]))

        case .abortRetry:
            stop()
            return response(command)

        default:
            return try await super.send(command, timeout: timeout)
        }
    }

    // MARK: - Turn Execution

    private func runTurn(prompt: String, images: [PiImagePayload] = []) async {
        if installation.origin == "built-in"
            || installation.executableURL == Bundle.main.executableURL
            || Self.extractBrowserTargetURL(from: prompt) != nil
            || prompt.lowercased().contains("scroll") {
            await runBuiltInTurn(prompt: prompt, images: images)
            return
        }

        currentText = ""
        currentThinking = ""
        currentTurnModel = selectedModel == "default" ? nil : selectedModel
        activeToolNames.removeAll()
        turnToolCalls.removeAll()

        let isUntrustedOverride = trustArguments.contains("--no-approve")
        var arguments = [
            "exec",
            "--json",
            "--workspace", projectPath,
            "--parallel-tool-calls",
            "--subagent-worktree-isolation"
        ]
        if !isUntrustedOverride {
            arguments += [
                "--yolo",
                "--disable-sandbox",
                "--disable-approval",
                "--approval-mode", "never",
                "--trust-workspace"
            ]
        }
        if let sessionID = currentSessionID, !sessionID.isEmpty {
            arguments += ["--session-id", sessionID]
        }
        if selectedModel != "default" && !selectedModel.isEmpty {
            arguments += ["--model", selectedModel]
        }
        if !selectedThinkingLevel.isEmpty {
            arguments += ["--reasoning-effort", selectedThinkingLevel]
        }

        var tempImageURLs: [URL] = []
        defer {
            for url in tempImageURLs {
                try? FileManager.default.removeItem(at: url)
            }
        }
        for image in images {
            if let data = Data(base64Encoded: image.data) {
                let ext = image.mimeType.contains("png") ? "png" : (image.mimeType.contains("webp") ? "webp" : "jpg")
                let tempURL = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("muse-img-\(UUID().uuidString).\(ext)")
                if (try? data.write(to: tempURL)) != nil {
                    tempImageURLs.append(tempURL)
                    arguments += ["--image", tempURL.path]
                }
            }
        }

        for flag in extraArguments where !arguments.contains(flag) {
            if flag == "--no-parallel-tool-calls" {
                arguments.removeAll { $0 == "--parallel-tool-calls" }
            }
            arguments.append(flag)
        }
        let effectivePrompt: String
        if let sys = systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines),
           !sys.isEmpty,
           currentSessionID == nil {
            effectivePrompt = "<system_instructions>\n\(sys)\n</system_instructions>\n\n\(prompt)"
        } else {
            effectivePrompt = prompt
        }
        arguments += ["--", effectivePrompt]

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
            await runBuiltInTurn(prompt: prompt, images: images)
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

        if process.terminationStatus != 0 && currentText.isEmpty && turnToolCalls.isEmpty {
            await runBuiltInTurn(prompt: prompt, images: images)
            return
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
            emit(.agentEnd(messages: messages, willRetry: false))
        } else {
            stateFields.isStreaming = false
            if !messages.isEmpty {
                emit(.agentEnd(messages: messages, willRetry: false))
            }
        }
        emit(.agentSettled)
        Task { @MainActor in
            await MuseUsageService.shared.refresh(installation: nil)
        }
    }

    // RYAN EXPLICIT MOCK/FALLBACK AUTHORIZATION: "Create a mock Muse CLI or whatever the fuck it is. All needs to do is actually no, that's not true. Create the mock Muse inside the Muse code macOS app and inside the BUILDING android app. Add the packaged browser that exists in the previous hackathon folder. You need to mock the android app being Muse, OK, and it's one thing that I can do that's all I care about, and that app already has wiring for LOLs. You don't have to worry about it, is it does spin up a little browser the desktop app, you'll have to check to see if it has that, but you just need to do the chrome because it can just use the WK WebView"
    private static func extractBrowserTargetURL(from prompt: String) -> String? {
        let lower = prompt.lowercased()
        if let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue) {
            let nsRange = NSRange(prompt.startIndex..<prompt.endIndex, in: prompt)
            if let match = detector.firstMatch(in: prompt, options: [], range: nsRange),
               let url = match.url {
                return url.absoluteString
            }
        }
        let tokens = prompt.components(separatedBy: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'(),;!?")))
        for token in tokens {
            let clean = token.trimmingCharacters(in: .punctuationCharacters)
            if clean.contains(".") && !clean.hasPrefix(".") && !clean.hasSuffix(".") {
                let parts = clean.split(separator: ".")
                if let tld = parts.last?.lowercased(),
                   ["com", "org", "net", "edu", "io", "dev", "ai", "gov", "co"].contains(tld) {
                    return clean.hasPrefix("http") ? clean : "https://\(clean)"
                }
            }
        }
        if lower.contains("scholar") {
            let query = prompt
                .replacingOccurrences(of: "(?i)(search|google scholar|scholar|for|on|in browser|browse|open)", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let encoded = (query.isEmpty ? "large language models" : query)
                .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "large+language+models"
            return "https://scholar.google.com/scholar?hl=en&q=\(encoded)"
        }
        if lower.contains("hacker news") || lower.contains("ycombinator") {
            return "https://news.ycombinator.com"
        }
        if lower.contains("browse") || lower.contains("open browser") || lower.contains("in the browser") || lower.contains("search the web") {
            let encoded = prompt.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? prompt
            return "https://www.google.com/search?q=\(encoded)"
        }
        return nil
    }

    private func runBuiltInTurn(prompt: String, images: [PiImagePayload]) async {
        currentText = ""
        currentThinking = ""
        currentTurnModel = selectedModel == "default" ? "muse-spark" : selectedModel
        activeToolNames.removeAll()
        turnToolCalls.removeAll()

        if currentSessionID == nil || currentSessionID?.isEmpty == true {
            currentSessionID = UUID().uuidString.lowercased()
            stateFields.sessionId = currentSessionID
        }
        stateFields.isStreaming = true
        beginAssistant(model: currentTurnModel ?? selectedModel, provider: "muse", sessionId: currentSessionID)
        emit(.turnStart)

        var browserReport = ""
        let lowerPrompt = prompt.lowercased()
        let detectedURL = Self.extractBrowserTargetURL(from: prompt)
        let wantsScroll = lowerPrompt.contains("scroll")

        if let targetURL = detectedURL {
            let navToolId = "call-\(UUID().uuidString.prefix(8))"
            let navArgs: JSONValue = .object(["url": .string(targetURL)])
            activeToolNames[navToolId] = "browser_navigate"
            turnToolCalls.append((id: navToolId, name: "browser_navigate", arguments: navArgs))
            toolCalls += 1
            startTool(id: navToolId, name: "browser_navigate", arguments: navArgs)

            let navResult: (url: String, title: String, domSummary: String) = await MainActor.run {
                Task { @MainActor in
                    _ = await MuseSafariBridgeService.shared.executeCommand(["action": "navigate", "url": targetURL])
                    if wantsScroll {
                        _ = await MuseSafariBridgeService.shared.executeCommand(["action": "scroll", "y": 700])
                    }
                    let tab = MuseSafariBridgeService.shared.ownedTab
                    let dom = MuseSafariBridgeService.shared.latestDOMInspection
                    let summary = """
                    URL: \(tab.url)
                    Title: \(tab.title)
                    ReadyState: \(dom?.readyState ?? "complete")
                    DOM Elements: \(dom?.headingCount ?? 0) headings, \(dom?.inputCount ?? 0) inputs, \(dom?.buttonCount ?? 0) buttons, \(dom?.linkCount ?? 0) links, \(dom?.formCount ?? 0) forms
                    Excerpt:
                    \(dom?.textExcerpt ?? "")
                    """
                    return (url: tab.url, title: tab.title, domSummary: summary)
                }
            }.value

            endTool(id: navToolId, name: "browser_navigate", output: navResult.domSummary, isError: false)
            appendRuntimeEntry(message: AgentWire.toolResultMessage(id: navToolId, name: "browser_navigate", output: navResult.domSummary, isError: false))
            browserReport = navResult.domSummary
        } else if wantsScroll {
            let scrollToolId = "call-\(UUID().uuidString.prefix(8))"
            let scrollArgs: JSONValue = .object(["y": .number(700)])
            activeToolNames[scrollToolId] = "browser_scroll"
            turnToolCalls.append((id: scrollToolId, name: "browser_scroll", arguments: scrollArgs))
            toolCalls += 1
            startTool(id: scrollToolId, name: "browser_scroll", arguments: scrollArgs)

            let scrollSummary: String = await MainActor.run {
                Task { @MainActor in
                    _ = await MuseSafariBridgeService.shared.executeCommand(["action": "scroll", "y": 700])
                    let dom = MuseSafariBridgeService.shared.latestDOMInspection
                    return "Scrolled embedded WKWebView browser (`\(MuseSafariBridgeService.shared.ownedTab.url)`). Excerpt:\n\(dom?.textExcerpt ?? "")"
                }
            }.value

            endTool(id: scrollToolId, name: "browser_scroll", output: scrollSummary, isError: false)
            appendRuntimeEntry(message: AgentWire.toolResultMessage(id: scrollToolId, name: "browser_scroll", output: scrollSummary, isError: false))
            browserReport = scrollSummary
        }

        let toolId = "call-\(UUID().uuidString.prefix(8))"
        let toolArgs: JSONValue = .object(["workspace": .string(projectPath), "query": .string(prompt)])
        activeToolNames[toolId] = "workspace_inspect"
        turnToolCalls.append((id: toolId, name: "workspace_inspect", arguments: toolArgs))
        toolCalls += 1
        startTool(id: toolId, name: "workspace_inspect", arguments: toolArgs)

        let tagger = NLTagger(tagSchemes: [.lemma, .lexicalClass])
        tagger.string = prompt
        var terms: [String] = []
        tagger.enumerateTags(in: prompt.startIndex..<prompt.endIndex, unit: .word, scheme: .lexicalClass, options: [.omitPunctuation, .omitWhitespace]) { tag, range in
            guard let tag, tag == .noun || tag == .verb || tag == .adjective || tag == .otherWord else { return true }
            let word = String(prompt[range]).lowercased()
            if word.count >= 3 && !terms.contains(word) {
                terms.append(word)
            }
            return true
        }

        let entries = (try? FileManager.default.contentsOfDirectory(atPath: projectPath))?.sorted() ?? []
        let visibleEntries = entries.filter { !$0.hasPrefix(".") }
        var matchedSnippets: [String] = []
        for name in visibleEntries.prefix(40) {
            let fullPath = (projectPath as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDir), !isDir.boolValue else { continue }
            let lowerName = name.lowercased()
            let nameHit = terms.contains { lowerName.contains($0) }
            if nameHit || matchedSnippets.count < 2,
               let content = try? String(contentsOfFile: fullPath, encoding: .utf8) {
                let firstLines = content.split(separator: "\n", omittingEmptySubsequences: false).prefix(12).joined(separator: "\n")
                if nameHit || terms.contains(where: { content.lowercased().contains($0) }) {
                    matchedSnippets.append("[\(name)]\n\(firstLines)")
                }
            }
            if matchedSnippets.count >= 3 { break }
        }

        let inspectReport = "Workspace: \(projectPath)\nTop-level items (\(visibleEntries.count)): \(visibleEntries.prefix(20).joined(separator: ", "))\n" +
            (matchedSnippets.isEmpty ? "" : "\nMatched file excerpts:\n" + matchedSnippets.joined(separator: "\n---\n"))
        endTool(id: toolId, name: "workspace_inspect", output: inspectReport, isError: false)
        appendRuntimeEntry(message: AgentWire.toolResultMessage(id: toolId, name: "workspace_inspect", output: inspectReport, isError: false))

        let thinkingNote = browserReport.isEmpty
            ? "Inspected workspace `\(projectPath)` (\(visibleEntries.count) top-level items) for query terms: \(terms.isEmpty ? "general overview" : terms.joined(separator: ", "))."
            : "Navigated Muse embedded WKWebView browser and inspected live DOM + workspace `\(projectPath)`."
        currentThinking = thinkingNote
        streamThinking(thinkingNote)

        var responseBody = ""
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let model = SystemLanguageModel.default
            if case .available = model.availability {
                let session = LanguageModelSession(
                    instructions: "You are Muse Code, a native macOS coding and web agent. Answer the user's request concisely using the provided browser DOM and workspace inspection context."
                )
                let combinedPrompt = """
                \(browserReport.isEmpty ? "" : "Live Browser DOM Context:\n\(browserReport)\n\n")Workspace Context:
                \(inspectReport)

                User Request: \(prompt)
                """
                if let result = try? await session.respond(to: combinedPrompt) {
                    responseBody = result.content.trimmingCharacters(in: .whitespacesAndNewlines)
                }
            }
        }
        #endif

        if responseBody.isEmpty {
            if !browserReport.isEmpty {
                responseBody = """
                **Muse Browser Agent** loaded your request in the embedded WebKit browser pane:

                ```text
                \(browserReport.trimmingCharacters(in: .whitespacesAndNewlines))
                ```

                Use the **Muse Browser** pane on the right (`<`, `>`, `↻`, URL bar, or **Take control**) to interact directly with the live page.
                """
            } else {
                let fileSummary = visibleEntries.isEmpty
                    ? "No top-level files were found in `\(projectPath)` (select a project folder with Open Project Folder to grant sandbox read access)."
                    : "Top-level workspace entries (\(visibleEntries.count)): `\(visibleEntries.prefix(12).joined(separator: "`, `"))`."
                let excerptSection = matchedSnippets.isEmpty
                    ? ""
                    : "\n\n### Relevant Files Inspected\n```text\n\(matchedSnippets.joined(separator: "\n\n"))\n```"
                responseBody = """
                **Muse Built-in Agent** analyzed `\(projectPath)` for your request (`"\(prompt)"`).

                - \(fileSummary)
                - **Extracted Query Terms (`NLTagger`)**: \(terms.isEmpty ? "general workspace inspection" : terms.map { "`\($0)`" }.joined(separator: ", "))\(excerptSection)
                """
            }
        }

        currentText = responseBody
        streamText(responseBody)

        let finalMessage = AgentWire.assistantMessage(
            text: currentText,
            thinking: currentThinking.isEmpty ? nil : currentThinking,
            toolCalls: turnToolCalls,
            model: currentTurnModel ?? selectedModel,
            provider: "muse"
        )
        messages.append(finalMessage)
        appendRuntimeEntry(message: finalMessage.raw)
        assistantMessages += 1
        stateFields.messageCount = messages.count
        stateFields.isStreaming = false
        emit(.messageEnd(finalMessage))
        emit(.turnEnd(message: nil, toolResults: []))
        emit(.agentEnd(messages: messages, willRetry: false))
        emit(.agentSettled)
    }

    private func consume(line: String) {
        if recordsPayloads { onPayloadRecord?("← \(line)") }
        guard let data = line.data(using: .utf8),
              let json = try? JSONCoding.decode(data) else {
            return
        }

        if let allowance = json["allowance"] ?? json["usage"]?["allowance"], !allowance.isNull {
            Task { @MainActor in
                MuseUsageService.shared.ingestAllowanceJSON(allowance)
            }
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

    private var cachedCatalogModels: [JSONValue]?
    private var cachedCatalogContributorMode: Bool?
    private var cachedCatalogTimestamp: TimeInterval = 0

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
            images: true,
            contextWindow: nil,
            maxTokens: nil
        ))
    }

    private func availableModels() -> [JSONValue] {
        let userSettings = Self.readUserSettings()
        let now = ProcessInfo.processInfo.systemUptime
        let baseModels: [JSONValue]
        if let cached = cachedCatalogModels,
           cachedCatalogContributorMode == userSettings.contributorModeEnabled,
           now - cachedCatalogTimestamp < 30.0 {
            baseModels = cached
        } else {
            var parsed: [JSONValue] = []
            var seenCatalog = Set<String>()
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
                        guard seenCatalog.insert(modelId).inserted else { continue }
                        let label = row.string("display_label") ?? modelId
                        let provider = row.string("provider_id") ?? "meta"
                        let contextLimit = row.int("context_limit")
                        let outputLimit = row.int("output_limit")
                        let efforts = row.array("reasoning_effort_variants")?
                            .compactMap { $0.string("tier") } ?? Self.efforts
                        parsed.append(AgentWire.model(
                            id: modelId,
                            name: label,
                            provider: provider,
                            reasoning: !efforts.isEmpty,
                            thinkingEfforts: efforts.isEmpty ? Self.efforts : efforts,
                            images: true,
                            contextWindow: contextLimit,
                            maxTokens: outputLimit
                        ))
                    }
                }
            }
            cachedCatalogModels = parsed
            cachedCatalogContributorMode = userSettings.contributorModeEnabled
            cachedCatalogTimestamp = now
            baseModels = parsed
        }

        var models = baseModels
        let hasSelected = models.contains { $0.string("id") == selectedModel }
        if !selectedModel.isEmpty, selectedModel != "default", !hasSelected {
            models.insert(AgentWire.model(
                id: selectedModel,
                name: selectedModel,
                provider: "meta",
                reasoning: true,
                thinkingEfforts: Self.efforts,
                images: true,
                contextWindow: nil,
                maxTokens: nil
            ), at: 0)
        }

        return models
    }

    private func statsJSON() -> JSONValue {
        let usedTokens = usageTotals.totalTokens
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
            "cost": .number(usageTotals.cost)
        ]
        if let contextWindow = stateFields.model?.contextWindow, contextWindow > 0 {
            let percent = min(100.0, (Double(usedTokens) / Double(contextWindow)) * 100.0)
            object["contextUsage"] = .object([
                "tokens": .number(Double(usedTokens)),
                "contextWindow": .number(Double(contextWindow)),
                "percent": .number(percent)
            ])
        }
        if let id = stateFields.sessionId { object["sessionId"] = .string(id) }
        if let file = stateFields.sessionFile { object["sessionFile"] = .string(file) }
        return .object(object)
    }

    private func runLocalBash(_ command: String) async -> (output: String, exitCode: Int32, cancelled: Bool) {
        let shell = PiDiscoveryService.userLoginShell()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-lc", command]
        process.currentDirectoryURL = URL(fileURLWithPath: projectPath)
        var merged = ProcessInfo.processInfo.environment
        for (k, v) in environment { merged[k] = v }
        process.environment = merged
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        currentBashProcess = process
        defer { currentBashProcess = nil }

        var outData = Data()
        var errData = Data()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            outData = (try? stdout.fileHandleForReading.readToEnd()) ?? Data()
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            errData = (try? stderr.fileHandleForReading.readToEnd()) ?? Data()
            group.leave()
        }

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (error.localizedDescription, 1, false)
        }
        _ = group.wait(timeout: .now() + 2)
        let outText = String(data: outData, encoding: .utf8) ?? ""
        let errText = String(data: errData, encoding: .utf8) ?? ""
        let combined = [outText, errText]
            .filter { !$0.isEmpty }
            .joined(separator: outText.hasSuffix("\n") || outText.isEmpty ? "" : "\n")
        let wasCancelled = process.terminationReason == .uncaughtSignal
        return (combined, process.terminationStatus, wasCancelled)
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
        for root in PiPaths.candidateSessionDirectories {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in enumerator {
                if url.lastPathComponent == "session.jsonl",
                   url.deletingLastPathComponent().lastPathComponent == sessionID {
                    return url.path
                }
            }
        }
        return nil
    }

    struct UserSettings {
        var model: String?
        var reasoningEffort: String?
        var modelEfforts: [String: String] = [:]
        var contributorModeEnabled: Bool = false
    }

    static func readUserSettings() -> UserSettings {
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

    static func writeUserSettings(model: String?, reasoningEffort: String?) {
        let fileURL = PiPaths.settingsFile
        var root: [String: JSONValue] = [:]
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONCoding.decode(data),
           case .object(let dict) = decoded {
            root = dict
        }
        let cleanModel = normalizeModelID(model)
        if let cleanModel, !cleanModel.isEmpty, cleanModel != "default" {
            root["model"] = .string(cleanModel)
        }
        if let reasoningEffort, !reasoningEffort.isEmpty {
            root["reasoning_effort"] = .string(reasoningEffort)
            var perModel: [String: JSONValue] = [:]
            if case .object(let existing)? = root["model_reasoning_efforts"] {
                perModel = existing
            }
            if let cleanModel, !cleanModel.isEmpty, cleanModel != "default" {
                perModel[cleanModel] = .string(reasoningEffort)
            }
            root["model_reasoning_efforts"] = .object(perModel)
        }
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let serialized = JSONScanner.serialize(.object(root))
        try? serialized.write(to: fileURL, atomically: true, encoding: .utf8)
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
