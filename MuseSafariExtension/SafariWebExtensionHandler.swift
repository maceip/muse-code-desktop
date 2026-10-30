//
//  SafariWebExtensionHandler.swift
//  MuseSafariExtension
//
//  Native WebExtension message handler for the bundled Muse Safari Bridge
//  (`xyz.hieunguyen.PiCode.SafariExtension`). Bridges `browser.runtime.sendNativeMessage`
//  from `background.js` directly to the local Muse Safari Bridge queue and HTTP
//  coordinator so the Muse agent can persistently own a Safari tab, navigate,
//  inspect the DOM, fill forms, click elements, and extract values.
//

import Foundation
import SafariServices
import os.log

@objc(SafariWebExtensionHandler)
final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    private let logger = Logger(subsystem: "xyz.hieunguyen.PiCode.SafariExtension", category: "Bridge")

    /// Dynamically resolves the shared Safari bridge directory without hardcoded user paths.
    private static func resolveBridgeDirectory() -> URL {
        let env = ProcessInfo.processInfo.environment
        let fm = FileManager.default
        if let explicit = env["MUSE_SAFARI_BRIDGE_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !explicit.isEmpty {
            return URL(fileURLWithPath: (explicit as NSString).expandingTildeInPath, isDirectory: true)
        }
        if let configDir = env["MUSE_CONFIG_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !configDir.isEmpty {
            return URL(fileURLWithPath: (configDir as NSString).expandingTildeInPath, isDirectory: true)
                .appendingPathComponent("safari-bridge", isDirectory: true)
        }
        if let museHome = env["MUSE_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !museHome.isEmpty {
            return URL(fileURLWithPath: (museHome as NSString).expandingTildeInPath, isDirectory: true)
                .appendingPathComponent("safari-bridge", isDirectory: true)
        }
        let home = fm.homeDirectoryForCurrentUser
        return home.appendingPathComponent(".muse/safari-bridge", isDirectory: true)
    }

    func beginRequest(with context: NSExtensionContext) {
        let request = context.inputItems.first as? NSExtensionItem
        let message = request?.userInfo?[SFExtensionMessageKey] as? [String: Any] ?? [:]
        let type = (message["type"] as? String) ?? "poll"

        let bridgeDir = Self.resolveBridgeDirectory()
        let requestsDir = bridgeDir.appendingPathComponent("requests", isDirectory: true)
        let responsesDir = bridgeDir.appendingPathComponent("responses", isDirectory: true)
        let stateFile = bridgeDir.appendingPathComponent("extension-state.json")
        try? FileManager.default.createDirectory(at: requestsDir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: responsesDir, withIntermediateDirectories: true)

        // Persist latest owned-tab state from background.js
        var tabState: [String: Any] = [
            "updatedAt": ISO8601DateFormatter().string(from: Date()),
            "extensionBundleId": "xyz.hieunguyen.PiCode.SafariExtension"
        ]
        if let tab = message["tabState"] as? [String: Any] {
            for (k, v) in tab { tabState[k] = v }
        }
        if let stateData = try? JSONSerialization.data(withJSONObject: tabState, options: [.prettyPrinted]) {
            try? stateData.write(to: stateFile, options: .atomic)
        }

        switch type {
        case "result":
            if let commandId = message["id"] as? String, !commandId.isEmpty {
                let responseFile = responsesDir.appendingPathComponent("\(commandId).json")
                if let data = try? JSONSerialization.data(withJSONObject: message, options: []) {
                    try? data.write(to: responseFile, options: .atomic)
                }
            }
            reply(context: context, payload: ["ok": true, "type": "ack"])

        case "poll", "heartbeat":
            let nextCommand = Self.dequeueNextRequest(in: requestsDir)
            if let nextCommand {
                logger.info("Dispatching Safari bridge command \(String(describing: nextCommand["id"]), privacy: .public)")
                reply(context: context, payload: [
                    "ok": true,
                    "type": "command",
                    "command": nextCommand
                ])
            } else {
                reply(context: context, payload: [
                    "ok": true,
                    "type": "idle"
                ])
            }

        default:
            reply(context: context, payload: [
                "ok": true,
                "type": "pong",
                "extension": "xyz.hieunguyen.PiCode.SafariExtension"
            ])
        }
    }

    private static func dequeueNextRequest(in requestsDir: URL) -> [String: Any]? {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: requestsDir,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return nil
        }
        let jsonFiles = files
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for file in jsonFiles {
            guard let data = try? Data(contentsOf: file),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                try? FileManager.default.removeItem(at: file)
                continue
            }
            try? FileManager.default.removeItem(at: file)
            return obj
        }
        return nil
    }

    private func reply(context: NSExtensionContext, payload: [String: Any]) {
        let response = NSExtensionItem()
        response.userInfo = [SFExtensionMessageKey: payload]
        context.completeRequest(returningItems: [response], completionHandler: nil)
    }
}
