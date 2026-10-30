//
//  PiCode path-resolution smoke test (Muse).
//
//  Checks `PiPaths` resolution for Muse's config (`~/.config/muse`) and session
//  directory (`~/.local/share/muse/sessions`), including `MUSE_HOME`,
//  `MUSE_SESSION_DIR`, and `settings.json` `sessionDir` overrides.
//
//      ./Tools/SmokeTest/run-paths.sh
//

import Foundation

@main
enum PiPathsTest {
    static func main() async {
        if CommandLine.arguments.contains("--resolve") {
            print(PiPaths.agentDirectory.path)
            print(PiPaths.sessionsDirectory.path)
            exit(0)
        }
        exit(await run())
    }
}

@MainActor
func run() async -> Int32 {
    var failures = 0
    func check(_ name: String, _ condition: Bool, _ detail: String = "") {
        if condition {
            print("  ok   \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        } else {
            failures += 1
            print("  FAIL \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        }
    }

    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("picode-paths-test-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    func resolve(_ environment: [String: String] = [:]) -> (agent: String, sessions: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["--resolve"]
        var env: [String: String] = ["HOME": NSHomeDirectory(), "PATH": "/usr/bin:/bin"]
        for (key, value) in environment { env[key] = value }
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            print("  FAIL could not re-launch harness: \(error)")
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let lines = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        guard lines.count >= 2 else { return nil }
        return (lines[0], lines[1])
    }

    func sessionDirInSettings(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url),
              let value = try? JSONCoding.decode(data),
              let raw = value["sessionDir"]?.stringValue,
              !raw.isEmpty
        else { return nil }
        return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath).standardizedFileURL.path
    }

    print("== default resolution (no overrides) ==")
    let defaultAgent = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/muse")
    let defaultSessions = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".local/share/muse/sessions")
    if let resolved = resolve() {
        check("agent directory is ~/.config/muse", resolved.agent == defaultAgent.path, resolved.agent.abbreviatingHomeDirectory)
        let expectedSessions = sessionDirInSettings(at: defaultAgent.appendingPathComponent("settings.json"))
            ?? defaultSessions.path
        check("session directory matches Muse's rules", resolved.sessions == expectedSessions,
              resolved.sessions.abbreviatingHomeDirectory)
    } else {
        check("default resolution available", false)
    }

    print("== MUSE_HOME ==")
    let agentOnly = root.appendingPathComponent("agent-only", isDirectory: true)
    try? FileManager.default.createDirectory(at: agentOnly, withIntermediateDirectories: true)
    if let resolved = resolve(["MUSE_HOME": agentOnly.path]) {
        check("agent directory follows MUSE_HOME", resolved.agent == agentOnly.standardizedFileURL.path, resolved.agent)
        check("session directory follows MUSE_HOME",
              resolved.sessions == agentOnly.appendingPathComponent("sessions").path, resolved.sessions)
    }

    print("== MUSE_SESSION_DIR ==")
    let sessionOverride = root.appendingPathComponent("env-sessions", isDirectory: true)
    if let resolved = resolve([
        "MUSE_HOME": agentOnly.path,
        "MUSE_SESSION_DIR": sessionOverride.path
    ]) {
        check("session directory follows MUSE_SESSION_DIR", resolved.sessions == sessionOverride.standardizedFileURL.path, resolved.sessions)
    }

    print("== settings.json sessionDir ==")
    let configured = root.appendingPathComponent("configured-sessions", isDirectory: true)
    let settingsAgent = root.appendingPathComponent("agent-settings", isDirectory: true)
    try? FileManager.default.createDirectory(at: settingsAgent, withIntermediateDirectories: true)
    let settingsJSON = "{\n  \"sessionDir\": \"\(configured.path)\"\n}\n"
    try? settingsJSON.data(using: .utf8)?.write(to: settingsAgent.appendingPathComponent("settings.json"))
    if let resolved = resolve(["MUSE_HOME": settingsAgent.path]) {
        check("session directory follows settings.json",
              resolved.sessions == configured.standardizedFileURL.path, resolved.sessions)
    }
    if let resolved = resolve([
        "MUSE_HOME": settingsAgent.path,
        "MUSE_SESSION_DIR": sessionOverride.path
    ]) {
        check("environment beats settings.json", resolved.sessions == sessionOverride.standardizedFileURL.path, resolved.sessions)
    }

    print("== input sanitizing ==")
    if let resolved = resolve(["MUSE_HOME": "~/picode-paths-tilde"]) {
        let expected = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("picode-paths-tilde").path
        check("tilde is expanded", resolved.agent == expected, resolved.agent.abbreviatingHomeDirectory)
    }
    if let resolved = resolve(["MUSE_SESSION_DIR": "relative/sessions"]) {
        check("relative session directory is ignored, not guessed",
              resolved.sessions == defaultSessions.path
                || resolved.sessions == (sessionDirInSettings(at: defaultAgent.appendingPathComponent("settings.json")) ?? ""),
              resolved.sessions.abbreviatingHomeDirectory)
    }

    print("== MUSE_DATA_DIR & XDG_DATA_HOME & XDG_CONFIG_HOME ==")
    let customDataDir = root.appendingPathComponent("custom-muse-data", isDirectory: true)
    if let resolved = resolve(["MUSE_DATA_DIR": customDataDir.path]) {
        check("session directory follows MUSE_DATA_DIR/sessions",
              resolved.sessions == customDataDir.appendingPathComponent("sessions").standardizedFileURL.path,
              resolved.sessions)
    }
    let xdgDataHome = root.appendingPathComponent("xdg-data", isDirectory: true)
    let xdgConfigHome = root.appendingPathComponent("xdg-config", isDirectory: true)
    if let resolved = resolve([
        "XDG_DATA_HOME": xdgDataHome.path,
        "XDG_CONFIG_HOME": xdgConfigHome.path
    ]) {
        check("agent directory follows XDG_CONFIG_HOME/muse",
              resolved.agent == xdgConfigHome.appendingPathComponent("muse").standardizedFileURL.path,
              resolved.agent)
        check("session directory follows XDG_DATA_HOME/muse/sessions",
              resolved.sessions == xdgDataHome.appendingPathComponent("muse/sessions").standardizedFileURL.path,
              resolved.sessions)
    }

    print("== login shell profile (.zshrc) dynamic discovery ==")
    let fakeHome = root.appendingPathComponent("fake-user-home", isDirectory: true)
    let profileSessions = fakeHome.appendingPathComponent("relocated-muse-sessions", isDirectory: true)
    let profileConfig = fakeHome.appendingPathComponent("relocated-muse-config", isDirectory: true)
    try? FileManager.default.createDirectory(at: fakeHome, withIntermediateDirectories: true)
    let zshrc = """
    export MUSE_CONFIG_DIR="\(profileConfig.path)"
    export MUSE_SESSION_DIR="\(profileSessions.path)"
    """
    try? zshrc.data(using: .utf8)?.write(to: fakeHome.appendingPathComponent(".zshrc"))
    if let resolved = resolve(["HOME": fakeHome.path]) {
        check("GUI app without env vars discovers MUSE_CONFIG_DIR from ~/.zshrc",
              resolved.agent == profileConfig.standardizedFileURL.path,
              resolved.agent)
        check("GUI app without env vars discovers MUSE_SESSION_DIR from ~/.zshrc",
              resolved.sessions == profileSessions.standardizedFileURL.path,
              resolved.sessions)
    }

    print(failures == 0 ? "RESULT: all checks passed" : "RESULT: \(failures) check(s) failed")
    return failures == 0 ? 0 : 1
}
