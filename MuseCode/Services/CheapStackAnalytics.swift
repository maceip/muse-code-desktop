//
//  CheapStackAnalytics.swift
//  MuseCode
//
//  Optional, fail-open telemetry to the owner's cheap-stack ingest endpoint
//  (Cloud Run + BigQuery). Design rules:
//  - Disabled by default. Enabled only when a token is present in the
//    CHEAP_STACK_TOKEN environment variable or the `cheapStackToken`
//    user default. No token is ever baked into the app binary.
//  - Fail-open: every failure (offline, endpoint down, GCP account gone,
//    timeout) is swallowed. Analytics runs off the main thread, never
//    blocks launch or any user action, and has a 2-second timeout.
//  - Metadata only: event kind + scalar fields supplied by callers.
//    Callers must never pass prompt text, file contents, or secrets.
//

import Foundation

enum CheapStackAnalytics {
    private static let defaultBase = "https://cheap-stack-api-4mvkrnysdq-uc.a.run.app"
    private static let appName = "muse-desktop"

    private static var token: String? {
        if let env = ProcessInfo.processInfo.environment["CHEAP_STACK_TOKEN"], !env.isEmpty {
            return env
        }
        let stored = UserDefaults.standard.string(forKey: "cheapStackToken") ?? ""
        return stored.isEmpty ? nil : stored
    }

    private static var baseURL: String {
        ProcessInfo.processInfo.environment["CHEAP_STACK_URL"]
            ?? UserDefaults.standard.string(forKey: "cheapStackURL")
            ?? defaultBase
    }

    static var isEnabled: Bool { token != nil }

    /// Fire-and-forget event. `fields` values must be scalars (String/Number/Bool).
    static func event(_ kind: String, _ fields: [String: Any] = [:]) {
        guard let token else { return }
        guard let url = URL(string: "\(baseURL)/api/events/\(appName)") else { return }
        var merged = sessionFields
        for (k, v) in fields { merged[k] = v }
        merged["props"] = fields
        let detail = (try? JSONSerialization.data(withJSONObject: merged))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
        let body: [String: Any] = ["kind": kind, "detail": detail]
        guard let bodyData = try? JSONSerialization.data(withJSONObject: body) else { return }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 2
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = bodyData

        // Errors are intentionally ignored: analytics must never affect the app.
        URLSession.shared.dataTask(with: request) { _, _, _ in }.resume()
    }

    static func appLaunch() {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        event("app-launch", ["version": version, "os": ProcessInfo.processInfo.operatingSystemVersionString])
    }

    /// Stable anonymous id + 30-minute-idle session id, matching the SDK clients.
    private static var sessionFields: [String: Any] {
        let defaults = UserDefaults.standard
        let now = Date()
        if defaults.string(forKey: "cs.anonId") == nil {
            defaults.set(UUID().uuidString, forKey: "cs.anonId")
        }
        let last = defaults.double(forKey: "cs.sessionLast")
        var sessionId = defaults.string(forKey: "cs.sessionId")
        if sessionId == nil || now.timeIntervalSince1970 - last > 30 * 60 {
            sessionId = UUID().uuidString
            defaults.set(sessionId, forKey: "cs.sessionId")
            defaults.set(now.timeIntervalSince1970, forKey: "cs.sessionStart")
        }
        defaults.set(now.timeIntervalSince1970, forKey: "cs.sessionLast")
        let start = defaults.double(forKey: "cs.sessionStart")
        return [
            "sessionId": sessionId ?? "",
            "anonymousId": defaults.string(forKey: "cs.anonId") ?? "",
            "platform": "macos",
            "sessionMs": Int((now.timeIntervalSince1970 - start) * 1000),
        ]
    }
}
