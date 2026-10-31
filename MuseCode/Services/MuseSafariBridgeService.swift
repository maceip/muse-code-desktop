//
//  MuseSafariBridgeService.swift
//  PiCode
//
//  Persistent JavaScript & Safari Web Extension bridge for Muse Code.
//  Coordinates:
//  1. Bundled Safari Web Extension (`com.musecode.Pie.SafariExtension`) state & preferences
//  2. Local loopback HTTP JSON bridge (`127.0.0.1:47635`) + file queue IPC (`PiPaths.safariBridgeDirectory`)
//  3. Persistent agent-owned tab DOM execution engine (`claimTab`, `navigate`, `inspectDOM`,
//     `getValue`, `querySelectorAll`, `fill`, `fillForm`, `click`, `submit`, `scroll`, `eval`,
//     `extractScholar`, `searchScholar`)
//  4. Muse CLI skill (`safari-browser`) + `safari_bridge.py` CLI tool installation
//

import AppKit
import Foundation
import Network
import Observation
import SafariServices
import WebKit

struct MuseSafariOwnedTabState: Equatable, Sendable {
    var tabId: Int?
    var url: String = ""
    var title: String = ""
    var status: String = "unclaimed"
    var transport: String = "idle"
    var lastHeartbeat: Date?

    var isClaimed: Bool {
        tabId != nil && status != "unclaimed"
    }
}

struct MuseSafariDOMInspection: Equatable, Sendable {
    var url: String
    var title: String
    var readyState: String
    var headingCount: Int
    var inputCount: Int
    var buttonCount: Int
    var linkCount: Int
    var formCount: Int
    var textExcerpt: String
}

@Observable
@MainActor
final class MuseSafariBridgeService: NSObject, WKNavigationDelegate {
    static let shared = MuseSafariBridgeService()
    nonisolated static let extensionBundleIdentifier = "xyz.hieunguyen.PiCode.SafariExtension"
    nonisolated static let skillName = "safari-browser"

    private(set) var isServerRunning: Bool = false
    private(set) var listeningPort: Int = 47635
    private(set) var isExtensionBundled: Bool = false
    private(set) var isExtensionEnabledInSafari: Bool = false
    private(set) var extensionStatusMessage: String = "Checking Safari Web Extension…"
    private(set) var ownedTab = MuseSafariOwnedTabState()
    private(set) var latestDOMInspection: MuseSafariDOMInspection?
    private(set) var isSkillInstalled: Bool = false
    private(set) var skillInstallPath: String = ""
    private(set) var lastActionMessage: String?

    private var listener: NWListener?
    private var pendingExtensionCommands: [[String: Any]] = []
    private var pendingWaiters: [String: CheckedContinuation<[String: Any], Never>] = [:]
    private var persistentWebView: WKWebView?
    private var navigationContinuations: [CheckedContinuation<Void, Never>] = []

    override init() {
        super.init()
        ensureBridgeDirectoriesExist()
    }

    var bridgeEndpointURLString: String {
        "http://127.0.0.1:\(listeningPort)"
    }

    var isExtensionConnected: Bool {
        guard let hb = ownedTab.lastHeartbeat else { return false }
        return Date().timeIntervalSince(hb) < 3.0 && ownedTab.transport == "safari-extension"
    }

    // MARK: - Directory & Bundled Extension Discovery

    static func allBridgeDirectories() -> [URL] {
        let primary = PiPaths.safariBridgeDirectory
        let container = PiPaths.userHomeDirectory
            .appendingPathComponent("Library/Containers/\(extensionBundleIdentifier)/Data/.muse/safari-bridge", isDirectory: true)
        return [primary, container]
    }

    func ensureBridgeDirectoriesExist() {
        for root in Self.allBridgeDirectories() {
            let requests = root.appendingPathComponent("requests", isDirectory: true)
            let responses = root.appendingPathComponent("responses", isDirectory: true)
            try? FileManager.default.createDirectory(at: requests, withIntermediateDirectories: true)
            try? FileManager.default.createDirectory(at: responses, withIntermediateDirectories: true)
        }
    }

    static func locateBundledAppexURL() -> URL? {
        let fm = FileManager.default
        if let pluginsDir = Bundle.main.builtInPlugInsURL {
            let candidate = pluginsDir.appendingPathComponent("MuseSafariExtension.appex", isDirectory: true)
            if fm.fileExists(atPath: candidate.path) {
                return candidate
            }
        }
        let appBundleAppex = Bundle.main.bundleURL
            .appendingPathComponent("Contents/PlugIns/MuseSafariExtension.appex", isDirectory: true)
        if fm.fileExists(atPath: appBundleAppex.path) {
            return appBundleAppex
        }
        let cwd = URL(fileURLWithPath: fm.currentDirectoryPath, isDirectory: true)
        let stageCandidate = cwd.appendingPathComponent("build/Muse Code.app/Contents/PlugIns/MuseSafariExtension.appex", isDirectory: true)
        if fm.fileExists(atPath: stageCandidate.path) {
            return stageCandidate
        }
        let legacyStageCandidate = cwd.appendingPathComponent("build/Pie.app/Contents/PlugIns/MuseSafariExtension.appex", isDirectory: true)
        if fm.fileExists(atPath: legacyStageCandidate.path) {
            return legacyStageCandidate
        }
        let sourceManifest = cwd.appendingPathComponent("MuseSafariExtension/Resources/manifest.json")
        if fm.fileExists(atPath: sourceManifest.path) {
            return cwd.appendingPathComponent("MuseSafariExtension", isDirectory: true)
        }
        return nil
    }

    // MARK: - Status & Safari Extension Manager

    func refreshStatus(preferences: PreferencesStore? = nil, installation: PiInstallation? = nil) async {
        ensureBridgeDirectoriesExist()
        if let preferences {
            if preferences.safariBridgeEnabled {
                startServerIfNeeded(port: preferences.safariBridgePort)
            } else {
                stopServer()
            }
        } else if !isServerRunning {
            startServerIfNeeded(port: listeningPort)
        }

        isExtensionBundled = Self.locateBundledAppexURL() != nil

        // Check Safari's extension state via SFSafariExtensionManager
        let safariState = await Self.querySafariExtensionState()
        isExtensionEnabledInSafari = safariState.enabled
        extensionStatusMessage = safariState.message

        // Check native extension handler state file if present (both primary and sandbox container)
        for dir in Self.allBridgeDirectories() {
            let stateFile = dir.appendingPathComponent("extension-state.json")
            guard let data = try? Data(contentsOf: stateFile),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                continue
            }
            isExtensionEnabledInSafari = true
            extensionStatusMessage = "Active & connected in Safari (\(Self.extensionBundleIdentifier))"
            if let updatedAtStr = json["updatedAt"] as? String,
               let date = ISO8601DateFormatter().date(from: updatedAtStr),
               Date().timeIntervalSince(date) < 10.0 {
                ownedTab.lastHeartbeat = date
                ownedTab.transport = "safari-extension"
            }
            if let tabId = json["ownedTabId"] as? Int {
                ownedTab.tabId = tabId
                ownedTab.url = (json["url"] as? String) ?? ownedTab.url
                ownedTab.title = (json["title"] as? String) ?? ownedTab.title
                ownedTab.status = (json["status"] as? String) ?? "complete"
                ownedTab.transport = "safari-extension"
            }
        }

        // Check skill installation
        let skillURL = Self.userSkillDirectoryURL()
        let skillFile = skillURL.appendingPathComponent("SKILL.md")
        let scriptFile = skillURL.appendingPathComponent("scripts/safari_bridge.py")
        skillInstallPath = skillURL.path
        isSkillInstalled = FileManager.default.fileExists(atPath: skillFile.path)
            && FileManager.default.isExecutableFile(atPath: scriptFile.path)
        if !isSkillInstalled {
            _ = await installOrUpdateMuseSkill(installation: installation)
        }
    }

    nonisolated private static func queryPlugInKitState() -> (registered: Bool, enabled: Bool) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        proc.arguments = ["-m", "-v", "-i", Self.extensionBundleIdentifier]
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            let output = String(data: data, encoding: .utf8) ?? ""
            let registered = output.contains(Self.extensionBundleIdentifier)
            let enabled = output.split(separator: "\n").contains { line in
                line.trimmingCharacters(in: .whitespaces).hasPrefix("+")
                    && line.contains(Self.extensionBundleIdentifier)
            }
            return (registered, enabled)
        } catch {
            return (false, false)
        }
    }

    private static func querySafariExtensionState() async -> (enabled: Bool, message: String) {
        let pkState = await Task.detached(priority: .utility) {
            Self.queryPlugInKitState()
        }.value

        let isRunningInsideAppBundle = Bundle.main.bundlePath.hasSuffix(".app")
        if isRunningInsideAppBundle {
            final class ContinuationBox: @unchecked Sendable {
                private let lock = NSLock()
                private var continuation: CheckedContinuation<(enabled: Bool, message: String)?, Never>?
                init(_ c: CheckedContinuation<(enabled: Bool, message: String)?, Never>) {
                    self.continuation = c
                }
                func resume(_ value: (enabled: Bool, message: String)?) {
                    lock.lock()
                    let c = continuation
                    continuation = nil
                    lock.unlock()
                    c?.resume(returning: value)
                }
            }

            let sfResult: (enabled: Bool, message: String)? = await withCheckedContinuation { continuation in
                let box = ContinuationBox(continuation)
                SFSafariExtensionManager.getStateOfSafariExtension(withIdentifier: Self.extensionBundleIdentifier) { state, _ in
                    if let state {
                        if state.isEnabled {
                            box.resume((true, "Enabled in Safari (\(Self.extensionBundleIdentifier))"))
                        } else {
                            box.resume((false, "Installed — enable “Muse Safari Bridge” in Safari Settings → Extensions"))
                        }
                    } else {
                        box.resume(nil)
                    }
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.8) {
                    box.resume(nil)
                }
            }
            if let sfResult {
                return sfResult
            }
        }

        if pkState.registered {
            if pkState.enabled {
                return (
                    true,
                    "Registered & enabled in PlugInKit (\(Self.extensionBundleIdentifier)) — in Safari Settings → Developer, enable “Allow unsigned extensions” if needed, then enable “Muse Safari Bridge” in Extensions"
                )
            }
            return (
                false,
                "Registered in PlugInKit (\(Self.extensionBundleIdentifier)) — enable “Muse Safari Bridge” in Safari Settings → Extensions"
            )
        }

        let bundled = Self.locateBundledAppexURL() != nil
        if bundled {
            return (
                false,
                "Bundled (\(Self.extensionBundleIdentifier)) — click “Open Safari Extensions…” to register and enable"
            )
        }
        return (false, "Extension not registered yet")
    }

    func openSafariExtensionPreferences() {
        if let appexURL = Self.locateBundledAppexURL(), appexURL.pathExtension == "appex" {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
            p.arguments = ["-a", appexURL.path]
            try? p.run()
            p.waitUntilExit()
        }
        SFSafariApplication.showPreferencesForExtension(withIdentifier: Self.extensionBundleIdentifier) { [weak self] error in
            Task { @MainActor in
                if error != nil {
                    let script = """
                    tell application "Safari"
                        activate
                    end tell
                    """
                    let proc = Process()
                    proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                    proc.arguments = ["-e", script]
                    try? proc.run()
                    self?.lastActionMessage = "Activated Safari. Open Safari → Settings (⌘,) → Extensions to enable Muse Safari Bridge (if hidden, check “Allow unsigned extensions” in Safari → Settings → Developer)."
                } else {
                    self?.lastActionMessage = "Opened Safari Extensions preferences."
                }
            }
        }
    }

    // MARK: - Local HTTP Bridge Server (`127.0.0.1:47635`)

    func startServerIfNeeded(port: Int = 47635) {
        let validPort = (1024...65535).contains(port) ? port : 47635
        if isServerRunning && listeningPort == validPort && listener != nil {
            return
        }
        stopServer()
        listeningPort = validPort

        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(validPort)) else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: nwPort)

        do {
            let nwListener = try NWListener(using: params)
            nwListener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        self?.isServerRunning = true
                        if let actualPort = nwListener.port?.rawValue {
                            self?.listeningPort = Int(actualPort)
                        }
                    case .failed:
                        self?.startFallbackEphemeralServerIfNeeded()
                    case .cancelled:
                        break
                    default:
                        break
                    }
                }
            }
            nwListener.newConnectionHandler = { [weak self] connection in
                self?.handleIncomingHTTPConnection(connection)
            }
            nwListener.start(queue: DispatchQueue(label: "com.musecode.Pie.SafariBridgeServer", qos: .userInitiated))
            self.listener = nwListener
            self.isServerRunning = true
        } catch {
            self.startFallbackEphemeralServerIfNeeded()
        }
    }

    private func startFallbackEphemeralServerIfNeeded() {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        guard let fallback = try? NWListener(using: params) else {
            self.isServerRunning = false
            return
        }
        fallback.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                if case .ready = state {
                    self?.isServerRunning = true
                    if let actualPort = fallback.port?.rawValue {
                        self?.listeningPort = Int(actualPort)
                    }
                }
            }
        }
        fallback.newConnectionHandler = { [weak self] connection in
            self?.handleIncomingHTTPConnection(connection)
        }
        fallback.start(queue: DispatchQueue(label: "com.musecode.Pie.SafariBridgeServer.Fallback", qos: .userInitiated))
        self.listener = fallback
        self.isServerRunning = true
    }

    func stopServer() {
        listener?.cancel()
        listener = nil
        isServerRunning = false
    }

    nonisolated private func handleIncomingHTTPConnection(_ connection: NWConnection) {
        connection.start(queue: DispatchQueue(label: "com.musecode.Pie.SafariBridgeConn", qos: .userInitiated))
        receiveFullHTTPRequest(on: connection, accumulated: Data())
    }

    nonisolated private func receiveFullHTTPRequest(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            var buffer = accumulated
            if let data, !data.isEmpty {
                buffer.append(data)
            }
            if let parsed = Self.parseHTTPRequest(from: buffer) {
                Task { @MainActor in
                    let responseJSON = await self.routeHTTPRequest(method: parsed.method, path: parsed.path, body: parsed.body)
                    Self.sendHTTPJSONResponse(responseJSON, on: connection)
                }
            } else if isComplete || error != nil || buffer.count > 2_000_000 {
                let fallback: [String: Any] = ["ok": false, "error": "Malformed or incomplete HTTP request"]
                Self.sendHTTPJSONResponse(fallback, on: connection)
            } else {
                self.receiveFullHTTPRequest(on: connection, accumulated: buffer)
            }
        }
    }

    nonisolated private static func parseHTTPRequest(from data: Data) -> (method: String, path: String, body: Data)? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: separator) else { return nil }
        let headerData = data.subdata(in: 0..<headerRange.lowerBound)
        guard let headerString = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerString.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0]).uppercased()
        let path = String(parts[1])

        var contentLength = 0
        for line in lines.dropFirst() {
            let lower = line.lowercased()
            if lower.hasPrefix("content-length:") {
                let val = line.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)
                contentLength = Int(val) ?? 0
            }
        }
        let bodyStart = headerRange.upperBound
        let availableBodyBytes = data.count - bodyStart
        guard availableBodyBytes >= contentLength else { return nil }
        let body = data.subdata(in: bodyStart..<(bodyStart + contentLength))
        return (method, path, body)
    }

    nonisolated private static func sendHTTPJSONResponse(_ jsonObject: [String: Any], on connection: NWConnection) {
        let bodyData = (try? JSONSerialization.data(withJSONObject: jsonObject, options: [])) ?? Data("{\"ok\":false}".utf8)
        let header = [
            "HTTP/1.1 200 OK",
            "Content-Type: application/json; charset=utf-8",
            "Content-Length: \(bodyData.count)",
            "Access-Control-Allow-Origin: *",
            "Access-Control-Allow-Methods: GET, POST, OPTIONS",
            "Access-Control-Allow-Headers: Content-Type",
            "Connection: close",
            "",
            ""
        ].joined(separator: "\r\n")
        var payload = Data(header.utf8)
        payload.append(bodyData)
        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private func routeHTTPRequest(method: String, path: String, body: Data) async -> [String: Any] {
        if method == "OPTIONS" {
            return ["ok": true]
        }
        let bodyJSON = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]

        switch path {
        case "/api/v1/status", "/status":
            return [
                "ok": true,
                "listening": isServerRunning,
                "port": listeningPort,
                "extensionBundleId": Self.extensionBundleIdentifier,
                "extensionBundled": isExtensionBundled,
                "extensionEnabledInSafari": isExtensionEnabledInSafari,
                "extensionConnected": isExtensionConnected,
                "skillInstalled": isSkillInstalled,
                "skillPath": skillInstallPath,
                "ownedTab": [
                    "tabId": ownedTab.tabId as Any,
                    "url": ownedTab.url,
                    "title": ownedTab.title,
                    "status": ownedTab.status,
                    "transport": ownedTab.transport
                ]
            ]

        case "/api/v1/extension/poll":
            if let tabState = bodyJSON["tabState"] as? [String: Any] {
                updateOwnedTabFromExtension(tabState)
            }
            if !pendingExtensionCommands.isEmpty {
                let next = pendingExtensionCommands.removeFirst()
                return [
                    "ok": true,
                    "type": "command",
                    "command": next
                ]
            }
            return ["ok": true, "type": "idle"]

        case "/api/v1/extension/result":
            if let tabState = bodyJSON["tabState"] as? [String: Any] {
                updateOwnedTabFromExtension(tabState)
            }
            if let id = bodyJSON["id"] as? String, let waiter = pendingWaiters.removeValue(forKey: id) {
                waiter.resume(returning: bodyJSON)
            }
            return ["ok": true, "type": "ack"]

        case "/api/v1/command", "/command":
            return await executeCommand(bodyJSON)

        default:
            return ["ok": false, "error": "Unknown endpoint \(path)"]
        }
    }

    private func updateOwnedTabFromExtension(_ tabState: [String: Any]) {
        if let tabId = tabState["ownedTabId"] as? Int {
            ownedTab.tabId = tabId
        }
        if let url = tabState["url"] as? String {
            ownedTab.url = url
        }
        if let title = tabState["title"] as? String {
            ownedTab.title = title
        }
        if let status = tabState["status"] as? String {
            ownedTab.status = status
        }
        ownedTab.transport = "safari-extension"
        ownedTab.lastHeartbeat = Date()
    }

    // MARK: - Command Execution Engine (Safari Web Extension + Persistent WebKit DOM Runtime)

    func executeCommand(_ rawCommand: [String: Any]) async -> [String: Any] {
        var command = rawCommand
        let commandId = (command["id"] as? String) ?? UUID().uuidString
        command["id"] = commandId
        let action = (command["action"] as? String) ?? "status"

        // High-level convenience action: `searchScholar` navigates to Google Scholar with the query and extracts results
        if action == "searchScholar" {
            let query = (command["query"] as? String) ?? (command["value"] as? String) ?? ""
            let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
            let targetURL = (command["url"] as? String) ?? "https://scholar.google.com/scholar?hl=en&q=\(encoded)"
            _ = await executeCommand(["action": "navigate", "url": targetURL])
            let extractResp = await executeCommand(["action": "extractScholar"])
            let domResp = await executeCommand(["action": "inspectDOM"])
            return [
                "ok": true,
                "id": commandId,
                "action": "searchScholar",
                "query": query,
                "url": ownedTab.url,
                "title": ownedTab.title,
                "scholarResults": (extractResp["data"] as? [String: Any])?["results"] ?? [],
                "dom": domResp["data"] ?? [:]
            ]
        }

        // 1. If the Safari Web Extension is actively connected via heartbeat, dispatch to Safari extension first
        if isExtensionConnected {
            let extResult = await dispatchToConnectedSafariExtension(command, id: commandId)
            if (extResult["ok"] as? Bool) == true {
                updateInspectionIfPresent(from: extResult)
                return extResult
            }
        }

        // 2. Execute against the persistent owned WebKit DOM runtime (which loads the exact same `content.js` bridge!)
        let domResult = await executeInPersistentDOMBridge(command)
        updateInspectionIfPresent(from: domResult)
        return domResult
    }

    private func dispatchToConnectedSafariExtension(_ command: [String: Any], id: String) async -> [String: Any] {
        pendingExtensionCommands.append(command)
        // Also write to both primary and sandboxed container request queues for SafariWebExtensionHandler
        if let data = try? JSONSerialization.data(withJSONObject: command) {
            for dir in Self.allBridgeDirectories() {
                let reqFile = dir
                    .appendingPathComponent("requests", isDirectory: true)
                    .appendingPathComponent("\(id).json")
                try? data.write(to: reqFile, options: .atomic)
            }
        }

        return await withCheckedContinuation { (continuation: CheckedContinuation<[String: Any], Never>) in
            pendingWaiters[id] = continuation
            Task { @MainActor in
                for _ in 0..<30 {
                    try? await Task.sleep(nanoseconds: 80_000_000)
                    guard self.pendingWaiters[id] != nil else { return }
                    for dir in Self.allBridgeDirectories() {
                        let respFile = dir
                            .appendingPathComponent("responses", isDirectory: true)
                            .appendingPathComponent("\(id).json")
                        if let data = try? Data(contentsOf: respFile),
                           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                            try? FileManager.default.removeItem(at: respFile)
                            if let waiter = self.pendingWaiters.removeValue(forKey: id) {
                                let resultPayload = (obj["result"] as? [String: Any]) ?? obj
                                waiter.resume(returning: resultPayload)
                                return
                            }
                        }
                    }
                }
                if let waiter = self.pendingWaiters.removeValue(forKey: id) {
                    waiter.resume(returning: ["ok": false, "error": "Safari extension timed out"])
                }
            }
        }
    }

    private func ensurePersistentWebView() -> WKWebView {
        if let existing = persistentWebView {
            return existing
        }
        let config = WKWebViewConfiguration()
        let userContent = WKUserContentController()
        if let scriptSource = Self.loadContentScriptSource() {
            let userScript = WKUserScript(
                source: scriptSource,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
            userContent.addUserScript(userScript)
        }
        config.userContentController = userContent
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800), configuration: config)
        webView.navigationDelegate = self
        webView.customUserAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_0) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"
        persistentWebView = webView
        return webView
    }

    static func loadContentScriptSource() -> String? {
        let fm = FileManager.default
        if let appexURL = locateBundledAppexURL() {
            let candidates = [
                appexURL.appendingPathComponent("Contents/Resources/content.js"),
                appexURL.appendingPathComponent("Resources/content.js")
            ]
            for c in candidates where fm.fileExists(atPath: c.path) {
                if let s = try? String(contentsOf: c, encoding: .utf8) {
                    return s
                }
            }
        }
        let repoCandidate = URL(fileURLWithPath: fm.currentDirectoryPath)
            .appendingPathComponent("MuseSafariExtension/Resources/content.js")
        if let s = try? String(contentsOf: repoCandidate, encoding: .utf8) {
            return s
        }
        return nil
    }

    private func executeInPersistentDOMBridge(_ command: [String: Any]) async -> [String: Any] {
        let action = (command["action"] as? String) ?? "status"
        let webView = ensurePersistentWebView()

        switch action {
        case "status", "ping":
            return [
                "ok": true,
                "action": action,
                "data": [
                    "ownedTabId": ownedTab.tabId as Any,
                    "url": ownedTab.url,
                    "title": ownedTab.title,
                    "status": ownedTab.status,
                    "transport": ownedTab.transport
                ]
            ]

        case "claimTab":
            if ownedTab.tabId == nil {
                ownedTab.tabId = 1
            }
            ownedTab.status = "complete"
            ownedTab.lastHeartbeat = Date()
            let syncSafari = (command["syncSafariWindow"] as? Bool) ?? (command["html"] == nil)
            if let urlString = command["url"] as? String, !urlString.isEmpty {
                _ = await loadURLOrHTMLInPersistentTab(
                    urlString: urlString,
                    html: command["html"] as? String,
                    syncRealSafariTab: syncSafari
                )
            } else if syncSafari, let safariTab = await Self.syncLiveSafariTab(navigateToURL: nil) {
                _ = await loadURLOrHTMLInPersistentTab(
                    urlString: safariTab.url,
                    html: safariTab.html,
                    syncRealSafariTab: false
                )
                ownedTab.transport = "safari-live+webkit-dom"
                if !safariTab.title.isEmpty {
                    ownedTab.title = safariTab.title
                }
            } else if ownedTab.url.isEmpty {
                _ = await loadURLOrHTMLInPersistentTab(
                    urlString: "https://scholar.google.com",
                    html: command["html"] as? String,
                    syncRealSafariTab: false
                )
                ownedTab.transport = syncSafari ? "safari-live+webkit-dom" : "webkit-dom"
            }
            lastActionMessage = "Claimed tab #\(ownedTab.tabId ?? 1) (\(ownedTab.url))"
            return [
                "ok": true,
                "action": action,
                "data": [
                    "ownedTabId": ownedTab.tabId ?? 1,
                    "url": ownedTab.url,
                    "title": ownedTab.title,
                    "status": ownedTab.status,
                    "transport": ownedTab.transport
                ]
            ]

        case "releaseTab":
            ownedTab = MuseSafariOwnedTabState()
            latestDOMInspection = nil
            lastActionMessage = "Released owned tab."
            return [
                "ok": true,
                "action": action,
                "data": [
                    "ownedTabId": NSNull(),
                    "url": "",
                    "title": "",
                    "status": "unclaimed"
                ]
            ]

        case "navigate", "openTab":
            if ownedTab.tabId == nil {
                ownedTab.tabId = 1
            }
            let targetURL = (command["url"] as? String) ?? "https://www.google.com"
            let htmlOverride = command["html"] as? String
            let syncSafari = (command["syncSafariWindow"] as? Bool) ?? (htmlOverride == nil)
            let loaded = await loadURLOrHTMLInPersistentTab(
                urlString: targetURL,
                html: htmlOverride,
                syncRealSafariTab: syncSafari
            )
            let domResp = await evaluateContentBridgeCommand(["action": "inspectDOM"], in: webView)
            return [
                "ok": loaded,
                "action": action,
                "data": [
                    "tabId": ownedTab.tabId ?? 1,
                    "url": ownedTab.url,
                    "title": ownedTab.title,
                    "transport": ownedTab.transport,
                    "dom": domResp["data"] ?? [:]
                ]
            ]

        case "reload":
            webView.reload()
            try? await Task.sleep(nanoseconds: 250_000_000)
            ownedTab.url = webView.url?.absoluteString ?? ownedTab.url
            ownedTab.title = webView.title ?? ownedTab.title
            return [
                "ok": true,
                "action": action,
                "data": ["tabId": ownedTab.tabId ?? 1, "url": ownedTab.url, "title": ownedTab.title]
            ]

        default:
            if ownedTab.tabId == nil {
                ownedTab.tabId = 1
                ownedTab.status = "complete"
                ownedTab.lastHeartbeat = Date()
                if ownedTab.url.isEmpty, let safariTab = await Self.syncLiveSafariTab(navigateToURL: nil) {
                    _ = await loadURLOrHTMLInPersistentTab(
                        urlString: safariTab.url,
                        html: safariTab.html,
                        syncRealSafariTab: false
                    )
                    ownedTab.transport = "safari-live+webkit-dom"
                    if !safariTab.title.isEmpty {
                        ownedTab.title = safariTab.title
                    }
                } else {
                    ownedTab.transport = "webkit-dom"
                }
            }
            return await evaluateContentBridgeCommand(command, in: webView)
        }
    }

    private func loadURLOrHTMLInPersistentTab(
        urlString: String,
        html: String?,
        syncRealSafariTab: Bool = false
    ) async -> Bool {
        let webView = ensurePersistentWebView()
        ownedTab.status = "loading"
        ownedTab.transport = syncRealSafariTab ? "safari-live+webkit-dom" : "webkit-dom"
        ownedTab.lastHeartbeat = Date()

        var resolvedHTML = html
        var resolvedURL = urlString
        var safariSyncedTitle: String?

        if syncRealSafariTab && (resolvedHTML == nil || resolvedHTML?.isEmpty == true) {
            if let liveTab = await Self.syncLiveSafariTab(navigateToURL: urlString) {
                if !liveTab.url.isEmpty {
                    resolvedURL = liveTab.url
                }
                if !liveTab.title.isEmpty {
                    safariSyncedTitle = liveTab.title
                }
                if !liveTab.html.isEmpty {
                    resolvedHTML = liveTab.html
                }
            }
        }

        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            navigationContinuations.append(continuation)
            if let resolvedHTML, !resolvedHTML.isEmpty {
                webView.loadHTMLString(resolvedHTML, baseURL: URL(string: resolvedURL))
            } else if let url = URL(string: resolvedURL) {
                webView.load(URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12))
            } else {
                let waiters = self.navigationContinuations
                self.navigationContinuations.removeAll()
                for w in waiters { w.resume() }
                return
            }

            let timeoutNs: UInt64 = (resolvedHTML != nil && !(resolvedHTML?.isEmpty ?? true))
                ? 1_500_000_000
                : 6_000_000_000
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: timeoutNs)
                if !self.navigationContinuations.isEmpty {
                    let waiters = self.navigationContinuations
                    self.navigationContinuations.removeAll()
                    for w in waiters { w.resume() }
                }
            }
        }

        if let scriptSource = Self.loadContentScriptSource() {
            _ = try? await webView.evaluateJavaScript(scriptSource)
        }
        ownedTab.url = webView.url?.absoluteString ?? resolvedURL
        let jsTitle = (try? await webView.evaluateJavaScript("document.title") as? String) ?? webView.title ?? ""
        ownedTab.title = !jsTitle.isEmpty ? jsTitle : (safariSyncedTitle ?? "")
        ownedTab.status = "complete"
        ownedTab.lastHeartbeat = Date()
        lastActionMessage = "Loaded \(ownedTab.title.isEmpty ? ownedTab.url : ownedTab.title)"
        return true
    }

    /// Drives the real running `Safari.app` window via AppleEvents:
    /// - Navigates the active tab of the front Safari window (or opens a window if none exists) when `navigateToURL` is provided.
    /// - Waits for the page to render and returns its live `(url, title, html)` so `MuseSafariBridgeService` and `Safari.app` stay in lockstep.
    nonisolated private static func syncLiveSafariTab(navigateToURL: String?) async -> (url: String, title: String, html: String)? {
        await Task.detached(priority: .userInitiated) {
            let escapedURL = (navigateToURL ?? "")
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            let appleScriptSource: String
            if let navigateToURL, !navigateToURL.isEmpty {
                appleScriptSource = """
                tell application "Safari"
                    if not running then launch
                    if (count of windows) is 0 then
                        make new document with properties {URL:"\(escapedURL)"}
                    else
                        set URL of current tab of front window to "\(escapedURL)"
                    end if
                    repeat 25 times
                        delay 0.15
                        try
                            set src to source of current tab of front window
                            if (length of src) > 200 then exit repeat
                        end try
                    end repeat
                    set tUrl to URL of current tab of front window
                    set tTitle to name of current tab of front window
                    set tSource to source of current tab of front window
                    return tUrl & "\\n---MUSE_SEP---\\n" & tTitle & "\\n---MUSE_SEP---\\n" & tSource
                end tell
                """
            } else {
                appleScriptSource = """
                tell application "Safari"
                    if not running then launch
                    if (count of windows) is 0 then
                        make new document with properties {URL:"https://scholar.google.com"}
                        delay 1.0
                    end if
                    set tUrl to URL of current tab of front window
                    set tTitle to name of current tab of front window
                    set tSource to source of current tab of front window
                    return tUrl & "\\n---MUSE_SEP---\\n" & tTitle & "\\n---MUSE_SEP---\\n" & tSource
                end tell
                """
            }

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = ["-e", appleScriptSource]
            let outPipe = Pipe()
            proc.standardOutput = outPipe
            proc.standardError = Pipe()
            do {
                try proc.run()
                let killItem = DispatchWorkItem {
                    if proc.isRunning {
                        proc.terminate()
                    }
                }
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 2.5, execute: killItem)
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                proc.waitUntilExit()
                killItem.cancel()
                guard proc.terminationStatus == 0 else { return nil }
                guard let output = String(data: data, encoding: .utf8) else { return nil }
                let parts = output.components(separatedBy: "\n---MUSE_SEP---\n")
                guard parts.count >= 3 else { return nil }
                let url = parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                let title = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
                let html = parts.dropFirst(2).joined(separator: "\n---MUSE_SEP---\n")
                return (url: url, title: title, html: html)
            } catch {
                return nil
            }
        }.value
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            let waiters = self.navigationContinuations
            self.navigationContinuations.removeAll()
            for w in waiters { w.resume() }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            let waiters = self.navigationContinuations
            self.navigationContinuations.removeAll()
            for w in waiters { w.resume() }
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            let waiters = self.navigationContinuations
            self.navigationContinuations.removeAll()
            for w in waiters { w.resume() }
        }
    }

    private func evaluateContentBridgeCommand(_ command: [String: Any], in webView: WKWebView) async -> [String: Any] {
        if let scriptSource = Self.loadContentScriptSource() {
            _ = try? await webView.evaluateJavaScript(scriptSource)
        }
        guard let cmdData = try? JSONSerialization.data(withJSONObject: command),
              let cmdJSON = String(data: cmdData, encoding: .utf8) else {
            return ["ok": false, "error": "Failed to serialize bridge command"]
        }

        let wrapperJS = """
        const cmd = \(cmdJSON);
        const res = await window.__museSafariBridge.handleCommand(cmd);
        return JSON.stringify(res);
        """
        do {
            let raw = try await webView.callAsyncJavaScript(
                wrapperJS,
                arguments: [:],
                in: nil,
                contentWorld: .page
            )
            if let jsonString = raw as? String,
               let data = jsonString.data(using: .utf8),
               let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                ownedTab.url = webView.url?.absoluteString ?? ownedTab.url
                ownedTab.title = webView.title ?? ownedTab.title
                ownedTab.lastHeartbeat = Date()
                return parsed
            }
            return ["ok": true, "data": raw ?? [:]]
        } catch {
            return ["ok": false, "error": error.localizedDescription]
        }
    }

    private func updateInspectionIfPresent(from response: [String: Any]) {
        let dataDict = (response["data"] as? [String: Any])
        let domDict: [String: Any]?
        if let nested = dataDict?["dom"] as? [String: Any] {
            domDict = nested
        } else if dataDict?["readyState"] != nil || dataDict?["inputs"] != nil {
            domDict = dataDict
        } else {
            domDict = nil
        }
        guard let domDict else { return }
        let url = (domDict["url"] as? String) ?? ownedTab.url
        let title = (domDict["title"] as? String) ?? ownedTab.title
        let readyState = (domDict["readyState"] as? String) ?? "complete"
        let headings = (domDict["headings"] as? [Any])?.count ?? 0
        let inputs = (domDict["inputs"] as? [Any])?.count ?? 0
        let buttons = (domDict["buttons"] as? [Any])?.count ?? 0
        let links = (domDict["links"] as? [Any])?.count ?? 0
        let formCount = (domDict["formCount"] as? Int) ?? 0
        let excerpt = (domDict["textExcerpt"] as? String) ?? ""
        if !url.isEmpty { ownedTab.url = url }
        if !title.isEmpty { ownedTab.title = title }
        latestDOMInspection = MuseSafariDOMInspection(
            url: url,
            title: title,
            readyState: readyState,
            headingCount: headings,
            inputCount: inputs,
            buttonCount: buttons,
            linkCount: links,
            formCount: formCount,
            textExcerpt: excerpt
        )
    }

    // MARK: - Muse CLI Skill (`safari-browser`) & CLI Script Installer

    static func userSkillDirectoryURL() -> URL {
        PiPaths.userHomeDirectory.appendingPathComponent(".agents/skills/\(skillName)", isDirectory: true)
    }

    static func bridgeStagedSkillDirectoryURL() -> URL {
        PiPaths.safariBridgeDirectory.appendingPathComponent("skills/\(skillName)", isDirectory: true)
    }

    @discardableResult
    func installOrUpdateMuseSkill(installation: PiInstallation? = nil) async -> Bool {
        let fm = FileManager.default
        let targetDirs = [Self.userSkillDirectoryURL(), Self.bridgeStagedSkillDirectoryURL()]

        let skillMarkdown = Self.buildSkillMarkdown(defaultPort: listeningPort)
        let cliPythonScript = Self.buildSafariBridgeCLIScript(defaultPort: listeningPort)

        for dir in targetDirs {
            let scriptsDir = dir.appendingPathComponent("scripts", isDirectory: true)
            do {
                try fm.createDirectory(at: scriptsDir, withIntermediateDirectories: true)
                let skillFile = dir.appendingPathComponent("SKILL.md")
                let scriptFile = scriptsDir.appendingPathComponent("safari_bridge.py")
                try skillMarkdown.write(to: skillFile, atomically: true, encoding: .utf8)
                try cliPythonScript.write(to: scriptFile, atomically: true, encoding: .utf8)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptFile.path)
            } catch {
                lastActionMessage = "Failed to write skill files: \(error.localizedDescription)"
                return false
            }
        }

        let stagedDir = Self.bridgeStagedSkillDirectoryURL()
        if let resolved = await MuseUsageService.resolveInstallation(installation) {
            let executable = resolved.executableURL
            let env = PiDiscoveryService.launchEnvironment(
                executable: executable,
                shellPath: resolved.shellPath
            )
            _ = await PiDiscoveryService().run(
                executable: executable,
                arguments: ["skills", "install", stagedDir.path, "--scope", "user", "--force"],
                directory: stagedDir,
                environment: env,
                timeout: 8.0
            )
            _ = await PiDiscoveryService().run(
                executable: executable,
                arguments: ["skills", "enable", Self.skillName, "--scope", "user"],
                directory: stagedDir,
                environment: env,
                timeout: 6.0
            )
        }

        let userSkillDir = Self.userSkillDirectoryURL()
        skillInstallPath = userSkillDir.path
        isSkillInstalled = fm.fileExists(atPath: userSkillDir.appendingPathComponent("SKILL.md").path)
            && fm.isExecutableFile(atPath: userSkillDir.appendingPathComponent("scripts/safari_bridge.py").path)
        if isSkillInstalled {
            lastActionMessage = "Installed & enabled '\(Self.skillName)' skill for Muse CLI."
        }
        return isSkillInstalled
    }

    private static func buildSkillMarkdown(defaultPort: Int) -> String {
        """
        ---
        name: safari-browser
        description: Persistent Safari Web Extension JavaScript bridge that lets Muse own and control a Safari tab, navigate to URLs (such as Google Scholar, docs, or web apps), inspect and query the live DOM, fill out forms, click buttons/links, and extract values directly from the page. Use whenever the user asks to browse in Safari, fill out a form, check a live DOM value, or search Google Scholar / web pages.
        ---

        # Muse Safari Bridge (`safari-browser`)

        This skill provides a persistent JavaScript bridge into Safari via the bundled **Muse Safari Bridge** Web Extension (`xyz.hieunguyen.PiCode.SafariExtension`) and local bridge coordinator (`http://127.0.0.1:\(defaultPort)`).

        It allows you to claim and own a dedicated Safari tab, navigate to pages, inspect live DOM structure, retrieve element values, fill out forms (with full React/Vue/DOM input & change events), click buttons or links, evaluate JavaScript in the page, and extract structured search results (such as Google Scholar).

        ## CLI Helper (`scripts/safari_bridge.py`)

        Run the bundled `scripts/safari_bridge.py` helper from this skill directory (or call `POST http://127.0.0.1:\(defaultPort)/api/v1/command` directly):

        ```bash
        # 1. Check bridge & owned Safari tab status
        python3 "$HOME/.agents/skills/safari-browser/scripts/safari_bridge.py" status

        # 2. Claim the active Safari tab (or open & claim a URL)
        python3 "$HOME/.agents/skills/safari-browser/scripts/safari_bridge.py" claim --url "https://scholar.google.com"

        # 3. Navigate the Muse-owned tab to a new URL and inspect the loaded DOM
        python3 "$HOME/.agents/skills/safari-browser/scripts/safari_bridge.py" navigate "https://scholar.google.com"

        # 4. Inspect the live DOM (headings, inputs, buttons, links, form count, text excerpt)
        python3 "$HOME/.agents/skills/safari-browser/scripts/safari_bridge.py" inspect

        # 5. Retrieve the text, value, attributes, and bounding box of a DOM element
        python3 "$HOME/.agents/skills/safari-browser/scripts/safari_bridge.py" get "input[name='q']"

        # 6. Fill a single input field (and optionally submit its form)
        python3 "$HOME/.agents/skills/safari-browser/scripts/safari_bridge.py" fill "input[name='q']" "speculative decoding" --submit

        # 7. Fill multiple form fields at once by CSS selector, name, id, placeholder, or label
        python3 "$HOME/.agents/skills/safari-browser/scripts/safari_bridge.py" fill-form '{"name":"Ada Lovelace","email":"ada@example.com"}' --submit

        # 8. Click a button or link by CSS selector or visible text
        python3 "$HOME/.agents/skills/safari-browser/scripts/safari_bridge.py" click "Search"

        # 9. Search Google Scholar and extract structured paper results from the DOM
        python3 "$HOME/.agents/skills/safari-browser/scripts/safari_bridge.py" scholar "flash attention transformer"

        # 10. Evaluate a JavaScript expression directly in the owned tab's DOM
        python3 "$HOME/.agents/skills/safari-browser/scripts/safari_bridge.py" eval "document.title"
        ```
        """
    }

    private static func buildSafariBridgeCLIScript(defaultPort: Int) -> String {
        """
        #!/usr/bin/env python3
        \"\"\"
        safari_bridge.py — Muse CLI helper for the Persistent Safari JavaScript Bridge.
        Communicates with Pie.app's MuseSafariBridgeService (`http://127.0.0.1:\(defaultPort)/api/v1/command`).
        \"\"\"

        import argparse
        import json
        import os
        import sys
        import urllib.error
        import urllib.request

        DEFAULT_PORT = int(os.environ.get("MUSE_SAFARI_BRIDGE_PORT", "\(defaultPort)"))

        def send_command(payload, port=DEFAULT_PORT, timeout=20.0):
            url = f"http://127.0.0.1:{port}/api/v1/command"
            data = json.dumps(payload).encode("utf-8")
            req = urllib.request.Request(
                url,
                data=data,
                headers={"Content-Type": "application/json"},
                method="POST",
            )
            try:
                with urllib.request.urlopen(req, timeout=timeout) as resp:
                    body = resp.read().decode("utf-8")
                    return json.loads(body)
            except urllib.error.URLError as exc:
                return {
                    "ok": False,
                    "error": f"Could not reach Muse Safari Bridge at {url}: {exc}",
                }

        def main():
            parser = argparse.ArgumentParser(description="Muse Safari Persistent JS Bridge CLI")
            parser.add_argument("--port", type=int, default=DEFAULT_PORT, help="Local bridge port")
            sub = parser.add_subparsers(dest="cmd", required=True)

            sub.add_parser("status", help="Get bridge and owned Safari tab status")

            claim_p = sub.add_parser("claim", help="Claim active tab or open URL as Muse-owned tab")
            claim_p.add_argument("--url", default=None, help="Optional initial URL")

            sub.add_parser("release", help="Release the Muse-owned Safari tab")

            nav_p = sub.add_parser("navigate", help="Navigate owned tab to URL")
            nav_p.add_argument("url", help="Target URL")

            sub.add_parser("inspect", help="Inspect current DOM structure and interactive elements")

            get_p = sub.add_parser("get", help="Get value/text/attributes of a DOM element")
            get_p.add_argument("selector", help="CSS selector or label/name hint")

            qall_p = sub.add_parser("query-all", help="Query all matching DOM elements")
            qall_p.add_argument("selector", help="CSS selector")
            qall_p.add_argument("--limit", type=int, default=50)

            fill_p = sub.add_parser("fill", help="Fill an input/textarea/select element")
            fill_p.add_argument("selector", help="CSS selector or field label/name")
            fill_p.add_argument("value", help="Value to fill")
            fill_p.add_argument("--submit", action="store_true", help="Submit form after filling")

            form_p = sub.add_parser("fill-form", help="Fill multiple fields from a JSON object")
            form_p.add_argument("fields_json", help="JSON dictionary of {selectorOrLabel: value}")
            form_p.add_argument("--submit", action="store_true", help="Submit form after filling")

            click_p = sub.add_parser("click", help="Click an element by selector or visible text")
            click_p.add_argument("target", help="CSS selector or visible button/link text")

            submit_p = sub.add_parser("submit", help="Submit a form")
            submit_p.add_argument("selector", nargs="?", default=None, help="Optional form/field selector")

            scroll_p = sub.add_parser("scroll", help="Scroll page or element into view")
            scroll_p.add_argument("--selector", default=None)
            scroll_p.add_argument("--position", choices=["top", "bottom"], default=None)
            scroll_p.add_argument("--y", type=int, default=500)

            eval_p = sub.add_parser("eval", help="Evaluate JavaScript expression in page DOM")
            eval_p.add_argument("script", help="JavaScript expression")

            scholar_p = sub.add_parser("scholar", help="Search Google Scholar and extract DOM results")
            scholar_p.add_argument("query", help="Google Scholar search query")

            args = parser.parse_args()

            if args.cmd == "status":
                res = send_command({"action": "status"}, port=args.port)
            elif args.cmd == "claim":
                payload = {"action": "claimTab"}
                if args.url:
                    payload["url"] = args.url
                res = send_command(payload, port=args.port)
            elif args.cmd == "release":
                res = send_command({"action": "releaseTab"}, port=args.port)
            elif args.cmd == "navigate":
                res = send_command({"action": "navigate", "url": args.url}, port=args.port)
            elif args.cmd == "inspect":
                res = send_command({"action": "inspectDOM"}, port=args.port)
            elif args.cmd == "get":
                res = send_command({"action": "getValue", "selector": args.selector}, port=args.port)
            elif args.cmd == "query-all":
                res = send_command({"action": "querySelectorAll", "selector": args.selector, "limit": args.limit}, port=args.port)
            elif args.cmd == "fill":
                res = send_command({"action": "fill", "selector": args.selector, "value": args.value, "submit": args.submit}, port=args.port)
            elif args.cmd == "fill-form":
                fields = json.loads(args.fields_json)
                res = send_command({"action": "fillForm", "fields": fields, "submit": args.submit}, port=args.port)
            elif args.cmd == "click":
                res = send_command({"action": "click", "selector": args.target}, port=args.port)
            elif args.cmd == "submit":
                res = send_command({"action": "submit", "selector": args.selector}, port=args.port)
            elif args.cmd == "scroll":
                res = send_command({"action": "scroll", "selector": args.selector, "position": args.position, "y": args.y}, port=args.port)
            elif args.cmd == "eval":
                res = send_command({"action": "eval", "script": args.script}, port=args.port)
            elif args.cmd == "scholar":
                res = send_command({"action": "searchScholar", "query": args.query}, port=args.port)
            else:
                res = {"ok": False, "error": f"Unknown command {args.cmd}"}

            print(json.dumps(res, indent=2))
            sys.exit(0 if res.get("ok", False) else 1)

        if __name__ == "__main__":
            main()
        """
    }
}
