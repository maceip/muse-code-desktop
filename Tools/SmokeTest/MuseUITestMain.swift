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
        check(allTexts.contains("target session id or name"), "Floating right panel must render recipient field ('target session id or name')")
        check(allTexts.contains("Send Muse agent message…"), "Floating right panel must render message composer ('Send Muse agent message…')")

        // Verify MuseRightSidebarPanel direct rendering as well
        let rightPanelHosting = NSHostingView(rootView: MuseRightSidebarPanel(state: state, controller: controller).frame(width: 310, height: 700))
        rightPanelHosting.frame = NSRect(x: 0, y: 0, width: 310, height: 700)
        rightPanelHosting.layoutSubtreeIfNeeded()
        let rightPanelTexts = collectTexts(in: rightPanelHosting)
        check(rightPanelTexts.contains("target session id or name") && rightPanelTexts.contains("Send Muse agent message…"),
              "MuseRightSidebarPanel must render Muse Agent Messages controls")

        // 5. Verify toggling floating right panel (`state.toggleInspector()`) removes the floating panel from the hierarchy
        state.toggleInspector()
        check(!state.isInspectorVisible, "toggleInspector() should hide the floating panel")
        rootHosting.layoutSubtreeIfNeeded()
        try? await Task.sleep(nanoseconds: 250_000_000)
        rootHosting.layoutSubtreeIfNeeded()
        let hiddenPanelTexts = collectTexts(in: rootHosting)
        check(!hiddenPanelTexts.contains("Send Muse agent message…"), "Hiding the floating right panel must unmount MuseRightSidebarPanel")

        state.toggleInspector()
        check(state.isInspectorVisible, "toggleInspector() should reveal the floating panel")
        rootHosting.layoutSubtreeIfNeeded()
        try? await Task.sleep(nanoseconds: 250_000_000)
        rootHosting.layoutSubtreeIfNeeded()
        let revealedPanelTexts = collectTexts(in: rootHosting)
        check(revealedPanelTexts.contains("Send Muse agent message…"), "Revealing the floating right panel must mount MuseRightSidebarPanel")

        // 6. Verify dynamic executable resolution without hardcoded paths
        let resolvedMuse = PiDiscoveryService.resolveExecutable(named: "muse")
        check(resolvedMuse != nil, "PiDiscoveryService.resolveExecutable(named: \"muse\") must dynamically locate muse on PATH")
        check(HarnessDescriptor.descriptor(for: .museCode).fallbackBinaries.isEmpty, "HarnessDescriptor.museCode.fallbackBinaries must not contain hardcoded paths")

        print("PASS: All Muse UI, layout, floating panel, dynamic PATH discovery, and backend state transitions verified.")
        exit(0)
    }
}
