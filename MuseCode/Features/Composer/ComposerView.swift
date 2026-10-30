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
    /// Width of the 2-container landing composer (top input pill + companion subcontainer),
    /// measured at `1036 px` (`518–520 pt` at 2x Retina) in `Screen Recording 2026-10-28 at 23.23.35.mov`.
    static let landingWidth: CGFloat = 520

    /// Height and corner radius of the top Liquid Glass input pill (`122 px` = `60–61 pt` at 2x Retina).
    static let topPillMinHeight: CGFloat = 60
    static let topPillCornerRadius: CGFloat = 30

    /// Continuous squircle corner radius of the companion subcontainer (`68 px` = `34 pt` at 2x Retina).
    static let companionCornerRadius: CGFloat = 34

    /// Vertical gap between the top input pill and its companion subcontainer (`24–26 px` = `12 pt` at 2x Retina).
    static let companionGap: CGFloat = 12

    /// Diameter of the 3D Liquid Glass Voice Orb (`208–210 px` = `104 pt` at 2x Retina).
    static let voiceOrbDiameter: CGFloat = 104

    /// Rounded enough that the box reads as one soft object next to the sidebar's
    /// pills, small enough that a single line does not look like a capsule.
    static let cornerRadius: CGFloat = 24

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
    @State private var caretUTF16Offset: Int?
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
    @State private var orbEnterStartDate: Date?
    @State private var orbExitStartDate: Date?
    @State private var topPillMeasuredSize: CGSize = CGSize(width: ComposerMetrics.landingWidth, height: ComposerMetrics.topPillMinHeight)
    @State private var enterExitPhase: ComposerEnterExitPhase = .hidden
    @State private var animationTask: Task<Void, Never>?
    @State private var internalFocusTick: Int = 0
    @Namespace private var morphNamespace
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.chatBackground) private var chatBackground
    @Bindable private var stt = MuseVoiceSTTService.shared

    private var isLightGlass: Bool {
        AppTheme.isLightGlass(colorScheme: colorScheme, chatBackground: chatBackground)
    }

    private var isVoiceActive: Bool {
        stt.isRecording || stt.isTranscribing
    }

    private var isVoiceOrbOverlayActive: Bool {
        orbEnterStartDate != nil || orbExitStartDate != nil || orbFrame > 1
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

    // CoreAnimation-interpolated subcontainer parameters driven by discrete `orbFrame` steps so `liquidGlassControlCard` is never re-evaluated inside a 120Hz `TimelineView`.
    private var orbSubScaleX: CGFloat {
        switch orbFrame {
        case 1: return 1.0
        case 2: return 0.992
        case 3: return 0.972
        case 4: return 0.945
        default: return 0.915
        }
    }

    private var orbSubScaleY: CGFloat {
        switch orbFrame {
        case 1: return 1.0
        case 2: return 0.985
        case 3: return 0.945
        case 4: return 0.895
        default: return 0.850
        }
    }

    private var orbSubOffsetY: CGFloat {
        switch orbFrame {
        case 1: return 0.0
        case 2: return -1.5
        case 3: return -4.0
        case 4: return -7.0
        default: return -10.0
        }
    }

    private var orbSubBlur: CGFloat {
        switch orbFrame {
        case 1: return 0.0
        case 2: return 1.8
        case 3: return 6.5
        case 4: return 14.0
        default: return 20.0
        }
    }

    private var orbSubOpacity: Double {
        switch orbFrame {
        case 1: return 1.0
        case 2: return 0.94
        case 3: return 0.80
        case 4: return 0.56
        default: return 0.0
        }
    }

    /// Before the first turn (`controller.items.isEmpty && !controller.hasDroppedComposerToBottom`),
    /// the composer renders as two separate Liquid Glass containers (top input pill + bottom subcontainer).
    /// As soon as the user clicks the mic button on a new session (`first.jpg`) or sends the first message,
    /// the composer drops to the bottom as one unified, consolidated Liquid Glass bar.
    var isConsolidatedBar: Bool {
        !controller.items.isEmpty || controller.hasDroppedComposerToBottom
    }

    /// On any voice interaction after the first untouched-session orb (`second.jpg`, `Computer Screen34.jpg`,
    /// `Computer Screen3dd4.jpeg`, `Computer Screen3445.jpeg`, `Computer Screen344.jpeg`, `C6omputer Screen.jpg`,
    /// `Untitled 22.jpg`, `Untitled20.jpg`), no orb is shown and the bottom of the consolidated chat box
    /// displays the reactive bottom light glow.
    var isShowingBottomVoiceGlow: Bool {
        isConsolidatedBar && !controller.isShowingFirstPromptCenterOrb && (stt.isRecording || stt.isTranscribing)
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

            // Top Smoked Liquid Glass Input Pill & Bottom Frosted Subcontainer — `ComposerTextView` (`NSTextView`) and `liquidGlassControlCard` stay completely outside `TimelineView` so typing/pasting never contends with 60fps Canvas rendering or Metal offscreen blur/mask passes.
            VStack(alignment: .leading, spacing: isConsolidatedBar ? 0 : ComposerMetrics.companionGap) {
                morphingTopInputOrOrb
                    .scaleEffect(
                        x: enterExitPhase.topPillScaleX,
                        y: enterExitPhase.topPillScaleY,
                        anchor: .top
                    )
                    .blur(radius: enterExitPhase.topPillBlur)
                    .offset(y: enterExitPhase.topPillOffsetY)
                    .opacity(enterExitPhase.topPillOpacity)
                    .zIndex(10)

                // Bottom Frosted Liquid Glass Subcontainer — stays mounted in the layout during Voice Orb mode so the window/VStack height never jumps vertically (`1028 (2).mp4`)
                if !isConsolidatedBar {
                    liquidGlassControlCard
                        .scaleEffect(
                            x: isVoiceOrbOverlayActive ? orbSubScaleX : enterExitPhase.subcontainerScaleX,
                            y: isVoiceOrbOverlayActive ? orbSubScaleY : enterExitPhase.subcontainerScaleY,
                            anchor: .top
                        )
                        .offset(y: isVoiceOrbOverlayActive ? orbSubOffsetY : enterExitPhase.subcontainerOffsetY)
                        .blur(radius: isVoiceOrbOverlayActive ? orbSubBlur : enterExitPhase.subcontainerBlur)
                        .opacity(isVoiceOrbOverlayActive ? orbSubOpacity : enterExitPhase.subcontainerOpacity)
                        .animation(.easeOut(duration: 0.11), value: orbFrame)
                        .allowsHitTesting(!isVoiceOrbOverlayActive)
                        .accessibilityHidden(isVoiceOrbOverlayActive)
                        .transition(.museSubcontainerEnterExit)
                }
            }
            .frame(maxWidth: isConsolidatedBar ? .infinity : ComposerMetrics.landingWidth)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .animation(.spring(response: 0.44, dampingFraction: 0.84), value: isConsolidatedBar)
        .onChange(of: stt.isRecording) { _, recording in
            if recording {
                if controller.isShowingFirstPromptCenterOrb && orbFrame == 1 && orbEnterStartDate == nil {
                    startVoiceOrb23FrameEntry()
                }
            } else if (isVoiceOrbOverlayActive || controller.isShowingFirstPromptCenterOrb) && !isTransitioningOutOfOrb {
                playVoiceOrbFrames19To23()
            }
        }
        .onChange(of: stt.isTranscribing) { _, transcribing in
            if !transcribing && !stt.isRecording && (isVoiceOrbOverlayActive || controller.isShowingFirstPromptCenterOrb) && !isTransitioningOutOfOrb {
                playVoiceOrbFrames19To23()
            }
        }
        .onAppear {
            loadDraft()
            if isVoiceActive {
                orbEnterStartDate = Date().addingTimeInterval(-1.2)
                orbExitStartDate = nil
                orbFrame = stt.isTranscribing ? 22 : 9
                enterExitPhase = .settled
            } else {
                orbEnterStartDate = nil
                orbExitStartDate = nil
                orbFrame = 1
                playComposerEnterAnimation(withLeadingExit: false)
            }
        }
        .onDisappear {
            animationTask?.cancel()
            orbAnimationTask?.cancel()
            orbEnterStartDate = nil
            orbExitStartDate = nil
            enterExitPhase = .hidden
        }
        .onChange(of: ObjectIdentifier(controller)) { _, _ in
            loadDraft()
            if !isVoiceActive {
                animationTask?.cancel()
                orbAnimationTask?.cancel()
                isTransitioningOutOfOrb = false
                orbEnterStartDate = nil
                orbExitStartDate = nil
                orbFrame = 1
                enterExitPhase = .settled
            }
        }
        .onChange(of: state.newSessionResetTick) { _, _ in
            animationTask?.cancel()
            orbAnimationTask?.cancel()
            isTransitioningOutOfOrb = false
            orbEnterStartDate = nil
            orbExitStartDate = nil
            orbFrame = 1
            text = ""
            attachments = []
            attachmentError = nil
            fileMatches = []
            suggestionIndex = 0
            enterExitPhase = .settled
            internalFocusTick += 1
        }
        .onChange(of: state.composerEnterAnimationTick) { _, _ in
            if !isVoiceActive {
                orbAnimationTask?.cancel()
                isTransitioningOutOfOrb = false
                orbEnterStartDate = nil
                orbExitStartDate = nil
                orbFrame = 1
                playComposerEnterAnimation(withLeadingExit: false)
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
        .onChange(of: attachments) { _, newAttachments in
            controller.drafts.setAttachments(newAttachments, for: controller.draftKey)
        }
    }

    // MARK: - Liquid Glass Top Input Pill & Morphing 3D Voice Orb (`1028 (2).mp4` & `14.58.49.png`)

    private func currentVoiceOrbEnterMetrics(at date: Date) -> VoiceOrbEnterMetrics {
        let fullW = max(topPillMeasuredSize.width, ComposerMetrics.landingWidth)
        let baseH = max(topPillMeasuredSize.height, isConsolidatedBar ? 82 : ComposerMetrics.topPillMinHeight)
        if let exitStart = orbExitStartDate {
            let exitElapsed = max(0, date.timeIntervalSince(exitStart))
            return VoiceOrbEnterMetrics.evaluateExit(
                elapsed: exitElapsed,
                fullWidth: fullW,
                baseHeight: baseH,
                orbFrame: orbFrame
            )
        } else if let enterStart = orbEnterStartDate {
            let enterElapsed = max(0, date.timeIntervalSince(enterStart))
            return VoiceOrbEnterMetrics.evaluateEnter(
                elapsed: enterElapsed,
                fullWidth: fullW,
                baseHeight: baseH,
                orbFrame: orbFrame
            )
        } else if orbFrame > 1 {
            return VoiceOrbEnterMetrics.fromStaticDescriptor(
                VoiceOrbFrameDescriptor.descriptor(forFrame: orbFrame),
                fullWidth: fullW,
                baseHeight: baseH
            )
        } else {
            return VoiceOrbEnterMetrics.idle(fullWidth: fullW, baseHeight: baseH)
        }
    }

    private var morphingTopInputOrOrb: some View {
        liquidGlassInputPill
            .frame(maxWidth: .infinity, alignment: .center)
    }

    private var liquidGlassInputPill: some View {
        VStack(alignment: .leading, spacing: isConsolidatedBar ? 8 : 0) {
            HStack(alignment: .center, spacing: 10) {
                ComposerTextView(
                    text: $text,
                    placeholder: placeholder,
                    focusTick: focusTick + internalFocusTick,
                    sendKey: state.preferences.sendKey,
                    suggestionsActive: !suggestions.isEmpty,
                    isEnabled: controller.connection.isConnected,
                    isLightGlass: isLightGlass,
                    onSend: { send() },
                    onFollowUp: { send(delivery: .followUp) },
                    onEscape: handleEscape,
                    onMoveSuggestion: moveSuggestion,
                    onAcceptSuggestion: acceptCurrentSuggestion,
                    onUserDirectEdit: {
                        controller.hasCompletedFirstVoiceOrTextInteraction = true
                        // If the user types or pastes (`⌘V`) directly into the editor while the Voice Orb is open, immediately cancel STT and reveal the editor.
                        if isVoiceOrbOverlayActive || controller.isShowingFirstPromptCenterOrb {
                            stt.cancel()
                            forceCollapseVoiceOrbImmediately()
                        }
                    },
                    onSelectionChange: { offset in
                        if caretUTF16Offset != offset {
                            caretUTF16Offset = offset
                            refreshFileMatchesIfNeeded()
                        }
                    }
                )
                .frame(minHeight: ComposerMetrics.editorMinHeight, maxHeight: ComposerMetrics.editorMaxHeight)
                .fixedSize(horizontal: false, vertical: true)

                if !isConsolidatedBar {
                    HStack(spacing: 8) {
                        voiceMicButton
                            .matchedGeometryEffect(id: "composerMicButton", in: morphNamespace)

                        if isStreamingRun || canSend {
                            primaryActionButton
                                .matchedGeometryEffect(id: "composerPrimaryAction", in: morphNamespace)
                        }
                    }
                }
            }

            if isConsolidatedBar {
                if !attachments.isEmpty {
                    attachmentRow
                }

                // Consolidated single-bar control strip (minimized attachment +, folder, branch, model, access, tachometer, mic, send)
                HStack(spacing: 12) {
                    Button {
                        chooseAttachments()
                    } label: {
                        HugeIcon(name: "add-01", size: 15)
                            .foregroundStyle(AppTheme.glassSecondaryText(isLight: isLightGlass))
                            .frame(width: 24, height: 24)
                            .background(AppTheme.glassChipFill(isLight: isLightGlass), in: Circle())
                            .overlay(
                                Circle()
                                    .strokeBorder(AppTheme.glassChipStroke(isLight: isLightGlass), lineWidth: 0.7)
                            )
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
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .padding(.leading, isConsolidatedBar ? 18 : 26)
        .padding(.trailing, isConsolidatedBar ? 16 : 20)
        .padding(.vertical, isConsolidatedBar ? 12 : 14)
        .frame(maxWidth: .infinity, minHeight: isConsolidatedBar ? 78 : ComposerMetrics.topPillMinHeight)
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear {
                        if geo.size.width > 120 {
                            topPillMeasuredSize = geo.size
                        }
                    }
                    .onChange(of: geo.size) { _, newSize in
                        if !isVoiceOrbOverlayActive && newSize.width > 120 {
                            topPillMeasuredSize = newSize
                        }
                    }
            }
        )
        .background(
            LiquidGlassCardBackground(
                cornerRadius: isConsolidatedBar ? ComposerMetrics.cornerRadius : ComposerMetrics.topPillCornerRadius,
                isDarkTopPill: true,
                isDropTargeted: isDropTargeted,
                sphereMix: 0.0
            )
            .overlay(alignment: .bottom) {
                if isShowingBottomVoiceGlow {
                    VoiceReactiveBottomGlowView(
                        isRecording: stt.isRecording,
                        isTranscribing: stt.isTranscribing,
                        audioLevel: stt.audioLevel
                    )
                    .clipShape(
                        RoundedRectangle(
                            cornerRadius: isConsolidatedBar ? ComposerMetrics.cornerRadius : ComposerMetrics.topPillCornerRadius,
                            style: .continuous
                        )
                    )
                    .transition(.opacity.animation(.easeInOut(duration: 0.20)))
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
            MuseMicrophoneIcon(isActive: isVoiceActive, size: 20)
                .frame(width: 32, height: 32)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .accessibilityLabel("Voice input (\(stt.routerBadgeText))")
        .help(stt.routerStatusDescription)
        .contextMenu {
            Section("Speech-to-Text Router (\(stt.routerBadgeText))") {
                ForEach(MuseVoiceSTTRouterMode.allCases) { mode in
                    Button {
                        stt.setRouterMode(mode)
                    } label: {
                        if stt.routerMode == mode {
                            Label(mode.label, systemImage: "checkmark")
                        } else {
                            Text(mode.label)
                        }
                    }
                }
            }
            Divider()
            if stt.activePrimaryBackend() == .museCLI {
                Button("Switch to macOS System STT Backup Now") {
                    stt.switchToSystemBackupNow()
                }
            } else {
                Button("Retry Muse STT Now") {
                    stt.retryMuseSTTNow()
                }
            }
            Divider()
            Button("Transcribe Audio Clip (.wav / .m4a)…") {
                pickAndTranscribeAudioFile()
            }
        }
    }

    private var voiceSTTRouterQuickSwitchPill: some View {
        Button {
            if stt.activePrimaryBackend() == .museCLI {
                stt.switchToSystemBackupNow()
            } else {
                stt.retryMuseSTTNow()
            }
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(stt.didFallbackToSystem || stt.activePrimaryBackend() == .macOSSystem ? Color.cyan : Color.green)
                    .frame(width: 5.5, height: 5.5)
                Text(stt.routerBadgeText)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(AppTheme.glassSecondaryText(isLight: isLightGlass))
                    .lineLimit(1)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(
                Capsule(style: .continuous)
                    .fill(AppTheme.glassChipFill(isLight: isLightGlass))
                    .overlay(
                        Capsule(style: .continuous)
                            .strokeBorder(AppTheme.glassChipStroke(isLight: isLightGlass), lineWidth: 0.7)
                    )
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("\(stt.routerStatusDescription) (Click to quick-switch, right-click for router modes)")
        .contextMenu {
            Section("Speech-to-Text Router") {
                ForEach(MuseVoiceSTTRouterMode.allCases) { mode in
                    Button {
                        stt.setRouterMode(mode)
                    } label: {
                        if stt.routerMode == mode {
                            Label(mode.label, systemImage: "checkmark")
                        } else {
                            Text(mode.label)
                        }
                    }
                }
            }
            Divider()
            if stt.activePrimaryBackend() == .museCLI {
                Button("Use macOS System Backup Now") {
                    stt.switchToSystemBackupNow()
                }
            } else {
                Button("Retry Muse STT Now") {
                    stt.retryMuseSTTNow()
                }
            }
        }
    }

    // MARK: - Bottom Frosted Liquid Glass Control Card (Landing State Before First Turn)

    private var liquidGlassControlCard: some View {
        VStack(alignment: .leading, spacing: 11) {
            // Voice Transcription Row (`Untitled 9.jpg` & `Computer Screen.jpg`):
            // Displays the circular Voice Orb wave badge icon and the quoted spoken transcript
            // (e.g. `"talk about food"`) at the top of the subcontainer after Voice STT completes.
            if let voiceQuote = stt.lastTranscript, !voiceQuote.isEmpty {
                HStack(spacing: 10) {
                    Button {
                        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            text = voiceQuote
                        }
                        if canSend {
                            send(delivery: .automatic)
                        } else {
                            internalFocusTick += 1
                        }
                    } label: {
                        HStack(spacing: 10) {
                            VoiceOrbBadgeIcon(size: 19, isLightGlass: isLightGlass)
                            Text("\"\(voiceQuote)\"")
                                .font(.system(size: 13.5, weight: .medium))
                                .foregroundStyle(AppTheme.glassPrimaryText(isLight: isLightGlass))
                                .lineLimit(1)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .focusEffectDisabled()
                    .accessibilityLabel("Voice transcription: \"\(voiceQuote)\"")
                    .help("Voice transcription: \"\(voiceQuote)\"")

                    Spacer(minLength: 8)

                    voiceSTTRouterQuickSwitchPill
                }
                .padding(.bottom, 1)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

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
                .fill(AppTheme.glassDivider(isLight: isLightGlass))
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
                            .foregroundStyle(AppTheme.glassSecondaryText(isLight: isLightGlass))
                        Text("Attach files or images")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(AppTheme.glassPrimaryText(isLight: isLightGlass))
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
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .background(
            LiquidGlassCardBackground(
                cornerRadius: ComposerMetrics.companionCornerRadius,
                isDarkTopPill: false,
                isDropTargeted: isDropTargeted
            )
        )
    }

    // MARK: - Staged Enter & Exit Choreography (`enter-anim.gif`)

    func playComposerEnterAnimation(withLeadingExit: Bool) {
        animationTask?.cancel()
        if state.preferences.reducedMotionOverride == true {
            enterExitPhase = .settled
            return
        }
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
                            .foregroundStyle(AppTheme.glassSecondaryText(isLight: isLightGlass))
                        VStack(alignment: .leading, spacing: 0) {
                            Text(attachment.fileName)
                                .font(.caption)
                                .foregroundStyle(AppTheme.glassPrimaryText(isLight: isLightGlass))
                                .lineLimit(1)
                            Text(attachment.displaySize)
                                .font(.caption2)
                                .foregroundStyle(AppTheme.glassMutedText(isLight: isLightGlass))
                        }
                        Button {
                            attachments.removeAll { $0.id == attachment.id }
                        } label: {
                            HugeIcon(name: "cancel-circle")
                                .imageScale(.small)
                                .foregroundStyle(AppTheme.glassMutedText(isLight: isLightGlass))
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Remove \(attachment.fileName)")
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(AppTheme.glassChipFill(isLight: isLightGlass), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(AppTheme.glassChipStroke(isLight: isLightGlass), lineWidth: 1)
                    )
                }
            }
            .padding(.horizontal, 2)
        }
    }

    // MARK: - First-Prompt Center Voice Orb (`first.jpg`) vs. Subsequent Reactive Bottom Light Glow (`second.jpg`, `Computer Screen34.jpg`)

    /// Evaluates the new session voice rule when the mic button is clicked:
    /// 1) For a new session where the user hasn't typed anything yet (`items.isEmpty && !hasCompletedFirstVoiceOrTextInteraction && text.isEmpty`):
    ///    Immediately drops the chat box to the bottom (`hasDroppedComposerToBottom = true`) and shows the 3D Voice Orb in the center (`isShowingFirstPromptCenterOrb = true`).
    /// 2) On any interaction afterwards:
    ///    Keeps the chat box at the bottom, shows NO orb (`isShowingFirstPromptCenterOrb = false`), and animates the reactive bottom light glow along the bottom of the chat box.
    @discardableResult
    func applyVoiceMicClickStateTransition() -> Bool {
        let isUntouchedNewSession = controller.items.isEmpty
            && !controller.hasCompletedFirstVoiceOrTextInteraction
            && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        if isUntouchedNewSession {
            withAnimation(.spring(response: 0.44, dampingFraction: 0.86)) {
                controller.hasDroppedComposerToBottom = true
                controller.hasCompletedFirstVoiceOrTextInteraction = true
                controller.isShowingFirstPromptCenterOrb = true
                controller.firstPromptOrbFrame = 7
            }
            return true
        } else {
            withAnimation(.spring(response: 0.42, dampingFraction: 0.86)) {
                controller.hasDroppedComposerToBottom = true
                controller.hasCompletedFirstVoiceOrTextInteraction = true
                controller.isShowingFirstPromptCenterOrb = false
            }
            forceCollapseVoiceOrbImmediately()
            return false
        }
    }

    private func toggleVoiceOrbRecording() {
        if !isVoiceOrbOverlayActive && !isVoiceActive && !controller.isShowingFirstPromptCenterOrb {
            let showCenterOrb = applyVoiceMicClickStateTransition()
            if showCenterOrb {
                startVoiceOrb23FrameEntry()
            }
            Task {
                await stt.toggleRecording(installation: controller.museInstallation) { transcribed in
                    appendTranscription(transcribed)
                }
                surfaceVoiceErrorIfNeeded(stt.lastError)
                if !stt.isRecording && !stt.isTranscribing {
                    if (isVoiceOrbOverlayActive || controller.isShowingFirstPromptCenterOrb) && !isTransitioningOutOfOrb {
                        playVoiceOrbFrames19To23()
                    }
                }
            }
        } else if isTransitioningOutOfOrb || (!stt.isRecording && stt.isTranscribing) {
            // Second click while already stopping/transcribing immediately cancels STT and restores the composer input box.
            stt.cancel()
            forceCollapseVoiceOrbImmediately()
        } else {
            if controller.isShowingFirstPromptCenterOrb || isVoiceOrbOverlayActive {
                // Stopping first-prompt center orb recording: step through Frames 19 -> 20 -> 21 -> 22 -> 23
                playVoiceOrbFrames19To23()
            }
            Task {
                if stt.isRecording {
                    await stt.toggleRecording(installation: controller.museInstallation) { transcribed in
                        appendTranscription(transcribed)
                    }
                    surfaceVoiceErrorIfNeeded(stt.lastError)
                }
            }
        }
    }

    private func forceCollapseVoiceOrbImmediately() {
        orbAnimationTask?.cancel()
        orbAnimationTask = nil
        isTransitioningOutOfOrb = false
        orbEnterStartDate = nil
        orbExitStartDate = nil
        orbFrame = 1
        controller.firstPromptOrbFrame = 7
        withAnimation(.easeOut(duration: 0.18)) {
            controller.isShowingFirstPromptCenterOrb = false
        }
        enterExitPhase = .settled
    }

    /// Drives the continuous Enter timeline matching `1028 (2).mp4` (`F018` -> `F046`)
    /// while updating `orbFrame` and `controller.firstPromptOrbFrame` through Frames 2 -> 3 -> 4 -> 5 -> 6 -> 7 -> 8 (dark pulse at `t=0.866s`) -> 9..18.
    private func startVoiceOrb23FrameEntry() {
        orbAnimationTask?.cancel()
        isTransitioningOutOfOrb = false
        orbExitStartDate = nil
        orbEnterStartDate = Date()
        orbFrame = 2
        controller.firstPromptOrbFrame = 6
        orbAnimationTask = Task { @MainActor in
            // Frame 2 (0..70ms, F019-F020): Full-width S-curve plasma wave ignition while placeholder & mic remain visible
            try? await Task.sleep(nanoseconds: 70_000_000)
            guard !Task.isCancelled else { return }

            // Frame 3 (70..170ms, F021-F023): Contraction to 83.9% width + bottom white-silver glow + subcontainer blur (alpha=0.80)
            orbFrame = 3
            controller.firstPromptOrbFrame = 6
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled else { return }

            // Frame 4 (170..270ms, F024-F026): Contraction to 68.7% width + heavy subcontainer blur (alpha=0.64)
            orbFrame = 4
            controller.firstPromptOrbFrame = 7
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled else { return }

            // Frame 5 (270..335ms, F027-F028): Rapid squeeze into plump stadium capsule (1.64x -> 1.40x) + subcontainer dissolves out
            orbFrame = 5
            controller.firstPromptOrbFrame = 7
            try? await Task.sleep(nanoseconds: 65_000_000)
            guard !Task.isCancelled else { return }

            // Frame 6 (335..420ms, F029-F030): Compact rounded stadium capsule (1.32x)
            orbFrame = 6
            controller.firstPromptOrbFrame = 7
            try? await Task.sleep(nanoseconds: 85_000_000)
            guard !Task.isCancelled else { return }

            // Frame 7 (420..830ms, F031-F043): Settled 1:1 3D Liquid Glass sphere with gently undulating horizon wave
            orbFrame = 7
            controller.firstPromptOrbFrame = 7
            try? await Task.sleep(nanoseconds: 410_000_000)
            guard !Task.isCancelled else { return }

            // Frame 8 (830..905ms, F044): Single-frame dark obsidian pulse/blink (`1028 (2).mp4` F044 & `14.58.49.png` Frame 8)
            orbFrame = 8
            controller.firstPromptOrbFrame = 8
            try? await Task.sleep(nanoseconds: 75_000_000)
            guard !Task.isCancelled else { return }

            // Frames 9..18 (905ms+, F045+): Active listening loop with undulating horizon wave & live `mic interactivity`
            var activeFrame = 9
            while !Task.isCancelled && stt.isRecording {
                orbFrame = activeFrame
                controller.firstPromptOrbFrame = activeFrame
                try? await Task.sleep(nanoseconds: 95_000_000)
                activeFrame = activeFrame < 18 ? (activeFrame + 1) : 9
            }
        }
    }

    /// Plays Frames 19 -> 20 -> 21 -> 22 -> 23 (central almond lens -> glowing white sun -> single dot -> 6 orbiting dots)
    /// and ALWAYS dismisses the first-prompt center orb once transcription finishes or times out.
    private func playVoiceOrbFrames19To23() {
        guard !isTransitioningOutOfOrb else { return }
        isTransitioningOutOfOrb = true
        orbAnimationTask?.cancel()
        orbAnimationTask = Task { @MainActor in
            for frame in 19...23 {
                guard !Task.isCancelled else { return }
                orbFrame = frame
                controller.firstPromptOrbFrame = frame
                try? await Task.sleep(nanoseconds: 75_000_000)
            }

            // Hold on the 6-dot constellation (Frames 22-23) while `muse voice transcribe` is still running (bounded to <= 15.0s)
            var waitTicks = 0
            while !Task.isCancelled && stt.isTranscribing && waitTicks < 150 {
                let f = (waitTicks % 2 == 0) ? 23 : 22
                orbFrame = f
                controller.firstPromptOrbFrame = f
                try? await Task.sleep(nanoseconds: 100_000_000)
                waitTicks += 1
            }

            guard !Task.isCancelled else { return }

            enterExitPhase = .settled
            orbExitStartDate = Date()
            for reverseFrame in [6, 5, 4, 3, 2] {
                guard !Task.isCancelled else { return }
                orbFrame = reverseFrame
                try? await Task.sleep(nanoseconds: 45_000_000)
            }
            orbEnterStartDate = nil
            orbExitStartDate = nil
            orbFrame = 1
            controller.firstPromptOrbFrame = 7
            withAnimation(.easeOut(duration: 0.22)) {
                controller.isShowingFirstPromptCenterOrb = false
            }
            isTransitioningOutOfOrb = false
            internalFocusTick += 1
        }
    }

    private func collapseOrbBackToInputPill() {
        playVoiceOrbFrames19To23()
    }

    private func appendTranscription(_ transcribed: String) {
        let trimmed = transcribed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        stt.lastTranscript = MuseVoiceSTTService.normalizedVoiceDisplayQuote(from: trimmed)
        if text.isEmpty {
            text = trimmed
        } else if text.hasSuffix(" ") || text.hasSuffix("\n") {
            text += trimmed
        } else {
            text += " " + trimmed
        }
        internalFocusTick += 1
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
            } else {
                surfaceVoiceErrorIfNeeded(stt.lastError)
            }
        }
    }

    private func surfaceVoiceErrorIfNeeded(_ error: String?) {
        guard let error, !error.isEmpty else { return }
        if error.localizedCaseInsensitiveContains("no words heard")
            || error.localizedCaseInsensitiveContains("no speech") {
            return
        }
        state.showToast(error)
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
                    .foregroundStyle(canSend ? Color.white : AppTheme.glassMutedText(isLight: isLightGlass))
                    .frame(width: 28, height: 28)
                    .background(
                        Circle()
                            .fill(canSend ? AppTheme.accentBlue : AppTheme.glassChipFill(isLight: isLightGlass))
                            .overlay(
                                Circle()
                                    .strokeBorder(
                                        canSend ? Color.clear : AppTheme.glassChipStroke(isLight: isLightGlass),
                                        lineWidth: 0.8
                                    )
                            )
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
                    .foregroundStyle(AppTheme.glassSecondaryText(isLight: isLightGlass))
                Text(controller.model?.displayName ?? "Model")
                    .font(.system(size: 13.5, weight: .medium))
                    .foregroundStyle(AppTheme.glassPrimaryText(isLight: isLightGlass))
                    .lineLimit(1)
                if let effort {
                    Text(effort.capitalized)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(AppTheme.glassMutedText(isLight: isLightGlass))
                }
                HugeIcon(name: "arrow-down-01", size: 11)
                    .foregroundStyle(AppTheme.glassMutedText(isLight: isLightGlass))
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
        stt.lastTranscript = nil
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
        if isVoiceActive || isVoiceOrbOverlayActive {
            stt.cancel()
            forceCollapseVoiceOrbImmediately()
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
        attachments = controller.drafts.attachments(for: controller.draftKey)
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

    /// Finds the active `@path` token range around the current cursor position (`caretUTF16Offset`),
    /// falling back to the end of `text` if the cursor position has not been reported yet.
    private var activeFileTokenInfo: (atIndex: String.Index, tokenEnd: String.Index, query: String)? {
        guard !text.isEmpty else { return nil }
        let caretIndex: String.Index
        if let offset = caretUTF16Offset {
            let clamped = max(0, min(offset, text.utf16.count))
            caretIndex = String.Index(utf16Offset: clamped, in: text)
        } else {
            caretIndex = text.endIndex
        }

        let prefixBeforeCaret = text[text.startIndex..<caretIndex]
        guard let atIndex = prefixBeforeCaret.lastIndex(of: "@") else { return nil }
        let beforeAt = text[text.startIndex..<atIndex]
        if let prevChar = beforeAt.last, !prevChar.isWhitespace, !prevChar.isNewline {
            return nil
        }
        let afterAt = text.index(after: atIndex)
        let querySlice = text[afterAt..<caretIndex]
        guard !querySlice.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            return nil
        }

        var tokenEnd = caretIndex
        while tokenEnd < text.endIndex,
              !text[tokenEnd].isWhitespace,
              !text[tokenEnd].isNewline {
            tokenEnd = text.index(after: tokenEnd)
        }
        return (atIndex: atIndex, tokenEnd: tokenEnd, query: String(querySlice))
    }

    /// The `@path` token being typed at the active cursor position in the composer.
    private var fileQuery: String? {
        activeFileTokenInfo?.query
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
            caretUTF16Offset = text.utf16.count
        case .file:
            guard let info = activeFileTokenInfo else { return }
            let prefix = String(text[text.startIndex..<info.atIndex])
            let suffix = String(text[info.tokenEnd..<text.endIndex])
            let needsLeadingSpaceDrop = suggestion.insertion.hasSuffix(" ") && suffix.first == " "
            let cleanSuffix = needsLeadingSpaceDrop ? String(suffix.dropFirst()) : suffix
            let newPrefixAndInsertion = prefix + suggestion.insertion
            text = newPrefixAndInsertion + cleanSuffix
            caretUTF16Offset = newPrefixAndInsertion.utf16.count
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
        if let info = activeFileTokenInfo {
            let prefix = String(text[text.startIndex..<info.atIndex])
            let suffix = String(text[info.tokenEnd..<text.endIndex])
            return prefix + suffix
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

    var popoverContent: some View {
        let totalTokens = controller.stats?.tokens.totalTokens ?? 0
        let inputTokens = controller.stats?.tokens.input ?? 0
        let outputTokens = controller.stats?.tokens.output ?? 0
        let cachedTokens = controller.stats?.tokens.cacheRead ?? 0
        let subagentTokens = controller.subagents.reduce(0) { $0 + $1.totalTokens }
        let contextWindow = controller.model?.contextWindow
        let isYoloEnabled = (controller.trustOverride ?? (controller.trustState != .untrusted))

        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text("Muse Credit Gauge")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(remainingPercentInt)%")
                    .font(.system(size: 12, weight: .bold).monospacedDigit())
                    .foregroundStyle(.primary)
            }

            TachometerLargeDial(
                fraction: remainingFraction
            )
            .frame(maxWidth: .infinity)
            .frame(height: 48)

            if let snapshot = usageService.latestSnapshot {
                Divider()
                VStack(alignment: .leading, spacing: 2) {
                    if let window = snapshot.window {
                        let resetSuffix = window.resetsAt.map { " · \($0.formatted(date: .omitted, time: .shortened))" } ?? ""
                        KeyValueRow(
                            key: "5h window",
                            value: "\(Int(window.remainingPercent.rounded()))% left\(resetSuffix)",
                            isMonospaced: true
                        )
                    }
                    if let weekly = snapshot.weekly {
                        let tierSuffix = (snapshot.tier?.isEmpty == false) ? " (\(snapshot.tier!))" : ""
                        KeyValueRow(
                            key: "Weekly",
                            value: "\(Int(weekly.remainingPercent.rounded()))% left\(tierSuffix)",
                            isMonospaced: true
                        )
                    }
                    if snapshot.window == nil && snapshot.weekly == nil {
                        if let allowance = snapshot.allowanceRemainingPercent {
                            KeyValueRow(
                                key: "Allowance",
                                value: "\(Int(allowance.rounded()))% left",
                                isMonospaced: true
                            )
                        } else if snapshot.reason == "server_sent_no_usage" {
                            KeyValueRow(
                                key: "5h window",
                                value: "100% available",
                                isMonospaced: false
                            )
                        } else if let reason = snapshot.reason {
                            KeyValueRow(key: "Status", value: reason, isMonospaced: false)
                        }
                    }
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 2) {
                KeyValueRow(key: "In / Out tokens", value: "\(inputTokens.formatted()) / \(outputTokens.formatted())", isMonospaced: true)
                if cachedTokens > 0 {
                    KeyValueRow(key: "Cached tokens", value: "\(cachedTokens.formatted())", isMonospaced: true)
                }
                if subagentTokens > 0 {
                    KeyValueRow(key: "Subagent tokens", value: "\(subagentTokens.formatted())", isMonospaced: true)
                }
                if let contextWindow, contextWindow > 0 {
                    KeyValueRow(key: "Session tokens", value: "\((totalTokens + subagentTokens).formatted()) / \(contextWindow.formatted())", isMonospaced: true)
                } else {
                    KeyValueRow(key: "Session tokens", value: "\((totalTokens + subagentTokens).formatted())", isMonospaced: true)
                }
                KeyValueRow(
                    key: "Mode",
                    value: isYoloEnabled ? "YOLO (auto)" : "Restricted",
                    isMonospaced: false
                )
            }

            Divider()

            HStack(spacing: 6) {
                Button {
                    Task { await usageService.refresh(installation: controller.museInstallation) }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10, weight: .semibold))
                            .opacity(usageService.isRefreshing ? 0.45 : 0.92)
                        Text(usageService.isRefreshing ? "Refreshing…" : "Refresh")
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(1)
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(.settingsPill)

                Spacer(minLength: 4)

                if let modelId = controller.model?.id {
                    Text(modelId)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(11)
        .frame(width: 224)
    }
}

/// Vector microphone icon matching `mic-01.svg` whose capsule head is completely filled
/// when voice recording/transcribing is active (`ff3.jpg`), and rendered as a clean outline when idle.
struct MuseMicrophoneIcon: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.chatBackground) private var chatBackground
    var isActive: Bool
    var size: CGFloat = 20

    private var isLightGlass: Bool {
        AppTheme.isLightGlass(colorScheme: colorScheme, chatBackground: chatBackground)
    }

    var body: some View {
        let isLight = isLightGlass
        Canvas { context, canvasSize in
            let s = min(canvasSize.width, canvasSize.height) / 24.0
            let strokeW = max(1.3, 1.65 * s)
            let activePrimary = isLight
                ? Color(red: 0.05, green: 0.16, blue: 0.09)
                : Color.white
            let strokeColor = isLight
                ? Color(red: 0.08, green: 0.21, blue: 0.12, opacity: isActive ? 0.96 : 0.84)
                : Color.white.opacity(isActive ? 0.98 : 0.84)

            // Microphone capsule head (`x: 7..16, y: 2..16, rx: 4.5` in 24x24 space)
            let capsuleRect = CGRect(
                x: 7.0 * s,
                y: 2.0 * s,
                width: 9.0 * s,
                height: 14.0 * s
            )
            let capsulePath = Path(roundedRect: capsuleRect, cornerRadius: 4.5 * s)

            if isActive {
                var glowCtx = context
                glowCtx.addFilter(.blur(radius: 2.2 * s))
                glowCtx.fill(
                    capsulePath,
                    with: .color(
                        isLight
                            ? Color(red: 0.24, green: 0.78, blue: 0.42, opacity: 0.46)
                            : Color.white.opacity(0.48)
                    )
                )
                context.fill(capsulePath, with: .color(activePrimary))
            }
            context.stroke(
                capsulePath,
                with: .color(isActive ? activePrimary : strokeColor),
                style: StrokeStyle(lineWidth: strokeW, lineCap: .round, lineJoin: .round)
            )

            // U-shaped cradle (`M4 13 C 4.577 16.462, 7.573 19, 11.083 19 H 11.917 C 15.427 19, 18.423 16.462, 19 13`)
            var cradle = Path()
            cradle.move(to: CGPoint(x: 4.0 * s, y: 13.0 * s))
            cradle.addCurve(
                to: CGPoint(x: 11.0828 * s, y: 19.0 * s),
                control1: CGPoint(x: 4.5771 * s, y: 16.4623 * s),
                control2: CGPoint(x: 7.5727 * s, y: 19.0 * s)
            )
            cradle.addLine(to: CGPoint(x: 11.9172 * s, y: 19.0 * s))
            cradle.addCurve(
                to: CGPoint(x: 19.0 * s, y: 13.0 * s),
                control1: CGPoint(x: 15.4273 * s, y: 19.0 * s),
                control2: CGPoint(x: 18.4229 * s, y: 16.4623 * s)
            )
            context.stroke(
                cradle,
                with: .color(strokeColor),
                style: StrokeStyle(lineWidth: strokeW, lineCap: .round, lineJoin: .round)
            )

            // Vertical stand (`M11.5 19 V 22`)
            var stem = Path()
            stem.move(to: CGPoint(x: 11.5 * s, y: 19.0 * s))
            stem.addLine(to: CGPoint(x: 11.5 * s, y: 22.0 * s))
            context.stroke(
                stem,
                with: .color(strokeColor),
                style: StrokeStyle(lineWidth: strokeW, lineCap: .round)
            )
        }
        .frame(width: size, height: size)
    }
}

/// Compact tachometer dial whose gauge stroke thins out as remaining credits decrease.
struct TachometerMiniDial: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.chatBackground) private var chatBackground
    var fraction: Double
    var isGlassSurface: Bool = true

    private var isLightGlass: Bool {
        AppTheme.isLightGlass(colorScheme: colorScheme, chatBackground: chatBackground)
    }

    var body: some View {
        let isLight = isLightGlass
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height - 2.5)
            let radius = min(size.width / 2 - 2.0, size.height - 3.5)
            let startDeg = 165.0
            let endDeg = 375.0
            let spanDeg = endDeg - startDeg
            let clamped = min(1.0, max(0.0, fraction))
            let needleDeg = startDeg + clamped * spanDeg

            let fgColor = isGlassSurface
                ? (isLight ? Color(red: 0.07, green: 0.18, blue: 0.11) : Color.white)
                : Color.primary
            let trackColor = isGlassSurface
                ? (isLight ? Color(red: 0.08, green: 0.22, blue: 0.13, opacity: 0.22) : Color.white.opacity(0.22))
                : Color.primary.opacity(0.18)

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

/// Compact monochrome tachometer instrument dial shown in the credit gauge popover (`ff3.jpg`),
/// with stroke thickness that tapers down as remaining credits decrease.
struct TachometerLargeDial: View {
    var fraction: Double

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height - 8)
            let radius = min(size.width / 2 - 12, size.height - 11)
            let startDeg = 165.0
            let endDeg = 375.0
            let spanDeg = endDeg - startDeg
            let clamped = min(1.0, max(0.0, fraction))
            let needleDeg = startDeg + clamped * spanDeg

            // Background track
            var track = Path()
            track.addArc(center: center, radius: radius, startAngle: .degrees(startDeg), endAngle: .degrees(endDeg), clockwise: false)
            context.stroke(track, with: .color(.primary.opacity(0.16)), style: StrokeStyle(lineWidth: 2.0, lineCap: .round))

            // Active monochrome arc with variable thickness (6.2pt full -> 1.4pt low)
            if clamped > 0.005 {
                let segments = 24
                let minStroke: CGFloat = 1.4
                let maxStrokeForFraction: CGFloat = minStroke + CGFloat(clamped) * 4.8
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
                let innerR = radius - (isMajor ? 8 : 5)
                let outerR = radius - 2
                let p1 = CGPoint(x: center.x + CGFloat(cos(rad)) * innerR, y: center.y + CGFloat(sin(rad)) * innerR)
                let p2 = CGPoint(x: center.x + CGFloat(cos(rad)) * outerR, y: center.y + CGFloat(sin(rad)) * outerR)
                var tick = Path()
                tick.move(to: p1)
                tick.addLine(to: p2)
                context.stroke(
                    tick,
                    with: .color(.primary.opacity(isMajor ? 0.55 : 0.28)),
                    style: StrokeStyle(lineWidth: isMajor ? 1.4 : 0.9, lineCap: .round)
                )
            }

            // Needle
            let rad = needleDeg * .pi / 180.0
            let tip = CGPoint(
                x: center.x + CGFloat(cos(rad)) * (radius - 6),
                y: center.y + CGFloat(sin(rad)) * (radius - 6)
            )
            var needle = Path()
            needle.move(to: center)
            needle.addLine(to: tip)
            let needleWidth: CGFloat = 1.2 + CGFloat(clamped) * 0.9
            context.stroke(needle, with: .color(.primary), style: StrokeStyle(lineWidth: needleWidth, lineCap: .round))

            let hubRadius: CGFloat = 2.4 + CGFloat(clamped) * 1.0
            let hub = CGRect(x: center.x - hubRadius, y: center.y - hubRadius, width: hubRadius * 2, height: hubRadius * 2)
            context.fill(Path(ellipseIn: hub), with: .color(.primary))
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

struct LiquidGlassBlurBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.chatBackground) private var chatBackground
    var material: NSVisualEffectView.Material = .popover
    var blendingMode: NSVisualEffectView.BlendingMode = .withinWindow

    var body: some View {
        let isLight = AppTheme.isLightGlass(colorScheme: colorScheme, chatBackground: chatBackground)
        if isLight {
            Color(red: 0.96, green: 0.99, blue: 0.97, opacity: 0.12)
        } else {
            Color(red: 0.03, green: 0.05, blue: 0.07, opacity: 0.10)
        }
    }
}

/// Coordinate-aligned optical refraction of the active chat background (`UntiSlehd 8.png`, `UntiSDDtlehd 8.png`, & `chat-bg-forest-light.png`),
/// blurring and refracting the `"M"` background directly behind the composer's top input pill, companion subcontainer, and floating cards.
struct LiquidGlassRefractedBackdrop: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.sessionPaneSize) private var sessionPaneSize
    @Environment(\.chatBackground) private var chatBackground

    var isDarkTopPill: Bool

    var body: some View {
        let isLight = AppTheme.isLightGlass(colorScheme: colorScheme, chatBackground: chatBackground)
        let effectiveStyle = chatBackground.resolved(for: colorScheme)
        GeometryReader { proxy in
            let cardRect = proxy.frame(in: .named("picode-session-pane"))
            let hasValidPane = sessionPaneSize.width > 10 && sessionPaneSize.height > 10 && cardRect.width > 10
            let paneW = hasValidPane ? sessionPaneSize.width : max(cardRect.maxX + 160, 1147)
            let paneH = hasValidPane ? sessionPaneSize.height : max(cardRect.maxY + 160, 817)
            let fallbackX = -(paneW - max(proxy.size.width, 520)) * 0.5
            let fallbackY = -(paneH * 0.44 + (isDarkTopPill ? 0 : 72))
            let offsetX = (hasValidPane && abs(cardRect.minX) > 1) ? -cardRect.minX : fallbackX
            let offsetY = (hasValidPane && abs(cardRect.minY) > 1) ? -cardRect.minY : fallbackY

            if let preBlurred = AppTheme.blurredChatBackgroundImage(
                for: effectiveStyle,
                isLight: isLight,
                isDarkTopPill: isDarkTopPill
            ) {
                Image(nsImage: preBlurred)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: paneW, height: paneH, alignment: .center)
                    .clipped()
                    .offset(x: offsetX, y: offsetY)
            } else {
                MuseChatBackgroundView(style: chatBackground)
                    .frame(width: paneW, height: paneH)
                    .offset(x: offsetX, y: offsetY)
            }
        }
        .allowsHitTesting(false)
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

/// Circular Voice Orb wave badge icon (`Untitled 9.jpg` & `Computer Screen.jpg`) rendered at the
/// leading edge of the voice transcription row inside `liquidGlassControlCard`.
struct VoiceOrbBadgeIcon: View {
    var size: CGFloat = 19
    var isLightGlass: Bool = false

    var body: some View {
        let strokeCol = isLightGlass
            ? Color(red: 0.07, green: 0.19, blue: 0.11, opacity: 0.88)
            : Color.white.opacity(0.90)
        Canvas { context, canvasSize in
            let w = canvasSize.width
            let h = canvasSize.height
            let inset: CGFloat = 1.4
            let circleRect = CGRect(x: inset, y: inset, width: w - inset * 2, height: h - inset * 2)
            context.stroke(
                Path(ellipseIn: circleRect),
                with: .color(strokeCol),
                lineWidth: 1.45
            )

            // Smooth S-curve horizon wave across the circle equator matching `Untitled 9.jpg`
            var wave = Path()
            let midY = h * 0.52
            wave.move(to: CGPoint(x: inset + 0.5, y: midY + 1.2))
            wave.addCurve(
                to: CGPoint(x: w - inset - 0.5, y: midY - 0.8),
                control1: CGPoint(x: w * 0.36, y: midY - 3.6),
                control2: CGPoint(x: w * 0.66, y: midY + 3.6)
            )
            context.stroke(
                wave,
                with: .color(strokeCol),
                style: StrokeStyle(lineWidth: 1.45, lineCap: .round)
            )
        }
        .frame(width: size, height: size)
    }
}

struct LiquidGlassCardBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.chatBackground) private var chatBackground
    var cornerRadius: CGFloat
    var isDarkTopPill: Bool
    var isDropTargeted: Bool = false
    var sphereMix: Double = 0.0

    var body: some View {
        let isLight = AppTheme.isLightGlass(colorScheme: colorScheme, chatBackground: chatBackground)
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            LiquidGlassBlurBackground(
                material: .popover,
                blendingMode: .withinWindow
            )

            // Crystal-clear Liquid Glass refraction of the chat background (`UntiSlehd 8.png`, `UntiSDDtlehd 8.png`, & `chat-bg-forest-light.png`)
            LiquidGlassRefractedBackdrop(isDarkTopPill: isDarkTopPill)
                .opacity(isLight ? 0.58 : (isDarkTopPill ? (0.58 * (1.0 - sphereMix * 0.6)) : 0.60))

            if isLight {
                // Light Mode crystal-clear pearlescent white & botanical-sage Liquid Glass
                if isDarkTopPill {
                    LinearGradient(
                        stops: [
                            .init(color: Color.white.opacity(0.54), location: 0.0),
                            .init(color: Color(red: 0.96, green: 0.99, blue: 0.96, opacity: 0.40), location: 0.52),
                            .init(color: Color(red: 0.90, green: 0.97, blue: 0.91, opacity: 0.34), location: 1.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                } else {
                    LinearGradient(
                        stops: [
                            .init(color: Color.white.opacity(0.46), location: 0.0),
                            .init(color: Color(red: 0.95, green: 0.99, blue: 0.96, opacity: 0.35), location: 0.55),
                            .init(color: Color(red: 0.89, green: 0.97, blue: 0.91, opacity: 0.28), location: 1.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }

                // Luminous diagonal specular glass sheen
                LinearGradient(
                    stops: [
                        .init(color: Color.white.opacity(0.32), location: 0.0),
                        .init(color: Color.clear, location: 0.48),
                        .init(color: Color(red: 0.76, green: 0.96, blue: 0.68, opacity: 0.14), location: 1.0)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            } else if isDarkTopPill {
                // Clear smoked Liquid Glass top pill that lets the luminous green M ribbon refract visibly through
                LinearGradient(
                    stops: [
                        .init(color: Color(red: 0.02, green: 0.04, blue: 0.05, opacity: 0.44), location: 0.0),
                        .init(color: Color(red: 0.05, green: 0.09, blue: 0.11, opacity: 0.32), location: 0.52),
                        .init(color: Color(red: 0.11, green: 0.18, blue: 0.22, opacity: 0.22), location: 1.0)
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
                // Translucent Liquid Glass companion subcontainer & floating third panel (`InspectorView`) with rich smoked-glass contrast so white text is 100% legible over dark backgrounds
                LinearGradient(
                    stops: [
                        .init(color: Color(red: 0.05, green: 0.09, blue: 0.12, opacity: 0.48), location: 0.0),
                        .init(color: Color(red: 0.07, green: 0.12, blue: 0.16, opacity: 0.42), location: 0.55),
                        .init(color: Color(red: 0.09, green: 0.15, blue: 0.19, opacity: 0.36), location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                // Subtle diagonal specular glass sheen across the companion subcontainer
                LinearGradient(
                    stops: [
                        .init(color: Color.white.opacity(0.08), location: 0.0),
                        .init(color: Color.clear, location: 0.48),
                        .init(color: Color(red: 0.68, green: 0.92, blue: 0.84, opacity: 0.07), location: 1.0)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
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
                            colors: isLight
                                ? [
                                    Color.white.opacity(0.92),
                                    Color(red: 0.76, green: 0.94, blue: 0.80).opacity(0.62),
                                    Color.white.opacity(0.82)
                                ]
                                : (isDarkTopPill
                                    ? [
                                        Color.white.opacity(0.18 + 0.20 * sphereMix),
                                        Color(red: 0.78, green: 0.92, blue: 0.88).opacity(0.22 + 0.08 * sphereMix),
                                        Color(red: 0.82, green: 0.94, blue: 0.90).opacity(0.34 + 0.40 * sphereMix)
                                    ]
                                    : [
                                        Color(red: 0.85, green: 0.95, blue: 0.92).opacity(0.32),
                                        Color(red: 0.78, green: 0.90, blue: 0.88).opacity(0.20),
                                        Color(red: 0.82, green: 0.94, blue: 0.90).opacity(0.28)
                                    ]),
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    ),
                lineWidth: isDropTargeted ? 2.0 : (isLight ? 1.15 : (1.0 + 0.3 * sphereMix))
            )
        )
        .shadow(
            color: isLight
                ? Color(red: 0.08, green: 0.24, blue: 0.14).opacity(isDarkTopPill ? 0.14 : 0.11)
                : Color.black.opacity(isDarkTopPill ? 0.28 : 0.22),
            radius: isDarkTopPill ? 18 : 16,
            y: isDarkTopPill ? 8 : 7
        )
    }
}

/// Continuous 120fps timeline state for the Voice Orb Enter (`1028 (2).mp4` `F018`->`F046`) and Exit transitions.
struct VoiceOrbEnterMetrics: Equatable {
    var isActive: Bool
    var capsuleWidth: CGFloat
    var capsuleHeight: CGFloat
    var cornerRadius: CGFloat
    var editorOpacity: Double
    var micOpacity: Double
    var editorBlur: CGFloat
    var waveOpacity: Double
    var pillBottomWhiteGlow: Double
    var sphereMix: Double
    var darkBlinkMix: Double
    var subScaleX: CGFloat
    var subScaleY: CGFloat
    var subOffsetY: CGFloat
    var subBlur: CGFloat
    var subOpacity: Double

    private static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        guard edge1 > edge0 else { return x >= edge1 ? 1.0 : 0.0 }
        let t = max(0.0, min(1.0, (x - edge0) / (edge1 - edge0)))
        return t * t * (3.0 - 2.0 * t)
    }

    private static func lerp(_ a: Double, _ b: Double, _ t: Double) -> Double {
        a + (b - a) * t
    }

    private static func lerpCG(_ a: CGFloat, _ b: CGFloat, _ t: Double) -> CGFloat {
        a + (b - a) * CGFloat(t)
    }

    static func idle(fullWidth: CGFloat, baseHeight: CGFloat) -> VoiceOrbEnterMetrics {
        VoiceOrbEnterMetrics(
            isActive: false,
            capsuleWidth: fullWidth,
            capsuleHeight: baseHeight,
            cornerRadius: baseHeight * 0.5,
            editorOpacity: 1.0,
            micOpacity: 1.0,
            editorBlur: 0.0,
            waveOpacity: 0.0,
            pillBottomWhiteGlow: 0.0,
            sphereMix: 0.0,
            darkBlinkMix: 0.0,
            subScaleX: 1.0,
            subScaleY: 1.0,
            subOffsetY: 0.0,
            subBlur: 0.0,
            subOpacity: 1.0
        )
    }

    /// Evaluates the exact frame-by-frame Enter progression measured from `/Users/mac/Desktop/1028 (2)/1028 (2).mp4` (`F018` at `0.000s` through `F046` at `0.933s`):
    /// - `0.000s..0.067s` (`F019..F020`): Full-width S-curve plasma wave ignites inside the `100% -> 97.5%` pill while placeholder & mic remain visible and subcontainer is crisp (`alpha = 1.0 -> 0.966`).
    /// - `0.067s..0.167s` (`F021..F023`): Pill contracts to `83.9%` width, lower belly glows silver-white (`pillBottomWhiteGlow = 0.92`), placeholder fades to `0.18` with slight motion blur, mic fades out, subcontainer blurs (`11pt`) & drops to `alpha = 0.80`.
    /// - `0.167s..0.267s` (`F024..F026`): Pill contracts to `68.7%` width, lower belly white glow peaks (`0.96`), placeholder reaches `0.0`, subcontainer blurs (`20pt`) & drops to `alpha = 0.64`.
    /// - `0.267s..0.333s` (`F027..F028`): Rapid horizontal squeeze into the plump stadium capsule (`28.3% -> 24.0%`, i.e., `1.64x -> 1.40x` orb diameter) while the subcontainer finishes dissolving (`alpha -> 0.0`).
    /// - `0.333s..0.420s` (`F029..F030`): Compact rounded stadium capsule (`22.8%`, `1.32x` orb diameter) rounding smoothly into the `1:1` 3D Liquid Glass sphere (`88x88pt`).
    /// - `0.420s..0.830s` (`F031..F043`): Settled `1:1` 3D sphere (`88x88pt`) with gently undulating equator wave & translucent frosted lower hemisphere.
    /// - `0.830s..0.905s` (`F044`): Single-frame dark obsidian pulse/blink (`scale = 1.055x`, `waveOpacity -> 0.0`, pure obsidian upper 65% + unlit frosted grey lower 35% crescent).
    /// - `0.905s+` (`F045+`): Active listening loop with undulating equator wave & live `mic interactivity`.
    static func evaluateEnter(
        elapsed t: TimeInterval,
        fullWidth: CGFloat,
        baseHeight: CGFloat,
        orbFrame: Int
    ) -> VoiceOrbEnterMetrics {
        let orbDiameter: CGFloat = orbFrame >= 20 ? 86 : (orbFrame == 19 ? 88 : 88)

        // 1. Capsule Width (`fullWidth` -> `0.975` -> `0.839` -> `0.687` -> `1.64*D` -> `1.32*D` -> `1.00*D`)
        let w0 = fullWidth
        let w1 = fullWidth * 0.975
        let w2 = fullWidth * 0.839
        let w3 = fullWidth * 0.687
        let w4 = orbDiameter * 1.64 // F027 (431/262 = 1.645)
        let w5 = orbDiameter * 1.32 // F029-F030 (347/262 = 1.324)
        let w6 = orbDiameter        // F031+ (1:1 circle)

        var width: CGFloat
        if t < 0.067 {
            width = lerpCG(w0, w1, smoothstep(0.000, 0.067, t))
        } else if t < 0.105 {
            width = lerpCG(w1, w2, smoothstep(0.067, 0.105, t))
        } else if t < 0.167 {
            width = lerpCG(w2, w2 * 0.995, smoothstep(0.105, 0.167, t))
        } else if t < 0.205 {
            width = lerpCG(w2 * 0.995, w3, smoothstep(0.167, 0.205, t))
        } else if t < 0.267 {
            width = lerpCG(w3, w3 * 0.99, smoothstep(0.205, 0.267, t))
        } else if t < 0.305 {
            width = lerpCG(w3 * 0.99, w4, smoothstep(0.267, 0.305, t))
        } else if t < 0.395 {
            width = lerpCG(w4, w5, smoothstep(0.305, 0.395, t))
        } else if t < 0.435 {
            width = lerpCG(w5, w6, smoothstep(0.395, 0.435, t))
        } else {
            width = w6
        }

        // 2. Capsule Height (`baseHeight` -> `orbDiameter`, growing downward from fixed `.top` anchor)
        var height: CGFloat
        if t < 0.067 {
            height = lerpCG(baseHeight, baseHeight + 2, smoothstep(0.000, 0.067, t))
        } else if t < 0.267 {
            height = lerpCG(baseHeight + 2, baseHeight + 14, smoothstep(0.067, 0.267, t))
        } else if t < 0.335 {
            height = lerpCG(baseHeight + 14, orbDiameter - 4, smoothstep(0.267, 0.335, t))
        } else if t < 0.435 {
            height = lerpCG(orbDiameter - 4, orbDiameter, smoothstep(0.335, 0.435, t))
        } else {
            height = orbDiameter
        }

        // 3. Signature Dark Obsidian Blink (`F044` at `t = 0.830s..0.905s`, peaking at `t = 0.867s`)
        let blinkRise = smoothstep(0.830, 0.867, t)
        let blinkFall = 1.0 - smoothstep(0.867, 0.905, t)
        let darkBlinkMix = (t >= 0.830 && t <= 0.905 && orbFrame < 19) ? (blinkRise * blinkFall) : 0.0
        if darkBlinkMix > 0.001 {
            let scaleBump = 1.0 + 0.055 * CGFloat(darkBlinkMix)
            width *= scaleBump
            height *= scaleBump
        }

        // 4. Placeholder Text & Mic Button Opacity + Motion Blur (`F018`..`F024`)
        let editorOpacity: Double
        if t < 0.067 {
            editorOpacity = lerp(1.0, 0.86, smoothstep(0.000, 0.067, t))
        } else if t < 0.135 {
            editorOpacity = lerp(0.86, 0.22, smoothstep(0.067, 0.135, t))
        } else if t < 0.205 {
            editorOpacity = lerp(0.22, 0.0, smoothstep(0.135, 0.205, t))
        } else {
            editorOpacity = 0.0
        }
        let micOpacity = max(0.0, 1.0 - smoothstep(0.030, 0.115, t))
        let editorBlur = lerpCG(0.0, 6.0, smoothstep(0.050, 0.205, t))

        // 5. Wave Opacity, Lower-Belly White-Silver Pill Glow (`F020`..`F026`), and 3D Sphere Glass Mix
        let ignitionWave = smoothstep(0.005, 0.065, t)
        let waveOpacity = ignitionWave * (1.0 - 0.96 * darkBlinkMix)

        let glowIn = smoothstep(0.025, 0.110, t)
        let glowOut = 1.0 - smoothstep(0.255, 0.345, t)
        let pillBottomWhiteGlow = glowIn * glowOut * 0.95

        let sphereMix: Double
        if t < 0.267 {
            sphereMix = lerp(0.0, 0.42, smoothstep(0.030, 0.267, t))
        } else {
            sphereMix = lerp(0.42, 1.0, smoothstep(0.267, 0.415, t))
        }

        // 6. Subcontainer (`liquidGlassControlCard`) Scale, Blur & Opacity (`F018`..`F027`)
        let subOpacity: Double
        if t < 0.067 {
            subOpacity = lerp(1.0, 0.966, smoothstep(0.000, 0.067, t))
        } else if t < 0.135 {
            subOpacity = lerp(0.966, 0.80, smoothstep(0.067, 0.135, t))
        } else if t < 0.265 {
            subOpacity = lerp(0.80, 0.64, smoothstep(0.135, 0.265, t))
        } else if t < 0.305 {
            subOpacity = lerp(0.64, 0.0, smoothstep(0.265, 0.305, t))
        } else {
            subOpacity = 0.0
        }

        let subBlur: CGFloat
        if t < 0.067 {
            subBlur = lerpCG(0.0, 1.5, smoothstep(0.000, 0.067, t))
        } else if t < 0.135 {
            subBlur = lerpCG(1.5, 11.0, smoothstep(0.067, 0.135, t))
        } else if t < 0.265 {
            subBlur = lerpCG(11.0, 20.0, smoothstep(0.135, 0.265, t))
        } else {
            subBlur = lerpCG(20.0, 30.0, smoothstep(0.265, 0.305, t))
        }

        let subScaleX = lerpCG(1.0, 0.94, smoothstep(0.067, 0.305, t))
        let subScaleY = lerpCG(1.0, 0.90, smoothstep(0.067, 0.305, t))
        let subOffsetY = lerpCG(0.0, -6.0, smoothstep(0.067, 0.305, t))

        return VoiceOrbEnterMetrics(
            isActive: true,
            capsuleWidth: width,
            capsuleHeight: height,
            cornerRadius: height * 0.5,
            editorOpacity: editorOpacity,
            micOpacity: micOpacity,
            editorBlur: editorBlur,
            waveOpacity: waveOpacity,
            pillBottomWhiteGlow: pillBottomWhiteGlow,
            sphereMix: sphereMix,
            darkBlinkMix: darkBlinkMix,
            subScaleX: subScaleX,
            subScaleY: subScaleY,
            subOffsetY: subOffsetY,
            subBlur: subBlur,
            subOpacity: subOpacity
        )
    }

    static func evaluateExit(
        elapsed t: TimeInterval,
        fullWidth: CGFloat,
        baseHeight: CGFloat,
        orbFrame: Int
    ) -> VoiceOrbEnterMetrics {
        // Reverse progression over 0.36s back to the full composer panel
        let reverseElapsed = max(0.0, 0.435 * (1.0 - smoothstep(0.0, 0.36, t)))
        return evaluateEnter(
            elapsed: reverseElapsed,
            fullWidth: fullWidth,
            baseHeight: baseHeight,
            orbFrame: min(orbFrame, 7)
        )
    }

    static func fromStaticDescriptor(
        _ desc: VoiceOrbFrameDescriptor,
        fullWidth: CGFloat,
        baseHeight: CGFloat
    ) -> VoiceOrbEnterMetrics {
        let elapsedForFrame: TimeInterval
        switch desc.frameIndex {
        case 1: return idle(fullWidth: fullWidth, baseHeight: baseHeight)
        case 2: elapsedForFrame = 0.060
        case 3: elapsedForFrame = 0.133
        case 4: elapsedForFrame = 0.220
        case 5: elapsedForFrame = 0.300
        case 6: elapsedForFrame = 0.366
        case 7: elapsedForFrame = 0.550
        case 8: elapsedForFrame = 0.867
        default: elapsedForFrame = 1.000
        }
        return evaluateEnter(
            elapsed: elapsedForFrame,
            fullWidth: fullWidth,
            baseHeight: baseHeight,
            orbFrame: desc.frameIndex
        )
    }
}

/// Unified morphing Liquid Glass capsule & 3D sphere surface rendered during the Voice Orb Enter/Active/Exit states (`1028 (2).mp4` & `1028 (2)(3).mp4`).
struct MorphingVoiceOrbCapsuleView: View {
    var metrics: VoiceOrbEnterMetrics
    var orbFrame: Int
    var isRecording: Bool
    var isTranscribing: Bool
    var audioLevel: Double
    var duration: TimeInterval
    var previewText: String = "Ask Anything"
    var fixedTimeOverride: TimeInterval? = nil
    var onTap: () -> Void

    @State private var hoverEnergy: Double = 0.0
    @State private var hoverPoint: CGPoint? = nil

    var body: some View {
        let w = metrics.capsuleWidth
        let h = metrics.capsuleHeight
        let cornerRadius = metrics.cornerRadius
        let sphereMix = metrics.sphereMix
        let blinkMix = metrics.darkBlinkMix
        let bottomWhiteGlow = metrics.pillBottomWhiteGlow
        let effectiveAudio = min(1.0, max(audioLevel, hoverEnergy * 0.45))
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let isCircularStage = (w / max(h, 1)) < 1.38

        ZStack {
            // Soft downward ambient drop shadow cast onto the background below the capsule/sphere (`1028 (2)(3).mp4` & `23.23.35.mov`)
            Ellipse()
                .fill(
                    RadialGradient(
                        stops: [
                            .init(color: Color.black.opacity(0.32 * sphereMix), location: 0.0),
                            .init(color: Color.black.opacity(0.16 * sphereMix), location: 0.52),
                            .init(color: Color.black.opacity(0.04 * sphereMix), location: 0.82),
                            .init(color: Color.clear, location: 1.0)
                        ],
                        center: .center,
                        startRadius: 6,
                        endRadius: max(24, w * 0.58)
                    )
                )
                .frame(width: w * 1.18, height: h * 0.76)
                .offset(y: 12 * CGFloat(sphereMix))
                .blur(radius: 6)

            ZStack {
                // Upper hemisphere blur material
                LiquidGlassBlurBackground(
                    material: .popover,
                    blendingMode: .withinWindow
                )
                .mask(
                    LinearGradient(
                        stops: [
                            .init(color: .black, location: 0.0),
                            .init(color: .black, location: 0.48 + 0.52 * (1.0 - sphereMix)),
                            .init(color: .black.opacity(1.0 - sphereMix * 0.85), location: 0.62 + 0.38 * (1.0 - sphereMix)),
                            .init(color: .black.opacity(1.0 - sphereMix * 0.85), location: 1.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )

                // Partially translucent Liquid Glass refraction of the chat background behind the top pill / orb
                LiquidGlassRefractedBackdrop(isDarkTopPill: true)
                    .opacity(0.66 * (1.0 - sphereMix * 0.55))

                // Deep velvety obsidian-charcoal top hemisphere grading smoothly into a translucent smoky-slate lower glass bowl
                // (`UntiSlehd 8.png`, `UntiSDDtlehd 8.png`, & `1028 (2)(3).mp4` F0065..F0732 — zero artificial interior bottom oval ring!)
                LinearGradient(
                    stops: [
                        .init(color: Color(red: 0.02 + 0.05 * sphereMix, green: 0.02 + 0.05 * sphereMix, blue: 0.03 + 0.06 * sphereMix, opacity: 0.78 + 0.20 * sphereMix), location: 0.0),
                        .init(color: Color(red: 0.03, green: 0.04, blue: 0.06, opacity: 0.62 + 0.36 * sphereMix), location: 0.42 + 0.14 * blinkMix),
                        .init(color: Color(red: 0.05, green: 0.07, blue: 0.10, opacity: 0.52 + 0.42 * sphereMix), location: 0.56 + 0.10 * blinkMix),
                        .init(color: Color(red: 0.09, green: 0.13, blue: 0.18, opacity: 0.42 + 0.36 * sphereMix), location: 0.76),
                        .init(color: Color(red: 0.14, green: 0.18, blue: 0.23, opacity: 0.36 + 0.36 * sphereMix), location: 0.92),
                        .init(color: Color(red: 0.18, green: 0.22, blue: 0.28, opacity: 0.34 + 0.36 * sphereMix), location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                // Contracting pill bottom silver-white illumination (`F020..F026` in `1028 (2).mp4`)
                if bottomWhiteGlow > 0.005 {
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.0),
                            .init(color: .clear, location: 0.46),
                            .init(color: Color.white.opacity(0.36 * bottomWhiteGlow), location: 0.72),
                            .init(color: Color.white.opacity(0.80 * bottomWhiteGlow), location: 0.92),
                            .init(color: Color.white.opacity(0.92 * bottomWhiteGlow), location: 1.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                }

                // Chromatic S-curve optical prism wave + 2D cursor interactivity + voice lens aperture + 3D bokeh constellation
                PlasmaHorizonWaveCanvas(
                    isCircularOrb: isCircularStage,
                    orbFrame: orbFrame,
                    audioLevel: effectiveAudio,
                    waveOpacity: metrics.waveOpacity,
                    hoverPoint: hoverPoint,
                    fixedTimeOverride: fixedTimeOverride
                )

                // Lightweight pure-SwiftUI placeholder/text & mic dissolve during Frames 2..4 (`F019..F024` in `1028 (2).mp4`)
                if metrics.editorOpacity > 0.01 {
                    HStack(alignment: .center, spacing: 10) {
                        Text(previewText.isEmpty ? "Ask Anything" : previewText)
                            .font(.system(size: ComposerTextView.fontSize))
                            .foregroundStyle(Color.white.opacity(0.60))
                            .lineLimit(1)
                            .opacity(metrics.editorOpacity)
                            .blur(radius: metrics.editorBlur)

                        Spacer(minLength: 8)

                        HugeIcon(name: "mic-01", size: 20)
                            .foregroundStyle(Color.white.opacity(0.82))
                            .frame(width: 32, height: 32)
                            .opacity(metrics.micOpacity)
                            .blur(radius: metrics.editorBlur)
                    }
                    .padding(.leading, 26)
                    .padding(.trailing, 20)
                    .allowsHitTesting(false)
                }
            }
            .frame(width: w, height: h)
            .clipShape(shape)
            .overlay(
                // Single continuous outer 3D glass rim (`1028 (2)(3).mp4` F0065..F0732):
                // Warm bronze-pearl top edge -> smoked flanks -> crisp silver-white bottom rim
                shape
                    .strokeBorder(
                        LinearGradient(
                            stops: [
                                .init(
                                    color: (hoverPoint.map { $0.y < 0.35 } == true)
                                        ? Color(red: 0.62, green: 0.86, blue: 1.0, opacity: 0.56)
                                        : Color(red: 0.88, green: 0.72, blue: 0.58, opacity: 0.24 + 0.10 * sphereMix),
                                    location: 0.0
                                ),
                                .init(color: Color(red: 0.74, green: 0.78, blue: 0.86, opacity: 0.22 + 0.08 * sphereMix), location: 0.48),
                                .init(color: Color(red: 0.92, green: 0.95, blue: 1.0, opacity: 0.42 + 0.26 * max(sphereMix, bottomWhiteGlow)), location: 1.0)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1.3
                    )
            )
            .shadow(color: Color.black.opacity(0.28 - 0.08 * sphereMix), radius: 14, x: 0, y: 7)
        }
        .contentShape(shape)
        .onTapGesture {
            onTap()
        }
        .onContinuousHover { phase in
            guard isCircularStage else { return }
            switch phase {
            case .active(let location):
                let nx = max(0.0, min(1.0, location.x / max(w, 1)))
                let ny = max(0.0, min(1.0, location.y / max(h, 1)))
                let center = CGPoint(x: w * 0.50, y: h * 0.50)
                let dist = hypot(location.x - center.x, location.y - center.y)
                let norm = max(0.0, min(1.0, 1.0 - Double(dist) / Double(max(w, 1) * 0.55)))
                withAnimation(.interactiveSpring(response: 0.18, dampingFraction: 0.82)) {
                    hoverPoint = CGPoint(x: nx, y: ny)
                    hoverEnergy = 0.20 + 0.45 * norm
                }
            case .ended:
                withAnimation(.easeOut(duration: 0.28)) {
                    hoverPoint = nil
                    hoverEnergy = 0.0
                }
            }
        }
    }
}

/// The 3D Liquid Glass Sphere / Voice Orb that the top input pill morphs into
/// when the microphone button is clicked (`1028 (2)(3).mp4` & `1028 (2)(3).gif`, Frames 6–23).
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
    @State private var hoverPoint: CGPoint? = nil

    var body: some View {
        let orbWidth = descriptor.pillFixedWidth ?? 90
        let orbHeight = descriptor.pillHeight ?? 90
        let cornerRadius = descriptor.pillCornerRadius
        let effectiveAudio = min(1.0, max(audioLevel, hoverEnergy * 0.45))
        let orbShape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        Button(action: onTap) {
            ZStack {
                // Soft downward ambient drop shadow cast onto the background below the sphere
                Ellipse()
                    .fill(
                        RadialGradient(
                            stops: [
                                .init(color: Color.black.opacity(0.30), location: 0.0),
                                .init(color: Color.black.opacity(0.15), location: 0.52),
                                .init(color: Color.black.opacity(0.04), location: 0.82),
                                .init(color: Color.clear, location: 1.0)
                            ],
                            center: .center,
                            startRadius: 6,
                            endRadius: orbWidth * 0.58
                        )
                    )
                    .frame(width: orbWidth * 1.18, height: orbHeight * 0.74)
                    .offset(y: 12)
                    .blur(radius: 6)

                // Core 3D Liquid Glass Sphere (`1028 (2)(3).mp4` — smooth obsidian upper dome & smoky-slate lower glass bowl with zero artificial bottom oval loop)
                ZStack {
                    LiquidGlassBlurBackground(
                        material: .hudWindow,
                        blendingMode: .withinWindow
                    )
                    .mask(
                        LinearGradient(
                            stops: [
                                .init(color: .black, location: 0.0),
                                .init(color: .black, location: 0.48),
                                .init(color: .black.opacity(0.18), location: 0.65),
                                .init(color: .black.opacity(0.15), location: 1.0)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                    LinearGradient(
                        stops: [
                            .init(color: Color(red: 0.07, green: 0.07, blue: 0.09, opacity: 0.98), location: 0.0),
                            .init(color: Color(red: 0.03, green: 0.03, blue: 0.05, opacity: 0.98), location: 0.44),
                            .init(color: Color(red: 0.05, green: 0.06, blue: 0.09, opacity: 0.92), location: 0.56),
                            .init(color: Color(red: 0.11, green: 0.13, blue: 0.17, opacity: 0.76), location: 0.76),
                            .init(color: Color(red: 0.19, green: 0.21, blue: 0.26, opacity: 0.70), location: 0.92),
                            .init(color: Color(red: 0.26, green: 0.28, blue: 0.34, opacity: 0.68), location: 1.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )

                    // 60fps optical prism horizon wave + 2D cursor interactivity + voice lens aperture + 3D bokeh constellation
                    PlasmaHorizonWaveCanvas(
                        isCircularOrb: true,
                        orbFrame: orbFrame,
                        audioLevel: effectiveAudio,
                        waveOpacity: descriptor.waveOpacity,
                        hoverPoint: hoverPoint,
                        fixedTimeOverride: fixedTimeOverride
                    )
                }
                .frame(width: orbWidth, height: orbHeight)
                .clipShape(orbShape)
                .overlay(
                    orbShape
                        .strokeBorder(
                            LinearGradient(
                                stops: [
                                    .init(
                                        color: (hoverPoint.map { $0.y < 0.35 } == true)
                                            ? Color(red: 0.62, green: 0.86, blue: 1.0, opacity: 0.56)
                                            : Color(red: 0.88, green: 0.72, blue: 0.58, opacity: 0.32),
                                        location: 0.0
                                    ),
                                    .init(color: Color(red: 0.74, green: 0.78, blue: 0.86, opacity: 0.26), location: 0.48),
                                    .init(color: Color(red: 0.92, green: 0.95, blue: 1.0, opacity: 0.64), location: 1.0)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 1.3
                        )
                        .frame(width: orbWidth, height: orbHeight)
                )
                .shadow(color: Color.black.opacity(0.22), radius: 12, x: 0, y: 6)
            }
            .contentShape(orbShape)
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .onContinuousHover { phase in
            switch phase {
            case .active(let location):
                let nx = max(0.0, min(1.0, location.x / max(orbWidth, 1)))
                let ny = max(0.0, min(1.0, location.y / max(orbHeight, 1)))
                let center = CGPoint(x: orbWidth * 0.50, y: orbHeight * 0.50)
                let dist = hypot(location.x - center.x, location.y - center.y)
                let norm = max(0.0, min(1.0, 1.0 - Double(dist) / Double(max(orbWidth, 1) * 0.55)))
                withAnimation(.interactiveSpring(response: 0.18, dampingFraction: 0.82)) {
                    hoverPoint = CGPoint(x: nx, y: ny)
                    hoverEnergy = 0.20 + 0.45 * norm
                }
            case .ended:
                withAnimation(.easeOut(duration: 0.28)) {
                    hoverPoint = nil
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

/// 60fps animated optical-prism horizon wave rendered across the full-width/contracting pill (Frames 2–5),
/// across the equator of the 3D Liquid Glass Voice Orb with 2D cursor hover & voice lens reactivity (Frames 6–18),
/// and through the Frame 19–23 almond-lens -> glowing-sun -> single-dot -> 3D bokeh constellation states (`1028 (2)(3).mp4` & `.gif`).
struct PlasmaHorizonWaveCanvas: View {
    var isCircularOrb: Bool
    var orbFrame: Int = 9
    var audioLevel: Double = 0.0
    var waveOpacity: Double = 1.0
    /// Normalized `(0...1, 0...1)` cursor position inside the Orb when hovered (`1028 (2)(3).mp4` F0065..F0215 & F0695..F0732).
    var hoverPoint: CGPoint? = nil
    /// Optional fixed timestamp for deterministic snapshot verification of the `mic interactivity` states.
    var fixedTimeOverride: TimeInterval? = nil

    @ViewBuilder
    var body: some View {
        if let fixedTimeOverride {
            renderCanvas(at: fixedTimeOverride)
        } else {
            TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
                renderCanvas(at: timeline.date.timeIntervalSinceReferenceDate)
            }
        }
    }

    private func renderCanvas(at t: TimeInterval) -> some View {
        Canvas { context, size in
            let width = size.width
            let height = size.height
            let center = CGPoint(x: width * 0.5, y: height * 0.5)

            if orbFrame == 19 {
                // Frame 19: Wave contracts horizontally toward the center into a bright white almond lens with warm-amber upper & cyan lower fringes
                drawFrame19AlmondLens(context: context, size: size, center: center, t: t)
            } else if orbFrame == 20 {
                // Frame 20: Central almond lens rounds into a circular glowing white sun in the center of the sphere
                drawFrame20GlowingSun(context: context, center: center, t: t)
            } else if orbFrame == 21 {
                // Frame 21: Condenses into a single crisp solid white dot centered inside the sphere
                drawFrame21SingleCenterDot(context: context, center: center)
            } else if orbFrame >= 22 {
                // Frames 22–23: 3D perspective-projected volumetric bokeh constellation rotating inside the sphere (`1028 (2)(3).mp4` F1317..F1805)
                drawFrames22And23Constellation(context: context, center: center, t: t, orbFrame: orbFrame)
            } else {
                // Frames 2–18: Soft optical-prism horizon wave + 2D cursor hover tracking + voice lens & swirl reactivity (`1028 (2)(3).mp4`)
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
        let steps = 40
        let micBoost = isCircularOrb ? micEnergy : (micEnergy * 0.25)

        // Cursor hover attraction (`1028 (2)(3).mp4` F0065..F0215 & F0695..F0732):
        // When the cursor hovers over the orb, the bright white focal bulge and wave inflection
        // smoothly track the cursor's horizontal and vertical position.
        let hoverU = hoverPoint.map { Double(min(max($0.x, 0.12), 0.88)) }
        let hoverV = hoverPoint.map { Double(min(max($0.y, 0.12), 0.88)) }
        let idleFocalU = 0.50 + 0.15 * sin(t * 1.45)
        let focalU = hoverU ?? idleFocalU
        let cursorTilt = hoverU.map { ($0 - 0.50) * 0.34 } ?? (0.09 * cos(t * 1.35))
        let cursorPullY = hoverV.map { ($0 - 0.50) * Double(height) * 0.22 } ?? 0.0

        // High-energy full-sphere S-curve arch blend (`1028 (2)(3).mp4` F0350..F0460)
        let highArchMix = isCircularOrb ? max(0.0, min(1.0, (micBoost - 0.52) / 0.28)) : 0.0
        // Symmetric 3D volumetric voice lens & figure-8 expansion (`1028 (2)(3).mp4` F0266..F0585)
        let voiceLensMix = isCircularOrb ? max(0.0, min(1.0, (micBoost - 0.05) / 0.42)) : 0.0

        // 0. Atmospheric internal sphere hazes (`1028 (2)(3).mp4` F0065..F0215):
        //    - Upper hemisphere warm amber/bronze atmospheric glow above the wave
        //    - Lower hemisphere cool cerulean/cobalt-blue atmospheric glow + soft silver-white lower glass bowl reflection
        if isCircularOrb {
            var atmoCtx = context
            atmoCtx.opacity = effectiveOpacity * (0.76 + 0.24 * micBoost)
            atmoCtx.addFilter(.blur(radius: 13.0))

            let shiftX = CGFloat(focalU - 0.50) * width * 0.28
            let shiftY = CGFloat(cursorPullY * 0.45)

            // Upper warm bronze-amber atmospheric cloud
            let upperAmberRect = CGRect(
                x: width * 0.10 + shiftX * 0.6,
                y: height * 0.16 + shiftY - CGFloat(micBoost) * 6.0,
                width: width * 0.80,
                height: height * (0.34 + 0.10 * CGFloat(micBoost))
            )
            atmoCtx.fill(
                Path(ellipseIn: upperAmberRect),
                with: .color(Color(red: 0.96, green: 0.46, blue: 0.14, opacity: 0.38 + 0.24 * micBoost))
            )

            // Lower cool cerulean-blue atmospheric cloud
            let lowerBlueRect = CGRect(
                x: width * 0.10 - shiftX * 0.4,
                y: height * 0.44 + shiftY,
                width: width * 0.80,
                height: height * (0.36 + 0.12 * CGFloat(micBoost))
            )
            atmoCtx.fill(
                Path(ellipseIn: lowerBlueRect),
                with: .color(Color(red: 0.10, green: 0.56, blue: 0.98, opacity: 0.44 + 0.28 * micBoost))
            )

            // Soft diffused silver-white lower glass bowl illumination (no hard oval line!)
            let bowlGlowW: CGFloat = width * (0.64 + 0.18 * CGFloat(micBoost))
            let bowlGlowH: CGFloat = height * (0.30 + 0.12 * CGFloat(micBoost))
            let bowlGlowRect = CGRect(
                x: width * 0.5 - bowlGlowW * 0.5 + shiftX * 0.45,
                y: midY + 2.0 + shiftY * 0.5,
                width: bowlGlowW,
                height: bowlGlowH
            )
            atmoCtx.fill(
                Path(ellipseIn: bowlGlowRect),
                with: .color(Color(red: 0.86, green: 0.92, blue: 1.0, opacity: 0.30 + 0.28 * micBoost))
            )
        }

        // If in high/peak speech (`highArchMix > 0.01`), blend in the full-sphere S-curve plasma arches (`1028 (2)(3).mp4` F0350..F0460)
        if highArchMix > 0.01 {
            drawHighEnergyMicSwirl(
                context: context,
                size: size,
                t: t,
                opacity: effectiveOpacity * highArchMix,
                intensity: micBoost,
                focalU: focalU
            )
        }

        let baseWaveOpacity = effectiveOpacity * (1.0 - highArchMix * 0.86)
        guard baseWaveOpacity > 0.01 else { return }

        // In the wide pill (`F019..F026` of `1028 (2).mp4`), the S-curve plasma wave spans `u in [0.16, 0.89]`
        // and smoothly expands to `[0.0, 1.0]` as the capsule contracts into the 1:1 sphere.
        let aspect = Double(width / max(height, 1))
        let wideFactor = max(0.0, min(1.0, (aspect - 1.35) / 5.5))
        let uStart = 0.16 * wideFactor
        let uEnd = 1.0 - 0.11 * wideFactor
        let uSpan = max(0.1, uEnd - uStart)

        // Smooth optical-prism wave centerline (`1028 (2)(3).mp4` F0065..F0215 & F0695..F0732):
        // Gently undulates across the equator and tilts/curves toward the 2D cursor `(hoverU, hoverV)` when hovered.
        func waveCenterY(sNorm: Double, phaseShift: Double = 0.0, ampScale: Double = 1.0, sign: Double = 1.0) -> CGFloat {
            let s = max(0.0, min(1.0, sNorm + phaseShift))
            let edgeEnvelope = isCircularOrb
                ? pow(sin(s * .pi), 0.78)
                : pow(sin(s * .pi), 1.15)
            let speed = 2.5 + 1.6 * micBoost
            let gentleSCurve = -sin((s - 0.50 + cursorTilt) * .pi * 1.65 + sin(t * speed * 0.55) * 0.45) * 0.68
                + 0.22 * cos(s * .pi * 2.0 - t * speed)
            let voiceHarmonic = sin((s - focalU) * .pi * 2.2) * cos(t * 3.1 + phaseShift * 2.0)
            let combined = gentleSCurve * (1.0 - 0.45 * voiceLensMix) + (sign * voiceHarmonic * 1.15) * (0.45 * voiceLensMix)
            let baseAmp = (isCircularOrb ? (height * 0.055) : (height * 0.11)) + CGFloat(isCircularOrb ? 3.2 * voiceLensMix : 1.2 * micBoost)
            let pullEnvelope = exp(-pow((s - focalU) / 0.34, 2.0)) * edgeEnvelope
            return midY + CGFloat(cursorPullY * pullEnvelope) + CGFloat(combined * ampScale * edgeEnvelope) * baseAmp
        }

        // Builds a smooth ribbon or volumetric lens path whose focal bulge centers around `focalU`
        func buildPrismRibbonPath(
            phaseShift: Double,
            yOffset: CGFloat,
            baseThickness: CGFloat,
            focalBulge: CGFloat,
            focalSigma: Double = 0.24,
            ampScale: Double = 1.0,
            upperArchBoost: CGFloat = 0.0,
            lowerArchBoost: CGFloat = 0.0,
            sign: Double = 1.0
        ) -> Path {
            var path = Path()
            for i in 0...steps {
                let s = Double(i) / Double(steps)
                let u = uStart + s * uSpan
                let x = CGFloat(u) * width
                let edgeTaper = CGFloat(pow(sin(s * .pi), isCircularOrb ? 0.72 : 1.30))
                let focalWeight = CGFloat(exp(-pow((s - focalU) / focalSigma, 2.0))) * edgeTaper
                let centerArch = CGFloat(pow(sin(s * .pi), 1.65))
                let upperHalf = (baseThickness * edgeTaper + focalBulge * focalWeight) * 0.5 + upperArchBoost * centerArch
                let y = waveCenterY(sNorm: s, phaseShift: phaseShift, ampScale: ampScale, sign: sign) + yOffset - upperHalf
                if i == 0 {
                    path.move(to: CGPoint(x: x, y: y))
                } else {
                    path.addLine(to: CGPoint(x: x, y: y))
                }
            }
            for i in (0...steps).reversed() {
                let s = Double(i) / Double(steps)
                let u = uStart + s * uSpan
                let x = CGFloat(u) * width
                let edgeTaper = CGFloat(pow(sin(s * .pi), isCircularOrb ? 0.72 : 1.30))
                let focalWeight = CGFloat(exp(-pow((s - focalU) / focalSigma, 2.0))) * edgeTaper
                let centerArch = CGFloat(pow(sin(s * .pi), 1.65))
                let lowerHalf = (baseThickness * edgeTaper + focalBulge * focalWeight) * 0.5 + lowerArchBoost * centerArch
                let y = waveCenterY(sNorm: s, phaseShift: phaseShift, ampScale: ampScale, sign: sign) + yOffset + lowerHalf
                path.addLine(to: CGPoint(x: x, y: y))
            }
            path.closeSubpath()
            return path
        }

        // 1. Optical Prism Chromatic Fringes (`1028 (2)(3).mp4` F0065..F0215 & F0266..F0585):
        //    - UPPER fringe is Warm Coral-Orange / Golden-Amber (`yOffset < 0`)
        //    - LOWER fringe is Cool Cerulean-Blue / Electric Cyan (`yOffset > 0`)
        var prismCtx = context
        prismCtx.opacity = baseWaveOpacity
        prismCtx.addFilter(.blur(radius: isCircularOrb ? 5.2 : 5.6))

        let lensAperture = CGFloat(voiceLensMix) * (isCircularOrb ? 15.5 : 3.0)

        // 1A. Upper Warm Coral-Orange / Amber-Gold Prism Fringe (`yOffset: -4.2`)
        let upperAmberPath = buildPrismRibbonPath(
            phaseShift: -0.015,
            yOffset: isCircularOrb ? (-4.2 - lensAperture * 0.32) : -2.6,
            baseThickness: (isCircularOrb ? 8.5 : 10.5) + 3.5 * CGFloat(voiceLensMix),
            focalBulge: (isCircularOrb ? 7.5 : 4.5) + 6.0 * CGFloat(voiceLensMix),
            focalSigma: 0.28,
            ampScale: 0.92,
            upperArchBoost: lensAperture * 0.55,
            lowerArchBoost: 0.0,
            sign: 1.0
        )
        prismCtx.fill(
            upperAmberPath,
            with: .linearGradient(
                Gradient(stops: [
                    .init(color: Color(red: 0.98, green: 0.42, blue: 0.10, opacity: 0.92), location: 0.0),
                    .init(color: Color(red: 1.0, green: 0.62, blue: 0.16, opacity: 0.98), location: max(0.15, min(0.85, focalU))),
                    .init(color: Color(red: 0.96, green: 0.46, blue: 0.12, opacity: 0.92), location: 1.0)
                ]),
                startPoint: CGPoint(x: width * CGFloat(uStart), y: midY - 12),
                endPoint: CGPoint(x: width * CGFloat(uEnd), y: midY + 2)
            )
        )

        // 1B. Lower Cool Cerulean-Blue / Cyan Prism Fringe (`yOffset: +4.4`)
        let lowerCyanPath = buildPrismRibbonPath(
            phaseShift: 0.015,
            yOffset: isCircularOrb ? (4.4 + lensAperture * 0.32) : 2.8,
            baseThickness: (isCircularOrb ? 9.0 : 10.5) + 4.0 * CGFloat(voiceLensMix),
            focalBulge: (isCircularOrb ? 8.0 : 4.5) + 6.5 * CGFloat(voiceLensMix),
            focalSigma: 0.28,
            ampScale: 1.08,
            upperArchBoost: 0.0,
            lowerArchBoost: lensAperture * 0.55,
            sign: 1.0
        )
        prismCtx.fill(
            lowerCyanPath,
            with: .linearGradient(
                Gradient(stops: [
                    .init(color: Color(red: 0.06, green: 0.58, blue: 1.0, opacity: 0.94), location: 0.0),
                    .init(color: Color(red: 0.18, green: 0.88, blue: 1.0, opacity: 0.99), location: max(0.15, min(0.85, focalU))),
                    .init(color: Color(red: 0.08, green: 0.50, blue: 0.98, opacity: 0.94), location: 1.0)
                ]),
                startPoint: CGPoint(x: width * CGFloat(uStart), y: midY - 2),
                endPoint: CGPoint(x: width * CGFloat(uEnd), y: midY + 14)
            )
        )

        // 2. Voice-Reactive Secondary Chromatic Cross-Wave (`1028 (2)(3).mp4` F0266..F0585)
        //    When speaking, the wave splits into a 3D braided aperture with golden-peach & electric-cyan edge Rim threads
        if voiceLensMix > 0.02 {
            var braidCtx = context
            braidCtx.opacity = baseWaveOpacity * min(1.0, voiceLensMix * 1.25)
            braidCtx.addFilter(.blur(radius: 2.6))

            let upperArchThread = buildPrismRibbonPath(
                phaseShift: 0.01,
                yOffset: -2.0 - lensAperture * 0.22,
                baseThickness: 4.2 + 2.5 * CGFloat(voiceLensMix),
                focalBulge: 5.5 * CGFloat(voiceLensMix),
                focalSigma: 0.26,
                ampScale: 1.22,
                upperArchBoost: lensAperture * 0.42,
                lowerArchBoost: 0.0,
                sign: 1.0
            )
            braidCtx.fill(
                upperArchThread,
                with: .linearGradient(
                    Gradient(stops: [
                        .init(color: Color(red: 1.0, green: 0.44, blue: 0.12), location: 0.0),
                        .init(color: Color(red: 1.0, green: 0.82, blue: 0.32), location: 0.35),
                        .init(color: Color.white, location: 0.55),
                        .init(color: Color(red: 0.22, green: 0.92, blue: 1.0), location: 1.0)
                    ]),
                    startPoint: CGPoint(x: 0, y: midY - 8),
                    endPoint: CGPoint(x: width, y: midY + 4)
                )
            )

            let lowerArchThread = buildPrismRibbonPath(
                phaseShift: -0.01,
                yOffset: 2.0 + lensAperture * 0.22,
                baseThickness: 4.2 + 2.5 * CGFloat(voiceLensMix),
                focalBulge: 5.5 * CGFloat(voiceLensMix),
                focalSigma: 0.26,
                ampScale: 1.22,
                upperArchBoost: 0.0,
                lowerArchBoost: lensAperture * 0.42,
                sign: -1.0
            )
            braidCtx.fill(
                lowerArchThread,
                with: .linearGradient(
                    Gradient(stops: [
                        .init(color: Color(red: 0.08, green: 0.68, blue: 1.0), location: 0.0),
                        .init(color: Color(red: 0.26, green: 0.96, blue: 0.92), location: 0.40),
                        .init(color: Color.white, location: 0.60),
                        .init(color: Color(red: 1.0, green: 0.52, blue: 0.16), location: 1.0)
                    ]),
                    startPoint: CGPoint(x: 0, y: midY + 8),
                    endPoint: CGPoint(x: width, y: midY - 4)
                )
            )
        }

        // 3. Soft-Focus Volumetric Pearl-White Halo (`1028 (2)(3).mp4` F0065..F0215 & F0266..F0585):
        //    Creates the dreamy optical-blur transition between the blazing white core and the warm/cool fringes
        var softCoreCtx = context
        softCoreCtx.opacity = baseWaveOpacity * 0.92
        softCoreCtx.addFilter(.blur(radius: isCircularOrb ? 4.2 : 3.2))
        let softWhitePath = buildPrismRibbonPath(
            phaseShift: 0.0,
            yOffset: 0.0,
            baseThickness: (isCircularOrb ? 5.6 : 6.4) + 2.5 * CGFloat(voiceLensMix),
            focalBulge: isCircularOrb ? (9.5 + 14.0 * CGFloat(voiceLensMix)) : 5.0,
            focalSigma: 0.23 + 0.06 * voiceLensMix,
            ampScale: 1.0,
            upperArchBoost: lensAperture * 0.48,
            lowerArchBoost: lensAperture * 0.48,
            sign: 1.0
        )
        softCoreCtx.fill(softWhitePath, with: .color(Color.white.opacity(0.95)))

        // 4. Blazing Pearl-White Focal Lens Core (`1028 (2)(3).mp4` F0065..F0215 & F0695..F0732):
        //    Smoothly follows `focalU` (cursor hover X) and expands into a luminous 3D eye/almond lens on voice input
        var coreCtx = context
        coreCtx.opacity = baseWaveOpacity
        coreCtx.addFilter(.blur(radius: isCircularOrb ? 1.9 : 1.4))
        let corePath = buildPrismRibbonPath(
            phaseShift: 0.0,
            yOffset: 0.0,
            baseThickness: (isCircularOrb ? 3.2 : 4.6) + 1.8 * CGFloat(voiceLensMix),
            focalBulge: isCircularOrb ? (7.2 + 12.5 * CGFloat(voiceLensMix)) : 3.8,
            focalSigma: 0.20 + 0.05 * voiceLensMix,
            ampScale: 1.0,
            upperArchBoost: lensAperture * 0.36,
            lowerArchBoost: lensAperture * 0.36,
            sign: 1.0
        )
        coreCtx.fill(
            corePath,
            with: .color(Color.white.opacity(0.99))
        )
    }

    /// Renders the high-amplitude S-curve plasma arches during loud speech bursts (`1028 (2)(3).mp4` F0350..F0460):
    /// - Mode A (`polarity >= 0`): Deep obsidian upper-right pocket + fiery golden-orange upper-left S-arch + huge S-curved white center core + electric cyan lower-right ribbon.
    /// - Mode B (`polarity < 0`): Icy cyan-white upper-left arch + warm bronze upper-right pocket + vivid coral-orange lower-left ribbon + blazing white/cyan center + deep cobalt-royal blue lower-right glow.
    private func drawHighEnergyMicSwirl(
        context: GraphicsContext,
        size: CGSize,
        t: TimeInterval,
        opacity: Double,
        intensity: Double,
        focalU: Double
    ) {
        let width = size.width
        let height = size.height
        let steps = 36
        let polarity = sin(t * 2.4 + (focalU - 0.5) * 2.0)
        let orb3Weight = max(0.0, min(1.0, (polarity + 1.0) * 0.5))
        let orb4Weight = 1.0 - orb3Weight

        if orb3Weight > 0.01 {
            let w3 = opacity * orb3Weight
            func orb3Y(u: Double) -> CGFloat {
                let arch = -0.20 * sin(u * .pi * 1.42) + 0.07 * sin(u * .pi * 2.4)
                return height * CGFloat(0.48 + arch)
            }
            func buildOrb3Path(yOff: CGFloat, thick: CGFloat, bulge: CGFloat) -> Path {
                var p = Path()
                for i in 0...steps {
                    let u = Double(i) / Double(steps)
                    let x = CGFloat(u) * width
                    let b = bulge * CGFloat(pow(sin(u * .pi), 1.7))
                    let ht = (thick + b) * 0.5
                    let y = orb3Y(u: u) + yOff - ht
                    if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
                }
                for i in (0...steps).reversed() {
                    let u = Double(i) / Double(steps)
                    let x = CGFloat(u) * width
                    let b = bulge * CGFloat(pow(sin(u * .pi), 1.7))
                    let ht = (thick + b) * 0.5
                    let y = orb3Y(u: u) + yOff + ht
                    p.addLine(to: CGPoint(x: x, y: y))
                }
                p.closeSubpath()
                return p
            }

            // 1. Upper-left golden-amber inner dome rim glow
            var rim3Ctx = context
            rim3Ctx.opacity = w3
            rim3Ctx.addFilter(.blur(radius: 6.0))
            let rim3Rect = CGRect(x: width * 0.04, y: height * 0.04, width: width * 0.68, height: height * 0.58)
            rim3Ctx.stroke(
                Path(ellipseIn: rim3Rect),
                with: .linearGradient(
                    Gradient(colors: [
                        Color(red: 1.0, green: 0.62, blue: 0.10),
                        Color(red: 1.0, green: 0.82, blue: 0.24),
                        Color.clear
                    ]),
                    startPoint: CGPoint(x: width * 0.08, y: height * 0.08),
                    endPoint: CGPoint(x: width * 0.68, y: height * 0.45)
                ),
                lineWidth: 9.5
            )

            // 2. Fiery orange-red & golden-yellow upper S-curve band
            var orange3Ctx = context
            orange3Ctx.opacity = w3
            orange3Ctx.addFilter(.blur(radius: 4.5))
            let orange3Path = buildOrb3Path(yOff: -5.5, thick: 12.0, bulge: 18.0)
            orange3Ctx.fill(
                orange3Path,
                with: .linearGradient(
                    Gradient(stops: [
                        .init(color: Color(red: 1.0, green: 0.38, blue: 0.06), location: 0.0),
                        .init(color: Color(red: 1.0, green: 0.52, blue: 0.06), location: 0.35),
                        .init(color: Color(red: 1.0, green: 0.84, blue: 0.16), location: 0.65),
                        .init(color: Color(red: 0.12, green: 0.78, blue: 1.0), location: 0.88),
                        .init(color: Color(red: 0.08, green: 0.42, blue: 1.0), location: 1.0)
                    ]),
                    startPoint: CGPoint(x: 0, y: height * 0.22),
                    endPoint: CGPoint(x: width, y: height * 0.58)
                )
            )

            // 3. Lower-right electric cyan & cobalt blue edge ribbon
            var cyan3Ctx = context
            cyan3Ctx.opacity = w3
            cyan3Ctx.addFilter(.blur(radius: 4.2))
            let cyan3Path = buildOrb3Path(yOff: 5.0, thick: 9.5, bulge: 15.0)
            cyan3Ctx.fill(
                cyan3Path,
                with: .linearGradient(
                    Gradient(stops: [
                        .init(color: Color.clear, location: 0.0),
                        .init(color: Color(red: 1.0, green: 0.88, blue: 0.35, opacity: 0.6), location: 0.40),
                        .init(color: Color(red: 0.06, green: 0.86, blue: 1.0), location: 0.72),
                        .init(color: Color(red: 0.08, green: 0.40, blue: 1.0), location: 1.0)
                    ]),
                    startPoint: CGPoint(x: width * 0.25, y: height * 0.40),
                    endPoint: CGPoint(x: width, y: height * 0.68)
                )
            )

            // 4. Huge S-curved soft-focus pearl-white central plasma core
            var white3Ctx = context
            white3Ctx.opacity = w3
            white3Ctx.addFilter(.blur(radius: 2.6))
            let white3Path = buildOrb3Path(yOff: 0.8, thick: 7.5, bulge: 25.0)
            white3Ctx.fill(white3Path, with: .color(Color.white.opacity(0.99)))
        }

        if orb4Weight > 0.01 {
            let w4 = opacity * orb4Weight
            func orb4Y(u: Double) -> CGFloat {
                let arch = 0.15 * cos(u * .pi * 1.65) - 0.06 * sin(u * .pi * 1.2)
                return height * CGFloat(0.47 + arch)
            }
            func buildOrb4Path(yOff: CGFloat, thick: CGFloat, bulge: CGFloat) -> Path {
                var p = Path()
                for i in 0...steps {
                    let u = Double(i) / Double(steps)
                    let x = CGFloat(u) * width
                    let b = bulge * CGFloat(pow(sin(u * .pi), 1.7))
                    let ht = (thick + b) * 0.5
                    let y = orb4Y(u: u) + yOff - ht
                    if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
                }
                for i in (0...steps).reversed() {
                    let u = Double(i) / Double(steps)
                    let x = CGFloat(u) * width
                    let b = bulge * CGFloat(pow(sin(u * .pi), 1.7))
                    let ht = (thick + b) * 0.5
                    let y = orb4Y(u: u) + yOff + ht
                    p.addLine(to: CGPoint(x: x, y: y))
                }
                p.closeSubpath()
                return p
            }

            // 1. Upper-left icy electric cyan-white dome arch
            var cyanRim4Ctx = context
            cyanRim4Ctx.opacity = w4
            cyanRim4Ctx.addFilter(.blur(radius: 6.0))
            let cyanRim4Rect = CGRect(x: width * 0.04, y: height * 0.04, width: width * 0.66, height: height * 0.56)
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

            // 2. Lower-right royal cobalt blue inner sphere wash
            var cobalt4Ctx = context
            cobalt4Ctx.opacity = w4
            cobalt4Ctx.addFilter(.blur(radius: 8.5))
            let cobalt4Rect = CGRect(x: width * 0.28, y: height * 0.42, width: width * 0.60, height: height * 0.38)
            cobalt4Ctx.fill(
                Path(ellipseIn: cobalt4Rect),
                with: .color(Color(red: 0.08, green: 0.40, blue: 1.0, opacity: 0.92))
            )

            // 3. Chromatic S-curve ribbon: Warm Coral-Orange on lower-left -> Blazing Cyan-White center -> Golden-Amber upper-right
            var swirl4Ctx = context
            swirl4Ctx.opacity = w4
            swirl4Ctx.addFilter(.blur(radius: 4.2))
            let swirl4Path = buildOrb4Path(yOff: 0, thick: 12.0, bulge: 18.0)
            swirl4Ctx.fill(
                swirl4Path,
                with: .linearGradient(
                    Gradient(stops: [
                        .init(color: Color(red: 1.0, green: 0.32, blue: 0.12), location: 0.0),
                        .init(color: Color(red: 1.0, green: 0.56, blue: 0.24), location: 0.24),
                        .init(color: Color(red: 0.14, green: 0.90, blue: 1.0), location: 0.54),
                        .init(color: Color(red: 1.0, green: 0.76, blue: 0.22), location: 0.82),
                        .init(color: Color(red: 0.16, green: 0.68, blue: 1.0), location: 1.0)
                    ]),
                    startPoint: CGPoint(x: 0, y: height * 0.60),
                    endPoint: CGPoint(x: width, y: height * 0.34)
                )
            )

            // 4. Blazing white S-curved central plasma core
            var white4Ctx = context
            white4Ctx.opacity = w4
            white4Ctx.addFilter(.blur(radius: 2.6))
            let white4Path = buildOrb4Path(yOff: -1.2, thick: 7.2, bulge: 24.0)
            white4Ctx.fill(white4Path, with: .color(Color.white.opacity(0.99)))
        }
    }

    private func drawFrame19AlmondLens(
        context: GraphicsContext,
        size: CGSize,
        center: CGPoint,
        t: TimeInterval
    ) {
        // Warm amber-orange upper halo around the contracting almond lens (`1028 (2)(3).mp4` F1269)
        var amberCtx = context
        amberCtx.addFilter(.blur(radius: 8.5))
        let amberRect = CGRect(x: center.x - 30, y: center.y - 14, width: 60, height: 20)
        amberCtx.fill(
            Path(ellipseIn: amberRect),
            with: .color(Color(red: 1.0, green: 0.56, blue: 0.16, opacity: 0.88))
        )

        // Cool cerulean-cyan lower halo
        var cyanCtx = context
        cyanCtx.addFilter(.blur(radius: 9.0))
        let cyanRect = CGRect(x: center.x - 28, y: center.y - 4, width: 56, height: 22)
        cyanCtx.fill(
            Path(ellipseIn: cyanRect),
            with: .color(Color(red: 0.14, green: 0.72, blue: 1.0, opacity: 0.90))
        )

        // Bright white central almond / eye lens (`1028 (2)(3).mp4` F1269)
        var almondPath = Path()
        let halfW: CGFloat = 25.0
        let halfH: CGFloat = 11.5
        almondPath.move(to: CGPoint(x: center.x - halfW, y: center.y + 1))
        almondPath.addQuadCurve(
            to: CGPoint(x: center.x + halfW, y: center.y - 1),
            control: CGPoint(x: center.x, y: center.y - halfH * 1.45)
        )
        almondPath.addQuadCurve(
            to: CGPoint(x: center.x - halfW, y: center.y + 1),
            control: CGPoint(x: center.x, y: center.y + halfH * 1.45)
        )
        almondPath.closeSubpath()

        var coreCtx = context
        coreCtx.addFilter(.blur(radius: 2.6))
        coreCtx.fill(almondPath, with: .color(Color.white.opacity(0.98)))
    }

    private func drawFrame20GlowingSun(
        context: GraphicsContext,
        center: CGPoint,
        t: TimeInterval
    ) {
        // Soft outer white/silver radial bloom (`1028 (2)(3).mp4` F1285)
        var outerBloomCtx = context
        outerBloomCtx.addFilter(.blur(radius: 9.0))
        let outerRect = CGRect(x: center.x - 22, y: center.y - 22, width: 44, height: 44)
        outerBloomCtx.fill(
            Path(ellipseIn: outerRect),
            with: .color(Color.white.opacity(0.68))
        )

        // Bright circular glowing white sun core
        var innerCoreCtx = context
        innerCoreCtx.addFilter(.blur(radius: 2.4))
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
        // Soft halo around the single center dot (`1028 (2)(3).mp4` F1301)
        var haloCtx = context
        haloCtx.addFilter(.blur(radius: 3.5))
        let haloRect = CGRect(x: center.x - 6.5, y: center.y - 6.5, width: 13.0, height: 13.0)
        haloCtx.fill(
            Path(ellipseIn: haloRect),
            with: .color(Color.white.opacity(0.48))
        )

        // Crisp solid white center dot
        let dotRect = CGRect(x: center.x - 4.4, y: center.y - 4.4, width: 8.8, height: 8.8)
        context.fill(
            Path(ellipseIn: dotRect),
            with: .color(Color.white.opacity(0.98))
        )
    }

    /// Renders the 3D perspective-projected volumetric bokeh constellation (`1028 (2)(3).mp4` F1317..F1805):
    /// 6 luminous white spheres distributed in 3D space inside the glass orb, rotating smoothly in 3D `(yaw, pitch, roll)`
    /// so foreground spheres pass large (`~13.5–15.8pt`) and bright with soft bokeh halos while background spheres
    /// recede (`~5.2–6.8pt`) on the far side of the sphere.
    private func drawFrames22And23Constellation(
        context: GraphicsContext,
        center: CGPoint,
        t: TimeInterval,
        orbFrame: Int
    ) {
        let baseNodes: [(x: Double, y: Double, z: Double)] = [
            ( 0.34,  0.64,  0.68),
            (-0.44,  0.58,  0.68),
            ( 0.88,  0.14,  0.18),
            ( 0.62, -0.52, -0.22),
            (-0.56, -0.58, -0.58),
            (-0.82,  0.04, -0.56)
        ]

        let spin = (orbFrame >= 23) ? t : 0.0
        let yaw = spin * 1.45
        let pitch = 0.24 * sin(spin * 0.92)
        let roll = 0.16 * cos(spin * 0.68)

        let cosY = cos(yaw), sinY = sin(yaw)
        let cosP = cos(pitch), sinP = sin(pitch)
        let cosR = cos(roll), sinR = sin(roll)

        struct ProjectedDot {
            let x: CGFloat
            let y: CGFloat
            let z: Double
            let diameter: CGFloat
            let stretch: CGFloat
            let tiltRad: Double
            let opacity: Double
        }

        let orbitRadius: Double = 22.8
        var projected: [ProjectedDot] = []
        projected.reserveCapacity(baseNodes.count)

        for node in baseNodes {
            // 1. Rotate around Y axis (yaw)
            let x1 = node.x * cosY + node.z * sinY
            let y1 = node.y
            let z1 = -node.x * sinY + node.z * cosY

            // 2. Rotate around X axis (pitch)
            let x2 = x1
            let y2 = y1 * cosP - z1 * sinP
            let z2 = y1 * sinP + z1 * cosP

            // 3. Rotate around Z axis (roll)
            let x3 = x2 * cosR - y2 * sinR
            let y3 = x2 * sinR + y2 * cosR
            let z3 = z2

            // Perspective projection (`z3` in `[-1, +1]`, where `+1` is closest to viewer)
            let depthNorm = max(0.0, min(1.0, (z3 + 1.0) * 0.5))
            let perspective = 0.78 + 0.36 * depthNorm
            let px = center.x + CGFloat(x3 * orbitRadius * perspective)
            let py = center.y + CGFloat(y3 * orbitRadius * perspective)

            // Foreground spheres scale up to `~15.2pt` with soft bokeh; background spheres scale to `~5.2pt`
            let diameter = CGFloat(4.8 + 10.4 * pow(depthNorm, 1.35))
            let radialDist = min(1.0, sqrt(x3 * x3 + y3 * y3))
            let stretch = CGFloat(1.0 - 0.14 * radialDist * depthNorm)
            let tiltRad = atan2(y3, x3) + .pi * 0.5
            let dotOpacity = 0.72 + 0.27 * depthNorm

            projected.append(
                ProjectedDot(
                    x: px,
                    y: py,
                    z: z3,
                    diameter: diameter,
                    stretch: stretch,
                    tiltRad: tiltRad,
                    opacity: dotOpacity
                )
            )
        }

        // Sort back-to-front by `z` depth
        projected.sort { $0.z < $1.z }

        // Pass 1: Soft volumetric bokeh halo around each 3D sphere (`1028 (2)(3).mp4` F1317..F1805)
        var haloCtx = context
        haloCtx.addFilter(.blur(radius: 5.5))
        for dot in projected {
            let haloW = dot.diameter * 1.55
            let haloH = dot.diameter * dot.stretch * 1.55
            var dCtx = haloCtx
            dCtx.opacity = dot.opacity * 0.58
            dCtx.translateBy(x: dot.x, y: dot.y)
            dCtx.rotate(by: .radians(dot.tiltRad))
            let rect = CGRect(x: -haloW * 0.5, y: -haloH * 0.5, width: haloW, height: haloH)
            dCtx.fill(Path(ellipseIn: rect), with: .color(Color.white))
        }

        // Pass 2: Soft-edged luminous white 3D sphere cores
        var coreCtx = context
        coreCtx.addFilter(.blur(radius: 1.15))
        for dot in projected {
            let w = dot.diameter
            let h = dot.diameter * dot.stretch
            var dCtx = coreCtx
            dCtx.opacity = dot.opacity
            dCtx.translateBy(x: dot.x, y: dot.y)
            dCtx.rotate(by: .radians(dot.tiltRad))
            let rect = CGRect(x: -w * 0.5, y: -h * 0.5, width: w, height: h)
            dCtx.fill(Path(ellipseIn: rect), with: .color(Color.white))
        }
    }
}

// MARK: - First-Prompt Center 3D Voice Orb (`first.jpg`) & Subsequent Reactive Bottom Light Glow (`second.jpg`, `Computer Screen34.jpg`)

/// Centered 3D Voice Orb shown below `"What should we build in <project>?"` on a new session
/// when the user hasn't typed anything and clicks the mic button for the first time (`first.jpg`),
/// while the consolidated chat box drops immediately to the bottom of the pane.
struct FirstPromptCenterVoiceOrbView: View {
    @Bindable var controller: PiSessionController
    var fixedTimeOverride: TimeInterval? = nil
    @Bindable private var stt = MuseVoiceSTTService.shared

    var body: some View {
        let frame = max(6, controller.firstPromptOrbFrame)
        let desc = VoiceOrbFrameDescriptor.descriptor(forFrame: frame)
        LiquidGlassVoiceOrbView(
            orbFrame: frame,
            descriptor: desc,
            isRecording: stt.isRecording,
            isTranscribing: stt.isTranscribing,
            audioLevel: stt.audioLevel,
            duration: stt.recordingDuration,
            fixedTimeOverride: fixedTimeOverride,
            onTap: {
                if stt.isRecording {
                    Task {
                        await stt.stopAndTranscribeUsingPending(installation: controller.museInstallation)
                    }
                } else {
                    stt.cancel()
                    withAnimation(.easeOut(duration: 0.20)) {
                        controller.isShowingFirstPromptCenterOrb = false
                    }
                }
            }
        )
        .frame(width: 96, height: 96)
    }
}

/// Reactive bottom light glow rendered along the lower edge of the consolidated chat box
/// on all voice interactions after the first untouched-session orb (`second.jpg`,
/// `Computer Screen34.jpg`, `Computer Screen3dd4.jpeg`, `Computer Screen3445.jpeg`,
/// `Computer Screen344.jpeg`, `C6omputer Screen.jpg`, `Untitled 22.jpg`, `Untitled20.jpg`).
struct VoiceReactiveBottomGlowView: View {
    var isRecording: Bool
    var isTranscribing: Bool
    var audioLevel: Double
    var fixedTimeOverride: TimeInterval? = nil

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: fixedTimeOverride != nil)) { timeline in
            let t = fixedTimeOverride ?? timeline.date.timeIntervalSinceReferenceDate
            VoiceReactiveBottomGlowCanvas(
                isRecording: isRecording,
                isTranscribing: isTranscribing,
                audioLevel: audioLevel,
                time: t
            )
        }
        .frame(height: 36)
        .allowsHitTesting(false)
    }
}

struct VoiceReactiveBottomGlowCanvas: View {
    var isRecording: Bool
    var isTranscribing: Bool
    var audioLevel: Double
    var time: TimeInterval

    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            guard w > 40 && h > 10 else { return }

            let level: Double = isTranscribing
                ? (0.22 + 0.14 * (0.5 + 0.5 * sin(time * 4.2)))
                : min(1.0, max(0.0, audioLevel))
            let cx = w * 0.50
            let halfSpan = min(w * 0.36, 265.0)
            let wavePhase = sin(time * 2.6) // +1: warm amber/coral left crest (`Computer Screen3445.jpeg`, `second.jpg`), -1: cyan/blue right crest (`Computer Screen344.jpeg`)

            // 1. Atmospheric Violet-Plum Upper Aurora & Vertical Bokeh Columns (`Untitled 22.jpg` & `Untitled20.jpg`)
            var auroraCtx = context
            auroraCtx.addFilter(.blur(radius: 8.5))
            let baseAuroraW = halfSpan * 1.75
            let baseAuroraH = CGFloat(18.0 + 10.0 * level)
            let baseAuroraRect = CGRect(
                x: cx - baseAuroraW * 0.5,
                y: h - baseAuroraH * 0.85,
                width: baseAuroraW,
                height: baseAuroraH + 6.0
            )
            auroraCtx.fill(
                Path(ellipseIn: baseAuroraRect),
                with: .color(Color(red: 0.50, green: 0.22, blue: 0.64, opacity: 0.30 + 0.20 * level))
            )

            // 6 vertical violet-plum bokeh pillars rising softly from the horizon (`Untitled 22.jpg` & `Untitled20.jpg`)
            let pillarOffsets: [Double] = [-0.66, -0.40, -0.14, 0.14, 0.40, 0.66]
            for (idx, uOff) in pillarOffsets.enumerated() {
                let pulse = 0.5 + 0.5 * sin(time * 2.1 + Double(idx) * 1.15)
                let env = exp(-uOff * uOff * 2.2)
                let px = cx + CGFloat(uOff) * halfSpan * 0.84
                let pw: CGFloat = 24.0
                let ph = CGFloat((15.0 + 8.0 * pulse + 6.0 * level) * env)
                let pRect = CGRect(x: px - pw * 0.5, y: h - ph, width: pw, height: ph + 6.0)
                auroraCtx.fill(
                    Path(ellipseIn: pRect),
                    with: .color(Color(red: 0.56, green: 0.25, blue: 0.70, opacity: (0.16 + 0.12 * pulse) * env))
                )
            }

            // Sample undulating S-curve horizon points across `u in [-1.0, +1.0]`
            // Kept sleek & low along the bottom 6pt..15pt (`Computer Screen34.jpg`, `Computer Screen3445.jpeg`, `second.jpg`)
            // so the control strip labels (`building`, `feat/...`, `muse-wonder-full-1.0`) remain 100% crisp above the glow.
            let steps = 72
            var coreCrestPoints: [CGPoint] = []
            var warmUpperPoints: [CGPoint] = []
            var coolUpperPoints: [CGPoint] = []
            coreCrestPoints.reserveCapacity(steps + 1)
            warmUpperPoints.reserveCapacity(steps + 1)
            coolUpperPoints.reserveCapacity(steps + 1)

            for i in 0...steps {
                let frac = Double(i) / Double(steps)
                let u = frac * 2.0 - 1.0 // -1.0 ... +1.0
                let x = cx + CGFloat(u) * halfSpan

                // Smooth zero-boundary bell envelope so left & right ends taper organically with zero hard edges
                let edgeFade = pow(max(0.0, 1.0 - u * u), 1.45)
                let bell = exp(-u * u * 2.15) * edgeFade

                // S-curve undulation reacting to `level` and `time`
                let sWave = sin(u * 2.75 - time * 3.1) * (0.35 + 0.65 * level)
                    + 0.28 * cos(u * 4.6 + time * 2.2) * level
                let coreHeight = bell * (4.2 + 5.2 * level + (1.4 + 3.2 * level) * sWave)
                let yCore = h - CGFloat(max(0.5, coreHeight))
                coreCrestPoints.append(CGPoint(x: x, y: yCore))

                // Warm amber/coral-magenta chromatic arch above the white core (`Computer Screen3445.jpeg`, `second.jpg`, `Untitled20.jpg`)
                let warmBias = max(0.0, min(1.0, 0.58 - 0.44 * u + 0.34 * wavePhase))
                let warmThickness = bell * warmBias * (3.5 + 8.2 * level)
                warmUpperPoints.append(CGPoint(x: x, y: yCore - CGFloat(warmThickness)))

                // Cool ice-cyan/cobalt chromatic arch above the white core (`Computer Screen344.jpeg`, `Computer Screen34.jpg`)
                let coolBias = max(0.0, min(1.0, 0.56 + 0.44 * u - 0.34 * wavePhase))
                let coolThickness = bell * coolBias * (3.4 + 7.8 * level)
                coolUpperPoints.append(CGPoint(x: x, y: yCore - CGFloat(coolThickness)))
            }

            // 2. Chromatic Prismatic Band (Rich Coral-Magenta & Golden-Amber vs. Electric Ice-Cyan & Cobalt-Blue)
            var chromaCtx = context
            chromaCtx.addFilter(.blur(radius: 3.4))

            // Warm Amber-Gold & Coral-Magenta Arch
            var warmPath = Path()
            if let first = warmUpperPoints.first {
                warmPath.move(to: CGPoint(x: first.x, y: h + 4))
                for pt in warmUpperPoints { warmPath.addLine(to: pt) }
                if let last = warmUpperPoints.last {
                    warmPath.addLine(to: CGPoint(x: last.x, y: h + 4))
                }
                warmPath.closeSubpath()
            }
            chromaCtx.fill(
                warmPath,
                with: .linearGradient(
                    Gradient(stops: [
                        .init(color: Color(red: 0.94, green: 0.34, blue: 0.52, opacity: 0.72 + 0.24 * level), location: 0.0),
                        .init(color: Color(red: 1.00, green: 0.68, blue: 0.16, opacity: 0.88 + 0.12 * level), location: 0.48),
                        .init(color: Color(red: 1.00, green: 0.86, blue: 0.38, opacity: 0.94), location: 1.0)
                    ]),
                    startPoint: CGPoint(x: cx - halfSpan * 0.25, y: h - CGFloat(12.0 + 11.0 * level)),
                    endPoint: CGPoint(x: cx - halfSpan * 0.25, y: h - 2.0)
                )
            )

            // Cool Ice-Cyan & Sky-Cobalt Arch
            var coolPath = Path()
            if let first = coolUpperPoints.first {
                coolPath.move(to: CGPoint(x: first.x, y: h + 4))
                for pt in coolUpperPoints { coolPath.addLine(to: pt) }
                if let last = coolUpperPoints.last {
                    coolPath.addLine(to: CGPoint(x: last.x, y: h + 4))
                }
                coolPath.closeSubpath()
            }
            chromaCtx.fill(
                coolPath,
                with: .linearGradient(
                    Gradient(stops: [
                        .init(color: Color(red: 0.42, green: 0.44, blue: 0.96, opacity: 0.65 + 0.25 * level), location: 0.0),
                        .init(color: Color(red: 0.28, green: 0.82, blue: 1.00, opacity: 0.82 + 0.16 * level), location: 0.54),
                        .init(color: Color(red: 0.68, green: 0.92, blue: 1.00, opacity: 0.90), location: 1.0)
                    ]),
                    startPoint: CGPoint(x: cx + halfSpan * 0.25, y: h - CGFloat(11.0 + 10.5 * level)),
                    endPoint: CGPoint(x: cx + halfSpan * 0.25, y: h - 2.0)
                )
            )

            // 3. Incandescent Pearl-White & Warm Cream Bottom Horizon Core (`y = yCore .. h`)
            var coreWavePath = Path()
            if let first = coreCrestPoints.first {
                coreWavePath.move(to: CGPoint(x: first.x, y: h + 4))
                for pt in coreCrestPoints { coreWavePath.addLine(to: pt) }
                if let last = coreCrestPoints.last {
                    coreWavePath.addLine(to: CGPoint(x: last.x, y: h + 4))
                }
                coreWavePath.closeSubpath()
            }

            var coreCtx = context
            coreCtx.addFilter(.blur(radius: 2.0))
            coreCtx.fill(
                coreWavePath,
                with: .linearGradient(
                    Gradient(stops: [
                        .init(color: Color(red: 1.00, green: 0.94, blue: 0.82, opacity: 0.86 + 0.12 * level), location: 0.0),
                        .init(color: Color(red: 0.99, green: 0.99, blue: 1.00, opacity: 0.96), location: 0.55),
                        .init(color: Color.white, location: 1.0)
                    ]),
                    startPoint: CGPoint(x: cx, y: h - CGFloat(7.5 + 6.5 * level)),
                    endPoint: CGPoint(x: cx, y: h)
                )
            )
        }
    }
}



