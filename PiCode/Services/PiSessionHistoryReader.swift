import Foundation

// MARK: - Muse Overview & Agent Message Models

struct MuseSubagentInfo: Identifiable, Equatable, Sendable {
    enum Status: String, Equatable, Sendable {
        case running
        case waiting
        case completed
        case failed
    }

    var id: String
    var childSessionId: String?
    var commandId: String?
    var role: String
    var title: String
    var objective: String
    var status: Status
    var summary: String?
    var sessionFilePath: String?
    var updatedAt: Date?
    var totalTokens: Int = 0
}

struct MuseBackgroundTaskInfo: Identifiable, Equatable, Sendable {
    enum Status: String, Equatable, Sendable {
        case running
        case completed
        case failed
    }

    var id: String
    var kind: String
    var title: String
    var detail: String?
    var status: Status
    var outputPreview: String?
    var toolCallId: String?
    var timestamp: Date?
}

struct MuseArtifactInfo: Identifiable, Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case file
        case edit
        case plan
        case document
    }

    var id: String
    var kind: Kind
    var title: String
    var path: String?
    var preview: String?
    var toolCallId: String?
    var timestamp: Date?
}

struct MuseAgentMessageInfo: Identifiable, Equatable, Sendable {
    enum Direction: String, Equatable, Sendable {
        case incoming
        case outgoing
        case subagent
        case subagentResult
    }

    var id: String
    var direction: Direction
    var sender: String
    var target: String
    var workspaceLabel: String?
    var body: String
    var timestamp: Date?
    var deliveryPolicy: String?
}

/// Reads a session file (Muse `session.jsonl` or legacy JSONL) without modifying
/// it. Converts Muse's event log into canonical `PiSessionEntry` objects so the
/// transcript, session tree, fork points, overview panel, and replay tools work seamlessly.
struct PiSessionHistoryReader: Sendable {
    func entries(at path: String) async -> [JSONValue] {
        await Task.detached(priority: .userInitiated) {
            MuseSessionHistory.entryJSONValues(at: path)
        }.value
    }

    func summary(at path: String) async -> MuseSessionHistory.Summary {
        await Task.detached(priority: .userInitiated) {
            MuseSessionHistory.loadSummary(at: path)
        }.value
    }
}

enum MuseSessionHistory {
    struct Summary: Sendable {
        var sessionId: String?
        var sessionName: String?
        var cwd: String?
        var modelId: String?
        var providerId: String?
        var createdAt: Date?
        var updatedAt: Date?
        var firstUserMessage: String?
        var messageCount: Int = 0
        var entries: [JSONValue] = []
        var messages: [PiMessage] = []
        var usage: PiUsage = PiUsage.zero
        var subagents: [MuseSubagentInfo] = []
        var backgroundTasks: [MuseBackgroundTaskInfo] = []
        var artifacts: [MuseArtifactInfo] = []
        var agentMessages: [MuseAgentMessageInfo] = []

        var leafID: String? { entries.last?.string("id") }
        var parsedEntries: [PiSessionEntry] { entries.map(PiSessionEntry.init(json:)) }
    }

    static func loadSummary(at url: URL) -> Summary {
        loadSummary(at: url.path)
    }

    static func entryJSONValues(at path: String) -> [JSONValue] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) else {
            return []
        }
        return entryJSONValues(from: data)
    }

    static func entryJSONValues(from data: Data) -> [JSONValue] {
        let rawLines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        guard let firstLine = rawLines.first,
              let firstJSON = try? JSONCoding.decode(Data(firstLine)) else {
            return []
        }
        if firstJSON.string("payload_type") != nil || firstJSON.string("retained_frame") != nil || firstJSON.string("retained_marker") != nil {
            return parseSummary(from: rawLines).entries
        }
        return rawLines
            .compactMap { try? JSONCoding.decode(Data($0)) }
            .filter { $0.string("type") != "session" }
    }

    static func loadSummary(at path: String) -> Summary {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe) else {
            return Summary()
        }
        let rawLines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        var summary = parseSummary(from: rawLines, sessionFilePath: path)
        discoverChildSubagentSessions(for: path, into: &summary)
        return summary
    }

    static func parseSummary(from rawLines: [Data.SubSequence], sessionFilePath: String? = nil) -> Summary {
        var summary = Summary()
        var currentModel = "muse-wonder-full-1.0"
        var currentProvider = "meta"
        var lastEntryId: String?
        var entryCounter = 0
        var toolNamesByCallId: [String: String] = [:]
        var subagentsById: [String: MuseSubagentInfo] = [:]
        var subagentOrder: [String] = []
        var tasksById: [String: MuseBackgroundTaskInfo] = [:]
        var taskOrder: [String] = []
        var artifactsByKey: [String: MuseArtifactInfo] = [:]
        var artifactOrder: [String] = []

        func nextEntryId(_ base: String?) -> String {
            entryCounter += 1
            if let base, !base.isEmpty {
                return "\(base)-\(entryCounter)"
            }
            return "muse-entry-\(entryCounter)"
        }

        func upsertSubagent(_ id: String, update: (inout MuseSubagentInfo) -> Void) {
            guard !id.isEmpty else { return }
            if subagentsById[id] == nil {
                subagentOrder.append(id)
                subagentsById[id] = MuseSubagentInfo(
                    id: id,
                    childSessionId: nil,
                    commandId: nil,
                    role: "subagent",
                    title: id,
                    objective: "",
                    status: .running,
                    summary: nil,
                    sessionFilePath: nil,
                    updatedAt: summary.updatedAt
                )
            }
            if var info = subagentsById[id] {
                update(&info)
                subagentsById[id] = info
            }
        }

        func upsertTask(_ id: String, defaultKind: String = "task", defaultTitle: String = "Background task", update: (inout MuseBackgroundTaskInfo) -> Void) {
            guard !id.isEmpty else { return }
            if tasksById[id] == nil {
                taskOrder.append(id)
                tasksById[id] = MuseBackgroundTaskInfo(
                    id: id,
                    kind: defaultKind,
                    title: defaultTitle,
                    detail: nil,
                    status: .running,
                    outputPreview: nil,
                    toolCallId: nil,
                    timestamp: summary.updatedAt
                )
            }
            if var info = tasksById[id] {
                update(&info)
                tasksById[id] = info
            }
        }

        func upsertArtifact(_ key: String, makeDefault: () -> MuseArtifactInfo, update: (inout MuseArtifactInfo) -> Void) {
            guard !key.isEmpty else { return }
            if artifactsByKey[key] == nil {
                artifactOrder.append(key)
                artifactsByKey[key] = makeDefault()
            }
            if var info = artifactsByKey[key] {
                update(&info)
                artifactsByKey[key] = info
            }
        }

        func appendEntry(id: String, timestampUs: Int64?, messageObject: [String: JSONValue]) {
            let ms: Double
            let isoTimestamp: String
            if let us = timestampUs, us > 0 {
                let seconds = Double(us) / 1_000_000.0
                ms = Double(us) / 1_000.0
                isoTimestamp = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: seconds))
            } else {
                ms = Date().timeIntervalSince1970 * 1000.0
                isoTimestamp = ISO8601DateFormatter().string(from: Date())
            }

            var msg = messageObject
            if msg["timestamp"] == nil {
                msg["timestamp"] = .number(ms)
            }
            let messageValue = JSONValue.object(msg)
            var entryObj: [String: JSONValue] = [
                "id": .string(id),
                "type": .string("message"),
                "timestamp": .string(isoTimestamp),
                "message": messageValue
            ]
            if let parent = lastEntryId {
                entryObj["parentId"] = .string(parent)
            }
            lastEntryId = id
            summary.entries.append(.object(entryObj))
            summary.messages.append(PiMessage(raw: messageValue))
        }

        func processRecord(_ record: JSONValue) {
            if let streamId = record.object("stream")?.string("id"), summary.sessionId == nil {
                summary.sessionId = streamId
            }
            let recordedUs = record.int("recorded_at").map(Int64.init)
                ?? (record["recorded_at"]?.doubleValue.map { Int64($0) })
            var recordDate: Date?
            if let us = recordedUs, us > 0 {
                let date = Date(timeIntervalSince1970: Double(us) / 1_000_000.0)
                recordDate = date
                if summary.createdAt == nil { summary.createdAt = date }
                summary.updatedAt = date
            }

            guard let payloadType = record.string("payload_type"),
                  let payload = record["payload"] else { return }

            switch payloadType {
            case "runtime.session.metadata":
                if let rec = payload["record"] {
                    if let ws = rec.string("workspace_root"), !ws.isEmpty {
                        summary.cwd = ws
                    }
                    if let sid = rec.string("session_id"), !sid.isEmpty {
                        summary.sessionId = sid
                    }
                    if let mid = rec.string("model_id"), !mid.isEmpty {
                        currentModel = mid
                        summary.modelId = mid
                    }
                    if let pid = rec.string("provider_id"), !pid.isEmpty {
                        currentProvider = pid
                        summary.providerId = pid
                    }
                }

            case "runtime.session.route_facts":
                if let rec = payload["record"] {
                    if summary.cwd == nil, let cwd = rec.string("cwd"), !cwd.isEmpty {
                        summary.cwd = cwd
                    }
                    if summary.sessionId == nil, let sid = rec.string("session_id"), !sid.isEmpty {
                        summary.sessionId = sid
                    }
                }

            case "session.name.changed":
                if let newName = payload.string("new_name")?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !newName.isEmpty {
                    summary.sessionName = newName
                }

            case "run.model.configured", "runtime.model_reconfigure.completed":
                let rec = payload["record"] ?? payload
                if let mid = rec.string("model_id"), !mid.isEmpty {
                    currentModel = mid
                    summary.modelId = mid
                }

            case "subagent.control.spawn_accepted",
                 "subagent.control.resume_context_recorded",
                 "subagent.control.child_session_bound",
                 "subagent.control.status_updated",
                 "subagent.control.result_ready",
                 "subagent.control.runtime_observed",
                 "subagent.control.wait_parked":
                let rec = payload["record"] ?? payload
                guard let subId = rec.string("subagent_id"), !subId.isEmpty else { break }
                upsertSubagent(subId) { info in
                    if let date = recordDate { info.updatedAt = date }
                    if let cmdId = rec.string("command_id") ?? rec.string("spawn_command_id"), !cmdId.isEmpty {
                        info.commandId = cmdId
                        if info.title == subId { info.title = cmdId }
                    }
                    if let role = rec.string("role") ?? rec.string("agent_path")?.split(separator: "/").last.map(String.init),
                       !role.isEmpty {
                        info.role = role
                    }
                    if let objective = rec.string("objective"), !objective.isEmpty {
                        info.objective = objective
                        info.title = objective.oneLinePreview(limit: 80)
                    }
                    if let childSid = rec.string("child_session_id") ?? rec.string("subagent_session_id"), !childSid.isEmpty {
                        info.childSessionId = childSid
                    }
                    if let status = rec.string("control_status") {
                        switch status {
                        case "running", "starting": info.status = .running
                        case "waiting", "parked": info.status = .waiting
                        case "completed", "succeeded", "ready": info.status = .completed
                        case "failed", "error", "cancelled": info.status = .failed
                        default: break
                        }
                    }
                    if payloadType == "subagent.control.wait_parked" {
                        info.status = .waiting
                    } else if payloadType == "subagent.control.result_ready" {
                        info.status = rec.string("error_kind") != nil ? .failed : .completed
                        if let text = rec.string("summary") ?? rec.string("text"), !text.isEmpty {
                            info.summary = text
                            summary.agentMessages.append(MuseAgentMessageInfo(
                                id: "subagent-res-\(subId)-\(summary.agentMessages.count)",
                                direction: .subagentResult,
                                sender: info.commandId ?? info.role,
                                target: "main",
                                workspaceLabel: nil,
                                body: text.oneLinePreview(limit: 260),
                                timestamp: recordDate,
                                deliveryPolicy: "result_ready"
                            ))
                        }
                        if let refs = rec.array("evidence_refs")?.compactMap(\.stringValue),
                           let firstRef = refs.first {
                            info.sessionFilePath = firstRef
                        }
                    }
                    if let usage = rec["usage"] {
                        let input = usage.int("input_tokens") ?? 0
                        let output = usage.int("output_tokens") ?? 0
                        info.totalTokens = max(info.totalTokens, input + output)
                    }
                }

            case "peer_message.admission.requested":
                let msgId = payload.string("message_id") ?? payload.string("request_id") ?? UUID().uuidString
                let hints = payload["display_hints"]
                let senderName = hints?.string("sender_session_name")
                    ?? hints?.string("sender_session_id")
                    ?? "peer-agent"
                let wsLabel = hints?.string("workspace_label")
                let body = payload.string("body") ?? ""
                let policy = payload.string("delivery_policy")
                if !body.isEmpty {
                    summary.agentMessages.append(MuseAgentMessageInfo(
                        id: msgId,
                        direction: .incoming,
                        sender: senderName,
                        target: summary.sessionName ?? summary.sessionId ?? "this session",
                        workspaceLabel: wsLabel,
                        body: body,
                        timestamp: recordDate,
                        deliveryPolicy: policy
                    ))
                }

            case "runtime.session.task":
                let taskId = payload.string("task_id") ?? ""
                guard !taskId.isEmpty, let ev = payload["event"], let kind = ev.string("kind") else { break }
                let taskKind = ev.string("task_kind") ?? "task"
                if taskKind == "session_name.allocate" { break }
                upsertTask(taskId, defaultKind: taskKind, defaultTitle: taskKind) { task in
                    if let date = recordDate { task.timestamp = date }
                    switch kind {
                    case "proposed", "accepted", "scheduled", "started":
                        task.status = .running
                    case "completed":
                        task.status = .completed
                    case "failed", "cancelled":
                        task.status = .failed
                    default:
                        break
                    }
                }

            case "runtime.session":
                let sessionKind = payload.string("kind")
                if sessionKind == "task",
                   let taskId = payload.string("task_id"),
                   let ev = payload["event"],
                   let kind = ev.string("kind") {
                    let taskKind = ev.string("task_kind") ?? "task"
                    if taskKind != "session_name.allocate" {
                        upsertTask(taskId, defaultKind: taskKind, defaultTitle: taskKind) { task in
                            if let date = recordDate { task.timestamp = date }
                            if kind == "completed" { task.status = .completed }
                            else if kind == "failed" || kind == "cancelled" { task.status = .failed }
                        }
                    }
                    return
                }

                guard sessionKind == "run",
                      let event = payload["event"],
                      let eventKind = event.string("kind") else { return }
                let recId = record.string("id")

                switch eventKind {
                case "started":
                    guard let prompt = event.string("prompt")?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !prompt.isEmpty else { return }
                    summary.messageCount += 1
                    if summary.firstUserMessage == nil {
                        summary.firstUserMessage = prompt.oneLinePreview(limit: 160)
                    }
                    appendEntry(
                        id: nextEntryId(recId),
                        timestampUs: recordedUs,
                        messageObject: [
                            "role": .string("user"),
                            "content": .string(prompt)
                        ]
                    )

                case "reasoning_summary_committed", "reasoning_committed":
                    guard let text = event.string("text")?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !text.isEmpty else { return }
                    appendEntry(
                        id: nextEntryId(event.string("message_id") ?? recId),
                        timestampUs: recordedUs,
                        messageObject: [
                            "role": .string("assistant"),
                            "model": .string(currentModel),
                            "provider": .string(currentProvider),
                            "content": .array([
                                .object([
                                    "type": .string("thinking"),
                                    "thinking": .string(text)
                                ])
                            ])
                        ]
                    )

                case "assistant_message_committed":
                    guard let text = event.string("text")?.trimmingCharacters(in: .whitespacesAndNewlines),
                          !text.isEmpty else { return }
                    summary.messageCount += 1
                    appendEntry(
                        id: nextEntryId(event.string("message_id") ?? recId),
                        timestampUs: recordedUs,
                        messageObject: [
                            "role": .string("assistant"),
                            "model": .string(currentModel),
                            "provider": .string(currentProvider),
                            "content": .array([
                                .object([
                                    "type": .string("text"),
                                    "text": .string(text)
                                ])
                            ])
                        ]
                    )

                case "assistant_tool_calls_committed":
                    guard let calls = event.array("tool_calls"), !calls.isEmpty else { return }
                    var blocks: [JSONValue] = []
                    for call in calls {
                        let callId = call.string("call_id") ?? call.string("id") ?? UUID().uuidString
                        let name = call.string("name") ?? "tool"
                        toolNamesByCallId[callId] = name
                        let argsValue: JSONValue
                        if let argsString = call.string("args"),
                           let decoded = try? JSONCoding.decode(Data(argsString.utf8)) {
                            argsValue = decoded
                        } else if let argsObj = call["args"], !argsObj.isNull {
                            argsValue = argsObj
                        } else {
                            argsValue = .object([:])
                        }
                        blocks.append(.object([
                            "type": .string("toolCall"),
                            "id": .string(callId),
                            "name": .string(name),
                            "arguments": argsValue
                        ]))

                        // Extract Subagents, Background Tasks, Artifacts, and Agent Messages from tool calls:
                        switch name {
                        case "subagent_spawn":
                            let cmdId = argsValue.string("command_id") ?? callId
                            let objective = argsValue.string("objective") ?? argsValue.string("prompt") ?? cmdId
                            let role = argsValue.string("role") ?? "subagent"
                            upsertSubagent(cmdId) { info in
                                info.commandId = cmdId
                                info.role = role
                                info.objective = objective
                                info.title = objective.oneLinePreview(limit: 80)
                                info.updatedAt = recordDate
                            }

                        case "subagent_send_message":
                            let target = argsValue.string("subagent_id") ?? argsValue.string("command_id") ?? "subagent"
                            let msgText = argsValue.string("message") ?? ""
                            if !msgText.isEmpty {
                                summary.agentMessages.append(MuseAgentMessageInfo(
                                    id: callId,
                                    direction: .subagent,
                                    sender: "main",
                                    target: target,
                                    workspaceLabel: nil,
                                    body: msgText,
                                    timestamp: recordDate,
                                    deliveryPolicy: argsValue.string("mode")
                                ))
                            }

                        case "send_session_message":
                            let target = argsValue.string("target") ?? "peer"
                            let body = argsValue.string("body") ?? ""
                            if !body.isEmpty {
                                summary.agentMessages.append(MuseAgentMessageInfo(
                                    id: callId,
                                    direction: .outgoing,
                                    sender: summary.sessionName ?? "this session",
                                    target: target,
                                    workspaceLabel: nil,
                                    body: body,
                                    timestamp: recordDate,
                                    deliveryPolicy: argsValue.string("message_intent")
                                ))
                            }

                        case "bash", "monitor", "cron_create", "work_list", "work_status", "workflow":
                            let cmd = argsValue.string("description")
                                ?? argsValue.string("command")
                                ?? name
                            upsertTask(callId, defaultKind: name, defaultTitle: cmd.oneLinePreview(limit: 72)) { task in
                                task.kind = name
                                task.title = cmd.oneLinePreview(limit: 72)
                                task.detail = argsValue.string("command")
                                task.toolCallId = callId
                                task.timestamp = recordDate
                            }

                        case "write_file", "edit_file":
                            if let filePath = argsValue.string("path"), !filePath.isEmpty {
                                let fileName = (filePath as NSString).lastPathComponent
                                upsertArtifact(filePath, makeDefault: {
                                    MuseArtifactInfo(
                                        id: filePath,
                                        kind: name == "write_file" ? .file : .edit,
                                        title: fileName.isEmpty ? filePath : fileName,
                                        path: filePath,
                                        preview: filePath,
                                        toolCallId: callId,
                                        timestamp: recordDate
                                    )
                                }, update: { art in
                                    art.toolCallId = callId
                                    art.timestamp = recordDate
                                })
                            }

                        case "write_todos", "update_goal":
                            let title = name == "write_todos" ? "Task Plan & Todos" : "Session Goal"
                            let preview: String
                            if let todos = argsValue.array("todos") {
                                preview = todos.compactMap { $0.string("text") }.joined(separator: " • ")
                            } else {
                                preview = argsValue.string("goal") ?? title
                            }
                            upsertArtifact(name, makeDefault: {
                                MuseArtifactInfo(
                                    id: name,
                                    kind: .plan,
                                    title: title,
                                    path: nil,
                                    preview: preview.oneLinePreview(limit: 120),
                                    toolCallId: callId,
                                    timestamp: recordDate
                                )
                            }, update: { art in
                                art.preview = preview.oneLinePreview(limit: 120)
                                art.toolCallId = callId
                                art.timestamp = recordDate
                            })

                        default:
                            break
                        }
                    }
                    guard !blocks.isEmpty else { return }
                    appendEntry(
                        id: nextEntryId(event.string("message_id") ?? recId),
                        timestampUs: recordedUs,
                        messageObject: [
                            "role": .string("assistant"),
                            "model": .string(currentModel),
                            "provider": .string(currentProvider),
                            "content": .array(blocks)
                        ]
                    )

                case "tool_result_batch_committed":
                    guard let results = event.array("results"), !results.isEmpty else { return }
                    for result in results {
                        guard let callId = result.string("tool_call_id") else { continue }
                        let rawText = result.string("text") ?? ""
                        let (output, isError) = extractToolResult(from: rawText)
                        let toolName = toolNamesByCallId[callId] ?? "tool"
                        if tasksById[callId] != nil {
                            upsertTask(callId) { task in
                                task.status = isError ? .failed : .completed
                                task.outputPreview = output.oneLinePreview(limit: 120)
                            }
                        }
                        appendEntry(
                            id: nextEntryId("\(recId ?? "res")-\(callId)"),
                            timestampUs: recordedUs,
                            messageObject: [
                                "role": .string("toolResult"),
                                "toolCallId": .string(callId),
                                "toolName": .string(toolName),
                                "isError": .bool(isError),
                                "content": .array([
                                    .object([
                                        "type": .string("text"),
                                        "text": .string(output)
                                    ])
                                ])
                            ]
                        )
                    }

                case "model_completed":
                    if let model = event.string("model"), !model.isEmpty {
                        currentModel = model
                        summary.modelId = model
                    }
                    if let usage = event["usage"] {
                        let input = usage.int("input_tokens") ?? 0
                        let output = usage.int("output_tokens") ?? 0
                        let cacheRead = usage.int("cache_read_tokens") ?? usage.int("cached_tokens") ?? 0
                        let cacheWrite = usage.int("cache_write_tokens") ?? 0
                        summary.usage.input += input
                        summary.usage.output += output
                        summary.usage.cacheRead += cacheRead
                        summary.usage.cacheWrite += cacheWrite
                        summary.usage.totalTokens += input + output
                    }

                default:
                    break
                }

            default:
                break
            }
        }

        for line in rawLines {
            guard let record = try? JSONCoding.decode(Data(line)) else { continue }
            if let children = record.array("children") {
                for child in children {
                    if let recordJSON = child.string("record_json"),
                       let nested = try? JSONCoding.decode(Data(recordJSON.utf8)) {
                        processRecord(nested)
                    }
                }
            } else {
                processRecord(record)
            }
        }

        summary.subagents = subagentOrder.compactMap { subagentsById[$0] }
        summary.backgroundTasks = taskOrder.compactMap { tasksById[$0] }
        summary.artifacts = artifactOrder.compactMap { artifactsByKey[$0] }
        return summary
    }

    private static func discoverChildSubagentSessions(for sessionFilePath: String, into summary: inout Summary) {
        let sessionURL = URL(fileURLWithPath: sessionFilePath)
        let subagentDir = sessionURL.deletingLastPathComponent().appendingPathComponent("subagent", isDirectory: true)
        guard let childDirs = try? FileManager.default.contentsOfDirectory(
            at: subagentDir,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var existingChildIds = Set(summary.subagents.compactMap(\.childSessionId) + summary.subagents.map(\.id))
        for dir in childDirs {
            let childId = dir.lastPathComponent
            let childSessionFile = dir.appendingPathComponent("session.jsonl")
            guard FileManager.default.fileExists(atPath: childSessionFile.path) else { continue }

            if let idx = summary.subagents.firstIndex(where: { $0.childSessionId == childId || $0.id == childId }) {
                if summary.subagents[idx].sessionFilePath == nil {
                    summary.subagents[idx].sessionFilePath = childSessionFile.path
                }
                continue
            }

            guard existingChildIds.insert(childId).inserted else { continue }
            guard let data = try? Data(contentsOf: childSessionFile, options: .mappedIfSafe) else { continue }
            let lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
            let childSummary = parseSummary(from: lines, sessionFilePath: childSessionFile.path)
            let promptTitle = childSummary.firstUserMessage ?? "Subagent \(childId.prefix(8))"
            let lastAssistant = childSummary.messages.last(where: \.isAssistant)?.textContent
            let isReminder = promptTitle.lowercased().contains("reminder observer")
            summary.subagents.append(MuseSubagentInfo(
                id: childId,
                childSessionId: childId,
                commandId: nil,
                role: isReminder ? "reminder" : "subagent",
                title: isReminder ? "Goal & Verification Observer" : promptTitle.oneLinePreview(limit: 72),
                objective: promptTitle,
                status: .completed,
                summary: lastAssistant?.oneLinePreview(limit: 200),
                sessionFilePath: childSessionFile.path,
                updatedAt: childSummary.updatedAt,
                totalTokens: childSummary.usage.totalTokens
            ))
        }
    }

    private static func extractToolResult(from rawText: String) -> (output: String, isError: Bool) {
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
}
