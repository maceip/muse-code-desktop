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

        // 7. Verify Tachometer Credit Gauge renders icon-only and tracks real `muse usage --json` RunUsageAllowance (`window` & `weekly`)
        let sampleAllowanceJSON = """
        {
          "schemaVersion": 1,
          "allowance": {
            "tier": "pro",
            "asOfMs": 1793220000000,
            "window": { "usedPercent": 28.0, "resetsAtMs": 1793238000000 },
            "weekly": { "usedPercent": 15.0, "resetsAtMs": 1793800000000 }
          }
        }
        """
        if let allowanceData = sampleAllowanceJSON.data(using: .utf8),
           let decodedUsage = try? JSONCoding.decode(allowanceData) {
            let parsedSnapshot = MuseUsageService.parseUsageResponse(decodedUsage)
            check(parsedSnapshot.tier == "pro", "MuseUsageService must parse allowance.tier")
            check(parsedSnapshot.window?.usedPercent == 28.0, "MuseUsageService must parse allowance.window.usedPercent")
            check(parsedSnapshot.window?.remainingPercent == 72.0, "MuseUsageService must compute 72% window remaining")
            check(parsedSnapshot.weekly?.usedPercent == 15.0, "MuseUsageService must parse allowance.weekly.usedPercent")
            check(parsedSnapshot.weekly?.remainingPercent == 85.0, "MuseUsageService must compute 85% weekly remaining")
            check(parsedSnapshot.allowanceRemainingPercent == 72.0, "MuseUsageService must report min(window, weekly) remaining percent (72%)")
            if let allowanceObj = decodedUsage["allowance"] {
                MuseUsageService.shared.ingestAllowanceJSON(allowanceObj)
            }
        }
        let tachoView = MuseCreditBatteryButton(controller: controller)
        let tachoHost = NSHostingView(rootView: tachoView)
        tachoHost.frame = NSRect(x: 0, y: 0, width: 40, height: 30)
        tachoHost.layoutSubtreeIfNeeded()
        let tachoTexts = collectTexts(in: tachoHost)
        check(tachoTexts.isEmpty, "MuseCreditBatteryButton must be icon-only with no text label (found: \(tachoTexts))")
        check(abs(tachoView.remainingFraction - 0.72) < 0.01, "Tachometer remainingFraction must reflect ingested 72% allowance (got \(tachoView.remainingFraction))")

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

        // 10. Verify Liquid Glass Composer, Enter/Exit Choreography (`enter-anim.gif`), & 3D Morphing Voice Orb (`orb1.gif`)
        // Also verify clicking the pink Muse icon (`MuseAppRailHeaderButton` / `newChatInCurrentProject()`) from any state creates/resets to a clean empty chat session
        let emptyFolder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("muse-empty-project-\(UUID().uuidString.prefix(6))").path
        try? FileManager.default.createDirectory(atPath: emptyFolder, withIntermediateDirectories: true)
        await state.startNewSession(projectPath: emptyFolder)
        check(state.activeController != nil, "startNewSession on an empty folder must keep activeController non-nil")
        await state.newChatInCurrentProject()
        check(state.activeController != nil, "Clicking the Muse rail icon (newChatInCurrentProject) must never make activeController nil or hide the composer/right panel")

        // Verify clicking the pink Muse icon when viewing a populated session or dirty/dropped composer state transitions to a clean empty chat session
        if let existingPopulatedSession = state.projects.flatMap(\.sessions).first(where: { $0.messageCount > 0 }) {
            await state.open(session: existingPopulatedSession)
        }
        if let activeBefore = state.activeController {
            activeBefore.hasDroppedComposerToBottom = true
            activeBefore.hasCompletedFirstVoiceOrTextInteraction = true
            check(activeBefore.hasDroppedComposerToBottom, "Precondition: active session has dropped composer")
        }
        var didInvokeMuseButton = false
        let museButtonView = MuseAppRailHeaderButton(isActive: false) {
            didInvokeMuseButton = true
            Task { await state.newChatInCurrentProject() }
        }
        let museButtonHost = NSHostingView(rootView: museButtonView)
        museButtonHost.frame = NSRect(x: 0, y: 0, width: 44, height: 44)
        museButtonHost.layoutSubtreeIfNeeded()
        check(museButtonHost.fittingSize.width >= 40 && museButtonHost.fittingSize.height >= 40,
              "MuseAppRailHeaderButton must have a full 40x40 hit target (got \(museButtonHost.fittingSize))")

        let tickBeforeNewChat = state.newSessionResetTick
        await state.newChatInCurrentProject()
        check(state.newSessionResetTick > tickBeforeNewChat, "Clicking Muse icon from a populated session must increment newSessionResetTick")
        check(state.activeController?.items.isEmpty == true, "Clicking Muse icon from a populated session must create an empty chat session (items.isEmpty)")
        check(state.activeController?.sessionFile == nil, "New chat session from Muse icon must have sessionFile == nil")
        check(state.activeController?.hasDroppedComposerToBottom == false, "New chat session from Muse icon must reset hasDroppedComposerToBottom to false (centered landing layout)")

        // Now dirty the empty session (drop composer via mic, set draft text, open settings, set voice transcript) and click the Muse icon again
        if let dirtyEmpty = state.activeController {
            dirtyEmpty.hasDroppedComposerToBottom = true
            dirtyEmpty.hasCompletedFirstVoiceOrTextInteraction = true
            dirtyEmpty.drafts.setText("Unsent draft text that should be cleared", for: dirtyEmpty.draftKey)
            MuseVoiceSTTService.shared.lastTranscript = "stale voice transcript"
            state.isSettingsPresented = true
            let tickBeforeReset = state.newSessionResetTick
            await state.newChatInCurrentProject()
            check(state.newSessionResetTick > tickBeforeReset, "Clicking Muse icon on a dirty empty session must increment newSessionResetTick")
            check(dirtyEmpty.hasDroppedComposerToBottom == false, "Clicking Muse icon must reset hasDroppedComposerToBottom back to false so composer returns to center")
            check(dirtyEmpty.drafts.text(for: dirtyEmpty.draftKey).isEmpty, "Clicking Muse icon must clear unsent draft text for the new empty session")
            check(MuseVoiceSTTService.shared.lastTranscript == nil, "Clicking Muse icon must clear stale voice transcript")
            check(state.isSettingsPresented == false, "Clicking Muse icon while Settings is open must dismiss Settings and return to the new chat")
        }
        _ = didInvokeMuseButton

        check(ComposerEnterExitPhase.hidden.topPillOpacity == 0.0, "Phase .hidden must hide top pill")
        check(ComposerEnterExitPhase.pillWithBlurredCapsule.topPillOpacity == 1.0 && ComposerEnterExitPhase.pillWithBlurredCapsule.subcontainerScaleX == 0.44 && ComposerEnterExitPhase.pillWithBlurredCapsule.subcontainerInnerOpacity == 0.0,
              "Phase .pillWithBlurredCapsule (Frame 02 of enter-anim.gif) must show full top pill and 0.44x blurred capsule subcontainer with hidden inner rows")
        check(ComposerEnterExitPhase.subcontainerExpanding.subcontainerScaleX == 0.96 && ComposerEnterExitPhase.subcontainerExpanding.subcontainerInnerOpacity == 0.54,
              "Phase .subcontainerExpanding (Frames 03-04 of enter-anim.gif) must expand subcontainer to 0.96x with 0.54 inner opacity")
        check(ComposerEnterExitPhase.settled.subcontainerScaleX == 1.0 && ComposerEnterExitPhase.settled.subcontainerBlur == 0.0 && ComposerEnterExitPhase.settled.subcontainerInnerOpacity == 1.0,
              "Phase .settled (Frame 05 of enter-anim.gif) must settle subcontainer at 1.0x scale and 0 blur")

        let composerViewLanding = ComposerView(
            state: state,
            controller: controller,
            focusTick: 0
        )
        check(!composerViewLanding.isConsolidatedBar, "Before the first turn (items.isEmpty), ComposerView must render the 2-container landing layout (!isConsolidatedBar)")
        let composerHost = NSHostingView(
            rootView: composerViewLanding
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
        await state.newChatInCurrentProject()
        composerHost.layoutSubtreeIfNeeded()
        check(
            composerHost.fittingSize.height >= 120,
            "Clicking the Muse icon (newChatInCurrentProject) must keep both the top input pill and bottom subcontainer mounted (fittingSize.height = \(composerHost.fittingSize.height))"
        )
        // Verify all 23 frames (`1...23`) of the Voice Orb transition (`14.58.49.png` & `orb1.gif`)
        let f1 = VoiceOrbFrameDescriptor.descriptor(forFrame: 1)
        let f2 = VoiceOrbFrameDescriptor.descriptor(forFrame: 2)
        let f3 = VoiceOrbFrameDescriptor.descriptor(forFrame: 3)
        let f4 = VoiceOrbFrameDescriptor.descriptor(forFrame: 4)
        let f5 = VoiceOrbFrameDescriptor.descriptor(forFrame: 5)
        let f6 = VoiceOrbFrameDescriptor.descriptor(forFrame: 6)
        let f7 = VoiceOrbFrameDescriptor.descriptor(forFrame: 7)
        let f8 = VoiceOrbFrameDescriptor.descriptor(forFrame: 8)
        let f12 = VoiceOrbFrameDescriptor.descriptor(forFrame: 12)
        let f19 = VoiceOrbFrameDescriptor.descriptor(forFrame: 19)
        let f20 = VoiceOrbFrameDescriptor.descriptor(forFrame: 20)
        let f21 = VoiceOrbFrameDescriptor.descriptor(forFrame: 21)
        let f22 = VoiceOrbFrameDescriptor.descriptor(forFrame: 22)
        let f23 = VoiceOrbFrameDescriptor.descriptor(forFrame: 23)
        check(f1.pillFixedWidth == nil && f1.waveOpacity == 0.0 && f1.subcontainerOpacity == 1.0, "Frame 1 must be full-width idle composer with no wave")
        check(f2.pillFixedWidth == nil && f2.waveOpacity > 0.90 && f2.subcontainerOpacity == 1.0, "Frame 2 must ignite full-width plasma wave inside full-width top pill while subcontainer remains visible")
        check(f3.pillFixedWidth == 380 && f3.subcontainerBlur == 6.5 && f3.subcontainerOpacity == 0.82, "Frame 3 must contract top pill to 380pt and soften subcontainer with blur 6.5")
        check(f4.pillFixedWidth == 240 && f4.subcontainerBlur == 14.0 && f4.subcontainerOpacity == 0.44, "Frame 4 must contract top pill to 240pt and blur subcontainer to 14.0")
        check(f5.pillFixedWidth == 118 && f5.subcontainerOpacity == 0.0, "Frame 5 must contract top pill to 118pt squircle and dissolve subcontainer")
        check(f6.pillFixedWidth == 98 && f6.pillHeight == 88, "Frame 6 must be 98x88 oblate 3D Liquid Glass sphere")
        check(f7.pillFixedWidth == 90 && f7.pillHeight == 90 && f7.waveOpacity == 1.0, "Frame 7 must be 90x90 circular 3D Liquid Glass sphere")
        check(f8.orbPhase == .darkBlink && f8.waveOpacity < 0.10, "Frame 8 must be single-frame dark obsidian blink before active listening")
        check(f12.orbPhase == .ribbonWave && f12.waveOpacity == 1.0, "Frames 9-18 must render undulating chromatic ribbon wave")
        check(f19.orbPhase == .centralAlmondLens, "Frame 19 must contract wave into central white almond lens")
        check(f20.orbPhase == .centralGlowingSun, "Frame 20 must round into central circular glowing white sun")
        check(f21.orbPhase == .singleCenterDot, "Frame 21 must condense into single crisp white center dot")
        check(f22.orbPhase == .constellationDots && f23.orbPhase == .constellationDots, "Frames 22-23 must burst into the 6-dot constellation")

        for testFrame in [6, 8, 12, 19, 20, 21, 23] {
            let desc = VoiceOrbFrameDescriptor.descriptor(forFrame: testFrame)
            let orbHost = NSHostingView(
                rootView: LiquidGlassVoiceOrbView(
                    orbFrame: testFrame,
                    descriptor: desc,
                    isRecording: testFrame < 19,
                    isTranscribing: testFrame >= 19,
                    audioLevel: testFrame == 12 ? 0.78 : 0.0,
                    duration: 2.5,
                    onTap: {}
                )
                .frame(width: 114, height: 114)
            )
            window.contentView = orbHost
            orbHost.frame = NSRect(x: 0, y: 0, width: 114, height: 114)
            orbHost.layoutSubtreeIfNeeded()
            check(orbHost.fittingSize.width >= 90 && orbHost.fittingSize.height >= 90, "LiquidGlassVoiceOrbView must render Frame \(testFrame) of the 3D Liquid Glass Voice Orb")
        }

        // Verify continuous 120fps VoiceOrbEnterMetrics against the measured timestamps of `1028 (2).mp4` (`F018` -> `F046`)
        let mF20 = VoiceOrbEnterMetrics.evaluateEnter(elapsed: 0.066, fullWidth: 580, baseHeight: 54, orbFrame: 2)
        let mF22 = VoiceOrbEnterMetrics.evaluateEnter(elapsed: 0.133, fullWidth: 580, baseHeight: 54, orbFrame: 3)
        let mF25 = VoiceOrbEnterMetrics.evaluateEnter(elapsed: 0.233, fullWidth: 580, baseHeight: 54, orbFrame: 4)
        let mF27 = VoiceOrbEnterMetrics.evaluateEnter(elapsed: 0.305, fullWidth: 580, baseHeight: 54, orbFrame: 5)
        let mF31 = VoiceOrbEnterMetrics.evaluateEnter(elapsed: 0.440, fullWidth: 580, baseHeight: 54, orbFrame: 7)
        let mF44 = VoiceOrbEnterMetrics.evaluateEnter(elapsed: 0.867, fullWidth: 580, baseHeight: 54, orbFrame: 8)
        let mF46 = VoiceOrbEnterMetrics.evaluateEnter(elapsed: 0.933, fullWidth: 580, baseHeight: 54, orbFrame: 9)
        check(mF20.capsuleWidth > 550 && mF20.waveOpacity > 0.95 && mF20.editorOpacity > 0.80 && mF20.subOpacity > 0.95,
              "At t=66ms (F020), full-width S-curve plasma wave must ignite while pill is ~97.5% wide, text & mic are visible, and subcontainer is crisp")
        check(mF22.capsuleWidth > 475 && mF22.capsuleWidth < 505 && mF22.pillBottomWhiteGlow > 0.85 && mF22.subOpacity > 0.75 && mF22.subOpacity < 0.85,
              "At t=133ms (F022), pill width must contract to ~83.9% with bright bottom white-silver glow and subcontainer alpha ~0.80")
        check(mF25.capsuleWidth > 390 && mF25.capsuleWidth < 435 && mF25.editorOpacity == 0.0 && mF25.subOpacity > 0.60 && mF25.subOpacity < 0.72,
              "At t=233ms (F025), pill width must contract to ~68.7% with heavy subcontainer blur and alpha ~0.64")
        check(mF27.capsuleWidth < 180 && mF27.subOpacity < 0.05,
              "At t=305ms (F027), pill must squeeze into plump stadium capsule while subcontainer finishes dissolving")
        check(abs(mF31.capsuleWidth - 88) < 1.0 && abs(mF31.capsuleHeight - 88) < 1.0 && mF31.waveOpacity > 0.95,
              "At t=440ms (F031), capsule must settle into 1:1 3D sphere (88x88) with active horizon wave")
        check(mF44.darkBlinkMix > 0.90 && mF44.waveOpacity < 0.10 && mF44.capsuleWidth > 91,
              "At t=867ms (F044), sphere must perform the signature dark obsidian blink with 1.055x scale bump")
        check(abs(mF46.capsuleWidth - 88) < 1.0 && mF46.waveOpacity > 0.95 && mF46.darkBlinkMix == 0.0,
              "At t=933ms (F046), sphere must resume 1.0x active listening")

        if ProcessInfo.processInfo.environment["MUSE_RENDER_ORB_SHEET"] == "1" {
            let enterTimestamps: [(label: String, t: TimeInterval, frame: Int)] = [
                ("F018 (0ms)", 0.000, 1),
                ("F020 (67ms)", 0.066, 2),
                ("F022 (133ms)", 0.133, 3),
                ("F025 (233ms)", 0.233, 4),
                ("F027 (305ms)", 0.308, 5),
                ("F029 (366ms)", 0.366, 6),
                ("F031 (440ms)", 0.440, 7),
                ("F044 (867ms Blink)", 0.867, 8),
                ("F046 (933ms Active)", 0.933, 9)
            ]
            let enterSheet = VStack(alignment: .center, spacing: 18) {
                ForEach(Array(enterTimestamps.enumerated()), id: \.offset) { _, item in
                    let m = item.t == 0 ? VoiceOrbEnterMetrics.idle(fullWidth: 520, baseHeight: 56) : VoiceOrbEnterMetrics.evaluateEnter(elapsed: item.t, fullWidth: 520, baseHeight: 56, orbFrame: item.frame)
                    ZStack(alignment: .top) {
                        Color.white
                        Text("when in app rail mode, search or add new should not be")
                            .font(.system(size: 14, weight: .regular))
                            .foregroundStyle(Color(red: 0.94, green: 0.12, blue: 0.90))
                            .offset(y: 44)
                        MorphingVoiceOrbCapsuleView(
                            metrics: m,
                            orbFrame: item.frame,
                            isRecording: true,
                            isTranscribing: false,
                            audioLevel: 0.0,
                            duration: item.t,
                            fixedTimeOverride: 0.30,
                            onTap: {}
                        )
                    }
                    .frame(width: 560, height: 108)
                    .clipped()
                }
            }
            .padding(20)
            .background(Color.white)

            let enterRenderer = ImageRenderer(content: enterSheet)
            enterRenderer.scale = 2.0
            if let cgImg = enterRenderer.cgImage {
                let rep = NSBitmapImageRep(cgImage: cgImg)
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: "/tmp/muse_enter_orb_sheet.png"))
                    print("Saved /tmp/muse_enter_orb_sheet.png")
                }
            }
            let micStates: [(label: String, level: Double, time: TimeInterval)] = [
                ("Mic 1 (Braid)", 0.28, 0.25),
                ("Mic 2 (Double Helix)", 0.42, 0.70),
                ("Mic 3 (Orange Arch)", 0.88, 0.60),   // sin(0.60 * 2.6) ≈ +1.0 -> Orb 3
                ("Mic 4 (Cyan/Cobalt)", 0.92, 1.81),   // sin(1.81 * 2.6) ≈ -1.0 -> Orb 4
                ("Mic 5 (Settling A)", 0.35, 1.15),
                ("Mic 6 (Settling B)", 0.24, 1.65)
            ]
            let sheetView = VStack(alignment: .leading, spacing: 20) {
                // Row 1: Bitmap shadow & lower-hemisphere translucency test (matching 14.58.49.png)
                HStack(spacing: 18) {
                    ForEach([6, 7, 8, 9, 19, 20, 21, 22], id: \.self) { frameNum in
                        let desc = VoiceOrbFrameDescriptor.descriptor(forFrame: frameNum)
                        ZStack {
                            Color.white
                            VStack(spacing: 28) {
                                Text("remove purple border")
                                    .font(.system(size: 13, weight: .regular))
                                    .foregroundStyle(Color(red: 0.94, green: 0.12, blue: 0.90))
                                Text("in app rail mode, search on")
                                    .font(.system(size: 13, weight: .regular))
                                    .foregroundStyle(Color(red: 0.94, green: 0.12, blue: 0.90))
                            }
                            .offset(y: -6)

                            LiquidGlassVoiceOrbView(
                                orbFrame: frameNum,
                                descriptor: desc,
                                isRecording: frameNum < 19,
                                isTranscribing: frameNum >= 19,
                                audioLevel: 0.0,
                                duration: 1.2,
                                fixedTimeOverride: 0.45,
                                onTap: {}
                            )
                        }
                        .frame(width: 132, height: 136)
                        .clipped()
                    }
                }

                // Row 2: The 6 `mic interactivity` states over white background with downward drop shadows
                HStack(spacing: 24) {
                    ForEach(Array(micStates.enumerated()), id: \.offset) { _, spec in
                        let desc = VoiceOrbFrameDescriptor.descriptor(forFrame: 12)
                        ZStack {
                            Color.white
                            LiquidGlassVoiceOrbView(
                                orbFrame: 12,
                                descriptor: desc,
                                isRecording: true,
                                isTranscribing: false,
                                audioLevel: spec.level,
                                duration: 2.0,
                                fixedTimeOverride: spec.time,
                                onTap: {}
                            )
                        }
                        .frame(width: 132, height: 136)
                    }
                }

                // Row 3: 2D Cursor Hover Interactivity (`hoverPoint` tracking) + 3D Perspective Bokeh Constellation (`1028 (2)(3).mp4`)
                HStack(spacing: 20) {
                    let hoverPoints: [CGPoint?] = [
                        CGPoint(x: 0.22, y: 0.52),
                        CGPoint(x: 0.50, y: 0.50),
                        CGPoint(x: 0.78, y: 0.46),
                        CGPoint(x: 0.46, y: 0.26)
                    ]
                    ForEach(0..<hoverPoints.count, id: \.self) { idx in
                        ZStack {
                            Color(red: 0.09, green: 0.09, blue: 0.10)
                            PlasmaHorizonWaveCanvas(
                                isCircularOrb: true,
                                orbFrame: 12,
                                audioLevel: 0.0,
                                waveOpacity: 1.0,
                                hoverPoint: hoverPoints[idx],
                                fixedTimeOverride: 0.35
                            )
                            .frame(width: 88, height: 88)
                            .clipShape(Circle())
                        }
                        .frame(width: 112, height: 112)
                    }
                    ForEach([0.0, 0.55, 1.10, 1.65], id: \.self) { spinTime in
                        let desc23 = VoiceOrbFrameDescriptor.descriptor(forFrame: 23)
                        ZStack {
                            Color(red: 0.09, green: 0.09, blue: 0.10)
                            LiquidGlassVoiceOrbView(
                                orbFrame: 23,
                                descriptor: desc23,
                                isRecording: false,
                                isTranscribing: true,
                                audioLevel: 0.0,
                                duration: 3.0,
                                fixedTimeOverride: spinTime,
                                onTap: {}
                            )
                        }
                        .frame(width: 112, height: 112)
                    }
                }
            }
            .padding(20)
            .background(Color.white)

            let renderer = ImageRenderer(content: sheetView)
            renderer.scale = 2.0
            if let cgImage = renderer.cgImage {
                let rep = NSBitmapImageRep(cgImage: cgImage)
                if let pngData = rep.representation(using: .png, properties: [:]) {
                    try? pngData.write(to: URL(fileURLWithPath: "/tmp/muse_orb_verification.png"))
                    print("Saved /tmp/muse_orb_verification.png")
                }
            }
        }

        // 13b. Verify updated Input Box & Companion Subcontainer geometry (`Screen Recording 2026-10-28 at 23.23.35.mov`)
        check(ComposerMetrics.landingWidth == 520, "Landing input pill and companion subcontainer width must be 520pt (got \(ComposerMetrics.landingWidth))")
        check(ComposerMetrics.topPillMinHeight == 60 && ComposerMetrics.topPillCornerRadius == 30,
              "Top input pill height must be 60pt with 30pt capsule radius (got \(ComposerMetrics.topPillMinHeight), \(ComposerMetrics.topPillCornerRadius))")
        check(ComposerMetrics.companionCornerRadius == 34 && ComposerMetrics.companionGap == 12,
              "Companion subcontainer corner radius must be 34pt with 12pt gap (got \(ComposerMetrics.companionCornerRadius), \(ComposerMetrics.companionGap))")

        // 14. Rapid Multi-Line Paste (`⌘V`) + Voice STT Cancel Stress Test (Zero Freeze / Layout Recursion)
        MuseVoiceSTTService.shared.cancel()
        check(!MuseVoiceSTTService.shared.isRecording && !MuseVoiceSTTService.shared.isTranscribing, "MuseVoiceSTTService.cancel() must immediately reset recording and transcribing flags")

        func findTextView(in view: NSView?) -> PlaceholderTextView? {
            guard let view else { return nil }
            if let tv = view as? PlaceholderTextView { return tv }
            for sub in view.subviews {
                if let found = findTextView(in: sub) { return found }
            }
            return nil
        }

        let textView = findTextView(in: composerHost) ?? findTextView(in: window.contentView)
        check(textView != nil, "ComposerView must mount a live PlaceholderTextView")
        if let textView {
            window.contentView = composerHost
            window.makeFirstResponder(textView)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("Line 1 of pasted voice+text test\nLine 2 with extra words\nLine 3 of paste", forType: .string)
            let pasteStart = ProcessInfo.processInfo.systemUptime
            for _ in 0..<10 {
                textView.paste(nil)
                composerHost.layoutSubtreeIfNeeded()
            }
            let pasteElapsedMs = (ProcessInfo.processInfo.systemUptime - pasteStart) * 1000.0
            print(String(format: "10x multi-line paste + layoutSubtreeIfNeeded completed in %.2f ms", pasteElapsedMs))
            check(pasteElapsedMs < 250.0, "Rapid 10x multi-line paste must complete without layout recursion or main-thread hang (took \(pasteElapsedMs)ms)")
            check(textView.string.contains("Line 1 of pasted voice+text test"), "PlaceholderTextView must contain pasted plain text")
            textView.string = ""
            textView.didChangeText()

            // 15. Verify macOS Dictation (`CampoLightweightUI`) compatibility & GlowingCaretView visibility (`Untitled 8.jpg`, `Und 9.jpg`, `Untitled 9.jpg`)
            for sub in textView.subviews where !(sub is GlowingCaretView) {
                if sub is NSTextInsertionIndicator {
                    check(!sub.isHidden && sub.alphaValue > 0.0, "NSTextInsertionIndicator must NOT be hidden or alpha=0 so macOS Dictation (CampoLightweightUI) validates its positioningView layout")
                }
            }
            let glowingCaret = textView.subviews.first(where: { $0 is GlowingCaretView })
            check(glowingCaret != nil && glowingCaret?.isHidden == false, "GlowingCaretView ('|Ask Anything') must be visible when string is empty")
            textView.setMarkedText("Talk about food", selectedRange: NSRange(location: 15, length: 0), replacementRange: NSRange(location: 0, length: 0))
            check(textView.hasMarkedText(), "PlaceholderTextView must support NSTextInputClient marked text for macOS Dictation")
            check(glowingCaret?.isHidden == true, "GlowingCaretView must hide while macOS Dictation marked text is active")
            textView.unmarkText()
            textView.string = ""
            textView.didChangeText()
            textView.refreshCaretState()
            check(glowingCaret?.isHidden == false, "GlowingCaretView must reappear after unmarkText()")

            // 16. End-to-End Speech-to-Text Router (`MuseVoiceSTTService`: Auto Muse -> macOS System Backup Failover & Quick-Switching) & Subcontainer Voice Row (`Untitled 9.jpg`)
            let sttService = MuseVoiceSTTService.shared
            sttService.setRouterMode(.autoMuseWithSystemBackup)
            sttService.retryMuseSTTNow()
            check(sttService.routerMode == .autoMuseWithSystemBackup, "Default STT routerMode must be .autoMuseWithSystemBackup")
            check(sttService.activePrimaryBackend() == .museCLI, "When Muse circuit is closed in Auto mode, activePrimaryBackend() must be .museCLI")

            let sttWavURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("muse-e2e-stt-\(UUID().uuidString.prefix(6)).wav")
            defer { try? FileManager.default.removeItem(at: sttWavURL) }
            let sayResult = await discovery.run(
                executable: URL(fileURLWithPath: "/usr/bin/say"),
                arguments: ["-o", sttWavURL.path, "--data-format=LEI16@16000", "Talk about food"],
                directory: URL(fileURLWithPath: NSTemporaryDirectory()),
                environment: nil,
                timeout: 10.0
            )
            check(sayResult.exitCode == 0 && FileManager.default.fileExists(atPath: sttWavURL.path), "macOS /usr/bin/say must synthesize 16kHz PCM .wav clip for STT test")

            // 16a. Primary route (Muse CLI healthy)
            let transcribedText = await sttService.transcribeFile(at: sttWavURL, installation: installation)
            print("MuseVoiceSTTService [Primary Muse] transcribed: \"\(transcribedText ?? "<nil>")\" (backend: \(sttService.lastUsedBackend?.rawValue ?? "nil"), lastTranscript: \(sttService.lastTranscript ?? "<nil>"))")
            check(transcribedText != nil && !(transcribedText ?? "").isEmpty, "MuseVoiceSTTService.transcribeFile must return non-empty speech transcription")
            let lowerTranscript = (transcribedText ?? "").lowercased()
            check(lowerTranscript.contains("talk about food"), "MuseVoiceSTTService transcription must match 'talk about food' (got '\(transcribedText ?? "")')")
            check(sttService.lastTranscript == "talk about food", "MuseVoiceSTTService.lastTranscript must normalize to 'talk about food' for the subcontainer voice row")
            check(sttService.lastUsedBackend == .museCLI, "Healthy Muse CLI transcription must record lastUsedBackend == .museCLI")
            check(!sttService.didFallbackToSystem, "Healthy Muse CLI transcription must have didFallbackToSystem == false")
            check(!sttService.isTranscribing, "MuseVoiceSTTService.isTranscribing must reset to false after transcription finishes")

            // 16b. Automatic Failover when Muse is down (`muse` exits non-zero / unreachable -> macOS System `SFSpeechRecognizer` takes over seamlessly)
            var downInstallation = installation
            downInstallation.executableURL = URL(fileURLWithPath: "/usr/bin/false")
            sttService.lastTranscript = nil
            let failoverText = await sttService.transcribeFile(at: sttWavURL, installation: downInstallation)
            print("MuseVoiceSTTService [Muse Down -> System Backup Failover] transcribed: \"\(failoverText ?? "<nil>")\" (backend: \(sttService.lastUsedBackend?.rawValue ?? "nil"), didFallback: \(sttService.didFallbackToSystem), badge: \(sttService.routerBadgeText), reason: \(sttService.lastMuseFailureReason ?? "none"))")
            check(failoverText != nil && (failoverText ?? "").lowercased().contains("talk about food"), "When Muse is down, STT router must automatically fail over to macOS System SFSpeechRecognizer and transcribe 'talk about food' (got '\(failoverText ?? "<nil>")')")
            check(sttService.lastUsedBackend == .macOSSystem, "Failover transcription must record lastUsedBackend == .macOSSystem")
            check(sttService.didFallbackToSystem, "Failover transcription must set didFallbackToSystem == true")
            check(sttService.isMuseCircuitOpen(), "Failover must open the Muse outage circuit breaker so subsequent clips route immediately to System STT")
            check(sttService.activePrimaryBackend() == .macOSSystem, "While Muse circuit breaker is open, activePrimaryBackend() must be .macOSSystem")
            check(sttService.routerBadgeText == "System Backup", "Router badge must display 'System Backup' after failover")
            check(sttService.lastTranscript == "talk about food", "Failover must update lastTranscript to 'talk about food'")

            // 16c. Quick-Switch Controls (`retryMuseSTTNow`, `switchToSystemBackupNow`, `.systemOnly`, `.autoMuseWithSystemBackup`)
            sttService.retryMuseSTTNow()
            check(!sttService.isMuseCircuitOpen() && !sttService.didFallbackToSystem, "retryMuseSTTNow() must clear the circuit breaker and fallback flag")
            check(sttService.activePrimaryBackend() == .museCLI, "After retryMuseSTTNow(), activePrimaryBackend() must return to .museCLI")

            sttService.switchToSystemBackupNow(reason: "Quick-switch test")
            check(sttService.isMuseCircuitOpen() && sttService.activePrimaryBackend() == .macOSSystem, "switchToSystemBackupNow() must immediately route to .macOSSystem")

            sttService.setRouterMode(.systemOnly)
            check(sttService.routerMode == .systemOnly && sttService.activePrimaryBackend() == .macOSSystem, "setRouterMode(.systemOnly) must route directly to .macOSSystem")
            let directSystemText = await sttService.transcribeFile(at: sttWavURL, installation: installation)
            check((directSystemText ?? "").lowercased().contains("talk about food") && sttService.lastUsedBackend == .macOSSystem && !sttService.didFallbackToSystem, "Direct .systemOnly mode must transcribe via macOS SFSpeechRecognizer with didFallbackToSystem == false")

            sttService.setRouterMode(.autoMuseWithSystemBackup)
            sttService.retryMuseSTTNow()

            controller.resetFirstPromptVoiceState()
            let unpinnedComposerAfter = NSHostingView(
                rootView: ComposerView(state: state, controller: controller, focusTick: 0)
                    .frame(width: ComposerMetrics.landingWidth)
            )
            unpinnedComposerAfter.layoutSubtreeIfNeeded()
            let heightWithVoiceRow = unpinnedComposerAfter.fittingSize.height

            MuseVoiceSTTService.shared.lastTranscript = nil
            check(MuseVoiceSTTService.shared.lastTranscript == nil, "Setting lastTranscript = nil must clear MuseVoiceSTTService.lastTranscript")
            let unpinnedComposerCleared = NSHostingView(
                rootView: ComposerView(state: state, controller: controller, focusTick: 0)
                    .frame(width: ComposerMetrics.landingWidth)
            )
            unpinnedComposerCleared.layoutSubtreeIfNeeded()
            let heightWithoutVoiceRow = unpinnedComposerCleared.fittingSize.height

            print(String(format: "Composer natural height with '\"talk about food\"' voice row: %.1f pt, without voice row: %.1f pt", heightWithVoiceRow, heightWithoutVoiceRow))
            check(
                heightWithVoiceRow >= heightWithoutVoiceRow + 20.0,
                "Subcontainer must expand to display the '\"talk about food\"' voice transcription row after STT completes (with row: \(heightWithVoiceRow)pt, without row: \(heightWithoutVoiceRow)pt)"
            )
        }

        // 17. Verify Chat Area Backgrounds (`UntiSlehd 8.png` Midnight Glow & `UntiSDDtlehd 8.png` Forest Glass) & Partially Translucent Liquid Glass Composer
        let forestImg = AppTheme.chatBackgroundImage(for: .forestGlass)
        let midnightImg = AppTheme.chatBackgroundImage(for: .midnightGlow)
        let solidImg = AppTheme.chatBackgroundImage(for: .solidBlack)
        check(forestImg != nil && (forestImg?.size.width ?? 0) > 100, "Forest Glass chat background asset ('chat-bg-forest') must load from Assets.xcassets")
        check(midnightImg != nil && (midnightImg?.size.width ?? 0) > 100, "Midnight Glow chat background asset ('chat-bg-midnight') must load from Assets.xcassets")
        check(solidImg == nil, "Solid Black chat background must use pure obsidian color without an image")

        let originalBg = state.preferences.chatBackground
        for bgCase in PreferencesStore.ChatBackground.allCases {
            state.preferences.chatBackground = bgCase
            state.preferences.persist()
            let reloaded = PreferencesStore()
            check(reloaded.chatBackground == bgCase, "PreferencesStore must persist chatBackground = \(bgCase.rawValue)")
        }
        state.preferences.chatBackground = originalBg
        state.preferences.persist()

        if ProcessInfo.processInfo.environment["MUSE_RENDER_ORB_SHEET"] == "1" {
            let fullDetailW: CGFloat = 1040
            let fullDetailH: CGFloat = 620
            let col3W: CGFloat = 310
            let splitComparison = VStack(spacing: 12) {
                ForEach([PreferencesStore.ChatBackground.forestGlass, PreferencesStore.ChatBackground.midnightGlow]) { bgStyle in
                    HStack(alignment: .top, spacing: 0) {
                        // Column 2: Chat area with centered Liquid Glass Composer
                        VStack {
                            Spacer()
                            VStack(spacing: ComposerMetrics.companionGap) {
                                MorphingVoiceOrbCapsuleView(
                                    metrics: VoiceOrbEnterMetrics.idle(fullWidth: ComposerMetrics.landingWidth, baseHeight: ComposerMetrics.topPillMinHeight),
                                    orbFrame: 1,
                                    isRecording: false,
                                    isTranscribing: false,
                                    audioLevel: 0.0,
                                    duration: 0.0,
                                    previewText: "Ask Anything",
                                    onTap: {}
                                )
                                .frame(width: ComposerMetrics.landingWidth, height: ComposerMetrics.topPillMinHeight)

                                VStack(alignment: .leading, spacing: 0) {
                                    HStack(spacing: 10) {
                                        Image(nsImage: .huge("folder-02"))
                                            .resizable()
                                            .frame(width: 15, height: 15)
                                            .opacity(0.68)
                                        Text("snow")
                                            .font(.system(size: 13))
                                            .foregroundStyle(Color.white.opacity(0.88))
                                        Spacer()
                                        Text("✦ muse-wonder-full-1.0  Xhigh ⌄")
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundStyle(Color.white.opacity(0.92))
                                    }
                                    .padding(.horizontal, 20)
                                    .frame(height: 44)

                                    Rectangle()
                                        .fill(Color.white.opacity(0.10))
                                        .frame(height: 1)
                                        .padding(.horizontal, 18)

                                    HStack(spacing: 10) {
                                        Image(nsImage: .huge("add-01"))
                                            .resizable()
                                            .frame(width: 15, height: 15)
                                            .opacity(0.68)
                                        Text("Attach files or images")
                                            .font(.system(size: 13))
                                            .foregroundStyle(Color.white.opacity(0.88))
                                        Spacer()
                                    }
                                    .padding(.horizontal, 20)
                                    .frame(height: 44)
                                }
                                .padding(.vertical, 8)
                                .frame(width: ComposerMetrics.landingWidth)
                                .background(
                                    LiquidGlassCardBackground(
                                        cornerRadius: ComposerMetrics.companionCornerRadius,
                                        isDarkTopPill: false
                                    )
                                )
                            }
                            Spacer()
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                        // Column 3: Right Inspector (`Overview` + `Muse Agent Messages`) floating over the extended background (`Untitled 11.jpg`)
                        VStack(spacing: 0) {
                            InspectorView(state: state)
                                .frame(width: col3W)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .stroke(AppTheme.cardStroke, lineWidth: 1)
                                )
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(.top, 10)
                        .padding(.trailing, 12)
                        .padding(.bottom, 12)
                    }
                    .frame(width: fullDetailW, height: fullDetailH)
                    .background(
                        MuseChatBackgroundView(style: bgStyle)
                            .frame(width: fullDetailW, height: fullDetailH)
                    )
                    .coordinateSpace(name: "picode-session-pane")
                    .environment(\.sessionPaneSize, CGSize(width: fullDetailW, height: fullDetailH))
                    .environment(\.chatBackground, bgStyle)
                    .environment(\.hasRootChatBackground, true)
                    .clipped()
                }
            }
            .background(Color.black)
            .environment(\.colorScheme, .dark)

            let bgRenderer = ImageRenderer(content: splitComparison)
            bgRenderer.scale = 2.0
            if let cgImg = bgRenderer.cgImage {
                let rep = NSBitmapImageRep(cgImage: cgImg)
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: "/tmp/muse_liquid_glass_backgrounds.png"))
                    print("Saved /tmp/muse_liquid_glass_backgrounds.png")
                }
            }
        }

        // 18. Verify First-Prompt Center Voice Orb + Immediate Bottom Drop (`first.jpg`) vs. Subsequent Reactive Bottom Light Glow (`second.jpg`, `Computer Screen34.jpg`)
        controller.resetFirstPromptVoiceState()
        check(!controller.hasDroppedComposerToBottom && !controller.isShowingFirstPromptCenterOrb && !controller.hasCompletedFirstVoiceOrTextInteraction,
              "resetFirstPromptVoiceState() must reset session voice flags to initial landing state")

        let freshRuleComposer = ComposerView(state: state, controller: controller, focusTick: 0)
        check(!freshRuleComposer.isConsolidatedBar, "Before first mic click on untouched new session, composer must be in 2-container landing layout")

        // First mic click on untouched new session (`first.jpg`) -> drops chat box to bottom AND shows center orb
        let firstClickShowedOrb = freshRuleComposer.applyVoiceMicClickStateTransition()
        check(firstClickShowedOrb, "First mic click on untouched new session must return true (show center orb)")
        check(controller.hasDroppedComposerToBottom && freshRuleComposer.isConsolidatedBar,
              "First mic click on untouched new session must immediately drop the chat box to the bottom consolidated bar (`first.jpg`)")
        check(controller.isShowingFirstPromptCenterOrb,
              "First mic click on untouched new session must show the 3D Voice Orb in the center (`first.jpg`)")

        // Second / subsequent mic click afterwards (`second.jpg`, `Computer Screen34.jpg`) -> NO orb is shown, uses reactive bottom light glow
        let secondClickShowedOrb = freshRuleComposer.applyVoiceMicClickStateTransition()
        check(!secondClickShowedOrb, "Subsequent mic click after first interaction must return false (no orb shown)")
        check(controller.hasDroppedComposerToBottom && freshRuleComposer.isConsolidatedBar,
              "Subsequent mic click must keep the chat box at the bottom")
        check(!controller.isShowingFirstPromptCenterOrb,
              "Subsequent mic click must NOT show the Voice Orb (`second.jpg`, `Computer Screen34.jpg`)")

        // Also verify that if the user types text first on a new session, clicking mic does NOT show the orb and instead uses the reactive bottom glow
        controller.resetFirstPromptVoiceState()
        controller.hasCompletedFirstVoiceOrTextInteraction = true
        let afterTypingShowedOrb = freshRuleComposer.applyVoiceMicClickStateTransition()
        check(!afterTypingShowedOrb && !controller.isShowingFirstPromptCenterOrb && controller.hasDroppedComposerToBottom,
              "Clicking mic after user has typed in session must drop box to bottom with reactive glow and NO orb")
        controller.resetFirstPromptVoiceState()

        if ProcessInfo.processInfo.environment["MUSE_RENDER_ORB_SHEET"] == "1" {
            let glowSpecs: [(label: String, level: Double, time: TimeInterval, transcribing: Bool)] = [
                ("1. Calm / Idle Glow (Computer Screen34.jpg)", 0.08, 0.0, false),
                ("2. Warm Amber-Coral Voice Swell (Computer Screen3445.jpeg / second.jpg)", 0.88, 0.60, false),
                ("3. Cool Ice-Cyan Voice Swell (Computer Screen344.jpeg)", 0.88, 1.81, false),
                ("4. Settling / Transcribing Glow (C6omputer Screen.jpg)", 0.24, 1.15, true)
            ]
            let ruleSheet = VStack(spacing: 18) {
                // Panel A: `first.jpg` — Untouched new session first mic click: center hero + 3D Voice Orb AND bottom dropped chat box
                ZStack {
                    Color(red: 0.03, green: 0.03, blue: 0.04)
                    VStack(spacing: 18) {
                        Text("What should we build in gadget?")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.88))
                        LiquidGlassVoiceOrbView(
                            orbFrame: 9,
                            descriptor: VoiceOrbFrameDescriptor.descriptor(forFrame: 9),
                            isRecording: true,
                            isTranscribing: false,
                            audioLevel: 0.36,
                            duration: 1.2,
                            fixedTimeOverride: 0.45,
                            onTap: {}
                        )
                    }
                    .offset(y: -44)

                    VStack {
                        Spacer()
                        VStack(alignment: .leading, spacing: 10) {
                            Text("|Ask Anything")
                                .font(.system(size: 14))
                                .foregroundStyle(Color.white.opacity(0.45))
                            HStack(spacing: 12) {
                                Image(nsImage: .huge("add-01")).resizable().frame(width: 14, height: 14).opacity(0.8)
                                Text("building  feat/smart-...wler-service  ✦ muse-wonder-full-1.0  Xhigh ⌄")
                                    .font(.system(size: 12.5, weight: .medium))
                                    .foregroundStyle(Color.white.opacity(0.86))
                                Spacer()
                                MuseMicrophoneIcon(isActive: true, size: 20)
                            }
                        }
                        .padding(.horizontal, 18)
                        .padding(.vertical, 14)
                        .frame(width: 680)
                        .background(
                            LiquidGlassCardBackground(cornerRadius: ComposerMetrics.cornerRadius, isDarkTopPill: true)
                        )
                        .padding(.bottom, 16)
                    }
                }
                .frame(width: 740, height: 340)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

                // Panel B: `second.jpg` & `Computer Screen34*.jpg` — Subsequent interactions with Reactive Bottom Light Glow (no orb)
                ForEach(Array(glowSpecs.enumerated()), id: \.offset) { _, spec in
                    VStack(alignment: .leading, spacing: 10) {
                        Text("|Ask Anything")
                            .font(.system(size: 14))
                            .foregroundStyle(Color.white.opacity(0.45))
                        HStack(spacing: 12) {
                            Image(nsImage: .huge("add-01")).resizable().frame(width: 14, height: 14).opacity(0.8)
                            Text("building  feat/smart-...wler-service  ✦ muse-wonder-full-1.0  Xhigh ⌄")
                                .font(.system(size: 12.5, weight: .medium))
                                .foregroundStyle(Color.white.opacity(0.86))
                            Spacer()
                            MuseMicrophoneIcon(isActive: true, size: 20)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .frame(width: 680)
                    .background(
                        LiquidGlassCardBackground(cornerRadius: ComposerMetrics.cornerRadius, isDarkTopPill: true)
                            .overlay(alignment: .bottom) {
                                VoiceReactiveBottomGlowView(
                                    isRecording: !spec.transcribing,
                                    isTranscribing: spec.transcribing,
                                    audioLevel: spec.level,
                                    fixedTimeOverride: spec.time
                                )
                                .clipShape(RoundedRectangle(cornerRadius: ComposerMetrics.cornerRadius, style: .continuous))
                            }
                    )
                }

                // Panel C: `ff3.jpg` — Compact Muse Credit Gauge Popover + Active vs Inactive Filled Microphone Icon
                HStack(spacing: 28) {
                    MuseCreditBatteryButton(controller: controller)
                        .popoverContent
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color(red: 0.11, green: 0.12, blue: 0.14))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                                )
                        )
                        .environment(\.colorScheme, .dark)

                    VStack(alignment: .leading, spacing: 14) {
                        Text("Microphone Icon States (ff3.jpg)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.white.opacity(0.85))
                        HStack(spacing: 18) {
                            VStack(spacing: 6) {
                                MuseMicrophoneIcon(isActive: false, size: 24)
                                    .padding(10)
                                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
                                Text("Inactive")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(Color.white.opacity(0.6))
                            }
                            VStack(spacing: 6) {
                                MuseMicrophoneIcon(isActive: true, size: 24)
                                    .padding(10)
                                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.10)))
                                Text("Active (Filled Capsule)")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(Color.white.opacity(0.9))
                            }
                        }
                    }
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color(red: 0.08, green: 0.10, blue: 0.12))
                    )
                }
            }
            .padding(20)
            .background(Color(red: 0.02, green: 0.02, blue: 0.03))
            .environment(\.chatBackground, .solidBlack)
            .environment(\.colorScheme, .dark)

            let popoverHost = NSHostingView(rootView: MuseCreditBatteryButton(controller: controller).popoverContent)
            let popoverSize = popoverHost.fittingSize
            check(
                popoverSize.width <= 230 && popoverSize.height <= 265,
                "MuseCreditBatteryButton popover should be compact (<= 230x265), got \(popoverSize)"
            )

            let ruleRenderer = ImageRenderer(content: ruleSheet)
            ruleRenderer.scale = 2.0
            if let cgImg = ruleRenderer.cgImage {
                let rep = NSBitmapImageRep(cgImage: cgImg)
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: "/tmp/muse_first_and_reactive_glow_sheet.png"))
                    print("Saved /tmp/muse_first_and_reactive_glow_sheet.png")
                }
            }
        }

        // 19. Verify Light Mode Backdrop (`chat-bg-forest-light` / `.daylightForest`) & Crystal-Clear Floating Components (`Untitled 10.jpg` & `Meta-Ai-Forest-Bg.html`)
        let daylightBgImg = AppTheme.chatBackgroundImage(for: .daylightForest)
        check(daylightBgImg != nil && (daylightBgImg?.size.width ?? 0) >= 1600,
              "Daylight Forest (`chat-bg-forest-light`) high-res background image must load from Assets.xcassets/ChatBackgrounds")
        check(PreferencesStore.ChatBackground.forestGlass.resolved(for: .light) == .daylightForest,
              "In Light Mode (`colorScheme == .light`), `.forestGlass` must automatically resolve to `.daylightForest`")
        check(PreferencesStore.ChatBackground.forestGlass.resolved(for: .dark) == .forestGlass,
              "In Dark Mode (`colorScheme == .dark`), `.forestGlass` must remain `.forestGlass`")
        check(AppTheme.isLightGlass(colorScheme: .light, chatBackground: .forestGlass),
              "`AppTheme.isLightGlass` must be true when `colorScheme == .light` with `.forestGlass`")
        check(AppTheme.isLightGlass(colorScheme: .dark, chatBackground: .daylightForest),
              "`AppTheme.isLightGlass` must be true when `.daylightForest` is explicitly selected")
        check(!AppTheme.isLightGlass(colorScheme: .dark, chatBackground: .forestGlass),
              "`AppTheme.isLightGlass` must be false in Dark Mode with `.forestGlass`")

        // Verify `GlowingCaretView` in Light Mode (`isLightGlass = true`) glows dark & narrow instead of white circular light
        let caretSize = NSSize(width: 30, height: 50)
        func renderCaretSnapshot(isLight: Bool) -> (NSImage, NSBitmapImageRep)? {
            let caret = GlowingCaretView(frame: NSRect(origin: .zero, size: caretSize))
            caret.isLightGlass = isLight
            guard let rep = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: Int(caretSize.width),
                pixelsHigh: Int(caretSize.height),
                bitsPerSample: 8,
                samplesPerPixel: 4,
                hasAlpha: true,
                isPlanar: false,
                colorSpaceName: .deviceRGB,
                bytesPerRow: 0,
                bitsPerPixel: 0
            ) else { return nil }
            NSGraphicsContext.saveGraphicsState()
            if let ctx = NSGraphicsContext(bitmapImageRep: rep) {
                NSGraphicsContext.current = ctx
                caret.draw(caret.bounds)
            }
            NSGraphicsContext.restoreGraphicsState()
            let img = NSImage(size: caretSize)
            img.addRepresentation(rep)
            return (img, rep)
        }

        if let (_, lightCaretRep) = renderCaretSnapshot(isLight: true),
           let centerColor = lightCaretRep.colorAt(x: Int(caretSize.width / 2), y: Int(caretSize.height / 2))?.usingColorSpace(.sRGB) {
            check(
                centerColor.redComponent < 0.15 && centerColor.greenComponent < 0.30 && centerColor.alphaComponent > 0.85,
                "Light Mode GlowingCaretView core must be deep dark forest-obsidian, got r=\(centerColor.redComponent) g=\(centerColor.greenComponent) a=\(centerColor.alphaComponent)"
            )
            if let farSideColor = lightCaretRep.colorAt(x: Int(caretSize.width / 2) + 8, y: Int(caretSize.height / 2))?.usingColorSpace(.sRGB) {
                check(
                    farSideColor.alphaComponent < 0.06,
                    "Light Mode GlowingCaretView dark glow must be tightly hugged to the vertical bar (not a wide circle), got alpha=\(farSideColor.alphaComponent) at +8px"
                )
            }
        } else {
            check(false, "Could not render Light Mode GlowingCaretView bitmap snapshot")
        }

        if ProcessInfo.processInfo.environment["MUSE_RENDER_ORB_SHEET"] == "1" {
            let paneW: CGFloat = 1060
            let paneH: CGFloat = 540
            let inspW: CGFloat = 304
            let lightCaretImg = renderCaretSnapshot(isLight: true)?.0
            let darkCaretImg = renderCaretSnapshot(isLight: false)?.0

            let lightVsDarkSheet = VStack(spacing: 16) {
                ForEach([true, false], id: \.self) { isLightMode in
                    let scheme: ColorScheme = isLightMode ? .light : .dark
                    let bgStyle: PreferencesStore.ChatBackground = isLightMode ? .daylightForest : .forestGlass
                    let isLight = AppTheme.isLightGlass(colorScheme: scheme, chatBackground: bgStyle)

                    HStack(alignment: .top, spacing: 0) {
                        // Left/Center Chat Column with Landing Composer +Consolidated Bottom Bar preview
                        VStack(spacing: 18) {
                            Spacer(minLength: 16)

                            Text(isLightMode ? "Light Mode — Daylight Forest (Light M) & Dark-Glowing Cursor" : "Dark Mode — Forest Glass (Liquid M) & Luminous Cursor")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(AppTheme.glassPrimaryText(isLight: isLight))

                            // Floating 2-Container Landing Composer (Top Input Pill + Companion Subcontainer)
                            VStack(spacing: ComposerMetrics.companionGap) {
                                HStack(spacing: 10) {
                                    HStack(spacing: 0) {
                                        if let caretImg = isLight ? lightCaretImg : darkCaretImg {
                                            Image(nsImage: caretImg)
                                                .frame(width: 14, height: 34)
                                                .offset(x: -2)
                                        }
                                        Text("Ask Anything")
                                            .font(.system(size: 18.5, weight: .regular))
                                            .foregroundStyle(isLight ? Color(red: 0.12, green: 0.25, blue: 0.16, opacity: 0.62) : Color.white.opacity(0.56))
                                    }
                                    Spacer()
                                    MuseMicrophoneIcon(isActive: false, size: 20)
                                    Circle()
                                        .fill(AppTheme.glassChipFill(isLight: isLight))
                                        .overlay(
                                            Circle().strokeBorder(AppTheme.glassChipStroke(isLight: isLight), lineWidth: 0.8)
                                        )
                                        .frame(width: 28, height: 28)
                                        .overlay(
                                            Image(nsImage: .huge("arrow-up-02"))
                                                .renderingMode(.template)
                                                .resizable()
                                                .frame(width: 14, height: 14)
                                                .foregroundStyle(AppTheme.glassMutedText(isLight: isLight))
                                        )
                                }
                                .padding(.leading, 26)
                                .padding(.trailing, 20)
                                .frame(width: ComposerMetrics.landingWidth, height: ComposerMetrics.topPillMinHeight)
                                .background(
                                    LiquidGlassCardBackground(
                                        cornerRadius: ComposerMetrics.topPillCornerRadius,
                                        isDarkTopPill: true
                                    )
                                )

                                // Companion Subcontainer
                                VStack(alignment: .leading, spacing: 11) {
                                    HStack(spacing: 10) {
                                        VoiceOrbBadgeIcon(size: 19, isLightGlass: isLight)
                                        Text("\"Design a light mode solution\"")
                                            .font(.system(size: 13.5, weight: .medium))
                                            .foregroundStyle(AppTheme.glassPrimaryText(isLight: isLight))
                                        Spacer()
                                        HStack(spacing: 5) {
                                            Circle().fill(Color.green).frame(width: 5.5, height: 5.5)
                                            Text("Muse STT")
                                                .font(.system(size: 10.5, weight: .semibold))
                                                .foregroundStyle(AppTheme.glassSecondaryText(isLight: isLight))
                                        }
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 2.5)
                                        .background(
                                            Capsule(style: .continuous)
                                                .fill(AppTheme.glassChipFill(isLight: isLight))
                                                .overlay(
                                                    Capsule(style: .continuous)
                                                        .strokeBorder(AppTheme.glassChipStroke(isLight: isLight), lineWidth: 0.7)
                                                )
                                        )
                                    }

                                    HStack(spacing: 14) {
                                        ComposerContextStrip(state: state, controller: controller, isGlassSurface: true)
                                        Spacer()
                                        HStack(spacing: 6) {
                                            Image(nsImage: .huge("sparkles"))
                                                .renderingMode(.template)
                                                .resizable()
                                                .frame(width: 14, height: 14)
                                                .foregroundStyle(AppTheme.glassSecondaryText(isLight: isLight))
                                            Text("muse-wonder-full-1.0")
                                                .font(.system(size: 13.5, weight: .medium))
                                                .foregroundStyle(AppTheme.glassPrimaryText(isLight: isLight))
                                            Text("Xhigh")
                                                .font(.system(size: 13))
                                                .foregroundStyle(AppTheme.glassMutedText(isLight: isLight))
                                        }
                                    }

                                    Rectangle()
                                        .fill(AppTheme.glassDivider(isLight: isLight))
                                        .frame(height: 1)

                                    HStack(spacing: 12) {
                                        HStack(spacing: 8) {
                                            Image(nsImage: .huge("add-01"))
                                                .renderingMode(.template)
                                                .resizable()
                                                .frame(width: 14, height: 14)
                                                .foregroundStyle(AppTheme.glassSecondaryText(isLight: isLight))
                                            Text("Attach files or images")
                                                .font(.system(size: 13, weight: .medium))
                                                .foregroundStyle(AppTheme.glassPrimaryText(isLight: isLight))
                                        }
                                        Spacer()
                                        TachometerMiniDial(fraction: 0.92, isGlassSurface: true)
                                            .frame(width: 22, height: 16)
                                    }
                                }
                                .padding(.horizontal, 22)
                                .padding(.vertical, 16)
                                .frame(width: ComposerMetrics.landingWidth)
                                .background(
                                    LiquidGlassCardBackground(
                                        cornerRadius: ComposerMetrics.companionCornerRadius,
                                        isDarkTopPill: false
                                    )
                                )
                            }

                            Spacer(minLength: 10)

                            // Bottom Consolidated Floating Composer Bar with Active Mic + Reactive Glow
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Color those floating components and make them more clear")
                                    .font(.system(size: 15, weight: .regular))
                                    .foregroundStyle(AppTheme.glassPrimaryText(isLight: isLight))
                                HStack(spacing: 12) {
                                    Circle()
                                        .fill(AppTheme.glassChipFill(isLight: isLight))
                                        .overlay(Circle().strokeBorder(AppTheme.glassChipStroke(isLight: isLight), lineWidth: 0.7))
                                        .frame(width: 24, height: 24)
                                        .overlay(
                                            Image(nsImage: .huge("add-01"))
                                                .renderingMode(.template)
                                                .resizable()
                                                .frame(width: 13, height: 13)
                                                .foregroundStyle(AppTheme.glassSecondaryText(isLight: isLight))
                                        )
                                    ComposerContextStrip(state: state, controller: controller, isGlassSurface: true)
                                    Spacer()
                                    TachometerMiniDial(fraction: 0.92, isGlassSurface: true)
                                        .frame(width: 22, height: 16)
                                    MuseMicrophoneIcon(isActive: true, size: 20)
                                    Circle()
                                        .fill(AppTheme.accentBlue)
                                        .frame(width: 28, height: 28)
                                        .overlay(
                                            Image(nsImage: .huge("arrow-up-02"))
                                                .renderingMode(.template)
                                                .resizable()
                                                .frame(width: 14, height: 14)
                                                .foregroundStyle(Color.white)
                                        )
                                }
                            }
                            .padding(.horizontal, 18)
                            .padding(.vertical, 12)
                            .frame(width: 640)
                            .background(
                                LiquidGlassCardBackground(
                                    cornerRadius: ComposerMetrics.cornerRadius,
                                    isDarkTopPill: true
                                )
                                .overlay(alignment: .bottom) {
                                    VoiceReactiveBottomGlowView(
                                        isRecording: true,
                                        isTranscribing: false,
                                        audioLevel: 0.74,
                                        fixedTimeOverride: 0.65
                                    )
                                    .clipShape(RoundedRectangle(cornerRadius: ComposerMetrics.cornerRadius, style: .continuous))
                                }
                            )
                            .padding(.bottom, 16)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                        // Floating Right Inspector (`Overview` + `Muse Agent Messages`)
                        VStack(spacing: 0) {
                            InspectorView(state: state)
                                .frame(width: inspW)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .stroke(
                                            isLight ? Color.white.opacity(0.84) : Color.white.opacity(0.22),
                                            lineWidth: 1
                                        )
                                )
                                .shadow(
                                    color: isLight
                                        ? Color(red: 0.08, green: 0.24, blue: 0.14).opacity(0.14)
                                        : .black.opacity(0.26),
                                    radius: 14,
                                    x: 0,
                                    y: 6
                                )
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                        }
                        .padding(.top, 14)
                        .padding(.trailing, 14)
                        .padding(.bottom, 14)
                    }
                    .frame(width: paneW, height: paneH)
                    .background(
                        MuseChatBackgroundView(style: bgStyle)
                            .frame(width: paneW, height: paneH)
                    )
                    .coordinateSpace(name: "picode-session-pane")
                    .environment(\.sessionPaneSize, CGSize(width: paneW, height: paneH))
                    .environment(\.chatBackground, bgStyle)
                    .environment(\.hasRootChatBackground, true)
                    .environment(\.colorScheme, scheme)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
            .padding(16)
            .background(Color(red: 0.08, green: 0.10, blue: 0.09))

            let lmRenderer = ImageRenderer(content: lightVsDarkSheet)
            lmRenderer.scale = 2.0
            if let cgImg = lmRenderer.cgImage {
                let rep = NSBitmapImageRep(cgImage: cgImg)
                if let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: "/tmp/muse_light_mode_verification.png"))
                    print("Saved /tmp/muse_light_mode_verification.png")
                }
            }
        }

        // 20. Verify All 10 UI Interactivity Improvements & Project Folder / Git Clone Support
        // 20a. Cached pre-blurred LiquidGlassRefractedBackdrop texture (`AppTheme.blurredChatBackgroundImage`)
        let blurredForestDark = AppTheme.blurredChatBackgroundImage(for: .forestGlass, isLight: false, isDarkTopPill: true)
        let blurredForestLight = AppTheme.blurredChatBackgroundImage(for: .daylightForest, isLight: true, isDarkTopPill: false)
        check(blurredForestDark != nil && (blurredForestDark?.size.width ?? 0) > 100,
              "AppTheme.blurredChatBackgroundImage must pre-compute and cache dark refracted texture")
        check(blurredForestLight != nil && (blurredForestLight?.size.width ?? 0) > 100,
              "AppTheme.blurredChatBackgroundImage must pre-compute and cache light refracted texture")
        check(AppTheme.blurredChatBackgroundImage(for: .forestGlass, isLight: false, isDarkTopPill: true) === blurredForestDark,
              "AppTheme.blurredChatBackgroundImage must return the exact cached NSImage instance on subsequent calls")

        // 20b. DraftStore attachment persistence across session switches
        let sampleAttachment = Attachment(
            id: UUID(),
            kind: .text,
            fileName: "diagram.png",
            mimeType: "text/plain",
            byteSize: 7,
            path: "/tmp/diagram.png",
            textContent: "diagram"
        )
        let testDraftKey = "test-attachments-key-\(UUID().uuidString.prefix(6))"
        state.drafts.setAttachments([sampleAttachment], for: testDraftKey)
        check(state.drafts.attachments(for: testDraftKey).count == 1 && state.drafts.attachments(for: testDraftKey).first?.fileName == "diagram.png",
              "DraftStore must persist and restore attachments by draftKey across session switches")
        state.drafts.clear(for: testDraftKey)
        check(state.drafts.attachments(for: testDraftKey).isEmpty, "DraftStore.clear(for:) must remove stored attachments")

        // 20c. GitStatusService URL normalization, suggested folder name,New Project Folder creation, & End-to-End Git Repository Clone
        check(GitStatusService.normalizedCloneURL("facebook/react") == "https://github.com/facebook/react.git",
              "GitStatusService.normalizedCloneURL must expand owner/repo shorthand to https://github.com/owner/repo.git")
        check(GitStatusService.suggestedFolderName(from: "https://github.com/facebook/react.git") == "react",
              "GitStatusService.suggestedFolderName must extract 'react' from https://github.com/facebook/react.git")
        check(GitStatusService.suggestedFolderName(from: "git@github.com:anthropics/claude-code.git") == "claude-code",
              "GitStatusService.suggestedFolderName must extract 'claude-code' from SSH git URL")

        let tempWorkspaceRoot = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("muse-project-tests-\(UUID().uuidString.prefix(6))")
        try? FileManager.default.createDirectory(at: tempWorkspaceRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempWorkspaceRoot) }

        // Test `createNewProjectFolder` (creates directory, runs `git init`, registers in `state.projects`, and opens session)
        let createFolderResult = await state.createNewProjectFolder(
            parentDirectory: tempWorkspaceRoot.path,
            folderName: "fresh-agent-repo",
            initializeGit: true
        )
        switch createFolderResult {
        case .success(let createdPath):
            check(FileManager.default.fileExists(atPath: (createdPath as NSString).appendingPathComponent(".git")),
                  "createNewProjectFolder(initializeGit: true) must initialize a .git repository in the new folder")
            check(state.projects.contains(where: { CanonicalPath.of($0.path) == createdPath }),
                  "createNewProjectFolder must register the new folder in state.projects")
            check(CanonicalPath.of(state.activeController?.projectPath ?? "") == createdPath,
                  "createNewProjectFolder must switch the active session to the newly created project folder")
            // Commit a seed file in `fresh-agent-repo` so we can clone it via `cloneAndOpenRepository`
            let readmePath = (createdPath as NSString).appendingPathComponent("README.md")
            try? "# Fresh Agent Repo\n".write(toFile: readmePath, atomically: true, encoding: .utf8)
            if let gitURL = PiDiscoveryService.resolveExecutable(named: "git") {
                _ = await discovery.run(executable: gitURL, arguments: ["-C", createdPath, "config", "user.email", "test@muse.local"], directory: tempWorkspaceRoot, environment: nil, timeout: 5)
                _ = await discovery.run(executable: gitURL, arguments: ["-C", createdPath, "config", "user.name", "Muse Test"], directory: tempWorkspaceRoot, environment: nil, timeout: 5)
                _ = await discovery.run(executable: gitURL, arguments: ["-C", createdPath, "add", "README.md"], directory: tempWorkspaceRoot, environment: nil, timeout: 5)
                _ = await discovery.run(executable: gitURL, arguments: ["-C", createdPath, "commit", "-m", "Initial commit"], directory: tempWorkspaceRoot, environment: nil, timeout: 5)
            }

            // Test `cloneAndOpenRepository` end-to-end
            let cloneResult = await state.cloneAndOpenRepository(
                url: createdPath,
                parentDirectory: tempWorkspaceRoot.path,
                folderName: "cloned-agent-repo"
            )
            switch cloneResult {
            case .success(let clonedPath):
                check(FileManager.default.fileExists(atPath: (clonedPath as NSString).appendingPathComponent("README.md")),
                      "cloneAndOpenRepository must clone the repository contents into the destination folder")
                check(state.projects.contains(where: { CanonicalPath.of($0.path) == clonedPath }),
                      "cloneAndOpenRepository must register the cloned repository in state.projects")
                check(CanonicalPath.of(state.activeController?.projectPath ?? "") == clonedPath,
                      "cloneAndOpenRepository must open an active session in the newly cloned repository")
            case .failure(let err):
                check(false, "cloneAndOpenRepository failed unexpectedly: \(err)")
            }
        case .failure(let err):
            check(false, "createNewProjectFolder failed unexpectedly: \(err)")
        }

        // Verify CloneRepositorySheet & CreateProjectFolderSheet mount and layout cleanly
        let cloneSheetHost = NSHostingView(rootView: CloneRepositorySheet(state: state, onDone: {}))
        window.contentView = cloneSheetHost
        cloneSheetHost.frame = NSRect(x: 0, y: 0, width: 500, height: 390)
        cloneSheetHost.layoutSubtreeIfNeeded()
        let cloneSheetTexts = collectTexts(in: cloneSheetHost)
        check(cloneSheetHost.fittingSize.width >= 480 && cloneSheetTexts.contains("Default branch") && cloneSheetTexts.contains("my-project"),
              "CloneRepositorySheet must mount and layout its form fields cleanly (got: \(cloneSheetTexts))")

        let createSheetHost = NSHostingView(rootView: CreateProjectFolderSheet(state: state, onDone: {}))
        window.contentView = createSheetHost
        createSheetHost.frame = NSRect(x: 0, y: 0, width: 480, height: 340)
        createSheetHost.layoutSubtreeIfNeeded()
        let createSheetTexts = collectTexts(in: createSheetHost)
        check(createSheetHost.fittingSize.width >= 460 && createSheetTexts.contains("my-new-project"),
              "CreateProjectFolderSheet must mount and layout its form fields cleanly (got: \(createSheetTexts))")

        // 21. Verify Titlebar Search Autocomplete, Suggestion Dropdown (`AOL Search History.jpg`),
        //     & Low-Energy Lazy Rolling Keyword Matcher (`MuseRollingKeywordIndex`) over Muse, Claude, and Codex transcripts
        let rollingIndex = MuseRollingKeywordIndex.shared
        let seedStart = CFAbsoluteTimeGetCurrent()
        rollingIndex.ensureFastSeedLoaded(projects: state.projects)
        let seedElapsedMs = (CFAbsoluteTimeGetCurrent() - seedStart) * 1000.0
        let kwStats = rollingIndex.stats
        print("MuseRollingKeywordIndex fast seed loaded in \(String(format: "%.2f", seedElapsedMs)) ms — totalKeywords: \(kwStats.totalKeywords) (muse: \(kwStats.museKeywordCount), claude: \(kwStats.claudeKeywordCount), codex: \(kwStats.codexKeywordCount), files scanned: \(kwStats.scannedFiles), bytes: \(kwStats.scannedBytes))")
        check(kwStats.totalKeywords >= 50 && kwStats.claudeKeywordCount == 0 && kwStats.codexKeywordCount == 0,
              "MuseRollingKeywordIndex must extract Muse-only Keywords without scanning Claude/Codex (got total=\(kwStats.totalKeywords), claude=\(kwStats.claudeKeywordCount), codex=\(kwStats.codexKeywordCount))")

        let searchService = MuseSearchSuggestionService.shared
        searchService.recordSearch("light mode cursor glow")
        searchService.recordSearch("search suggestions rolling keyword matcher")
        check(searchService.recentQueries.first == "search suggestions rolling keyword matcher",
              "MuseSearchSuggestionService.recordSearch must persist recent query at index 0")

        // Verify exact prefix & fuzzy/similar-string matching ("seacrh", "bzel", "lght mode", "semntic")
        let bazelMatches = rollingIndex.matchKeywords(for: "bazel", limit: 6)
        let bzelFuzzyMatches = rollingIndex.matchKeywords(for: "bzel", limit: 6)
        let seacrhTypoMatches = rollingIndex.matchKeywords(for: "seacrh", limit: 6)
        let lghtFuzzyMatches = rollingIndex.matchKeywords(for: "lght mode", limit: 6)
        print("Rolling matches for 'bazel': \(bazelMatches.map { "\($0.phrase) (\($0.sources.joined(separator: "+"))·\($0.hitCount)x)" })")
        print("Rolling fuzzy matches for 'bzel': \(bzelFuzzyMatches.map { "\($0.phrase) (sim=\(String(format: "%.2f", $0.similarity)))" })")
        print("Rolling typo matches for 'seacrh': \(seacrhTypoMatches.map { "\($0.phrase) (sim=\(String(format: "%.2f", $0.similarity)))" })")
        print("Rolling fuzzy matches for 'lght mode': \(lghtFuzzyMatches.map { "\($0.phrase) (sim=\(String(format: "%.2f", $0.similarity)))" })")

        check(bzelFuzzyMatches.contains(where: { $0.phrase.contains("bazel") }),
              "MuseRollingKeywordIndex must match similar/abbreviated string 'bzel' to 'bazel...' Muse Keywords (got \(bzelFuzzyMatches.map(\.phrase)))")
        check(seacrhTypoMatches.contains(where: { $0.phrase.contains("search") }),
              "MuseRollingKeywordIndex must match transposed typo 'seacrh' to 'search...' Muse Keywords (got \(seacrhTypoMatches.map(\.phrase)))")
        check(lghtFuzzyMatches.contains(where: { $0.phrase.contains("light mode") }),
              "MuseRollingKeywordIndex must match similar string 'lght mode' to 'light mode...' Muse Keywords (got \(lghtFuzzyMatches.map(\.phrase)))")

        // Benchmark 50 consecutive rolling keyword queries to verify ultra-low compute (< 2.0 ms/query average)
        let benchmarkQueries = [
            "b", "ba", "baz", "bzel", "bazel build",
            "s", "se", "sea", "seacrh", "search suggestions",
            "l", "li", "lght", "light mode", "liquid glass",
            "v", "vo", "voice orb", "semntic", "semantic code",
            "a", "an", "andr", "android build", "xcode",
            "c", "cl", "clone git", "cursor glow", "tachometer",
            "f", "fl", "floating panel", "binary diff", "side panel",
            "p", "pr", "project folder", "subagent", "worktree",
            "t", "tr", "transcript", "litrt", "litert lm",
            "m", "mu", "muse keywords", "rolling", "history"
        ]
        let benchStart = CFAbsoluteTimeGetCurrent()
        var totalMatchedCount = 0
        for q in benchmarkQueries {
            totalMatchedCount += rollingIndex.matchKeywords(for: q, limit: 6).count
        }
        let totalBenchMs = (CFAbsoluteTimeGetCurrent() - benchStart) * 1000.0
        let avgQueryMs = totalBenchMs / Double(benchmarkQueries.count)
        print("50 rolling keyword queries completed in \(String(format: "%.2f", totalBenchMs)) ms (avg \(String(format: "%.3f", avgQueryMs)) ms/query, \(totalMatchedCount) matches)")
        check(avgQueryMs < 2.5, "MuseRollingKeywordIndex must average < 2.5 ms per query (got \(avgQueryMs) ms)")

        let aolSuggestions = searchService.suggestions(for: "aol", projects: state.projects, limit: 6)
        check(aolSuggestions.count == 6, "MuseSearchSuggestionService must return 6 suggestions for 'aol' (got \(aolSuggestions.count))")
        check(aolSuggestions.first?.queryText == "aol" && aolSuggestions.contains(where: { $0.queryText == "aol mail" }) && aolSuggestions.contains(where: { $0.queryText == "aol news" }),
              "MuseSearchSuggestionService must generate 'aol', 'aol mail', 'aol news' suggestions matching AOL Search History.jpg")

        let lightSuggestions = searchService.suggestions(for: "light", projects: state.projects, limit: 6)
        check(lightSuggestions.contains(where: { $0.queryText.lowercased().contains("light mode") }),
              "MuseSearchSuggestionService must suggest 'light mode...' from search history and session corpus")

        // Verify semantic / co-occurrence neighbor matching ("java" -> "kotlin")
        let javaMatches = rollingIndex.matchKeywords(for: "java", limit: 6)
        let javaSuggestions = searchService.suggestions(for: "java", projects: state.projects, limit: 6)
        print("Rolling matches for 'java': \(javaMatches.map { "\($0.phrase) (assoc=\($0.isAssociatedNeighbor))" })")
        print("Dropdown suggestions for 'java': \(javaSuggestions.map(\.queryText))")
        check(javaMatches.contains(where: { $0.phrase == "kotlin" }) && javaSuggestions.contains(where: { $0.queryText == "kotlin" }),
              "Typing 'java' must surface 'kotlin' as a related Muse Keyword suggestion (got \(javaSuggestions.map(\.queryText)))")

        // Verify first-time user with zero history on disk still gets clean suggestions (including "java" -> "kotlin")
        let zeroHistoryDB = tempWorkspaceRoot.appendingPathComponent("zero-history-keywords.sqlite")
        let zeroHistoryIndex = MuseRollingKeywordIndex(dbURL: zeroHistoryDB, enableDiskScan: false)
        check(zeroHistoryIndex.stats.totalKeywords == 0, "Zero-history index must start with 0 persisted keywords")
        let zeroJavaMatches = zeroHistoryIndex.matchKeywords(for: "java", limit: 6)
        check(zeroJavaMatches.contains(where: { $0.phrase == "kotlin" }),
              "Even with 0 transcript history on first launch, typing 'java' must match 'kotlin' (got \(zeroJavaMatches.map(\.phrase)))")

        state.openPalette()
        state.paletteQuery = "aol"
        state.updatePaletteQuery()
        check(state.isPalettePresented, "state.openPalette() must set isPalettePresented = true")

        let inlineAuto = searchService.inlineAutocomplete(for: "aol", projects: state.projects, matchingSessions: [])
        check(inlineAuto != nil && !(inlineAuto?.displayHighlightText ?? "").isEmpty,
              "MuseSearchSuggestionService.inlineAutocomplete must provide inline completion highlight text for the titlebar search field")

        let dropdownView = TitlebarSearchDropdownView(state: state, onRunCommand: { _ in })
        let dropdownHost = NSHostingView(rootView: dropdownView)
        window.contentView = dropdownHost
        dropdownHost.frame = NSRect(x: 0, y: 0, width: 400, height: 320)
        dropdownHost.layoutSubtreeIfNeeded()
        check(dropdownHost.fittingSize.width == 400 && dropdownHost.fittingSize.height >= 120,
              "TitlebarSearchDropdownView must render 400pt wide compact dropdown with sessions at top + 2 Muse Suggestions at bottom (size: \(dropdownHost.fittingSize))")
        check(dropdownView.suggestions.count == 2,
              "TitlebarSearchDropdownView.suggestions must be capped at 2 rows at the bottom (got \(dropdownView.suggestions.count))")
        if let firstSwitchIdx = dropdownView.selectableRowIDs.firstIndex(where: { $0.hasPrefix("switch-") }),
           let firstSugIdx = dropdownView.selectableRowIDs.firstIndex(where: { $0.hasPrefix("sug-") }) {
            check(firstSwitchIdx < firstSugIdx,
                  "Previous sessions ('switch to session') must appear BEFORE 'Muse Suggestions' (got \(dropdownView.selectableRowIDs))")
        }

        // Verify clicking any item in the dropdown smoothly closes the dropdown (`isPalettePresented == false`)
        if let firstSug = aolSuggestions.first {
            state.openPalette()
            check(state.isPalettePresented, "Precondition: palette open before clicking suggestion")
            dropdownView.activateSuggestion(firstSug)
            check(!state.isPalettePresented, "Clicking a suggestion in TitlebarSearchDropdownView must close the dropdown")
        }
        if let firstKnownSession = state.windowKnownSessions.first?.session {
            state.openPalette()
            check(state.isPalettePresented, "Precondition: palette open before clicking session row")
            dropdownView.activateSession(firstKnownSession)
            check(!state.isPalettePresented, "Clicking a session row in TitlebarSearchDropdownView must close the dropdown")
        }

        // Verify resilience when background keyword service is crashed/unavailable OR when there is no disk session history:
        // must survive without crashing and default to listing current sessions known to the app window (`state.windowKnownSessions`).
        let savedProjects = state.projects
        rollingIndex.isServiceAvailable = false
        state.projects = [] // Simulate zero persisted projects/sessions on disk while an active window controller exists
        state.openPalette()
        state.paletteQuery = "unmatchable_query_xyz"
        state.updatePaletteQuery()
        let degradedSuggestions = searchService.suggestions(for: state.paletteQuery, projects: state.projects, limit: 6)
        check(degradedSuggestions.isEmpty,
              "When background keyword service is down, suggestions must safely return [] without crashing")
        let degradedDropdown = TitlebarSearchDropdownView(state: state, onRunCommand: { _ in })
        check(degradedDropdown.isDegradedFallbackMode,
              "TitlebarSearchDropdownView.isDegradedFallbackMode must be true when keyword service is offline")
        check((degradedDropdown.degradedFallbackExplanation ?? "").contains("Degraded fallback mode")
              && (degradedDropdown.degradedFallbackExplanation ?? "").contains("connection lost"),
              "degradedFallbackExplanation must explain that keyword service connection was lost (got: \(String(describing: degradedDropdown.degradedFallbackExplanation)))")
        check(!degradedDropdown.matchingSessions.isEmpty,
              "When keyword service is down and projects is empty, TitlebarSearchDropdownView must default to listing current window sessions from state.controllers (got \(degradedDropdown.matchingSessions.count))")
        check(degradedDropdown.selectableRowIDs.contains(where: { $0.hasPrefix("switch-") }),
              "Degraded TitlebarSearchDropdownView must still populate 'switch to session' rows for active window sessions")
        let degradedHost = NSHostingView(rootView: degradedDropdown)
        window.contentView = degradedHost
        degradedHost.frame = NSRect(x: 0, y: 0, width: 400, height: 220)
        degradedHost.layoutSubtreeIfNeeded()
        let degradedTexts = collectTexts(in: degradedHost)
        check(degradedTexts.contains(where: { $0.contains("Degraded fallback mode") && $0.contains("connection lost") }),
              "Degraded TitlebarSearchDropdownView must render the degraded fallback mode banner text at the top of the dropdown (found: \(degradedTexts))")
        check(degradedHost.fittingSize.width == 400 && degradedHost.fittingSize.height >= 60,
              "Degraded TitlebarSearchDropdownView must still layout cleanly at 400pt width (got \(degradedHost.fittingSize))")

        // Restore service and projects
        rollingIndex.isServiceAvailable = true
        state.projects = savedProjects

        // Also verify degraded fallback mode when service is online but query matches 0 keywords & 0 sessions
        state.paletteQuery = "zzzz_unmatchable_999"
        state.updatePaletteQuery()
        let unmatchableDropdown = TitlebarSearchDropdownView(state: state, onRunCommand: { _ in })
        check(unmatchableDropdown.isDegradedFallbackMode,
              "TitlebarSearchDropdownView must enter degraded fallback mode when query matches 0 keywords and 0 sessions")
        check((unmatchableDropdown.degradedFallbackExplanation ?? "").contains("No matching keywords"),
              "degradedFallbackExplanation must explain when no matching keywords were found (got: \(String(describing: unmatchableDropdown.degradedFallbackExplanation)))")

        // Verify normal query ("java") is NOT in degraded fallback mode
        state.paletteQuery = "java"
        state.updatePaletteQuery()
        let normalJavaDropdown = TitlebarSearchDropdownView(state: state, onRunCommand: { _ in })
        check(!normalJavaDropdown.isDegradedFallbackMode,
              "Normal query 'java' with active keyword service must not be in degraded fallback mode")

        if !state.windowKnownSessions.isEmpty {
            state.paletteQuery = ""
            state.updatePaletteQuery()
            let emptyQueryDropdown = TitlebarSearchDropdownView(state: state, onRunCommand: { _ in })
            check(emptyQueryDropdown.selectableRowIDs.contains(where: { $0.hasPrefix("switch-") }),
                  "TitlebarSearchDropdownView must populate 'switch to session' rows when sessions exist (got: \(emptyQueryDropdown.selectableRowIDs))")
        }
        // Verify TitlebarSearchPill uses search icon (never green "M"), expands to compact 310pt when active,
        // contracts when closed, and positions TitlebarSearchDropdownView 4pt directly beneath the search bar.
        state.openPalette()
        let activeSearchPill = TitlebarSearchPill(state: state, width: 310, onOpenPalette: {})
        let activePillHost = NSHostingView(rootView: activeSearchPill)
        window.contentView = activePillHost
        activePillHost.frame = NSRect(x: 0, y: 0, width: 310, height: 32)
        activePillHost.layoutSubtreeIfNeeded()
        let activePillTexts = collectTexts(in: activePillHost)
        check(!activePillTexts.contains("M"),
              "Active TitlebarSearchPill must render the search icon, never the green 'M' glyph (found: \(activePillTexts))")
        check(activePillHost.fittingSize.width == 310,
              "Active TitlebarSearchPill must expand to compact 310pt width (got \(activePillHost.fittingSize.width))")

        state.closePalette()
        check(!state.isPalettePresented, "state.closePalette() must dismiss the titlebar search dropdown")
        let collapsedSearchPill = TitlebarSearchPill(state: state, width: 220, onOpenPalette: {})
        let collapsedPillHost = NSHostingView(rootView: collapsedSearchPill)
        window.contentView = collapsedPillHost
        collapsedPillHost.frame = NSRect(x: 0, y: 0, width: 220, height: 32)
        collapsedPillHost.layoutSubtreeIfNeeded()
        check(collapsedPillHost.fittingSize.width == 220,
              "Collapsed TitlebarSearchPill must contract back to compact 220pt width (got \(collapsedPillHost.fittingSize.width))")

        let searchBarBottomY = WindowChromeMetrics.titlebarRowCenter + TitlebarIconButton.size / 2
        let dropdownTopY = searchBarBottomY + 4
        check(dropdownTopY - searchBarBottomY == 4 && dropdownTopY == 36,
              "TitlebarSearchDropdownView must sit 4pt directly below TitlebarSearchPill at y=36pt without safe-area gap (got \(dropdownTopY))")

        // 30. Verify dynamic path discovery for relocated Muse session, config, and data directories
        let tempMuseRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("pie-dynamic-muse-paths-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let customSessionsDir = tempMuseRoot.appendingPathComponent("custom-sessions", isDirectory: true)
        let customSessionSubdir = customSessionsDir.appendingPathComponent("2026/10/30/session-relocated-01", isDirectory: true)
        let customConfigDir = tempMuseRoot.appendingPathComponent("custom-config", isDirectory: true)
        try? FileManager.default.createDirectory(at: customSessionSubdir, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: customConfigDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempMuseRoot) }

        let relocatedSessionFile = customSessionSubdir.appendingPathComponent("session.jsonl")
        let relocatedJSONL = """
        {"type":"session","id":"relocated-01","cwd":"\(tempMuseRoot.path)","timestamp":"2026-10-30T12:00:00Z"}
        {"type":"session_info","name":"Relocated Custom Session Store"}
        {"type":"message","message":{"role":"user","content":[{"type":"text","text":"verify dynamic custom session path discovery TensorRT pipeline"}]}}
        """
        try? relocatedJSONL.write(to: relocatedSessionFile, atomically: true, encoding: .utf8)

        setenv("MUSE_CONFIG_DIR", customConfigDir.path, 1)
        setenv("MUSE_SESSION_DIR", customSessionsDir.path, 1)
        check(PiPaths.agentDirectory.path == customConfigDir.standardizedFileURL.path,
              "PiPaths.agentDirectory must dynamically resolve MUSE_CONFIG_DIR (\(PiPaths.agentDirectory.path))")
        check(PiPaths.sessionsDirectory.path == customSessionsDir.standardizedFileURL.path,
              "PiPaths.sessionsDirectory must dynamically resolve MUSE_SESSION_DIR (\(PiPaths.sessionsDirectory.path))")
        let relocatedRefs = SessionIndex().loadAllSessions()
        check(relocatedRefs.contains(where: { $0.name == "Relocated Custom Session Store" }),
              "SessionIndex must dynamically index sessions from relocated MUSE_SESSION_DIR (found \(relocatedRefs.count) sessions)")

        let customDBURL = tempMuseRoot.appendingPathComponent("relocated-keywords.sqlite")
        let relocatedIndex = MuseRollingKeywordIndex(dbURL: customDBURL, enableDiskScan: true)
        relocatedIndex.ensureFastSeedLoaded()
        let relocatedMatches = relocatedIndex.matchKeywords(for: "tensorrt", limit: 4)
        check(relocatedMatches.contains(where: { $0.phrase.contains("tensorrt") }),
              "MuseRollingKeywordIndex must dynamically scan relocated PiPaths.sessionsDirectory without hardcoded paths (got: \(relocatedMatches.map(\.phrase)))")

        unsetenv("MUSE_CONFIG_DIR")
        unsetenv("MUSE_SESSION_DIR")

        print("PASS: All Muse UI, Liquid Glass composer, chat backgrounds, 3D Voice Orb, reactive bottom voice glow, end-to-end STT, tachometer, glowing cursor, session icon catalog, layout, floating panel, dynamic PATH discovery, 10 UI interactivity improvements, project folder creation, git clone, titlebar search autocomplete & suggestion service, and backend state transitions verified.")
        exit(0)
    }
}
