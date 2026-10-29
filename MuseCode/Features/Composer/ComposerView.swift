//
//  ComposerView.swift
//  PiCode
//
//  The prompt composer: text, attachments, model/thinking controls, and the
//  send/queue decision.
//
//  PiCode sends exactly what the user typed. Slash commands and `@path`
//  references are Pi's own prompt syntax, so the composer only autocompletes
//  them; it never rewrites the prompt on the way out.
//

import AppKit
import SwiftUI

/// Shape, padding and height constants shared by the composer and its harness.
///
/// They are here, and not inline in the view, so the harness can *predict* the
/// box's height and width instead of hard-coding a number that then drifts: it
/// asserts the measured box against `boxHeight(forEditor:)` and against
/// `ConversationLayout.maxContentWidth`.
enum ComposerMetrics {
    /// Rounded enough that the box reads as one soft object next to the sidebar's
    /// pills, small enough that a single line does not look like a capsule.
    static let cornerRadius: CGFloat = 22

    /// The box's own padding. Roomy on the sides and underneath: the prompt should
    /// sit in the box rather than press against its edge, and the controls need air
    /// below the text they act on. There is deliberately *none* on top — the editor
    /// already carries its own text inset, and the box must shrink to exactly the
    /// editor's height plus this chrome, so a two-line prompt is a two-line box and
    /// not a box with a blank band above it.
    static let boxHorizontalPadding: CGFloat = 14
    static let boxTopPadding: CGFloat = 0
    static let boxBottomPadding: CGFloat = 10

    /// Between the editor and the control row, and a little more before an
    /// attachment chip row when one is showing.
    static let editorControlGap: CGFloat = 7
    static let attachmentGap: CGFloat = 8

    /// The context strip the box sits on: how much of it shows above the box,
    /// and how far the box overlaps it so the strip reads as tucked behind.
    static let contextStripHeight: CGFloat = 36
    static let contextStripOverlap: CGFloat = 18
    static let contextStripInset: CGFloat = 14

    /// What one control row takes. Not a guess: the harness measures the drawn
    /// box against `boxHeight(forEditor:)`, so a control that grows taller than
    /// this is caught rather than silently absorbed.
    static let controlRowHeight: CGFloat = 28

    /// The editor's own height: two lines always visible, six before it starts
    /// scrolling instead of growing further.
    static var editorMinHeight: CGFloat { ComposerTextView.height(forLines: ComposerTextView.minimumLines) + 8 }
    static var editorMaxHeight: CGFloat { ComposerTextView.height(forLines: ComposerTextView.maximumLines) + 8 }

    /// The box's height for an editor of `editorHeight` — the number the harness
    /// checks the rendered box against. Attachments add a row on top.
    static func boxHeight(forEditor editorHeight: CGFloat) -> CGFloat {
        editorHeight + boxTopPadding + editorControlGap + controlRowHeight + boxBottomPadding
    }
}

struct ComposerView: View {
    @Bindable var state: AppState
    var controller: PiSessionController
    var focusTick: Int
    /// What the agent has to say above the box — trust prompts, notices,
    /// extension widgets, the queue. Drawn in the same light, borderless band
    /// as the context strip, tucked behind the top of the box.
    var tray: AnyView? = nil

    @State private var text = ""
    @State private var attachments: [Attachment] = []
    @State private var suggestionIndex = 0
    @State private var fileMatches: [FileNode] = []
    @State private var fileSearchTask: Task<Void, Never>?
    @State private var isSending = false
    @State private var attachmentError: String?
    @State private var isDropTargeted = false
    @State private var isModelPickerPresented = false
    @State private var orbFrame: Int = 1
    @State private var orbAnimationTask: Task<Void, Never>?
    @State private var isTransitioningOutOfOrb = false
    @State private var isShowingVoiceErrorPopover = false
    @State private var enterExitPhase: ComposerEnterExitPhase = .hidden
    @State private var animationTask: Task<Void, Never>?
    @Namespace private var morphNamespace
    @Bindable private var stt = MuseVoiceSTTService.shared

    private var isVoiceActive: Bool {
        stt.isRecording || stt.isTranscribing
    }

    private var orbDescriptor: VoiceOrbFrameDescriptor {
        VoiceOrbFrameDescriptor.descriptor(forFrame: orbFrame)
    }

    private var isWaveIgniting: Bool {
        orbFrame >= 2 && orbFrame <= 5
    }

    private var isContractedToOrb: Bool {
        orbFrame >= 6
    }

    /// Before the first turn (`controller.items.isEmpty`), the composer renders as two
    /// separate Liquid Glass containers (top input pill + bottom subcontainer).
    /// After the first turn (`!controller.items.isEmpty`), the two containers animate-morph
    /// into one unified, consolidated Liquid Glass bar.
    var isConsolidatedBar: Bool {
        !controller.items.isEmpty
    }

    var body: some View {
        VStack(alignment: .center, spacing: 10) {
            if !suggestions.isEmpty && !isContractedToOrb {
                ComposerSuggestionList(
                    suggestions: suggestions,
                    selectedIndex: suggestionIndex,
                    onSelect: accept(suggestion:),
                    onHover: { index in suggestionIndex = index }
                )
            }

            if let attachmentError {
                BannerView(level: .warning, title: "Attachment not added", message: attachmentError, onDismiss: { self.attachmentError = nil })
            }

            if let tray, !isContractedToOrb {
                tray.environment(\.isInComposerTray, true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(
                        LiquidGlassCardBackground(cornerRadius: 18, isDarkTopPill: false)
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }

            // Top Smoked Liquid Glass Input Pill (or Consolidated Single Bar after first turn) — morphs into the 3D Liquid Glass Voice Orb when mic is active
            morphingTopInputOrOrb
                .scaleEffect(
                    x: enterExitPhase.topPillScaleX,
                    y: enterExitPhase.topPillScaleY,
                    anchor: .top
                )
                .blur(radius: enterExitPhase.topPillBlur)
                .offset(y: enterExitPhase.topPillOffsetY)
                .opacity(enterExitPhase.topPillOpacity)

            // Bottom Frosted Liquid Glass Subcontainer — shown before the first turn, and morphs into the top bar after the first turn
            if !isContractedToOrb && !isConsolidatedBar {
                liquidGlassControlCard
                    .scaleEffect(
                        x: orbFrame > 1 ? orbDescriptor.subcontainerScaleX : enterExitPhase.subcontainerScaleX,
                        y: orbFrame > 1 ? orbDescriptor.subcontainerScaleY : enterExitPhase.subcontainerScaleY,
                        anchor: .top
                    )
                    .offset(y: orbFrame > 1 ? orbDescriptor.subcontainerOffsetY : enterExitPhase.subcontainerOffsetY)
                    .blur(radius: orbFrame > 1 ? orbDescriptor.subcontainerBlur : enterExitPhase.subcontainerBlur)
                    .opacity(orbFrame > 1 ? orbDescriptor.subcontainerOpacity : enterExitPhase.subcontainerOpacity)
                    .transition(.museSubcontainerEnterExit)
            }
        }
        .animation(.spring(response: 0.44, dampingFraction: 0.84), value: isConsolidatedBar)
        .animation(.interactiveSpring(response: 0.14, dampingFraction: 0.86), value: orbFrame)
        .onChange(of: stt.isRecording) { _, recording in
            if recording {
                if orbFrame == 1 {
                    startVoiceOrb23FrameEntry()
                }
            } else if stt.isTranscribing {
                playVoiceOrbFrames19To23(collapseWhenDone: false)
            }
        }
        .onChange(of: stt.isTranscribing) { _, transcribing in
            if !transcribing && !stt.isRecording && orbFrame > 1 && !isTransitioningOutOfOrb {
                playVoiceOrbFrames19To23(collapseWhenDone: true)
            }
        }
        .onAppear {
            loadDraft()
            if isVoiceActive {
                orbFrame = stt.isTranscribing ? 22 : 9
                enterExitPhase = .settled
            } else {
                orbFrame = 1
                playComposerEnterAnimation(withLeadingExit: false)
            }
        }
        .onDisappear {
            animationTask?.cancel()
            orbAnimationTask?.cancel()
            enterExitPhase = .hidden
        }
        .onChange(of: ObjectIdentifier(controller)) { _, _ in
            loadDraft()
            if !isVoiceActive {
                playComposerEnterAnimation(withLeadingExit: true)
            }
        }
        .onChange(of: state.selectedSessionKey) { _, _ in
            if !isVoiceActive {
                playComposerEnterAnimation(withLeadingExit: true)
            }
        }
        .onChange(of: state.composerEnterAnimationTick) { _, _ in
            if !isVoiceActive {
                playComposerEnterAnimation(withLeadingExit: true)
            }
        }
        .onChange(of: controller.draftKey) { _, _ in loadDraft() }
        .onChange(of: controller.composerPrefill) { _, newValue in
            guard let newValue, !newValue.isEmpty else { return }
            text = newValue
            controller.composerPrefill = nil
        }
        .onChange(of: state.composerInsertion) { _, newValue in
            guard let newValue, !newValue.isEmpty else { return }
            text = text.isEmpty ? newValue : text + " " + newValue
            state.composerInsertion = nil
        }
        .onChange(of: text) { _, newValue in
            controller.drafts.setText(newValue, for: controller.draftKey, attachments: attachments)
            suggestionIndex = 0
            refreshFileMatchesIfNeeded()
        }
    }

    // MARK: - Liquid Glass Top Input Pill & Morphing 3D Voice Orb (`orb1.gif`, 23 Frames)

    private var morphingTopInputOrOrb: some View {
        let desc = orbDescriptor
        return ZStack {
            if isContractedToOrb {
                LiquidGlassVoiceOrbView(
                    orbFrame: orbFrame,
                    descriptor: desc,
                    isRecording: stt.isRecording,
                    isTranscribing: stt.isTranscribing,
                    audioLevel: stt.audioLevel,
                    duration: stt.recordingDuration,
                    onTap: { toggleVoiceOrbRecording() }
                )
                .frame(width: desc.pillFixedWidth ?? 92, height: desc.pillHeight ?? 92)
                .transition(.identity)
            } else {
                liquidGlassInputPill
                    .transition(.identity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .popover(isPresented: $isShowingVoiceErrorPopover, arrowEdge: .top) {
            voiceErrorPopover
        }
    }

    private var liquidGlassInputPill: some View {
        let desc = orbDescriptor
        let barCornerRadius: CGFloat = orbFrame > 1 ? desc.pillCornerRadius : (isConsolidatedBar ? 22 : 28)
        return VStack(alignment: .leading, spacing: (isConsolidatedBar && orbFrame == 1) ? 8 : 0) {
            HStack(alignment: .center, spacing: 10) {
                ComposerTextView(
                    text: $text,
                    placeholder: placeholder,
                    focusTick: focusTick,
                    sendKey: state.preferences.sendKey,
                    suggestionsActive: !suggestions.isEmpty,
                    isEnabled: controller.connection.isConnected,
                    onSend: { send() },
                    onFollowUp: { send(delivery: .followUp) },
                    onEscape: handleEscape,
                    onMoveSuggestion: moveSuggestion,
                    onAcceptSuggestion: acceptCurrentSuggestion
                )
                .frame(minHeight: ComposerMetrics.editorMinHeight, maxHeight: ComposerMetrics.editorMaxHeight)
                .fixedSize(horizontal: false, vertical: true)
                .opacity(desc.editorAndControlsOpacity)

                if !isConsolidatedBar {
                    HStack(spacing: 8) {
                        voiceMicButton
                            .matchedGeometryEffect(id: "composerMicButton", in: morphNamespace)

                        if isStreamingRun || canSend {
                            primaryActionButton
                                .matchedGeometryEffect(id: "composerPrimaryAction", in: morphNamespace)
                        }
                    }
                    .opacity(desc.editorAndControlsOpacity)
                }
            }

            if isConsolidatedBar && orbFrame == 1 {
                if !attachments.isEmpty {
                    attachmentRow
                        .opacity(desc.editorAndControlsOpacity)
                }

                // Consolidated single-bar control strip (minimized attachment +, folder, branch, model, access, tachometer, mic, send)
                HStack(spacing: 12) {
                    Button {
                        chooseAttachments()
                    } label: {
                        HugeIcon(name: "add-01", size: 15)
                            .foregroundStyle(Color.white.opacity(0.82))
                            .frame(width: 24, height: 24)
                            .background(Color.white.opacity(0.08), in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .accessibilityLabel("Attach files or images")
                    .help("Attach images or text files — drag and drop works too")
                    .matchedGeometryEffect(id: "composerAttachControl", in: morphNamespace)

                    ComposerContextStrip(state: state, controller: controller, isGlassSurface: true)
                        .matchedGeometryEffect(id: "composerContextStrip", in: morphNamespace)

                    modelThinkingMenu
                        .matchedGeometryEffect(id: "composerModelMenu", in: morphNamespace)

                    Spacer(minLength: 10)

                    ComposerAccessControl(controller: controller)
                        .matchedGeometryEffect(id: "composerAccessControl", in: morphNamespace)

                    MuseCreditBatteryButton(controller: controller, isGlassSurface: true)
                        .matchedGeometryEffect(id: "composerTachometer", in: morphNamespace)

                    voiceMicButton
                        .matchedGeometryEffect(id: "composerMicButton", in: morphNamespace)

                    primaryActionButton
                        .matchedGeometryEffect(id: "composerPrimaryAction", in: morphNamespace)
                }
                .opacity(desc.editorAndControlsOpacity)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .padding(.leading, orbFrame >= 4 ? 0 : (isConsolidatedBar ? 16 : 18))
        .padding(.trailing, orbFrame >= 4 ? 0 : 14)
        .padding(.vertical, orbFrame >= 4 ? 0 : (isConsolidatedBar ? 10 : 11))
        .frame(
            maxWidth: desc.pillFixedWidth ?? .infinity,
            minHeight: desc.pillHeight
        )
        .background(
            ZStack {
                LiquidGlassCardBackground(
                    cornerRadius: barCornerRadius,
                    isDarkTopPill: true,
                    isDropTargeted: isDropTargeted,
                    sphereMix: desc.sphereMix
                )

                // Frames 2–5 of `Screenshot 2026-10-28 at 14.58.49.png`:
                // Frame 2 ignites the full-width chromatic plasma wave across the top pill while placeholder & mic are still visible;
                // Frames 3–5 contract the pill horizontally into the 3D sphere while the lower subcontainer blurs and dissolves.
                if orbFrame >= 2 {
                    PlasmaHorizonWaveCanvas(
                        isCircularOrb: orbFrame >= 5,
                        orbFrame: orbFrame,
                        audioLevel: stt.audioLevel,
                        waveOpacity: desc.waveOpacity
                    )
                    .clipShape(RoundedRectangle(cornerRadius: barCornerRadius, style: .continuous))
                    .transition(.opacity)
                }
            }
        )
        .dropDestination(for: URL.self) { urls, _ in
            addAttachments(urls)
            return true
        } isTargeted: { isDropTargeted = $0 }
    }

    private var voiceMicButton: some View {
        Button {
            toggleVoiceOrbRecording()
        } label: {
            HugeIcon(name: "mic-01", size: 17)
                .foregroundStyle(Color.white.opacity(0.82))
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .accessibilityLabel("Voice input via Muse built-in STT")
        .help("Voice input via Muse built-in STT (`muse voice transcribe`)")
        .contextMenu {
            Button("Transcribe Audio Clip (.wav / .m4a)…") {
                pickAndTranscribeAudioFile()
            }
        }
    }

    // MARK: - Bottom Frosted Liquid Glass Control Card (Landing State Before First Turn)

    private var liquidGlassControlCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Row 1: Project Folder & Git Branch on the left, Model & Reasoning Effort Selector on the right
            HStack(spacing: 14) {
                ComposerContextStrip(state: state, controller: controller, isGlassSurface: true)
                    .matchedGeometryEffect(id: "composerContextStrip", in: morphNamespace)
                ComposerAccessControl(controller: controller)
                    .matchedGeometryEffect(id: "composerAccessControl", in: morphNamespace)
                Spacer(minLength: 14)
                modelThinkingMenu
                    .matchedGeometryEffect(id: "composerModelMenu", in: morphNamespace)
            }

            Rectangle()
                .fill(Color.white.opacity(0.14))
                .frame(height: 1)

            if !attachments.isEmpty {
                attachmentRow
            }

            // Row 2: Attach Control on left, Icon-Only Tachometer Credit Gauge on right
            HStack(spacing: 12) {
                Button {
                    chooseAttachments()
                } label: {
                    HStack(spacing: 8) {
                        HugeIcon(name: "add-01", size: 15)
                            .foregroundStyle(Color.white.opacity(0.84))
                        Text("Attach files or images")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.white.opacity(0.88))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focusEffectDisabled()
                .accessibilityLabel("Attach files or images")
                .help("Attach images or text files — drag and drop works too")
                .matchedGeometryEffect(id: "composerAttachControl", in: morphNamespace)

                Spacer(minLength: 14)

                MuseCreditBatteryButton(controller: controller, isGlassSurface: true)
                    .matchedGeometryEffect(id: "composerTachometer", in: morphNamespace)
            }
        }
        .opacity(enterExitPhase.subcontainerInnerOpacity)
        .blur(radius: enterExitPhase.subcontainerInnerBlur)
        .offset(y: enterExitPhase.subcontainerInnerOffsetY)
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .background(
            LiquidGlassCardBackground(
                cornerRadius: enterExitPhase == .pillWithBlurredCapsule ? 28 : 24,
                isDarkTopPill: false,
                isDropTargeted: isDropTargeted
            )
        )
    }

    // MARK: - Staged Enter & Exit Choreography (`enter-anim.gif`)

    func playComposerEnterAnimation(withLeadingExit: Bool) {
        animationTask?.cancel()
        animationTask = Task { @MainActor in
            if withLeadingExit && enterExitPhase != .hidden {
                // Reverse exit stages (Frames 05 -> 03 -> 02 -> 01)
                withAnimation(.easeIn(duration: 0.08)) {
                    enterExitPhase = .subcontainerExpanding
                }
                try? await Task.sleep(nanoseconds: 75_000_000)
                guard !Task.isCancelled else { return }

                withAnimation(.easeIn(duration: 0.09)) {
                    enterExitPhase = .pillWithBlurredCapsule
                }
                try? await Task.sleep(nanoseconds: 85_000_000)
                guard !Task.isCancelled else { return }

                withAnimation(.easeIn(duration: 0.07)) {
                    enterExitPhase = .hidden
                }
                try? await Task.sleep(nanoseconds: 65_000_000)
                guard !Task.isCancelled else { return }
            } else {
                enterExitPhase = .hidden
            }

            // Frame 02 (200ms): Top pill snaps in crisp at 100%; bottom subcontainer materializes
            // as a compact, blurred dark glass capsule centered beneath the top pill.
            withAnimation(.spring(response: 0.18, dampingFraction: 0.88)) {
                enterExitPhase = .pillWithBlurredCapsule
            }
            try? await Task.sleep(nanoseconds: 95_000_000)
            guard !Task.isCancelled else { return }

            // Frames 03–04 (300–400ms): Bottom subcontainer expands outward & downward from `.top`
            // to 96% with soft blur while inner rows fade in at 54% opacity.
            withAnimation(.spring(response: 0.22, dampingFraction: 0.84)) {
                enterExitPhase = .subcontainerExpanding
            }
            try? await Task.sleep(nanoseconds: 135_000_000)
            guard !Task.isCancelled else { return }

            // Frame 05 (500ms+): Settles crisp at 100% scale, 0 blur, and 100% inner contrast.
            withAnimation(.spring(response: 0.22, dampingFraction: 0.88)) {
                enterExitPhase = .settled
            }
        }
    }

    func playComposerExitAnimation() {
        animationTask?.cancel()
        animationTask = Task { @MainActor in
            withAnimation(.easeIn(duration: 0.08)) {
                enterExitPhase = .subcontainerExpanding
            }
            try? await Task.sleep(nanoseconds: 75_000_000)
            guard !Task.isCancelled else { return }

            withAnimation(.easeIn(duration: 0.09)) {
                enterExitPhase = .pillWithBlurredCapsule
            }
            try? await Task.sleep(nanoseconds: 85_000_000)
            guard !Task.isCancelled else { return }

            withAnimation(.easeIn(duration: 0.08)) {
                enterExitPhase = .hidden
            }
        }
    }

    private var placeholder: String {
        if !controller.connection.isConnected { return "Muse is not running…" }
        if controller.runtime.isBusy { return "Steer Muse, or queue a follow-up…" }
        return "Ask Anything"
    }

    private var attachmentRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(attachments) { attachment in
                    HStack(spacing: 6) {
                        HugeIcon(name: attachment.systemImage)
                            .imageScale(.small)
                            .foregroundStyle(Color.white.opacity(0.82))
                        VStack(alignment: .leading, spacing: 0) {
                            Text(attachment.fileName)
                                .font(.caption)
                                .foregroundStyle(Color.white.opacity(0.95))
                                .lineLimit(1)
                            Text(attachment.displaySize)
                                .font(.caption2)
                                .foregroundStyle(Color.white.opacity(0.65))
                        }
                        Button {
                            attachments.removeAll { $0.id == attachment.id }
                        } label: {
                            HugeIcon(name: "cancel-circle")
                                .imageScale(.small)
                                .foregroundStyle(Color.white.opacity(0.72))
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove \(attachment.fileName)")
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Color.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.22), lineWidth: 1)
                    )
                }
            }
            .padding(.horizontal, 2)
        }
    }

    // MARK: - 23-Frame Voice Orb Morphing & STT Recording Actions (`Screenshot 2026-10-28 at 14.58.49.png`)

    private func toggleVoiceOrbRecording() {
        if orbFrame == 1 && !isVoiceActive {
            startVoiceOrb23FrameEntry()
            Task {
                await stt.toggleRecording(installation: controller.museInstallation) { transcribed in
                    appendTranscription(transcribed)
                }
                if stt.lastError != nil {
                    isShowingVoiceErrorPopover = true
                }
                if !stt.isRecording && !stt.isTranscribing && !isTransitioningOutOfOrb {
                    playVoiceOrbFrames19To23(collapseWhenDone: true)
                }
            }
        } else {
            // Stopping recording: step through Frames 19 -> 20 -> 21 -> 22 -> 23 (almond lens -> white sun -> single dot -> 6-dot constellation)
            playVoiceOrbFrames19To23(collapseWhenDone: true)
            Task {
                if stt.isRecording {
                    await stt.toggleRecording(installation: controller.museInstallation) { transcribed in
                        appendTranscription(transcribed)
                    }
                    if stt.lastError != nil {
                        isShowingVoiceErrorPopover = true
                    }
                }
            }
        }
    }

    /// Steps deterministically through Frames 1 -> 2 -> 3 -> 4 -> 5 -> 6 -> 7 -> 8 (dark pulse) -> 9..18 (active listening loop).
    private func startVoiceOrb23FrameEntry() {
        orbAnimationTask?.cancel()
        isTransitioningOutOfOrb = false
        orbAnimationTask = Task { @MainActor in
            // Frames 2..7: Full pill ignition -> progressive horizontal contraction & subcontainer blur -> 3D sphere
            for frame in 2...7 {
                guard !Task.isCancelled else { return }
                withAnimation(.interactiveSpring(response: 0.12, dampingFraction: 0.86)) {
                    orbFrame = frame
                }
                try? await Task.sleep(nanoseconds: 75_000_000)
            }

            // Frame 8: Dark obsidian pulse / blink right before active voice listening
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.08)) {
                orbFrame = 8
            }
            try? await Task.sleep(nanoseconds: 85_000_000)

            // Frames 9..18: Active listening loop with undulating horizon wave & live `mic interactivity`
            var activeFrame = 9
            while !Task.isCancelled && (stt.isRecording || (!stt.isTranscribing && !isTransitioningOutOfOrb && orbFrame >= 8 && orbFrame <= 18)) {
                withAnimation(.linear(duration: 0.09)) {
                    orbFrame = activeFrame
                }
                try? await Task.sleep(nanoseconds: 95_000_000)
                activeFrame = activeFrame < 18 ? (activeFrame + 1) : 9
                if !stt.isRecording && !stt.isTranscribing {
                    break
                }
            }
        }
    }

    /// Plays Frames 19 -> 20 -> 21 -> 22 -> 23 (central almond lens -> glowing white sun -> single dot -> 6 orbiting dots)
    /// and then smoothly expands back to the full composer panel once transcription finishes.
    private func playVoiceOrbFrames19To23(collapseWhenDone: Bool) {
        guard !isTransitioningOutOfOrb else { return }
        isTransitioningOutOfOrb = true
        orbAnimationTask?.cancel()
        orbAnimationTask = Task { @MainActor in
            for frame in 19...23 {
                guard !Task.isCancelled else { return }
                withAnimation(.easeInOut(duration: 0.09)) {
                    orbFrame = frame
                }
                try? await Task.sleep(nanoseconds: 95_000_000)
            }

            // Hold on the 6-dot constellation (Frames 22-23) while `muse voice transcribe` is still running
            while !Task.isCancelled && stt.isTranscribing {
                try? await Task.sleep(nanoseconds: 110_000_000)
            }

            guard collapseWhenDone || !stt.isTranscribing else {
                isTransitioningOutOfOrb = false
                return
            }

            // Smoothly morph back through Frames 5 -> 4 -> 3 -> 2 -> 1 into the full composer panel
            enterExitPhase = .settled
            for reverseFrame in [5, 4, 3, 2, 1] {
                guard !Task.isCancelled else { return }
                withAnimation(.spring(response: 0.16, dampingFraction: 0.86)) {
                    orbFrame = reverseFrame
                }
                try? await Task.sleep(nanoseconds: 55_000_000)
            }
            isTransitioningOutOfOrb = false
        }
    }

    private func collapseOrbBackToInputPill() {
        playVoiceOrbFrames19To23(collapseWhenDone: true)
    }

    private func appendTranscription(_ transcribed: String) {
        let trimmed = transcribed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if text.isEmpty {
            text = trimmed
        } else if text.hasSuffix(" ") || text.hasSuffix("\n") {
            text += trimmed
        } else {
            text += " " + trimmed
        }
    }

    private func pickAndTranscribeAudioFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a .wav or .m4a audio clip to transcribe with `muse voice transcribe`"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            if let result = await stt.transcribeFile(at: url, installation: controller.museInstallation) {
                appendTranscription(result)
            } else if stt.lastError != nil {
                isShowingVoiceErrorPopover = true
            }
        }
    }

    private var voiceErrorPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Muse Voice STT", huge: "mic-01")
                .font(.callout.weight(.semibold))
            Text(stt.lastError ?? "Could not transcribe audio.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Transcribe Audio File (.wav / .m4a)…") {
                isShowingVoiceErrorPopover = false
                pickAndTranscribeAudioFile()
            }
            .buttonStyle(.settingsPill)
        }
        .padding(12)
        .frame(width: 260)
    }

    /// Idle it sends; working it stops. Both are one button, in the place the
    /// hand already is.
    @ViewBuilder
    private var primaryActionButton: some View {
        if isStreamingRun {
            Button {
                Task {
                    await controller.interrupt()
                    text = controller.drafts.text(for: controller.draftKey)
                }
            } label: {
                HugeIcon(name: "stop")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Circle().fill(AppTheme.accentBlue))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Stop Muse and put anything queued back in the box (esc; ⌘. aborts without restoring)")
        } else {
            Button {
                send(delivery: .automatic)
            } label: {
                HugeIcon(name: "arrow-up-02", size: 15)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(canSend ? Color.white : Color.white.opacity(0.45))
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(canSend ? AppTheme.accentBlue : Color.white.opacity(0.14))
                    )
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .focusEffectDisabled()
            .disabled(!canSend)
            .help("Send (⏎)")
        }
    }

    /// Model and reasoning effort remain one control, rendered in transparent
    /// baseline style inside the frosted Liquid Glass card.
    private var modelThinkingMenu: some View {
        Button {
            isModelPickerPresented.toggle()
        } label: {
            HStack(spacing: 8) {
                HugeIcon(name: "sparkles", size: 15)
                    .foregroundStyle(Color.white.opacity(0.82))
                Text(controller.model?.displayName ?? "Model")
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.95))
                    .lineLimit(1)
                if let effort {
                    Text(effort.capitalized)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(Color.white.opacity(0.72))
                }
                HugeIcon(name: "arrow-down-01", size: 11)
                    .foregroundStyle(Color.white.opacity(0.70))
                    .padding(.leading, 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .fixedSize()
        .help("Model and reasoning effort used for new prompts")
        .popover(isPresented: $isModelPickerPresented, arrowEdge: .bottom) {
            ComposerModelPicker(
                controller: controller,
                state: state,
                onDismiss: { isModelPickerPresented = false }
            )
        }
    }

    /// The reasoning effort to draw beside the model, or `nil` when the model is
    /// not reasoning: an "off" level is not a second word to read, it is silence.
    private var effort: String? {
        guard let level = controller.thinkingLevel?.trimmingCharacters(in: .whitespaces),
              !level.isEmpty,
              level.lowercased() != "off"
        else { return nil }
        return level
    }

    // MARK: - Send

    private var isStreamingRun: Bool { controller.runtime.isBusy }

    private var canSend: Bool {
        let hasContent = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || attachments.contains { $0.imagePayload != nil }
        return hasContent && controller.connection.isConnected && !isSending
    }

    private func send(delivery: PiSessionController.PromptDelivery = .automatic) {
        guard canSend else { return }
        let outgoing = text
        let outgoingAttachments = attachments
        isSending = true
        // Cleared now rather than once Pi answers, so the prompt leaves the box
        // the moment it appears in the transcript (a new chat's first prompt
        // visibly flies out of it). A failed send puts it back, unless the user
        // has started typing something else meanwhile.
        text = ""
        attachments = []
        fileMatches = []
        Task {
            let delivered = await controller.send(text: outgoing, attachments: outgoingAttachments, delivery: delivery)
            isSending = false
            if !delivered, text.isEmpty, attachments.isEmpty {
                text = outgoing
                attachments = outgoingAttachments
            }
        }
    }

    private func handleEscape() {
        if isVoiceActive || isContractedToOrb {
            toggleVoiceOrbRecording()
            return
        }
        if !suggestions.isEmpty {
            text = suggestionContextCleared()
            fileMatches = []
            return
        }
        if controller.hasPendingWork {
            Task {
                await controller.interrupt()
                text = controller.drafts.text(for: controller.draftKey)
            }
        }
    }

    private func loadDraft() {
        text = controller.drafts.text(for: controller.draftKey)
    }

    // MARK: - Attachments

    private func chooseAttachments() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.message = "Images are sent to Pi as image content. Text files are inlined as @path references."
        guard panel.runModal() == .OK else { return }
        addAttachments(panel.urls)
    }

    private func addAttachments(_ urls: [URL]) {
        attachmentError = nil
        var failures: [String] = []
        for url in urls {
            switch AttachmentLoader.load(url: url) {
            case .success(let attachment):
                guard !attachments.contains(where: { $0.path == attachment.path && $0.fileName == attachment.fileName }) else { continue }
                attachments.append(attachment)
            case .failure(let failure):
                failures.append(failure.message)
            }
        }
        if !failures.isEmpty {
            attachmentError = failures.joined(separator: "\n") + " (AppleScript-based and binary formats are not attached.)"
        }
    }

    // MARK: - Suggestions

    private var suggestions: [ComposerSuggestion] {
        if let query = commandQuery {
            let matches = controller.commands.filter { command in
                query.isEmpty
                    || command.name.lowercased().contains(query.lowercased())
                    || command.description.lowercased().contains(query.lowercased())
            }
            return matches.prefix(8).map(ComposerSuggestion.init(command:))
        }
        if fileQuery != nil {
            return fileMatches.prefix(8).compactMap { node in
                ComposerSuggestion(node: node, root: controller.projectPath)
            }
        }
        return []
    }

    /// Everything after the first character, when the composer holds only a
    /// slash command being typed.
    private var commandQuery: String? {
        guard text.hasPrefix("/"), !text.contains("\n") else { return nil }
        let body = String(text.dropFirst())
        guard !body.contains(" ") else { return nil }
        return body
    }

    /// The `@path` token being typed at the end of the composer.
    private var fileQuery: String? {
        guard let atIndex = text.lastIndex(of: "@") else { return nil }
        let prefix = text[text.startIndex..<atIndex]
        if let last = prefix.last, !last.isWhitespace, !last.isNewline { return nil }
        let token = text[text.index(after: atIndex)...]
        guard !token.contains(where: { $0.isWhitespace || $0.isNewline }) else { return nil }
        return String(token)
    }

    private func refreshFileMatchesIfNeeded() {
        guard let query = fileQuery else {
            fileSearchTask?.cancel()
            fileMatches = []
            return
        }
        let root = controller.projectPath
        fileSearchTask?.cancel()
        fileSearchTask = Task {
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled else { return }
            let matches = await Task.detached(priority: .userInitiated) {
                ProjectFileTree.search(root: root, query: query, limit: 60)
            }.value
            guard !Task.isCancelled else { return }
            fileMatches = matches
        }
    }

    private func accept(suggestion: ComposerSuggestion) {
        switch suggestion.kind {
        case .command:
            text = suggestion.insertion
        case .file:
            guard let atIndex = text.lastIndex(of: "@") else { return }
            text = String(text[text.startIndex..<atIndex]) + suggestion.insertion
        }
        fileMatches = []
        suggestionIndex = 0
    }

    private func acceptCurrentSuggestion() {
        let list = suggestions
        guard !list.isEmpty else { return }
        accept(suggestion: list[min(suggestionIndex, list.count - 1)])
    }

    private func moveSuggestion(_ delta: Int) {
        let count = suggestions.count
        guard count > 0 else { return }
        suggestionIndex = (suggestionIndex + delta + count) % count
    }

    private func suggestionContextCleared() -> String {
        if commandQuery != nil { return "" }
        if let atIndex = text.lastIndex(of: "@") {
            return String(text[text.startIndex..<atIndex])
        }
        return text
    }

}

// MARK: - Suggestions list

struct ComposerSuggestion: Identifiable, Equatable {
    enum Kind: Equatable { case command, file }

    var id: String
    var kind: Kind
    var title: String
    var subtitle: String?
    var insertion: String
    var systemImage: String

    init(command: PiCommand) {
        id = "command-\(command.name)"
        kind = .command
        title = command.invocation
        subtitle = command.description.isEmpty ? command.sourceLabel : command.description
        insertion = command.invocation + " "
        systemImage = command.source == .skill ? "magic-wand-01" : "slash"
    }

    init?(node: FileNode, root: String) {
        guard !node.isDirectory else { return nil }
        let relative = ProjectFileTree.relativePath(of: node.path, from: root)
        id = "file-\(node.path)"
        kind = .file
        title = relative
        subtitle = node.byteSize > 0 ? ByteCountFormatter.string(fromByteCount: Int64(node.byteSize), countStyle: .file) : nil
        insertion = "@" + relative + " "
        systemImage = "note-01"
    }
}

struct ComposerSuggestionList: View {
    var suggestions: [ComposerSuggestion]
    var selectedIndex: Int
    var onSelect: (ComposerSuggestion) -> Void
    var onHover: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, suggestion in
                Button {
                    onSelect(suggestion)
                } label: {
                    HStack(spacing: 8) {
                        HugeIcon(name: suggestion.systemImage)
                            .imageScale(.small)
                            .foregroundStyle(.secondary)
                            .frame(width: 16)
                        Text(suggestion.title)
                            .font(.callout.monospaced())
                            .lineLimit(1)
                        if let subtitle = suggestion.subtitle {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(index == selectedIndex ? Color.accentColor.opacity(0.14) : .clear)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    if hovering { onHover(index) }
                }
            }
        }
        .padding(.vertical, 4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).stroke(.separator))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 3)
    }
}

// MARK: - Attachment loading

enum AttachmentLoader {
    struct Failure: Error {
        var message: String
    }

    static let maxImageBytes = 12 * 1024 * 1024
    static let maxTextBytes = 400 * 1024

    static func load(url: URL) -> Result<Attachment, Failure> {
        let path = url.path
        let name = url.lastPathComponent
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        let mime = FileClassification.mimeType(for: path)

        if FileClassification.isImage(path: path) {
            guard size <= maxImageBytes else {
                return .failure(Failure(message: "\(name) is larger than \(ByteCountFormatter.string(fromByteCount: Int64(maxImageBytes), countStyle: .file))."))
            }
            guard let data = try? Data(contentsOf: url) else {
                return .failure(Failure(message: "Could not read \(name)."))
            }
            return .success(Attachment(
                kind: .image,
                fileName: name,
                mimeType: mime,
                byteSize: size,
                path: path,
                imageData: data.base64EncodedString(),
                textContent: nil,
                error: nil
            ))
        }

        if FileClassification.isTextLike(path: path) {
            guard size <= maxTextBytes else {
                return .failure(Failure(message: "\(name) is larger than \(ByteCountFormatter.string(fromByteCount: Int64(maxTextBytes), countStyle: .file)). Use an @path reference instead."))
            }
            let preview = FilePreviewLoader.load(path: path)
            if let error = preview.error {
                return .failure(Failure(message: "Could not read \(name): \(error)"))
            }
            return .success(Attachment(
                kind: .text,
                fileName: name,
                mimeType: mime,
                byteSize: preview.byteSize,
                path: path,
                imageData: nil,
                textContent: preview.text,
                error: nil
            ))
        }

        return .failure(Failure(message: "\(name) is not an image or a text file."))
    }
}

// MARK: - Credit & Capacity Tachometer Gauge (White Variable-Thickness Dial)

struct MuseCreditBatteryButton: View {
    var controller: PiSessionController
    var isGlassSurface: Bool = true
    @State private var isPopoverPresented = false
    @Bindable private var usageService = MuseUsageService.shared

    private var totalSessionTokens: Int {
        (controller.stats?.tokens.totalTokens ?? 0)
            + controller.subagents.reduce(0) { $0 + $1.totalTokens }
    }

    private var allowancePercentage: Int? {
        usageService.allowancePercentage
    }

    /// Remaining capacity fraction (`1.0` = full allowance/capacity, `0.0` = depleted).
    /// Driven by `muse usage --json` (`window` & `weekly` allowance) when reported by the server,
    /// or by the active model's real catalog `contextWindow` and session token count.
    var remainingFraction: Double {
        if let pct = allowancePercentage {
            return min(1.0, max(0.0, Double(pct) / 100.0))
        }
        if let usedPct = controller.contextUsagePercent, usedPct > 0 {
            return min(1.0, max(0.0, 1.0 - (usedPct / 100.0)))
        }
        if let capacity = controller.model?.contextWindow, capacity > 0, totalSessionTokens > 0 {
            let used = min(1.0, max(0.0, Double(totalSessionTokens) / Double(capacity)))
            return 1.0 - used
        }
        return 1.0
    }

    private var remainingPercentInt: Int {
        Int((remainingFraction * 100.0).rounded())
    }

    var body: some View {
        Button {
            isPopoverPresented.toggle()
            Task { await usageService.refresh(installation: controller.museInstallation) }
        } label: {
            TachometerMiniDial(
                fraction: remainingFraction,
                isGlassSurface: isGlassSurface
            )
            .frame(width: 22, height: 16)
            .frame(width: 28, height: 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help("Muse Credit & Capacity Gauge (\(remainingPercentInt)% remaining)")
        .popover(isPresented: $isPopoverPresented, arrowEdge: .top) {
            popoverContent
        }
        .task(id: controller.sessionId) {
            await usageService.refresh(installation: controller.museInstallation)
        }
    }

    private var popoverContent: some View {
        let totalTokens = controller.stats?.tokens.totalTokens ?? 0
        let inputTokens = controller.stats?.tokens.input ?? 0
        let outputTokens = controller.stats?.tokens.output ?? 0
        let cachedTokens = controller.stats?.tokens.cacheRead ?? 0
        let subagentTokens = controller.subagents.reduce(0) { $0 + $1.totalTokens }
        let contextWindow = controller.model?.contextWindow
        let isYoloEnabled = (controller.trustOverride ?? (controller.trustState != .untrusted))

        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Muse Credit Gauge")
                    .font(.callout.weight(.semibold))
                Spacer()
                Text("\(remainingPercentInt)%")
                    .font(.callout.monospacedDigit().weight(.bold))
                    .foregroundStyle(.primary)
            }

            TachometerLargeDial(
                fraction: remainingFraction
            )
            .frame(maxWidth: .infinity)
            .frame(height: 92)
            .padding(.vertical, 2)

            HStack {
                Text("Thin / Low")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Full")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if let snapshot = usageService.latestSnapshot {
                Divider()
                VStack(alignment: .leading, spacing: 5) {
                    if let window = snapshot.window {
                        KeyValueRow(
                            key: "5h window remaining",
                            value: "\(Int(window.remainingPercent.rounded()))% (\(String(format: "%.1f%%", window.usedPercent)) used)",
                            isMonospaced: true
                        )
                        if let resetsAt = window.resetsAt {
                            KeyValueRow(
                                key: "Window resets",
                                value: resetsAt.formatted(date: .omitted, time: .shortened),
                                isMonospaced: false
                            )
                        }
                    }
                    if let weekly = snapshot.weekly {
                        KeyValueRow(
                            key: "Weekly remaining",
                            value: "\(Int(weekly.remainingPercent.rounded()))% (\(String(format: "%.1f%%", weekly.usedPercent)) used)",
                            isMonospaced: true
                        )
                        if let resetsAt = weekly.resetsAt {
                            KeyValueRow(
                                key: "Weekly resets",
                                value: resetsAt.formatted(date: .abbreviated, time: .shortened),
                                isMonospaced: false
                            )
                        }
                    }
                    if let tier = snapshot.tier, !tier.isEmpty {
                        KeyValueRow(key: "Subscription tier", value: tier, isMonospaced: false)
                    }
                    if snapshot.window == nil && snapshot.weekly == nil {
                        if let allowance = snapshot.allowanceRemainingPercent {
                            KeyValueRow(
                                key: "Subscription allowance",
                                value: "\(Int(allowance.rounded()))% remaining",
                                isMonospaced: true
                            )
                        } else if snapshot.reason == "server_sent_no_usage" {
                            KeyValueRow(
                                key: "5h window status",
                                value: "100% available (no usage in window yet)",
                                isMonospaced: false
                            )
                        } else if let reason = snapshot.reason {
                            KeyValueRow(key: "muse usage", value: reason, isMonospaced: false)
                        }
                    }
                    if let hint = snapshot.hint {
                        Text(hint)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 5) {
                KeyValueRow(key: "Input tokens", value: "\(inputTokens.formatted())", isMonospaced: true)
                KeyValueRow(key: "Output tokens", value: "\(outputTokens.formatted())", isMonospaced: true)
                KeyValueRow(key: "Cached tokens", value: "\(cachedTokens.formatted())", isMonospaced: true)
                if subagentTokens > 0 {
                    KeyValueRow(key: "Subagent tokens", value: "\(subagentTokens.formatted())", isMonospaced: true)
                }
                if let contextWindow, contextWindow > 0 {
                    KeyValueRow(key: "Context capacity", value: "\((totalTokens + subagentTokens).formatted()) / \(contextWindow.formatted())", isMonospaced: true)
                } else {
                    KeyValueRow(key: "Total session tokens", value: "\((totalTokens + subagentTokens).formatted())", isMonospaced: true)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                KeyValueRow(
                    key: "Execution mode",
                    value: isYoloEnabled ? "YOLO (no sandbox / no prompts)" : "Restricted (--no-approve)",
                    isMonospaced: false
                )
            }

            HStack {
                Button {
                    Task { await usageService.refresh(installation: controller.museInstallation) }
                } label: {
                    HStack(spacing: 4) {
                        if usageService.isRefreshing {
                            ProgressView().controlSize(.mini)
                        } else {
                            HugeIcon(name: "refresh")
                                .font(.system(size: 11))
                        }
                        Text("Refresh `muse usage`")
                    }
                }
                .buttonStyle(.settingsPill)
                Spacer()
                if let modelId = controller.model?.id {
                    Text(modelId)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
        }
        .padding(14)
        .frame(width: 320)
    }
}

/// Compact white tachometer dial whose gauge stroke thins out as remaining credits decrease.
struct TachometerMiniDial: View {
    var fraction: Double
    var isGlassSurface: Bool = true

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height - 2.5)
            let radius = min(size.width / 2 - 2.0, size.height - 3.5)
            let startDeg = 165.0
            let endDeg = 375.0
            let spanDeg = endDeg - startDeg
            let clamped = min(1.0, max(0.0, fraction))
            let needleDeg = startDeg + clamped * spanDeg

            let fgColor = isGlassSurface ? Color.white : Color.primary
            let trackColor = isGlassSurface ? Color.white.opacity(0.22) : Color.primary.opacity(0.18)

            // Subtle background track
            var bgArc = Path()
            bgArc.addArc(
                center: center,
                radius: radius,
                startAngle: .degrees(startDeg),
                endAngle: .degrees(endDeg),
                clockwise: false
            )
            context.stroke(
                bgArc,
                with: .color(trackColor),
                style: StrokeStyle(lineWidth: 1.25, lineCap: .round)
            )

            // Active white arc whose thickness scales down as credits decrease
            // (3.0pt when full -> 0.85pt when low, plus progressive taper along the arc)
            if clamped > 0.005 {
                let segments = 16
                let minStroke: CGFloat = 0.85
                let maxStrokeForFraction: CGFloat = minStroke + CGFloat(clamped) * 2.15
                for i in 0..<segments {
                    let t0 = Double(i) / Double(segments)
                    let t1 = Double(i + 1) / Double(segments)
                    let segStart = startDeg + (needleDeg - startDeg) * t0
                    let segEnd = startDeg + (needleDeg - startDeg) * t1
                    let segProgress = CGFloat((t0 + t1) * 0.5)
                    let segWidth = minStroke + (maxStrokeForFraction - minStroke) * (0.35 + 0.65 * segProgress)

                    var segPath = Path()
                    segPath.addArc(
                        center: center,
                        radius: radius,
                        startAngle: .degrees(segStart),
                        endAngle: .degrees(segEnd),
                        clockwise: false
                    )
                    context.stroke(
                        segPath,
                        with: .color(fgColor.opacity(0.96)),
                        style: StrokeStyle(lineWidth: segWidth, lineCap: .round)
                    )
                }
            }

            // Needle (also thins slightly as credits decrease)
            let rad = needleDeg * .pi / 180.0
            let tip = CGPoint(
                x: center.x + CGFloat(cos(rad)) * (radius - 1.0),
                y: center.y + CGFloat(sin(rad)) * (radius - 1.0)
            )
            var needle = Path()
            needle.move(to: center)
            needle.addLine(to: tip)
            let needleWidth: CGFloat = 0.95 + CGFloat(clamped) * 0.65
            context.stroke(
                needle,
                with: .color(fgColor.opacity(0.95)),
                style: StrokeStyle(lineWidth: needleWidth, lineCap: .round)
            )

            // Center pivot
            let hubRadius: CGFloat = 1.3 + CGFloat(clamped) * 0.5
            let hubRect = CGRect(
                x: center.x - hubRadius,
                y: center.y - hubRadius,
                width: hubRadius * 2,
                height: hubRadius * 2
            )
            context.fill(Path(ellipseIn: hubRect), with: .color(fgColor))
        }
    }
}

/// Full monochrome tachometer instrument dial shown in the credit gauge popover,
/// with stroke thickness that tapers down as remaining credits decrease.
struct TachometerLargeDial: View {
    var fraction: Double

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height - 12)
            let radius = min(size.width / 2 - 18, size.height - 18)
            let startDeg = 165.0
            let endDeg = 375.0
            let spanDeg = endDeg - startDeg
            let clamped = min(1.0, max(0.0, fraction))
            let needleDeg = startDeg + clamped * spanDeg

            // Background track
            var track = Path()
            track.addArc(center: center, radius: radius, startAngle: .degrees(startDeg), endAngle: .degrees(endDeg), clockwise: false)
            context.stroke(track, with: .color(.primary.opacity(0.16)), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))

            // Active monochrome arc with variable thickness (8.5pt full -> 1.8pt low)
            if clamped > 0.005 {
                let segments = 28
                let minStroke: CGFloat = 1.8
                let maxStrokeForFraction: CGFloat = minStroke + CGFloat(clamped) * 6.7
                for i in 0..<segments {
                    let t0 = Double(i) / Double(segments)
                    let t1 = Double(i + 1) / Double(segments)
                    let segStart = startDeg + (needleDeg - startDeg) * t0
                    let segEnd = startDeg + (needleDeg - startDeg) * t1
                    let segProgress = CGFloat((t0 + t1) * 0.5)
                    let segWidth = minStroke + (maxStrokeForFraction - minStroke) * (0.30 + 0.70 * segProgress)

                    var seg = Path()
                    seg.addArc(center: center, radius: radius, startAngle: .degrees(segStart), endAngle: .degrees(segEnd), clockwise: false)
                    context.stroke(seg, with: .color(.primary.opacity(0.92)), style: StrokeStyle(lineWidth: segWidth, lineCap: .round))
                }
            }

            // Tick marks
            let tickCount = 15
            for i in 0...tickCount {
                let t = Double(i) / Double(tickCount)
                let deg = startDeg + t * spanDeg
                let rad = deg * .pi / 180.0
                let isMajor = i % 5 == 0
                let innerR = radius - (isMajor ? 11 : 7)
                let outerR = radius - 3
                let p1 = CGPoint(x: center.x + CGFloat(cos(rad)) * innerR, y: center.y + CGFloat(sin(rad)) * innerR)
                let p2 = CGPoint(x: center.x + CGFloat(cos(rad)) * outerR, y: center.y + CGFloat(sin(rad)) * outerR)
                var tick = Path()
                tick.move(to: p1)
                tick.addLine(to: p2)
                context.stroke(
                    tick,
                    with: .color(.primary.opacity(isMajor ? 0.55 : 0.28)),
                    style: StrokeStyle(lineWidth: isMajor ? 1.8 : 1.0, lineCap: .round)
                )
            }

            // Needle
            let rad = needleDeg * .pi / 180.0
            let tip = CGPoint(
                x: center.x + CGFloat(cos(rad)) * (radius - 8),
                y: center.y + CGFloat(sin(rad)) * (radius - 8)
            )
            var needle = Path()
            needle.move(to: center)
            needle.addLine(to: tip)
            let needleWidth: CGFloat = 1.4 + CGFloat(clamped) * 1.2
            context.stroke(needle, with: .color(.primary), style: StrokeStyle(lineWidth: needleWidth, lineCap: .round))

            let hubRadius: CGFloat = 3.2 + CGFloat(clamped) * 1.4
            let hub = CGRect(x: center.x - hubRadius, y: center.y - hubRadius, width: hubRadius * 2, height: hubRadius * 2)
            context.fill(Path(ellipseIn: hub), with: .color(.primary))
        }
        .overlay(alignment: .bottom) {
            Text("\(Int((fraction * 100.0).rounded()))%")
                .font(.system(size: 11, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Staged Enter & Exit Choreography Types (`enter-anim.gif`)

enum ComposerEnterExitPhase: Int, Equatable {
    /// Frame 00–01 & Frame 36+: Both the top chat input pill and bottom subcontainer are hidden.
    case hidden = 0
    /// Frame 02 (200ms): Top chat input pill is crisp at 100% size; bottom subcontainer is a small,
    /// heavily blurred dark glass capsule centered directly beneath the top pill (`scaleX: 0.44, scaleY: 0.44, anchor: .top, blur: 12, opacity: 0.42`),
    /// while its inner rows are hidden (`innerOpacity: 0`).
    case pillWithBlurredCapsule = 1
    /// Frames 03–04 (300–400ms): Bottom subcontainer expands outward & downward from `.top` anchor
    /// (`scaleX: 0.96, scaleY: 0.96, anchor: .top, blur: 3.2, opacity: 0.82`), while its inner controls
    /// fade in with a soft motion blur (`innerOpacity: 0.54, innerBlur: 2.8, innerOffsetY: -2.5`).
    case subcontainerExpanding = 2
    /// Frame 05–35 (500ms+): Both top pill and bottom subcontainer (and all inner rows) are settled
    /// at full crispness (`scale: 1.0, blur: 0, opacity: 1.0`).
    case settled = 3

    var topPillScaleX: CGFloat {
        self == .hidden ? 0.96 : 1.0
    }

    var topPillScaleY: CGFloat {
        self == .hidden ? 0.92 : 1.0
    }

    var topPillBlur: CGFloat {
        self == .hidden ? 6.0 : 0.0
    }

    var topPillOffsetY: CGFloat {
        self == .hidden ? -6.0 : 0.0
    }

    var topPillOpacity: Double {
        self == .hidden ? 0.0 : 1.0
    }

    var subcontainerScaleX: CGFloat {
        switch self {
        case .hidden: return 0.38
        case .pillWithBlurredCapsule: return 0.44
        case .subcontainerExpanding: return 0.96
        case .settled: return 1.0
        }
    }

    var subcontainerScaleY: CGFloat {
        switch self {
        case .hidden: return 0.34
        case .pillWithBlurredCapsule: return 0.44
        case .subcontainerExpanding: return 0.96
        case .settled: return 1.0
        }
    }

    var subcontainerOffsetY: CGFloat {
        switch self {
        case .hidden: return -14.0
        case .pillWithBlurredCapsule: return -8.0
        case .subcontainerExpanding: return -2.0
        case .settled: return 0.0
        }
    }

    var subcontainerBlur: CGFloat {
        switch self {
        case .hidden: return 16.0
        case .pillWithBlurredCapsule: return 12.0
        case .subcontainerExpanding: return 3.2
        case .settled: return 0.0
        }
    }

    var subcontainerOpacity: Double {
        switch self {
        case .hidden: return 0.0
        case .pillWithBlurredCapsule: return 0.42
        case .subcontainerExpanding: return 0.82
        case .settled: return 1.0
        }
    }

    var subcontainerInnerOpacity: Double {
        switch self {
        case .hidden, .pillWithBlurredCapsule: return 0.0
        case .subcontainerExpanding: return 0.54
        case .settled: return 1.0
        }
    }

    var subcontainerInnerBlur: CGFloat {
        switch self {
        case .hidden, .pillWithBlurredCapsule: return 8.0
        case .subcontainerExpanding: return 2.8
        case .settled: return 0.0
        }
    }

    var subcontainerInnerOffsetY: CGFloat {
        switch self {
        case .hidden, .pillWithBlurredCapsule: return -5.0
        case .subcontainerExpanding: return -2.5
        case .settled: return 0.0
        }
    }
}

private struct MuseSubcontainerTransitionModifier: ViewModifier {
    var isCollapsed: Bool

    func body(content: Content) -> some View {
        content
            .scaleEffect(
                x: isCollapsed ? 0.44 : 1.0,
                y: isCollapsed ? 0.42 : 1.0,
                anchor: .top
            )
            .offset(y: isCollapsed ? -8.0 : 0.0)
            .blur(radius: isCollapsed ? 12.0 : 0.0)
            .opacity(isCollapsed ? 0.0 : 1.0)
    }
}

extension AnyTransition {
    static var museSubcontainerEnterExit: AnyTransition {
        .modifier(
            active: MuseSubcontainerTransitionModifier(isCollapsed: true),
            identity: MuseSubcontainerTransitionModifier(isCollapsed: false)
        )
    }
}

// MARK: - Liquid Glass Translucent Surfaces & 3D Morphing Voice Orb (`orb1.gif`)

struct LiquidGlassBlurBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var blendingMode: NSVisualEffectView.BlendingMode = .withinWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        view.isEmphasized = true
        view.appearance = NSAppearance(named: .darkAqua)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = .active
        nsView.appearance = NSAppearance(named: .darkAqua)
    }
}

// MARK: - 23-Frame Voice Orb Transition Specification (`14.58.49.png` & `orb1.gif`)

enum VoiceOrbVisualPhase: Equatable {
    case ribbonWave
    case darkBlink
    case centralAlmondLens
    case centralGlowingSun
    case singleCenterDot
    case constellationDots
}

struct VoiceOrbFrameDescriptor: Equatable {
    let frameIndex: Int
    /// `nil` means full width (`maxWidth: .infinity`, Frames 1 & 2).
    let pillFixedWidth: CGFloat?
    /// `nil` means natural height (`minHeight: 54`, Frames 1 & 2).
    let pillHeight: CGFloat?
    let pillCornerRadius: CGFloat
    let editorAndControlsOpacity: Double
    let waveOpacity: Double
    let sphereMix: Double
    let subcontainerScaleX: CGFloat
    let subcontainerScaleY: CGFloat
    let subcontainerOffsetY: CGFloat
    let subcontainerBlur: CGFloat
    let subcontainerOpacity: Double
    let orbPhase: VoiceOrbVisualPhase

    static func descriptor(forFrame rawFrame: Int) -> VoiceOrbFrameDescriptor {
        let frame = min(max(rawFrame, 1), 23)
        switch frame {
        case 1:
            // Frame 1: Idle full composer panel — 100% width dark top pill + crisp bottom subcontainer
            return VoiceOrbFrameDescriptor(
                frameIndex: 1,
                pillFixedWidth: nil,
                pillHeight: nil,
                pillCornerRadius: 27,
                editorAndControlsOpacity: 1.0,
                waveOpacity: 0.0,
                sphereMix: 0.0,
                subcontainerScaleX: 1.0,
                subcontainerScaleY: 1.0,
                subcontainerOffsetY: 0,
                subcontainerBlur: 0,
                subcontainerOpacity: 1.0,
                orbPhase: .ribbonWave
            )
        case 2:
            // Frame 2: Full-width plasma wave ignition inside the 100%-width top pill while placeholder & mic button remain visible
            return VoiceOrbFrameDescriptor(
                frameIndex: 2,
                pillFixedWidth: nil,
                pillHeight: nil,
                pillCornerRadius: 27,
                editorAndControlsOpacity: 0.90,
                waveOpacity: 0.96,
                sphereMix: 0.14,
                subcontainerScaleX: 1.0,
                subcontainerScaleY: 1.0,
                subcontainerOffsetY: 0,
                subcontainerBlur: 0,
                subcontainerOpacity: 1.0,
                orbPhase: .ribbonWave
            )
        case 3:
            // Frame 3: Horizontal contraction stage 1 — top pill contracts toward center while bottom subcontainer blurs in place
            return VoiceOrbFrameDescriptor(
                frameIndex: 3,
                pillFixedWidth: 380,
                pillHeight: 58,
                pillCornerRadius: 29,
                editorAndControlsOpacity: 0.16,
                waveOpacity: 1.0,
                sphereMix: 0.35,
                subcontainerScaleX: 0.98,
                subcontainerScaleY: 0.97,
                subcontainerOffsetY: -2,
                subcontainerBlur: 6.5,
                subcontainerOpacity: 0.82,
                orbPhase: .ribbonWave
            )
        case 4:
            // Frame 4: Horizontal contraction stage 2 — compact capsule & heavy subcontainer motion blur
            return VoiceOrbFrameDescriptor(
                frameIndex: 4,
                pillFixedWidth: 240,
                pillHeight: 66,
                pillCornerRadius: 33,
                editorAndControlsOpacity: 0.0,
                waveOpacity: 1.0,
                sphereMix: 0.62,
                subcontainerScaleX: 0.92,
                subcontainerScaleY: 0.90,
                subcontainerOffsetY: -6,
                subcontainerBlur: 14.0,
                subcontainerOpacity: 0.44,
                orbPhase: .ribbonWave
            )
        case 5:
            // Frame 5: Wide squircle & subcontainer dissolve out
            return VoiceOrbFrameDescriptor(
                frameIndex: 5,
                pillFixedWidth: 118,
                pillHeight: 84,
                pillCornerRadius: 42,
                editorAndControlsOpacity: 0.0,
                waveOpacity: 1.0,
                sphereMix: 0.85,
                subcontainerScaleX: 0.82,
                subcontainerScaleY: 0.76,
                subcontainerOffsetY: -12,
                subcontainerBlur: 22.0,
                subcontainerOpacity: 0.0,
                orbPhase: .ribbonWave
            )
        case 6:
            // Frame 6: Slightly oblate 3D Liquid Glass sphere (`98x88`)
            return VoiceOrbFrameDescriptor(
                frameIndex: 6,
                pillFixedWidth: 98,
                pillHeight: 88,
                pillCornerRadius: 44,
                editorAndControlsOpacity: 0.0,
                waveOpacity: 1.0,
                sphereMix: 0.95,
                subcontainerScaleX: 0.76,
                subcontainerScaleY: 0.70,
                subcontainerOffsetY: -16,
                subcontainerBlur: 24.0,
                subcontainerOpacity: 0.0,
                orbPhase: .ribbonWave
            )
        case 7:
            // Frame 7: Full circular 3D Liquid Glass sphere (`90x90`)
            return VoiceOrbFrameDescriptor(
                frameIndex: 7,
                pillFixedWidth: 90,
                pillHeight: 90,
                pillCornerRadius: 45,
                editorAndControlsOpacity: 0.0,
                waveOpacity: 1.0,
                sphereMix: 1.0,
                subcontainerScaleX: 0.74,
                subcontainerScaleY: 0.68,
                subcontainerOffsetY: -18,
                subcontainerBlur: 24.0,
                subcontainerOpacity: 0.0,
                orbPhase: .ribbonWave
            )
        case 8:
            // Frame 8: Single-frame dark obsidian pulse/blink right before active listening begins (`14.58.49.png` Frame 8)
            return VoiceOrbFrameDescriptor(
                frameIndex: 8,
                pillFixedWidth: 90,
                pillHeight: 90,
                pillCornerRadius: 45,
                editorAndControlsOpacity: 0.0,
                waveOpacity: 0.06,
                sphereMix: 1.0,
                subcontainerScaleX: 0.74,
                subcontainerScaleY: 0.68,
                subcontainerOffsetY: -18,
                subcontainerBlur: 24.0,
                subcontainerOpacity: 0.0,
                orbPhase: .darkBlink
            )
        case 9...18:
            // Frames 9–18: Active listening loop (`90x90`) with undulating chromatic equator wave + mic interactivity
            return VoiceOrbFrameDescriptor(
                frameIndex: frame,
                pillFixedWidth: 90,
                pillHeight: 90,
                pillCornerRadius: 45,
                editorAndControlsOpacity: 0.0,
                waveOpacity: 1.0,
                sphereMix: 1.0,
                subcontainerScaleX: 0.74,
                subcontainerScaleY: 0.68,
                subcontainerOffsetY: -18,
                subcontainerBlur: 24.0,
                subcontainerOpacity: 0.0,
                orbPhase: .ribbonWave
            )
        case 19:
            // Frame 19: Wave contracts horizontally toward sphere center into a bright white almond lens (`88x88`)
            return VoiceOrbFrameDescriptor(
                frameIndex: 19,
                pillFixedWidth: 88,
                pillHeight: 88,
                pillCornerRadius: 44,
                editorAndControlsOpacity: 0.0,
                waveOpacity: 1.0,
                sphereMix: 1.0,
                subcontainerScaleX: 0.74,
                subcontainerScaleY: 0.68,
                subcontainerOffsetY: -18,
                subcontainerBlur: 24.0,
                subcontainerOpacity: 0.0,
                orbPhase: .centralAlmondLens
            )
        case 20:
            // Frame 20: Central almond lens rounds into a glowing circular white sun (`86x86`)
            return VoiceOrbFrameDescriptor(
                frameIndex: 20,
                pillFixedWidth: 86,
                pillHeight: 86,
                pillCornerRadius: 43,
                editorAndControlsOpacity: 0.0,
                waveOpacity: 1.0,
                sphereMix: 1.0,
                subcontainerScaleX: 0.74,
                subcontainerScaleY: 0.68,
                subcontainerOffsetY: -18,
                subcontainerBlur: 24.0,
                subcontainerOpacity: 0.0,
                orbPhase: .centralGlowingSun
            )
        case 21:
            // Frame 21: Condenses into a single crisp solid white dot centered inside the sphere (`86x86`)
            return VoiceOrbFrameDescriptor(
                frameIndex: 21,
                pillFixedWidth: 86,
                pillHeight: 86,
                pillCornerRadius: 43,
                editorAndControlsOpacity: 0.0,
                waveOpacity: 1.0,
                sphereMix: 1.0,
                subcontainerScaleX: 0.74,
                subcontainerScaleY: 0.68,
                subcontainerOffsetY: -18,
                subcontainerBlur: 24.0,
                subcontainerOpacity: 0.0,
                orbPhase: .singleCenterDot
            )
        default:
            // Frames 22–23: Bursts into the 6-dot constellation rotating inside the dark-top / frosted-bottom sphere (`86x86`)
            return VoiceOrbFrameDescriptor(
                frameIndex: frame,
                pillFixedWidth: 86,
                pillHeight: 86,
                pillCornerRadius: 43,
                editorAndControlsOpacity: 0.0,
                waveOpacity: 1.0,
                sphereMix: 1.0,
                subcontainerScaleX: 0.74,
                subcontainerScaleY: 0.68,
                subcontainerOffsetY: -18,
                subcontainerBlur: 24.0,
                subcontainerOpacity: 0.0,
                orbPhase: .constellationDots
            )
        }
    }
}

struct LiquidGlassCardBackground: View {
    var cornerRadius: CGFloat
    var isDarkTopPill: Bool
    var isDropTargeted: Bool = false
    var sphereMix: Double = 0.0

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            LiquidGlassBlurBackground(
                material: .hudWindow,
                blendingMode: .withinWindow
            )

            if isDarkTopPill {
                // Deep obsidian black top fading smoothly into dark smoked glass at the bottom (matching 15.23.15 & enter-anim.gif)
                LinearGradient(
                    stops: [
                        .init(color: Color(red: 0.03, green: 0.03, blue: 0.05, opacity: 0.97), location: 0.0),
                        .init(color: Color(red: 0.09, green: 0.09, blue: 0.12, opacity: 0.92), location: 0.56),
                        .init(color: Color(red: 0.20, green: 0.20, blue: 0.24, opacity: 0.86), location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                // As the pill contracts through Frames 2–5 (`sphereMix > 0`), blend in the 3D sphere's frosted silver-grey lower hemisphere
                if sphereMix > 0.01 {
                    LinearGradient(
                        stops: [
                            .init(color: Color(red: 0.02, green: 0.02, blue: 0.04, opacity: 0.98), location: 0.0),
                            .init(color: Color(red: 0.05, green: 0.06, blue: 0.09, opacity: 0.94), location: 0.46),
                            .init(color: Color(red: 0.54, green: 0.55, blue: 0.60, opacity: 0.60), location: 0.74),
                            .init(color: Color(red: 0.74, green: 0.75, blue: 0.79, opacity: 0.54), location: 1.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .opacity(sphereMix)
                }
            } else {
                // Dark translucent smoked glass subcontainer without milky grey/white tint overlays (matching enter-anim.gif)
                LinearGradient(
                    stops: [
                        .init(color: Color(red: 0.11, green: 0.11, blue: 0.13, opacity: 0.88), location: 0.0),
                        .init(color: Color(red: 0.14, green: 0.14, blue: 0.16, opacity: 0.84), location: 0.55),
                        .init(color: Color(red: 0.17, green: 0.17, blue: 0.20, opacity: 0.80), location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
        }
        .clipShape(shape)
        .overlay(
            shape.strokeBorder(
                isDropTargeted
                    ? AnyShapeStyle(Color.accentColor)
                    : AnyShapeStyle(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(isDarkTopPill ? (0.28 + 0.16 * sphereMix) : 0.22),
                                Color.white.opacity(0.14 + 0.08 * sphereMix),
                                Color.white.opacity(isDarkTopPill ? (0.36 + 0.30 * sphereMix) : 0.20)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    ),
                lineWidth: isDropTargeted ? 2.0 : (1.0 + 0.3 * sphereMix)
            )
        )
        .shadow(
            color: Color.black.opacity(isDarkTopPill ? 0.28 : 0.22),
            radius: isDarkTopPill ? 18 : 16,
            y: isDarkTopPill ? 8 : 7
        )
    }
}

/// The 3D Liquid Glass Sphere / Voice Orb that the top input pill morphs into
/// when the microphone button is clicked (`14.58.49.png` & `orb1.gif`, Frames 6–23).
struct LiquidGlassVoiceOrbView: View {
    var orbFrame: Int
    var descriptor: VoiceOrbFrameDescriptor
    var isRecording: Bool
    var isTranscribing: Bool
    var audioLevel: Double
    var duration: TimeInterval
    var fixedTimeOverride: TimeInterval? = nil
    var onTap: () -> Void

    @State private var hoverEnergy: Double = 0.0

    var body: some View {
        let orbWidth = descriptor.pillFixedWidth ?? 90
        let orbHeight = descriptor.pillHeight ?? 90
        let cornerRadius = descriptor.pillCornerRadius
        let effectiveAudio = min(1.0, max(audioLevel, hoverEnergy))
        let orbShape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        Button(action: onTap) {
            ZStack {
                // Soft downward ambient drop shadow cast onto the background bitmap below the sphere (`14.58.49.png`)
                Ellipse()
                    .fill(
                        RadialGradient(
                            stops: [
                                .init(color: Color.black.opacity(0.22), location: 0.0),
                                .init(color: Color.black.opacity(0.11), location: 0.50),
                                .init(color: Color.black.opacity(0.03), location: 0.80),
                                .init(color: Color.clear, location: 1.0)
                            ],
                            center: .center,
                            startRadius: 6,
                            endRadius: orbWidth * 0.58
                        )
                    )
                    .frame(width: orbWidth * 1.16, height: orbHeight * 0.72)
                    .offset(y: 14)
                    .blur(radius: 5)

                // Core 3D Liquid Glass Sphere (`98x88` in Frame 6 -> `90x90` in Frames 7–18 -> `88x88` in Frame 19 -> `86x86` in Frames 20–23)
                ZStack {
                    // Upper hemisphere only: opaque dark backing so the upper obsidian dome is pure jet-black while the lower glass hemisphere lets the background bitmap show through with 3D spherical shadows (`14.58.49.png`)
                    LiquidGlassBlurBackground(
                        material: .hudWindow,
                        blendingMode: .withinWindow
                    )
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .black, location: 0.0),
                                .init(color: .black, location: 0.44),
                                .init(color: .clear, location: 0.53),
                                .init(color: .clear, location: 1.0)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                    // Base sphere vertical shading matching `14.58.49.png`:
                    // - Upper hemisphere (`0.0...0.47`): pure jet-black obsidian (`#020204`)
                    // - Equatorial shadow band (`0.47...0.58`): casts a rich dark shadow onto the bitmap behind the middle of the orb
                    // - Lower hemisphere (`0.58...1.0`): translucent smoked grey glass grading into a frosted silver-grey bottom rim
                    LinearGradient(
                        stops: [
                            .init(color: Color(red: 0.01, green: 0.01, blue: 0.02, opacity: 0.99), location: 0.0),
                            .init(color: Color(red: 0.02, green: 0.02, blue: 0.04, opacity: 0.98), location: 0.45),
                            .init(color: Color(red: 0.06, green: 0.07, blue: 0.09, opacity: 0.86), location: 0.52),
                            .init(color: Color(red: 0.24, green: 0.25, blue: 0.28, opacity: 0.56), location: 0.66),
                            .init(color: Color(red: 0.48, green: 0.49, blue: 0.53, opacity: 0.44), location: 0.85),
                            .init(color: Color(red: 0.68, green: 0.69, blue: 0.73, opacity: 0.46), location: 1.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )

                    // Interior 3D spherical limb darkening on the lower hemisphere:
                    // Illuminates the center-bottom window with a soft white caustic glow while shading the curved left & right flanks over the background bitmap (`14.58.49.png`)
                    RadialGradient(
                        stops: [
                            .init(color: Color.white.opacity(0.32 + 0.14 * effectiveAudio), location: 0.0),
                            .init(color: Color.white.opacity(0.12), location: 0.32),
                            .init(color: Color(red: 0.06, green: 0.07, blue: 0.09, opacity: 0.46), location: 0.72),
                            .init(color: Color(red: 0.02, green: 0.03, blue: 0.05, opacity: 0.68), location: 0.92),
                            .init(color: Color.white.opacity(0.28), location: 1.0)
                        ],
                        center: UnitPoint(x: 0.5, y: 0.58),
                        startRadius: 2,
                        endRadius: orbWidth * 0.50
                    )
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0.0),
                                .init(color: .clear, location: 0.45),
                                .init(color: .black, location: 0.53),
                                .init(color: .black, location: 1.0)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                    // 60fps undulating chromatic plasma wave (Frames 6–18 + mic interactivity) and Frame 19–23 condensation & constellation states
                    PlasmaHorizonWaveCanvas(
                        isCircularOrb: true,
                        orbFrame: orbFrame,
                        audioLevel: effectiveAudio,
                        waveOpacity: descriptor.waveOpacity,
                        fixedTimeOverride: fixedTimeOverride
                    )

                    // Subtle top-left curved glass rim reflection (keeps the upper obsidian dome deep jet-black like Frame 7 & 8 of `14.58.49.png`)
                    Ellipse()
                        .trim(from: 0.56, to: 0.88)
                        .stroke(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.28),
                                    Color.white.opacity(0.08),
                                    Color.clear
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            ),
                            style: StrokeStyle(lineWidth: 1.4, lineCap: .round)
                        )
                        .frame(width: orbWidth - 3, height: orbHeight - 3)

                    // Bottom inner crescent glass refraction rim
                    Ellipse()
                        .trim(from: 0.06, to: 0.44)
                        .stroke(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.18),
                                    Color.white.opacity(0.82),
                                    Color.white.opacity(0.18)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            ),
                            style: StrokeStyle(lineWidth: 2.0, lineCap: .round)
                        )
                        .frame(width: orbWidth - 3.0, height: orbHeight - 3.0)
                }
                .frame(width: orbWidth, height: orbHeight)
                .clipShape(orbShape)
                .overlay(
                    orbShape
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.28),
                                    Color.white.opacity(0.20),
                                    Color.white.opacity(0.78)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 1.25
                        )
                        .frame(width: orbWidth, height: orbHeight)
                )
                .shadow(color: Color.black.opacity(0.14), radius: 10, x: 0, y: 6)
            }
            .contentShape(orbShape)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                let center = CGPoint(x: orbWidth * 0.58, y: orbHeight * 0.50)
                let dist = hypot(location.x - center.x, location.y - center.y)
                let norm = max(0.0, min(1.0, 1.0 - Double(dist) / 48.0))
                withAnimation(.easeOut(duration: 0.14)) {
                    hoverEnergy = 0.35 + 0.60 * norm
                }
            case .ended:
                withAnimation(.easeOut(duration: 0.22)) {
                    hoverEnergy = 0.0
                }
            }
        }
        .help(
            isTranscribing
                ? "Transcribing voice via `muse voice transcribe`…"
                : "Listening (\(String(format: "%d:%02d", Int(duration) / 60, Int(duration) % 60))) — click Orb or press Esc to transcribe"
        )
    }
}

/// 60fps animated chromatic plasma wave rendered across the full-width/contracting pill (Frames 2–5),
/// across the equator of the 3D Liquid Glass Voice Orb with `mic interactivity` (Frames 6–18),
/// and through the Frame 19–23 almond-lens -> glowing-sun -> single-dot -> 6-dot constellation states (`14.58.49.png`).
struct PlasmaHorizonWaveCanvas: View {
    var isCircularOrb: Bool
    var orbFrame: Int = 9
    var audioLevel: Double = 0.0
    var waveOpacity: Double = 1.0
    /// Optional fixed timestamp for deterministic snapshot verification of the 6 `mic interactivity` states.
    var fixedTimeOverride: TimeInterval? = nil

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            let t = fixedTimeOverride ?? timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                let width = size.width
                let height = size.height
                let center = CGPoint(x: width * 0.5, y: height * 0.5)

                if orbFrame == 19 {
                    // Frame 19: Wave contracts horizontally toward the center into a bright white almond lens with cyan & warm-amber fringes
                    drawFrame19AlmondLens(context: context, size: size, center: center, t: t)
                } else if orbFrame == 20 {
                    // Frame 20: Central almond lens rounds into a circular glowing white sun in the center of the sphere
                    drawFrame20GlowingSun(context: context, center: center, t: t)
                } else if orbFrame == 21 {
                    // Frame 21: Condenses into a single crisp solid white dot (`8.5pt`) centered inside the sphere
                    drawFrame21SingleCenterDot(context: context, center: center)
                } else if orbFrame >= 22 {
                    // Frames 22–23: Bursts into the 6-dot constellation of graded white dots rotating inside the sphere
                    drawFrames22And23Constellation(context: context, center: center, t: t, orbFrame: orbFrame)
                } else {
                    // Frames 2–18: Undulating chromatic plasma wave + Frame 8 dark blink + `mic interactivity` states
                    drawRibbonWaveAndMicInteractivity(
                        context: context,
                        size: size,
                        t: t,
                        effectiveOpacity: waveOpacity,
                        micEnergy: min(1.0, max(0.0, audioLevel))
                    )
                }
            }
        }
    }

    private func drawRibbonWaveAndMicInteractivity(
        context: GraphicsContext,
        size: CGSize,
        t: TimeInterval,
        effectiveOpacity: Double,
        micEnergy: Double
    ) {
        guard effectiveOpacity > 0.005 else { return }

        let width = size.width
        let height = size.height
        let midY = height * (isCircularOrb ? 0.50 : 0.54)
        let steps = 64
        let micBoost = isCircularOrb ? micEnergy : (micEnergy * 0.25)

        // High-energy full-sphere S-curve arch blend (`Orbs 3 & 4` in the `mic interactivity` strip of `14.58.49.png`)
        let highArchMix = isCircularOrb ? max(0.0, min(1.0, (micBoost - 0.50) / 0.28)) : 0.0
        // Braided figure-8 double-helix blend (`Orbs 1, 2, 5, 6` in the `mic interactivity` strip of `14.58.49.png`)
        let braidMix = isCircularOrb ? max(0.0, min(1.0, (micBoost - 0.06) / 0.30)) * (1.0 - highArchMix * 0.85) : 0.0

        // 0. Focused white radial caustic glow immediately beneath the center of the wave (`14.58.49.png`)
        if isCircularOrb {
            var causticCtx = context
            causticCtx.opacity = effectiveOpacity * (0.45 + 0.35 * micBoost)
            causticCtx.addFilter(.blur(radius: 7.5))
            let causticW: CGFloat = 28.0 + 16.0 * CGFloat(micBoost)
            let causticH: CGFloat = 18.0 + 10.0 * CGFloat(micBoost)
            let causticRect = CGRect(
                x: width * 0.5 - causticW * 0.5,
                y: midY - 1.0,
                width: causticW,
                height: causticH
            )
            causticCtx.fill(
                Path(ellipseIn: causticRect),
                with: .color(Color.white.opacity(0.90))
            )
        }

        // If in high/peak speech (`highArchMix > 0.01`), draw the full-sphere S-curve plasma arches (Orb 3 fiery orange-gold upper-left arch & Orb 4 icy-cyan/cobalt/red-orange diagonal swirl)
        if highArchMix > 0.01 {
            drawHighEnergyMicSwirl(
                context: context,
                size: size,
                t: t,
                opacity: effectiveOpacity * highArchMix,
                intensity: micBoost
            )
        }

        // Base + Braided Figure-8 Equator Wave (`Frames 2–18` & `Orbs 1, 2, 5, 6` of `mic interactivity`)
        let baseWaveOpacity = effectiveOpacity * (1.0 - highArchMix * 0.92)
        guard baseWaveOpacity > 0.01 else { return }

        // Keep the wave tightly focused around the equator (`amp ~ 3.2pt` idle, `~5.8pt` braided) so the upper obsidian dome stays pure jet-black like `14.58.49.png`!
        func waveY(xNorm: Double, phaseOffset: Double, ampScale: Double, sign: Double = 1.0) -> CGFloat {
            let edgeEnvelope = isCircularOrb
                ? (0.25 + 0.75 * sin(xNorm * .pi))
                : (0.45 + 0.55 * sin(xNorm * .pi))
            let speed = 3.6 + 1.6 * micBoost
            // Smooth 1.25-cycle S-curve across the equator (`Frames 6, 7, 9` of `14.58.49.png`)
            let gentleSCurve = sin((xNorm - 0.18) * .pi * 1.65 - t * speed + phaseOffset)
            // Figure-8 braided harmonic for `Orbs 1, 2, 5, 6` of `mic interactivity`
            let figure8 = sin((xNorm - 0.5) * .pi * 2.1) * cos(t * 3.2 + phaseOffset * 0.6)
            let blended = gentleSCurve * (1.0 - 0.58 * braidMix) + (sign * figure8 * 1.25) * (0.58 * braidMix)
            let baseAmp = (isCircularOrb ? 3.2 : 4.2) + (isCircularOrb ? 3.4 * braidMix : 1.2 * micBoost)
            return midY + CGFloat(blended * baseAmp * ampScale * edgeEnvelope)
        }

        func buildRibbonPath(
            phaseOffset: Double,
            yOffset: CGFloat,
            thickness: CGFloat,
            ampScale: Double = 1.0,
            centerBulge: CGFloat = 0.0,
            sign: Double = 1.0
        ) -> Path {
            var path = Path()
            for i in 0...steps {
                let u = Double(i) / Double(steps)
                let x = CGFloat(u) * width
                let bulge = centerBulge * CGFloat(pow(sin(u * .pi), 3.2))
                let halfThick = (thickness + bulge) * 0.5
                let y = waveY(xNorm: u, phaseOffset: phaseOffset, ampScale: ampScale, sign: sign) + yOffset - halfThick
                if i == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }
            for i in (0...steps).reversed() {
                let u = Double(i) / Double(steps)
                let x = CGFloat(u) * width
                let bulge = centerBulge * CGFloat(pow(sin(u * .pi), 3.2))
                let halfThick = (thickness + bulge) * 0.5
                let y = waveY(xNorm: u, phaseOffset: phaseOffset + 0.25, ampScale: ampScale, sign: sign) + yOffset + halfThick
                path.addLine(to: CGPoint(x: x, y: y))
            }
            path.closeSubpath()
            return path
        }

        // 1. Upper warm amber-orange horizon glow just above the white wave core (matching `Frames 6, 7, 9` in `14.58.49.png`)
        var upperAmberCtx = context
        upperAmberCtx.opacity = baseWaveOpacity
        upperAmberCtx.addFilter(.blur(radius: isCircularOrb ? 5.0 : 8.5))
        let upperAmberPath = buildRibbonPath(
            phaseOffset: 0.0,
            yOffset: -3.5,
            thickness: (isCircularOrb ? 8.5 : 12.0) + 3.0 * CGFloat(braidMix),
            ampScale: 1.0,
            sign: 1.0
        )
        upperAmberCtx.fill(
            upperAmberPath,
            with: .linearGradient(
                Gradient(stops: [
                    .init(color: Color(red: 0.95, green: 0.48, blue: 0.12, opacity: 0.72), location: 0.0),
                    .init(color: Color(red: 1.0, green: 0.58, blue: 0.14, opacity: 0.95), location: 0.48),
                    .init(color: Color(red: 0.95, green: 0.45, blue: 0.12, opacity: 0.72), location: 1.0)
                ]),
                startPoint: CGPoint(x: 0, y: midY - 6),
                endPoint: CGPoint(x: width, y: midY - 2)
            )
        )

        // 2. Lower & edge icy cyan-blue refraction fringe just below the white wave core (matching `Frames 6, 7, 9` in `14.58.49.png`)
        var lowerCyanCtx = context
        lowerCyanCtx.opacity = baseWaveOpacity
        lowerCyanCtx.addFilter(.blur(radius: isCircularOrb ? 4.2 : 7.5))
        let lowerCyanPath = buildRibbonPath(
            phaseOffset: 0.25,
            yOffset: 2.5,
            thickness: (isCircularOrb ? 7.5 : 11.0) + 3.0 * CGFloat(braidMix),
            ampScale: 1.05,
            sign: 1.0
        )
        lowerCyanCtx.fill(
            lowerCyanPath,
            with: .linearGradient(
                Gradient(stops: [
                    .init(color: Color(red: 0.06, green: 0.74, blue: 1.0, opacity: 0.95), location: 0.0),
                    .init(color: Color(red: 0.24, green: 0.88, blue: 1.0, opacity: 0.96), location: 0.45),
                    .init(color: Color(red: 0.08, green: 0.62, blue: 1.0, opacity: 0.90), location: 1.0)
                ]),
                startPoint: CGPoint(x: 0, y: midY),
                endPoint: CGPoint(x: width, y: midY + 6)
            )
        )

        // 3. `mic interactivity` Braided Figure-8 Double-Helix Ribbons (`Orbs 1, 2, 5, 6` in `14.58.49.png`)
        if braidMix > 0.02 {
            // Strand A (sign = +1): Vivid Cyan -> Spring Emerald-Lime -> Blazing White Center -> Warm Amber-Orange
            var strandACtx = context
            strandACtx.opacity = baseWaveOpacity * min(1.0, braidMix * 1.35)
            strandACtx.addFilter(.blur(radius: 1.8))
            let strandAPath = buildRibbonPath(
                phaseOffset: 0.05,
                yOffset: -1.0,
                thickness: 4.5 + 3.0 * CGFloat(braidMix),
                ampScale: 1.35,
                centerBulge: 7.0 * CGFloat(braidMix),
                sign: 1.0
            )
            strandACtx.fill(
                strandAPath,
                with: .linearGradient(
                    Gradient(stops: [
                        .init(color: Color(red: 0.05, green: 0.78, blue: 1.0), location: 0.0),
                        .init(color: Color(red: 0.25, green: 0.96, blue: 0.55), location: 0.28),
                        .init(color: Color.white, location: 0.50),
                        .init(color: Color(red: 1.0, green: 0.80, blue: 0.18), location: 0.72),
                        .init(color: Color(red: 1.0, green: 0.38, blue: 0.10), location: 1.0)
                    ]),
                    startPoint: CGPoint(x: 0, y: midY - 5),
                    endPoint: CGPoint(x: width, y: midY + 5)
                )
            )

            // Strand B (sign = -1): Warm Coral-Orange -> Peach-Gold -> Blazing White Center -> Icy Cyan -> Cobalt Blue
            var strandBCtx = context
            strandBCtx.opacity = baseWaveOpacity * min(1.0, braidMix * 1.35)
            strandBCtx.addFilter(.blur(radius: 1.8))
            let strandBPath = buildRibbonPath(
                phaseOffset: 0.45,
                yOffset: 1.0,
                thickness: 4.5 + 3.0 * CGFloat(braidMix),
                ampScale: 1.35,
                centerBulge: 7.0 * CGFloat(braidMix),
                sign: -1.0
            )
            strandBCtx.fill(
                strandBPath,
                with: .linearGradient(
                    Gradient(stops: [
                        .init(color: Color(red: 1.0, green: 0.42, blue: 0.14), location: 0.0),
                        .init(color: Color(red: 1.0, green: 0.72, blue: 0.36), location: 0.28),
                        .init(color: Color.white, location: 0.50),
                        .init(color: Color(red: 0.20, green: 0.94, blue: 1.0), location: 0.70),
                        .init(color: Color(red: 0.10, green: 0.48, blue: 1.0), location: 1.0)
                    ]),
                    startPoint: CGPoint(x: 0, y: midY + 5),
                    endPoint: CGPoint(x: width, y: midY - 5)
                )
            )
        }

        // 4. Crisp blazing white plasma core ribbon + central figure-8 lens bulge
        var coreCtx = context
        coreCtx.opacity = baseWaveOpacity
        coreCtx.addFilter(.blur(radius: 1.2))
        let corePath = buildRibbonPath(
            phaseOffset: 0.12,
            yOffset: 0,
            thickness: (isCircularOrb ? 3.8 : 4.6) + 2.0 * CGFloat(braidMix),
            ampScale: 0.90,
            centerBulge: isCircularOrb ? (3.5 + 11.5 * CGFloat(braidMix)) : 2.5,
            sign: 1.0
        )
        coreCtx.fill(
            corePath,
            with: .color(Color.white.opacity(0.99))
        )
    }

    /// Renders the high-amplitude S-curve plasma arches of Orbs 3 & 4 in the `mic interactivity` strip (`14.58.49.png`):
    /// - Mode A (`polarity >= 0`, matching Orb 3): Deep black upper-right pocket + fiery golden-orange upper-left S-arch + huge S-curved white center core + electric cyan lower-right ribbon.
    /// - Mode B (`polarity < 0`, matching Orb 4): Icy cyan-white upper-left arch + dark bronze upper-right pocket + vivid red-orange-magenta lower-left ribbon + blazing white/cyan center + deep cobalt-royal blue lower-right glow.
    private func drawHighEnergyMicSwirl(
        context: GraphicsContext,
        size: CGSize,
        t: TimeInterval,
        opacity: Double,
        intensity: Double
    ) {
        let width = size.width
        let height = size.height
        let steps = 64
        let polarity = sin(t * 2.6)
        let orb3Weight = max(0.0, min(1.0, (polarity + 1.0) * 0.5))
        let orb4Weight = 1.0 - orb3Weight

        if orb3Weight > 0.01 {
            let w3 = opacity * orb3Weight
            // Orb 3 S-curve centerline: starts at left (y ~ 0.44), arches high in upper-left (u=0.26, y ~ 0.25), sweeps through center (u=0.52, y ~ 0.48) to lower-right (u=0.92, y ~ 0.58)
            func orb3Y(u: Double) -> CGFloat {
                let arch = -0.22 * sin(u * .pi * 1.42) + 0.08 * sin(u * .pi * 2.4)
                return height * CGFloat(0.47 + arch)
            }
            func buildOrb3Path(yOff: CGFloat, thick: CGFloat, bulge: CGFloat) -> Path {
                var p = Path()
                for i in 0...steps {
                    let u = Double(i) / Double(steps)
                    let x = CGFloat(u) * width
                    let b = bulge * CGFloat(pow(sin(u * .pi), 1.8))
                    let ht = (thick + b) * 0.5
                    let y = orb3Y(u: u) + yOff - ht
                    if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
                }
                for i in (0...steps).reversed() {
                    let u = Double(i) / Double(steps)
                    let x = CGFloat(u) * width
                    let b = bulge * CGFloat(pow(sin(u * .pi), 1.8))
                    let ht = (thick + b) * 0.5
                    let y = orb3Y(u: u) + yOff + ht
                    p.addLine(to: CGPoint(x: x, y: y))
                }
                p.closeSubpath()
                return p
            }

            // 1. Upper-left golden-amber inner dome rim glow (`Orb 3`)
            var rim3Ctx = context
            rim3Ctx.opacity = w3
            rim3Ctx.addFilter(.blur(radius: 4.5))
            let rim3Rect = CGRect(x: width * 0.03, y: height * 0.03, width: width * 0.68, height: height * 0.58)
            rim3Ctx.stroke(
                Path(ellipseIn: rim3Rect),
                with: .linearGradient(
                    Gradient(colors: [
                        Color(red: 1.0, green: 0.62, blue: 0.08),
                        Color(red: 1.0, green: 0.82, blue: 0.22),
                        Color.clear
                    ]),
                    startPoint: CGPoint(x: width * 0.08, y: height * 0.08),
                    endPoint: CGPoint(x: width * 0.68, y: height * 0.45)
                ),
                lineWidth: 9.0
            )

            // 2. Fiery orange-red & golden-yellow upper S-curve band (`Orb 3`)
            var orange3Ctx = context
            orange3Ctx.opacity = w3
            orange3Ctx.addFilter(.blur(radius: 3.2))
            let orange3Path = buildOrb3Path(yOff: -5.5, thick: 12.0, bulge: 18.0)
            orange3Ctx.fill(
                orange3Path,
                with: .linearGradient(
                    Gradient(stops: [
                        .init(color: Color(red: 1.0, green: 0.36, blue: 0.04), location: 0.0),
                        .init(color: Color(red: 1.0, green: 0.48, blue: 0.02), location: 0.35),
                        .init(color: Color(red: 1.0, green: 0.84, blue: 0.12), location: 0.65),
                        .init(color: Color(red: 0.12, green: 0.78, blue: 1.0), location: 0.88),
                        .init(color: Color(red: 0.08, green: 0.42, blue: 1.0), location: 1.0)
                    ]),
                    startPoint: CGPoint(x: 0, y: height * 0.22),
                    endPoint: CGPoint(x: width, y: height * 0.58)
                )
            )

            // 3. Lower-right electric cyan & cobalt blue edge ribbon (`Orb 3`)
            var cyan3Ctx = context
            cyan3Ctx.opacity = w3
            cyan3Ctx.addFilter(.blur(radius: 3.0))
            let cyan3Path = buildOrb3Path(yOff: 5.0, thick: 9.0, bulge: 14.0)
            cyan3Ctx.fill(
                cyan3Path,
                with: .linearGradient(
                    Gradient(stops: [
                        .init(color: Color.clear, location: 0.0),
                        .init(color: Color(red: 1.0, green: 0.88, blue: 0.35, opacity: 0.6), location: 0.42),
                        .init(color: Color(red: 0.05, green: 0.86, blue: 1.0), location: 0.74),
                        .init(color: Color(red: 0.08, green: 0.38, blue: 1.0), location: 1.0)
                    ]),
                    startPoint: CGPoint(x: width * 0.25, y: height * 0.40),
                    endPoint: CGPoint(x: width, y: height * 0.68)
                )
            )

            // 4. Huge S-curved blazing white central plasma core (`Orb 3`)
            var white3Ctx = context
            white3Ctx.opacity = w3
            white3Ctx.addFilter(.blur(radius: 1.6))
            let white3Path = buildOrb3Path(yOff: 1.0, thick: 7.5, bulge: 26.0)
            white3Ctx.fill(white3Path, with: .color(Color.white.opacity(0.99)))
        }

        if orb4Weight > 0.01 {
            let w4 = opacity * orb4Weight
            // Orb 4 S-curve centerline: lower-left (u=0.08, y ~ 0.60) -> arches up through center (u=0.48, y ~ 0.36) -> curves to mid-right (u=0.92, y ~ 0.54)
            func orb4Y(u: Double) -> CGFloat {
                let arch = 0.16 * cos(u * .pi * 1.65) - 0.06 * sin(u * .pi * 1.2)
                return height * CGFloat(0.46 + arch)
            }
            func buildOrb4Path(yOff: CGFloat, thick: CGFloat, bulge: CGFloat) -> Path {
                var p = Path()
                for i in 0...steps {
                    let u = Double(i) / Double(steps)
                    let x = CGFloat(u) * width
                    let b = bulge * CGFloat(pow(sin(u * .pi), 1.8))
                    let ht = (thick + b) * 0.5
                    let y = orb4Y(u: u) + yOff - ht
                    if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
                }
                for i in (0...steps).reversed() {
                    let u = Double(i) / Double(steps)
                    let x = CGFloat(u) * width
                    let b = bulge * CGFloat(pow(sin(u * .pi), 1.8))
                    let ht = (thick + b) * 0.5
                    let y = orb4Y(u: u) + yOff + ht
                    p.addLine(to: CGPoint(x: x, y: y))
                }
                p.closeSubpath()
                return p
            }

            // 1. Upper-left icy electric cyan-white dome arch (`Orb 4`)
            var cyanRim4Ctx = context
            cyanRim4Ctx.opacity = w4
            cyanRim4Ctx.addFilter(.blur(radius: 4.5))
            let cyanRim4Rect = CGRect(x: width * 0.04, y: height * 0.03, width: width * 0.66, height: height * 0.56)
            cyanRim4Ctx.stroke(
                Path(ellipseIn: cyanRim4Rect),
                with: .linearGradient(
                    Gradient(colors: [
                        Color(red: 0.28, green: 0.94, blue: 1.0),
                        Color.white,
                        Color.clear
                    ]),
                    startPoint: CGPoint(x: width * 0.10, y: height * 0.08),
                    endPoint: CGPoint(x: width * 0.66, y: height * 0.44)
                ),
                lineWidth: 9.5
            )

            // 2. Upper-right golden-bronze rim accent & lower-right royal cobalt blue glow (`Orb 4`)
            var cobalt4Ctx = context
            cobalt4Ctx.opacity = w4
            cobalt4Ctx.addFilter(.blur(radius: 6.5))
            let cobalt4Rect = CGRect(x: width * 0.34, y: height * 0.44, width: width * 0.56, height: height * 0.34)
            cobalt4Ctx.fill(
                Path(ellipseIn: cobalt4Rect),
                with: .color(Color(red: 0.08, green: 0.38, blue: 1.0, opacity: 0.95))
            )

            // 3. Chromatic S-curve ribbon: Warm Red-Orange-Magenta on lower-left -> Blazing Cyan-White center -> Golden-Amber upper-right (`Orb 4`)
            var swirl4Ctx = context
            swirl4Ctx.opacity = w4
            swirl4Ctx.addFilter(.blur(radius: 3.0))
            let swirl4Path = buildOrb4Path(yOff: 0, thick: 12.0, bulge: 18.0)
            swirl4Ctx.fill(
                swirl4Path,
                with: .linearGradient(
                    Gradient(stops: [
                        .init(color: Color(red: 1.0, green: 0.24, blue: 0.12), location: 0.0),
                        .init(color: Color(red: 1.0, green: 0.28, blue: 0.58), location: 0.24),
                        .init(color: Color(red: 0.12, green: 0.90, blue: 1.0), location: 0.52),
                        .init(color: Color(red: 1.0, green: 0.76, blue: 0.22), location: 0.82),
                        .init(color: Color(red: 0.16, green: 0.68, blue: 1.0), location: 1.0)
                    ]),
                    startPoint: CGPoint(x: 0, y: height * 0.60),
                    endPoint: CGPoint(x: width, y: height * 0.34)
                )
            )

            // 4. Blazing white S-curved central plasma core (`Orb 4`)
            var white4Ctx = context
            white4Ctx.opacity = w4
            white4Ctx.addFilter(.blur(radius: 1.6))
            let white4Path = buildOrb4Path(yOff: -1.5, thick: 7.0, bulge: 24.0)
            white4Ctx.fill(white4Path, with: .color(Color.white.opacity(0.99)))
        }
    }

    private func drawFrame19AlmondLens(
        context: GraphicsContext,
        size: CGSize,
        center: CGPoint,
        t: TimeInterval
    ) {
        // Cyan upper atmospheric halo around the contracting almond lens
        var cyanCtx = context
        cyanCtx.addFilter(.blur(radius: 9.0))
        let cyanRect = CGRect(x: center.x - 28, y: center.y - 14, width: 56, height: 22)
        cyanCtx.fill(
            Path(ellipseIn: cyanRect),
            with: .color(Color(red: 0.18, green: 0.72, blue: 1.0, opacity: 0.90))
        )

        // Warm amber-orange lower halo at left/right tips
        var amberCtx = context
        amberCtx.addFilter(.blur(radius: 8.0))
        let amberRect = CGRect(x: center.x - 30, y: center.y - 4, width: 60, height: 20)
        amberCtx.fill(
            Path(ellipseIn: amberRect),
            with: .color(Color(red: 1.0, green: 0.58, blue: 0.16, opacity: 0.86))
        )

        // Bright white central almond / eye lens (`14.58.49.png` Frame 19)
        var almondPath = Path()
        let halfW: CGFloat = 25.0
        let halfH: CGFloat = 11.5
        almondPath.move(to: CGPoint(x: center.x - halfW, y: center.y + 2))
        almondPath.addQuadCurve(
            to: CGPoint(x: center.x + halfW, y: center.y - 1),
            control: CGPoint(x: center.x, y: center.y - halfH * 1.45)
        )
        almondPath.addQuadCurve(
            to: CGPoint(x: center.x - halfW, y: center.y + 2),
            control: CGPoint(x: center.x, y: center.y + halfH * 1.45)
        )
        almondPath.closeSubpath()

        var coreCtx = context
        coreCtx.addFilter(.blur(radius: 2.2))
        coreCtx.fill(almondPath, with: .color(Color.white.opacity(0.98)))
    }

    private func drawFrame20GlowingSun(
        context: GraphicsContext,
        center: CGPoint,
        t: TimeInterval
    ) {
        // Soft outer white/silver radial bloom (`14.58.49.png` Frame 20)
        var outerBloomCtx = context
        outerBloomCtx.addFilter(.blur(radius: 8.5))
        let outerRect = CGRect(x: center.x - 21, y: center.y - 21, width: 42, height: 42)
        outerBloomCtx.fill(
            Path(ellipseIn: outerRect),
            with: .color(Color.white.opacity(0.65))
        )

        // Bright circular glowing white sun core
        var innerCoreCtx = context
        innerCoreCtx.addFilter(.blur(radius: 2.0))
        let innerRect = CGRect(x: center.x - 14.5, y: center.y - 14.5, width: 29, height: 29)
        innerCoreCtx.fill(
            Path(ellipseIn: innerRect),
            with: .color(Color.white.opacity(0.98))
        )
    }

    private func drawFrame21SingleCenterDot(
        context: GraphicsContext,
        center: CGPoint
    ) {
        // Subtle halo around the single center dot
        var haloCtx = context
        haloCtx.addFilter(.blur(radius: 3.0))
        let haloRect = CGRect(x: center.x - 6.0, y: center.y - 6.0, width: 12.0, height: 12.0)
        haloCtx.fill(
            Path(ellipseIn: haloRect),
            with: .color(Color.white.opacity(0.42))
        )

        // Crisp solid white center dot (`14.58.49.png` Frame 21)
        let dotRect = CGRect(x: center.x - 4.4, y: center.y - 4.4, width: 8.8, height: 8.8)
        context.fill(
            Path(ellipseIn: dotRect),
            with: .color(Color.white.opacity(0.98))
        )
    }

    private func drawFrames22And23Constellation(
        context: GraphicsContext,
        center: CGPoint,
        t: TimeInterval,
        orbFrame: Int
    ) {
        // 6 graded white dots arranged around the sphere matching Frames 22 & 23 of `14.58.49.png`:
        // - 2 larger slightly oval dots at bottom-left and bottom-right (~8.5x6.8pt)
        // - 2 medium dots at right and top-right (~5.6pt)
        // - 2 smaller dots at top-left and left (~3.8pt)
        let baseRotation = (orbFrame >= 23) ? (t * 0.85) : 0.0
        let specs: [(angleDeg: Double, radius: CGFloat, w: CGFloat, h: CGFloat, tiltDeg: Double)] = [
            (72,  21.5, 8.8, 6.8, -14), // bottom-right large oval dot
            (116, 20.5, 8.2, 6.4,  18), // bottom-left large oval dot
            (16,  23.0, 5.8, 5.4,   0), // mid-right medium dot
            (-36, 21.0, 5.2, 5.0,   0), // top-right medium dot
            (-132, 20.5, 3.8, 3.8,  0), // top-left small dot
            (172, 22.0, 3.6, 3.6,   0)  // mid-left small dot
        ]

        for spec in specs {
            let rad = (spec.angleDeg * .pi / 180.0) + baseRotation * 0.35
            let px = center.x + cos(rad) * spec.radius
            let py = center.y + sin(rad) * spec.radius

            var dotCtx = context
            dotCtx.translateBy(x: px, y: py)
            if spec.tiltDeg != 0 {
                dotCtx.rotate(by: .degrees(spec.tiltDeg))
            }
            let rect = CGRect(x: -spec.w * 0.5, y: -spec.h * 0.5, width: spec.w, height: spec.h)
            dotCtx.fill(
                Path(ellipseIn: rect),
                with: .color(Color.white.opacity(0.96))
            )
        }
    }
}


