//
//  PiDiscoveryService.swift
//  PiCode
//
//  Resolves the user's installed `muse` executable and its login-shell PATH.
//

import Darwin
import Foundation

enum PiDiscoveryResult: Equatable {
    case found(PiInstallation)
    case missing(searched: [String], shellPath: String?, detail: String?)
}

struct PiDiscoveryService {
    /// Resolves the current user's login shell from `$SHELL` or the POSIX account database (`getpwuid`).
    static func userLoginShell() -> String {
        if let envShell = ProcessInfo.processInfo.environment["SHELL"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !envShell.isEmpty {
            return envShell
        }
        if let pw = getpwuid(getuid()), let shellPtr = pw.pointee.pw_shell {
            let pwShell = String(cString: shellPtr).trimmingCharacters(in: .whitespacesAndNewlines)
            if !pwShell.isEmpty {
                return pwShell
            }
        }
        return "sh"
    }

    /// Queries POSIX `_CS_PATH` so no system PATH directories are hardcoded.
    static func posixSystemPath() -> String {
        let length = confstr(_CS_PATH, nil, 0)
        guard length > 0 else { return ProcessInfo.processInfo.environment["PATH"] ?? "" }
        var buffer = [CChar](repeating: 0, count: length)
        confstr(_CS_PATH, &buffer, length)
        return String(cString: buffer)
    }

    /// Ordered, deduplicated search directories from the login shell PATH, process environment PATH, and POSIX `_CS_PATH`.
    static func searchDirectories(shellPath: String? = nil) -> [String] {
        let envPath = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let sysPath = posixSystemPath()
        let combined = [shellPath ?? "", envPath, sysPath].joined(separator: ":")
        var seen = Set<String>()
        var result: [String] = []
        for raw in combined.split(separator: ":") {
            let dir = String(raw).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !dir.isEmpty, seen.insert(dir).inserted else { continue }
            result.append(dir)
        }
        return result
    }

    /// Dynamically resolves any executable by name across the user's PATH without hardcoding binary paths.
    static func resolveExecutable(named binaryName: String, shellPath: String? = nil) -> URL? {
        for dir in searchDirectories(shellPath: shellPath) {
            let candidate = URL(fileURLWithPath: dir, isDirectory: true)
                .appendingPathComponent(binaryName)
            if FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    /// PATH used to launch Muse: the login-shell PATH with the executable's own
    /// directory first.
    static func launchEnvironment(executable: URL, shellPath: String?) -> [String: String] {
        let directory = executable.deletingLastPathComponent().path
        let entries = searchDirectories(shellPath: shellPath)
            .filter { $0 != directory }
        let path = ([directory] + entries).joined(separator: ":")
        return ["PATH": path]
    }

    var timeout: TimeInterval = 20

    func discover() async -> PiDiscoveryResult {
        let shell = Self.userLoginShell()
        let shellPath = await loginShellPath(shell: shell)

        var searched: [String] = []
        var detail: String?

        if let located = await loginShellWhich(shell: shell) {
            searched.append(located)
            if let installation = await makeInstallation(
                path: located,
                shellPath: shellPath,
                shell: shell,
                origin: "login shell"
            ) {
                return .found(installation)
            }
            detail = "The login shell reported \(located) but it could not be executed."
        } else {
            detail = "The login shell did not report a `muse` executable."
        }

        let candidates = Self.searchDirectories(shellPath: shellPath).map {
            URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent("muse").path
        }
        for candidate in candidates {
            guard !searched.contains(candidate) else { continue }
            searched.append(candidate)
            guard FileManager.default.isExecutableFile(atPath: candidate) else { continue }
            if let installation = await makeInstallation(
                path: candidate,
                shellPath: shellPath,
                shell: shell,
                origin: "PATH scan"
            ) {
                return .found(installation)
            }
        }

        return .missing(searched: searched, shellPath: shellPath, detail: detail)
    }

    /// Verifies `muse --version` runs before handing the path to the runtime.
    private func makeInstallation(path: String,
                                  shellPath: String?,
                                  shell: String,
                                  origin: String) async -> PiInstallation? {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        guard let version = await version(at: url, shellPath: shellPath) else { return nil }
        return PiInstallation(
            executableURL: url,
            version: version.trimmingCharacters(in: .whitespacesAndNewlines),
            shellPath: shellPath,
            shell: shell,
            origin: origin
        )
    }

    func version(at executable: URL, shellPath: String?) async -> String? {
        let result = await run(
            executable: executable,
            arguments: ["--version"],
            directory: URL(fileURLWithPath: NSHomeDirectory()),
            environment: Self.launchEnvironment(executable: executable, shellPath: shellPath)
        )
        guard result.exitCode == 0 else { return nil }
        let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? nil : output
    }

    // MARK: - Shell probing

    private func loginShellWhich(shell: String) async -> String? {
        let result = await run(
            executable: URL(fileURLWithPath: shell),
            arguments: ["-lc", "command -v muse"],
            directory: URL(fileURLWithPath: NSHomeDirectory()),
            environment: nil
        )
        guard result.exitCode == 0 else { return nil }
        let path = result.stdout
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty }
        guard let path, path.hasPrefix("/") else { return nil }
        return path
    }

    private func loginShellPath(shell: String) async -> String? {
        let result = await run(
            executable: URL(fileURLWithPath: shell),
            arguments: ["-lc", "printf %s \"$PATH\""],
            directory: URL(fileURLWithPath: NSHomeDirectory()),
            environment: nil
        )
        guard result.exitCode == 0 else { return nil }
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }

    // MARK: - Direct process execution

    struct CommandResult {
        var stdout: String
        var stderr: String
        var exitCode: Int32
    }

    /// Runs a short-lived helper process.
    func run(executable: URL,
             arguments: [String],
             directory: URL,
             environment: [String: String]?) async -> CommandResult {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = executable
                process.arguments = arguments
                process.currentDirectoryURL = directory
                if let environment {
                    var merged = ProcessInfo.processInfo.environment
                    for (key, value) in environment { merged[key] = value }
                    process.environment = merged
                }

                let outPipe = Pipe()
                let errPipe = Pipe()
                process.standardOutput = outPipe
                process.standardError = errPipe
                process.standardInput = FileHandle.nullDevice

                var stdout = Data()
                var stderr = Data()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    stdout = (try? outPipe.fileHandleForReading.readToEnd()) ?? Data()
                    group.leave()
                }
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    stderr = (try? errPipe.fileHandleForReading.readToEnd()) ?? Data()
                    group.leave()
                }

                var exitCode: Int32 = -1
                do {
                    try process.run()
                    process.waitUntilExit()
                    exitCode = process.terminationStatus
                } catch {
                    stderr.append(Data(error.localizedDescription.utf8))
                }
                _ = group.wait(timeout: .now() + 5)

                continuation.resume(returning: CommandResult(
                    stdout: String(data: stdout, encoding: .utf8) ?? "",
                    stderr: String(data: stderr, encoding: .utf8) ?? "",
                    exitCode: exitCode
                ))
            }
        }
    }
}
