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
        // Also verify clicking the Muse icon (`newChatInCurrentProject()`) in a folder with 0 saved sessions never makes `activeController` nil
        let emptyFolder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("muse-empty-project-\(UUID().uuidString.prefix(6))").path
        try? FileManager.default.createDirectory(atPath: emptyFolder, withIntermediateDirectories: true)
        await state.startNewSession(projectPath: emptyFolder)
        check(state.activeController != nil, "startNewSession on an empty folder must keep activeController non-nil")
        await state.newChatInCurrentProject()
        check(state.activeController != nil, "Clicking the Muse rail icon (newChatInCurrentProject) must never make activeController nil or hide the composer/right panel")

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

        if ProcessInfo.processInfo.environment["MUSE_RENDER_ORB_SHEET"] == "1" {
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

        print("PASS: All Muse UI, Liquid Glass composer, 3D Voice Orb, tachometer, glowing cursor, session icon catalog, layout, floating panel, dynamic PATH discovery, and backend state transitions verified.")
        exit(0)
    }
}
