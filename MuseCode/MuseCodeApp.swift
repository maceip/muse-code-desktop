//
//  PiCodeApp.swift
//  PiCode
//
//  A native macOS client for Pi Coding Agent.
//
//  PiCode is not a fork of Pi and does not reimplement its agent loop. It hosts
//  the user's own `pi` binary over Pi's documented RPC mode and renders the
//  result with native AppKit/SwiftUI surfaces.
//

import AppKit
import SwiftUI

@main
struct PiCodeApp: App {
    @State private var state: AppState

    init() {
        if CommandLine.arguments.contains("--selftest") {
            Self.runSelfTestAndExit()
        }
        _state = State(initialValue: AppState())
        #if DEBUG
        DebugSnapshot.scheduleIfRequested()
        DebugScrollBench.scheduleIfRequested()
        #endif
    }

    private static func runSelfTestAndExit() -> Never {
        let bundle = Bundle.main
        guard let bundleId = bundle.bundleIdentifier, !bundleId.isEmpty else {
            fputs("FAIL: missing CFBundleIdentifier in packaged app bundle\n", stderr)
            exit(1)
        }
        guard let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String,
              !version.isEmpty else {
            fputs("FAIL: missing CFBundleShortVersionString in packaged app bundle\n", stderr)
            exit(1)
        }
        guard let micDesc = bundle.infoDictionary?["NSMicrophoneUsageDescription"] as? String,
              !micDesc.isEmpty else {
            fputs("FAIL: missing NSMicrophoneUsageDescription in Info.plist\n", stderr)
            exit(1)
        }
        guard !SessionIconCatalog.all.isEmpty,
              let firstIcon = SessionIconCatalog.all.first,
              NSImage(named: "SessionIcons/\(firstIcon.id)") != nil || NSImage(named: firstIcon.id) != nil else {
            fputs("FAIL: SessionIconCatalog assets missing from compiled Assets.car\n", stderr)
            exit(1)
        }
        let sampleJSON = Data("""
        {
          "schemaVersion": 1,
          "allowance": {
            "tier": "pro",
            "window": { "usedPercent": 25.0, "resetsAtMs": 1793232000000 },
            "weekly": { "usedPercent": 20.0, "resetsAtMs": 1793750400000 }
          }
        }
        """.utf8)
        guard let decoded = try? JSONCoding.decode(sampleJSON) else {
            fputs("FAIL: JSONCoding.decode self-test failed\n", stderr)
            exit(1)
        }
        let usage = MuseUsageService.parseUsageResponse(decoded, fetchedAt: Date())
        guard usage.allowanceRemainingPercent == 75.0,
              usage.tier == "pro" else {
            fputs("FAIL: MuseUsageService.parseUsageResponse self-test failed\n", stderr)
            exit(1)
        }
        guard ComposerEnterExitPhase.settled.topPillScaleX == 1.0,
              ComposerEnterExitPhase.hidden.topPillOpacity == 0.0 else {
            fputs("FAIL: ComposerEnterExitPhase self-test failed\n", stderr)
            exit(1)
        }
        let f1 = VoiceOrbFrameDescriptor.descriptor(forFrame: 1)
        let f2 = VoiceOrbFrameDescriptor.descriptor(forFrame: 2)
        let f4 = VoiceOrbFrameDescriptor.descriptor(forFrame: 4)
        let f8 = VoiceOrbFrameDescriptor.descriptor(forFrame: 8)
        let f19 = VoiceOrbFrameDescriptor.descriptor(forFrame: 19)
        let f20 = VoiceOrbFrameDescriptor.descriptor(forFrame: 20)
        let f21 = VoiceOrbFrameDescriptor.descriptor(forFrame: 21)
        let f23 = VoiceOrbFrameDescriptor.descriptor(forFrame: 23)
        guard f1.pillFixedWidth == nil, f1.waveOpacity == 0.0,
              f2.pillFixedWidth == nil, f2.waveOpacity > 0.9, f2.subcontainerOpacity == 1.0,
              f4.pillFixedWidth == 240, f4.subcontainerBlur == 14.0,
              f8.orbPhase == .darkBlink, f8.waveOpacity < 0.1,
              f19.orbPhase == .centralAlmondLens,
              f20.orbPhase == .centralGlowingSun,
              f21.orbPhase == .singleCenterDot,
              f23.orbPhase == .constellationDots else {
            fputs("FAIL: VoiceOrbFrameDescriptor 23-frame progression self-test failed\n", stderr)
            exit(1)
        }
        print("PASS: MuseCode --selftest verified (\(bundleId) v\(version), \(SessionIconCatalog.all.count) icons, 23-frame orb verified)")
        exit(0)
    }

    var body: some Scene {
        WindowGroup {
            RootView(state: state)
                .frame(minWidth: 900, minHeight: 560)
                .preferredColorScheme(state.preferences.appearance.colorScheme)
        }
        // The content column draws its own header, so the window draws no title
        // bar or toolbar above it: the content runs to the top of the window and
        // the transcript's header is the only thing at the top.
        .windowStyle(.hiddenTitleBar)
        // The unified row places the traffic lights and the system sidebar
        // toggle on the project title's vertical centre.
        .windowToolbarStyle(.unifiedCompact)
        .commands { PiCodeCommands(state: state) }
    }
}

/// Menu bar commands. Every entry routes through the same `PaletteCommand` list
/// the command palette uses, so the two can never drift apart.
struct PiCodeCommands: Commands {
    let state: AppState

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(PaletteCommand.newSession.title) { state.run(.newSession) }
                .keyboardShortcut("n", modifiers: .command)
            Button(PaletteCommand.addProject.title) { state.run(.addProject) }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Divider()
            Button(PaletteCommand.openInTerminal.title) { state.run(.openInTerminal) }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(state.activeController == nil)
        }

        CommandGroup(replacing: .appSettings) {
            Button(PaletteCommand.openSettings.title) { state.run(.openSettings) }
                .keyboardShortcut(",", modifiers: .command)
        }

        CommandMenu("Session") {
            Button(PaletteCommand.renameSession.title) { state.run(.renameSession) }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(state.activeController == nil)
            Divider()
            Button(PaletteCommand.exportSession.title) { state.run(.exportSession) }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(state.activeController == nil)
            Button(PaletteCommand.copyTranscript.title) { state.run(.copyTranscript) }
                .disabled(state.activeController == nil)
            Button(PaletteCommand.copyLastResponse.title) { state.run(.copyLastResponse) }
                .disabled(state.activeController == nil)
            Divider()
            Button(PaletteCommand.deleteSession.title) { state.run(.deleteSession) }
                .disabled(state.activeController == nil)
        }

        CommandMenu("Agent") {
            Button(PaletteCommand.focusComposer.title) { state.run(.focusComposer) }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(state.activeController == nil)
            Button(PaletteCommand.interrupt.title) { state.run(.interrupt) }
                .disabled(state.activeController == nil)
            Button(PaletteCommand.abortRun.title) { state.run(.abortRun) }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(state.activeController == nil)
            Divider()
            Button(PaletteCommand.cycleModel.title) { state.run(.cycleModel) }
                .disabled(state.activeController == nil)
            Button(PaletteCommand.cycleThinkingLevel.title) { state.run(.cycleThinkingLevel) }
                .disabled(state.activeController == nil)
            Divider()
            Button(PaletteCommand.refreshSessions.title) { state.run(.refreshSessions) }
                .keyboardShortcut("r", modifiers: .command)
        }

        CommandGroup(after: .sidebar) {
            Button(PaletteCommand.toggleInspector.title) { state.run(.toggleInspector) }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Button(PaletteCommand.toggleSidebar.title) { state.run(.toggleSidebar) }
                .keyboardShortcut("s", modifiers: [.control, .command])
        }
    }
}
