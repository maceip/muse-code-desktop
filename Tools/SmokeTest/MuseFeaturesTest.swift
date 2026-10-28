import Foundation

@main
enum MuseFeaturesTest {
    static func main() async {
        var failures: [String] = []
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            if !condition() {
                failures.append(message)
                fputs("FAIL: \(message)\n", stderr)
            } else {
                print("PASS: \(message)")
            }
        }

        // 1. Verify YOLO mode, no sandbox, no approval, parallel tool calls, and subagent worktree isolation by default
        let trust = ProjectTrustService()
        check(trust.defaultProjectTrust() == "always", "Default project trust is 'always' (YOLO mode)")
        check(trust.state(for: "/tmp/nonexistent-project") == .trusted, "Arbitrary project defaults to .trusted")
        check(trust.effectiveTrust(cwd: "/tmp/nonexistent-project") == true, "Effective trust defaults to true")
        let launchArgs = trust.launchArguments(cwd: "/tmp/nonexistent-project")
        for flag in ["--yolo", "--disable-sandbox", "--disable-approval", "--parallel-tool-calls", "--subagent-worktree-isolation", "--trust-workspace"] {
            check(launchArgs.contains(flag), "Default launch arguments contain \(flag)")
        }

        // 2. Verify real Muse session subagent, artifact, background task, and agent message parsing
        let sessionsRoot = PiPaths.sessionsDirectory
        var totalSubagents = 0
        var totalArtifacts = 0
        var totalMessages = 0
        if let enumerator = FileManager.default.enumerator(at: sessionsRoot, includingPropertiesForKeys: nil) {
            while let url = enumerator.nextObject() as? URL {
                guard url.lastPathComponent == "session.jsonl",
                      !url.path.contains("/subagent/") else { continue }
                let summary = MuseSessionHistory.loadSummary(at: url.path)
                totalSubagents += summary.subagents.count
                totalArtifacts += summary.artifacts.count
                totalMessages += summary.agentMessages.count
            }
        }
        print("INFO: Parsed \(totalSubagents) subagents, \(totalArtifacts) artifacts, \(totalMessages) agent messages across real Muse sessions")
        check(totalSubagents > 0, "Discovered real Muse subagents from ~/.local/share/muse/sessions")
        check(totalArtifacts > 0, "Discovered real Muse artifacts from ~/.local/share/muse/sessions")
        check(totalMessages > 0, "Discovered real Muse agent messages from ~/.local/share/muse/sessions")

        // 3. Verify MuseUsageService battery calculation and live CLI query
        let usage = await MainActor.run { MuseUsageService.shared }
        await usage.refresh(installation: nil)
        let fullBattery = await MainActor.run {
            usage.batteryPercentage(contextUsagePercent: 0, sessionTokens: 0, contextWindow: 1_000_000)
        }
        let drainedBattery = await MainActor.run {
            usage.batteryPercentage(contextUsagePercent: 35.0, sessionTokens: 350_000, contextWindow: 1_000_000)
        }
        check(fullBattery == 100, "Fresh session battery starts at 100% (got \(fullBattery)%)")
        check(drainedBattery == 65, "Session with 35% context used shows 65% battery remaining (got \(drainedBattery)%)")

        // 4. Verify MuseSkillsService loads real skills from `muse skills list`
        let skills = await MuseSkillsService.loadSkills(workspace: FileManager.default.currentDirectoryPath, installation: nil)
        print("INFO: Loaded \(skills.count) Muse skills via `muse skills list`")
        check(!skills.isEmpty, "Loaded real skills from `muse skills list`")

        if !failures.isEmpty {
            fputs("\n\(failures.count) check(s) failed.\n", stderr)
            exit(1)
        }
        print("\nAll Muse feature checks passed.")
    }
}
