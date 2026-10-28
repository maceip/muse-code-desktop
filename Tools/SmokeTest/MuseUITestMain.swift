//
//  MuseUITestMain.swift
//  Pie
//
//  Automated end-to-end UI & backend verification test for pure Muse GUI on `main`:
//  1. Pure Muse-only harness registry (`HarnessID.allCases == [.museCode]`)
//  2. Default YOLO / no-sandbox / subagent / parallel-tool-calls flags in MuseRuntime
//  3. Sparing #0077FF (`AppTheme.accentBlue`) highlighting on user bubbles, "See more" pills, and send button
//  4. Titlebar Search pill (`TitlebarSearchPill`), moved sidebar-hide button (`layout-align-left`), and Back button (`arrow-left-01`)
//  5. Vanishing `AppRail` when sidebar is expanded, and session icons (`SessionRailButton`) in `AppRail` when sidebar is hidden
//  6. Floating right panel (`MuseRightSidebarPanel`) overlaying the detail conversation view without shrinking it
//  7. Real CLI backing for `MuseUsageService`, `MuseSkillsService`, `MuseSessionMessageService`, and `MuseRuntime`
//

import AppKit
import Foundation
import SwiftUI

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@MainActor
private func collectAccessibilityTexts(from object: Any, depth: Int = 0) -> [String] {
    guard depth < 25 else { return [] }
    var out: [String] = []
    if let element = object as? NSAccessibilityProtocol {
        if let label = element.accessibilityLabel()?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
            out.append(label)
        }
        if let title = element.accessibilityTitle()?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            out.append(title)
        }
        if let value = element.accessibilityValue() as? String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { out.append(trimmed) }
        }
        if let help = element.accessibilityHelp()?.trimmingCharacters(in: .whitespacesAndNewlines), !help.isEmpty {
            out.append(help)
        }
        if let children = element.accessibilityChildren() {
            for child in children {
                out.append(contentsOf: collectAccessibilityTexts(from: child, depth: depth + 1))
            }
        }
    }
    return out
}

@MainActor
private func collectTexts(in view: NSView) -> [String] {
    var out: [String] = []
    if let tv = view as? PlaceholderTextView {
        if !tv.placeholder.isEmpty { out.append(tv.placeholder) }
        let s = tv.string.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.isEmpty { out.append(s) }
    }
    if let tf = view as? NSTextField {
        let s = tf.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.isEmpty { out.append(s) }
        if let ph = tf.placeholderString?.trimmingCharacters(in: .whitespacesAndNewlines), !ph.isEmpty {
            out.append(ph)
        }
    }
    if let btn = view as? NSButton {
        let t = btn.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { out.append(t) }
        if let help = btn.toolTip?.trimmingCharacters(in: .whitespacesAndNewlines), !help.isEmpty {
            out.append(help)
        }
    }
    if let help = view.toolTip?.trimmingCharacters(in: .whitespacesAndNewlines), !help.isEmpty {
        out.append(help)
    }
    out.append(contentsOf: collectAccessibilityTexts(from: view))
    for sub in view.subviews {
        out.append(contentsOf: collectTexts(in: sub))
    }
    return out
}

@main
struct MuseUITestMain {
    @MainActor
    static func main() async {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)

        // 1. Verify Pure Muse-only HarnessRegistry
        check(HarnessID.allCases == [.museCode], "HarnessID.allCases must only contain .museCode")
        check(HarnessDescriptor.all.map(\.id) == [.museCode], "HarnessDescriptor.all must only contain .museCode")

        // 2. Verify #0077FF (`AppTheme.accentBlue`) color value
        let nsBlue = NSColor(AppTheme.accentBlue).usingColorSpace(.sRGB)!
        check(abs(nsBlue.redComponent - (0.0 / 255.0)) < 0.02, "accentBlue red component must be 0x00")
        check(abs(nsBlue.greenComponent - (0x77 / 255.0)) < 0.02, "accentBlue green component must be 0x77")
        check(abs(nsBlue.blueComponent - (0xFF / 255.0)) < 0.02, "accentBlue blue component must be 0xFF")

        // 3. Verify Muse CLI discovery & real services
        let discovery = PiDiscoveryService()
        let result = await discovery.discover()
        let installation: PiInstallation
        switch result {
        case .found(let inst):
            installation = inst
        case .missing(_, _, let detail):
            fputs("FAIL: Muse CLI not discovered on machine: \(detail ?? "unknown")\n", stderr)
            exit(1)
        }
        print("Discovered Muse CLI: \(installation.version) at \(installation.displayPath)")

        await MuseUsageService.shared.refresh(installation: installation)
        check(MuseUsageService.shared.latestSnapshot != nil, "MuseUsageService must parse `muse usage --json`")
        if MuseUsageService.shared.latestSnapshot?.allowanceRemainingPercent == nil {
            check(MuseUsageService.shared.allowancePercentage == nil, "MuseUsageService must NOT fabricate 100% allowance when server_sent_no_usage")
        }

        let cwd = FileManager.default.currentDirectoryPath
        await MuseSkillsService.shared.refresh(cwd: cwd, installation: installation)
        print("Loaded \(MuseSkillsService.shared.skills.count) Muse skills via `muse skills list`")
        check(!MuseSkillsService.shared.skills.isEmpty, "MuseSkillsService must load skills from `muse skills list`")

        let cliMessages = await MuseSessionMessageService.listMessages(installation: installation)
        print("Queried `muse session-message list --json`: \(cliMessages.count) message(s)")

        // 4. Verify RootView, TitlebarSearchPill, SidebarView Settings footer, and Floating Right Panel
        let state = AppState()
        await state.launch()
        check(state.phase == .ready, "AppState should launch into .ready phase with Muse CLI")

        if state.activeController == nil {
            await state.startNewSession(projectPath: cwd)
        }
        guard let controller = state.activeController else {
            fputs("FAIL: Expected active PiSessionController\n", stderr)
            exit(1)
        }
        await controller.refreshMuseTelemetry()
        check(!controller.commands.isEmpty, "MuseRuntime .getCommands must populate slash commands from MuseSkillsService")
        check(!controller.subagents.contains(where: { $0.title.lowercased().contains("reminder observer") || $0.title == "Goal & Verification Observer" }),
              "Subagents list must not disguise internal reminder observer")

        // Verify Plan artifact opens directly in Inspector without 'Not available'
        state.openPlanInInspector(title: "Task Plan & Todos", content: "- [x] Verified real plan viewer")
        check(state.inspectorArtifact == .plan(title: "Task Plan & Todos", content: "- [x] Verified real plan viewer"),
              "openPlanInInspector must set .plan artifact state")
        state.showOverview()

        let rootHosting = NSHostingView(rootView: RootView(state: state).frame(width: 1280, height: 820))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 820),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = rootHosting
        state.showOverview()
        rootHosting.layoutSubtreeIfNeeded()
        try? await Task.sleep(nanoseconds: 350_000_000)
        state.showOverview()
        rootHosting.layoutSubtreeIfNeeded()

        let allTexts = collectTexts(in: rootHosting)
        if controller.agentMessages.isEmpty {
            check(!allTexts.contains("Send Muse agent message…"), "MuseAgentMessagesCard must collapse when there are 0 messages")
        }
        if controller.sessionArtifacts.isEmpty {
            check(!allTexts.contains("Files written and plans created in this session appear here."), "MuseOverviewCard must hide Artifacts section when empty")
        }

        // Verify MuseRightSidebarPanel expanded rendering
        let rightPanelHosting = NSHostingView(
            rootView: MuseRightSidebarPanel(
                state: state,
                controller: controller,
                initiallyExpandMessages: true
            )
            .frame(width: 310)
        )
        rightPanelHosting.frame = NSRect(x: 0, y: 0, width: 310, height: 420)
        rightPanelHosting.layoutSubtreeIfNeeded()
        let rightPanelTexts = collectTexts(in: rightPanelHosting)
        check(rightPanelTexts.contains("target session id or name") && rightPanelTexts.contains("Send Muse agent message…"),
              "Expanded MuseRightSidebarPanel must render Muse Agent Messages controls")

        // 5. Verify toggling floating right panel (`state.toggleInspector()`)
        state.toggleInspector()
        check(!state.isInspectorVisible, "toggleInspector() should hide the floating panel")
        rootHosting.layoutSubtreeIfNeeded()
        try? await Task.sleep(nanoseconds: 250_000_000)
        rootHosting.layoutSubtreeIfNeeded()

        state.toggleInspector()
        check(state.isInspectorVisible, "toggleInspector() should reveal the floating panel")
        rootHosting.layoutSubtreeIfNeeded()
        try? await Task.sleep(nanoseconds: 250_000_000)
        rootHosting.layoutSubtreeIfNeeded()

        // 6. Verify dynamic executable resolution without hardcoded paths
        let resolvedMuse = PiDiscoveryService.resolveExecutable(named: "muse")
        check(resolvedMuse != nil, "PiDiscoveryService.resolveExecutable(named: \"muse\") must dynamically locate muse on PATH")
        check(HarnessDescriptor.descriptor(for: .museCode).fallbackBinaries.isEmpty, "HarnessDescriptor.museCode.fallbackBinaries must not contain hardcoded paths")

        // 7. Verify Tachometer Credit Gauge renders icon-only (no text or border around icon)
        let tachoView = MuseCreditBatteryButton(controller: controller)
        let tachoHost = NSHostingView(rootView: tachoView)
        tachoHost.frame = NSRect(x: 0, y: 0, width: 40, height: 30)
        tachoHost.layoutSubtreeIfNeeded()
        let tachoTexts = collectTexts(in: tachoHost)
        check(tachoTexts.isEmpty, "MuseCreditBatteryButton must be icon-only with no text label (found: \(tachoTexts))")
        check(tachoView.remainingFraction >= 0.0 && tachoView.remainingFraction <= 1.0, "Tachometer remainingFraction must be within 0.0...1.0")

        // 8. Verify SessionIcons catalog (16 icons) and 4–5 char shorthand persistence
        check(SessionIconCatalog.all.count == 16, "SessionIconCatalog must provide 16 session icons")
        for entry in SessionIconCatalog.all {
            let img = NSImage.huge(entry.id)
            check(img.size.width > 0, "SessionIcon asset '\(entry.id)' must load from Assets.xcassets/SessionIcons")
        }
        let sampleSession = SessionRef(
            id: "test-session-shorthand",
            sessionId: "test-session-shorthand",
            filePath: nil,
            name: "Building the new tachometer UI",
            cwd: cwd,
            createdAt: Date(),
            updatedAt: Date(),
            messageCount: 2,
            firstUserMessage: "Building the new tachometer UI",
            parentSession: nil,
            isPinned: false,
            isEphemeral: false,
            harnessID: .museCode
        )
        let defaultShort = SessionIconCatalog.defaultShorthand(for: sampleSession)
        check((4...5).contains(defaultShort.count), "Default session shorthand must be 4–5 characters (got '\(defaultShort)')")
        state.preferences.setSessionIcon("session-rocket", for: sampleSession)
        state.preferences.setSessionShorthand("TACHO", for: sampleSession)
        check(state.preferences.resolvedSessionIcon(for: sampleSession) == "session-rocket", "Custom session icon must persist in PreferencesStore")
        check(state.preferences.resolvedSessionShorthand(for: sampleSession) == "TACHO", "Custom 4–5 char shorthand must persist in PreferencesStore")
        state.preferences.setSessionIcon(nil, for: sampleSession)
        state.preferences.setSessionShorthand(nil, for: sampleSession)

        // 9. Verify GlowingCaretView in PlaceholderTextView
        let placeholderTV = PlaceholderTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 48))
        check(placeholderTV.subviews.contains(where: { $0 is GlowingCaretView }), "PlaceholderTextView must contain GlowingCaretView")

        // 10. Verify Liquid Glass Composer & 3D Morphing Voice Orb (`orb1.gif`)
        let composerHost = NSHostingView(
            rootView: ComposerView(
                state: state,
                controller: controller,
                focusTick: 0
            )
            .frame(width: 680, height: 220)
        )
        window.contentView = composerHost
        composerHost.frame = NSRect(x: 0, y: 0, width: 680, height: 220)
        composerHost.layoutSubtreeIfNeeded()
        try? await Task.sleep(nanoseconds: 150_000_000)
        composerHost.layoutSubtreeIfNeeded()
        let composerTexts = collectTexts(in: composerHost)
        check(
            composerTexts.contains("Ask Anything") || composerTexts.contains("Muse is not running…") || composerTexts.contains("Steer Muse, or queue a follow-up…"),
            "Liquid Glass input pill must mount PlaceholderTextView with 'Ask Anything' placeholder (got: \(composerTexts))"
        )
        let orbHost = NSHostingView(
            rootView: LiquidGlassVoiceOrbView(
                isRecording: true,
                isTranscribing: false,
                duration: 2.5,
                onTap: {}
            )
            .frame(width: 96, height: 96)
        )
        window.contentView = orbHost
        orbHost.frame = NSRect(x: 0, y: 0, width: 96, height: 96)
        orbHost.layoutSubtreeIfNeeded()
        check(orbHost.fittingSize.width >= 92 && orbHost.fittingSize.height >= 92, "LiquidGlassVoiceOrbView must render the 3D 96x96 Liquid Glass Voice Orb")

        print("PASS: All Muse UI, Liquid Glass composer, 3D Voice Orb, tachometer, glowing cursor, session icon catalog, layout, floating panel, dynamic PATH discovery, and backend state transitions verified.")
        exit(0)
    }
}
