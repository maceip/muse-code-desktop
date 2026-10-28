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
    @State private var isWaveIgniting = false
    @State private var isContractedToOrb = false
    @State private var isShowingVoiceErrorPopover = false
    @Bindable private var stt = MuseVoiceSTTService.shared

    private var isVoiceActive: Bool {
        stt.isRecording || stt.isTranscribing
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

            // Top Smoked Liquid Glass Input Pill — morphs into the 3D Liquid Glass Voice Orb when mic is active
            morphingTopInputOrOrb

            // Bottom Frosted Liquid Glass Control Card — fades and scales out when morphed into the Voice Orb
            if !isContractedToOrb {
                liquidGlassControlCard
                    .opacity(isWaveIgniting ? 0.0 : 1.0)
                    .scaleEffect(isWaveIgniting ? 0.95 : 1.0, anchor: .top)
                    .transition(.opacity.combined(with: .scale(scale: 0.94, anchor: .top)))
            }
        }
        .animation(.spring(response: 0.44, dampingFraction: 0.80), value: isContractedToOrb)
        .animation(.easeOut(duration: 0.22), value: isWaveIgniting)
        .onChange(of: isVoiceActive) { _, active in
            syncOrbAnimationState(active: active)
        }
        .onAppear {
            loadDraft()
            if isVoiceActive {
                isWaveIgniting = true
                isContractedToOrb = true
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

    // MARK: - Liquid Glass Top Input Pill & Morphing 3D Voice Orb (`orb1.gif`)

    private var morphingTopInputOrOrb: some View {
        ZStack {
            if isContractedToOrb {
                LiquidGlassVoiceOrbView(
                    isRecording: stt.isRecording,
                    isTranscribing: stt.isTranscribing,
                    duration: stt.recordingDuration,
                    onTap: { toggleVoiceOrbRecording() }
                )
                .frame(width: 96, height: 96)
                .transition(.scale(scale: 0.86).combined(with: .opacity))
            } else {
                liquidGlassInputPill
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .popover(isPresented: $isShowingVoiceErrorPopover, arrowEdge: .top) {
            voiceErrorPopover
        }
    }

    private var liquidGlassInputPill: some View {
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
            .opacity(isWaveIgniting ? 0.15 : 1.0)

            HStack(spacing: 8) {
                Button {
                    toggleVoiceOrbRecording()
                } label: {
                    HugeIcon(name: "mic-01", size: 18)
                        .foregroundStyle(Color.white.opacity(0.82))
                        .frame(width: 30, height: 30)
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

                if isStreamingRun || canSend {
                    primaryActionButton
                }
            }
            .opacity(isWaveIgniting ? 0.0 : 1.0)
        }
        .padding(.leading, 18)
        .padding(.trailing, 14)
        .padding(.vertical, 11)
        .background(
            ZStack {
                LiquidGlassCardBackground(
                    cornerRadius: 28,
                    isDarkTopPill: true,
                    isDropTargeted: isDropTargeted
                )

                // Stage 1 of `orb1.gif`: Horizontal chromatic plasma wave igniting across the pill before contracting into the 3D orb
                if isWaveIgniting {
                    PlasmaHorizonWaveCanvas(isCircularOrb: false)
                        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                        .transition(.opacity)
                }
            }
        )
        .frame(maxWidth: isWaveIgniting ? 280 : .infinity)
        .dropDestination(for: URL.self) { urls, _ in
            addAttachments(urls)
            return true
        } isTargeted: { isDropTargeted = $0 }
    }

    // MARK: - Bottom Frosted Liquid Glass Control Card (Transparent Baseline Controls)

    private var liquidGlassControlCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Row 1: Project Folder & Git Branch on the left, Model & Reasoning Effort Selector on the right
            HStack(spacing: 14) {
                ComposerContextStrip(state: state, controller: controller, isGlassSurface: true)
                ComposerAccessControl(controller: controller)
                Spacer(minLength: 14)
                modelThinkingMenu
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

                Spacer(minLength: 14)

                MuseCreditBatteryButton(controller: controller, isGlassSurface: true)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 13)
        .background(
            LiquidGlassCardBackground(
                cornerRadius: 24,
                isDarkTopPill: false,
                isDropTargeted: isDropTargeted
            )
        )
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

    // MARK: - Voice Orb Morphing & STT Recording Actions

    private func toggleVoiceOrbRecording() {
        if !isVoiceActive && !isContractedToOrb {
            // Stage 1: Ignite the horizontal plasma wave inside the dark Liquid Glass input pill
            withAnimation(.easeOut(duration: 0.18)) {
                isWaveIgniting = true
            }
            // Stage 2: Contract pill horizontally into the centered 3D Liquid Glass Orb
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                    isContractedToOrb = true
                }
            }
        }

        Task {
            await stt.toggleRecording(installation: controller.museInstallation) { transcribed in
                appendTranscription(transcribed)
            }
            if stt.lastError != nil {
                isShowingVoiceErrorPopover = true
            }
            if !stt.isRecording && !stt.isTranscribing {
                collapseOrbBackToInputPill()
            }
        }
    }

    private func syncOrbAnimationState(active: Bool) {
        if active {
            if !isContractedToOrb {
                withAnimation(.easeOut(duration: 0.16)) {
                    isWaveIgniting = true
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
                    withAnimation(.spring(response: 0.42, dampingFraction: 0.78)) {
                        isContractedToOrb = true
                    }
                }
            }
        } else {
            collapseOrbBackToInputPill()
        }
    }

    private func collapseOrbBackToInputPill() {
        withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
            isContractedToOrb = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.20) {
            withAnimation(.easeOut(duration: 0.20)) {
                isWaveIgniting = false
            }
        }
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

// MARK: - Tachometer Credit & Capacity Gauge (15k RPM Full -> 500 RPM Low)

struct MuseCreditBatteryButton: View {
    var controller: PiSessionController
    var isGlassSurface: Bool = true
    @State private var isPopoverPresented = false
    @Bindable private var usageService = MuseUsageService.shared

    static let maxRPM: Int = 15_000
    static let minRPM: Int = 500

    private var totalSessionTokens: Int {
        (controller.stats?.tokens.totalTokens ?? 0)
            + controller.subagents.reduce(0) { $0 + $1.totalTokens }
    }

    private var allowancePercentage: Int? {
        usageService.allowancePercentage
    }

    /// Remaining capacity fraction (`1.0` = full credits / 15k rpm, `0.0` = almost out / 500 rpm).
    var remainingFraction: Double {
        if let pct = allowancePercentage {
            return min(1.0, max(0.0, Double(pct) / 100.0))
        }
        if let usedPct = controller.contextUsagePercent, usedPct > 0 {
            return min(1.0, max(0.0, 1.0 - (usedPct / 100.0)))
        }
        let capacity = max(1, controller.model?.contextWindow ?? 200_000)
        if totalSessionTokens > 0 {
            let used = min(1.0, max(0.0, Double(totalSessionTokens) / Double(capacity)))
            return 1.0 - used
        }
        return 1.0
    }

    /// Current tachometer RPM mapped linearly between `500 rpm` (almost out) and `15k rpm` (full).
    var currentRPM: Int {
        let span = Double(Self.maxRPM - Self.minRPM)
        let raw = Double(Self.minRPM) + remainingFraction * span
        return min(Self.maxRPM, max(Self.minRPM, Int(raw.rounded())))
    }

    var rpmLabel: String {
        Self.formatRPM(currentRPM)
    }

    static func formatRPM(_ rpm: Int) -> String {
        if rpm >= 1_000 {
            let k = Double(rpm) / 1_000.0
            if abs(k.rounded() - k) < 0.05 {
                return "\(Int(k.rounded()))k rpm"
            }
            return String(format: "%.1fk rpm", k)
        }
        return "\(rpm) rpm"
    }

    private var gaugeColor: Color {
        if currentRPM <= 2_000 { return .red }
        if currentRPM <= 5_500 { return .orange }
        return isGlassSurface
            ? Color(red: 0.25, green: 0.68, blue: 1.0)
            : AppTheme.accentBlue
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
                tint: gaugeColor,
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
                    .foregroundStyle(gaugeColor)
            }

            TachometerLargeDial(
                rpm: currentRPM,
                fraction: remainingFraction,
                tint: gaugeColor
            )
            .frame(maxWidth: .infinity)
            .frame(height: 92)
            .padding(.vertical, 2)

            HStack {
                Text("Low")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Full")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
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

            if let snapshot = usageService.latestSnapshot {
                Divider()
                HStack(alignment: .top, spacing: 6) {
                    HugeIcon(name: "flash")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        if let allowance = snapshot.allowanceRemainingPercent {
                            Text(snapshot.allowanceSummary ?? "Allowance: \(Int(allowance.rounded()))% remaining")
                                .font(.caption.weight(.medium))
                        } else {
                            Text("muse usage: \(snapshot.reason ?? "no allowance reported")")
                                .font(.caption.weight(.medium))
                        }
                        if let hint = snapshot.hint {
                            Text(hint)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
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
        .frame(width: 310)
    }
}

/// Compact tachometer dial with tick marks, arc, and needle for the composer bar.
struct TachometerMiniDial: View {
    var fraction: Double
    var tint: Color
    var isGlassSurface: Bool = true

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height - 2.5)
            let radius = min(size.width / 2 - 1.5, size.height - 3.5)
            let startDeg = 165.0
            let endDeg = 375.0
            let clamped = min(1.0, max(0.0, fraction))
            let needleDeg = startDeg + clamped * (endDeg - startDeg)

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
                with: .color(isGlassSurface ? Color.white.opacity(0.28) : Color.primary.opacity(0.22)),
                style: StrokeStyle(lineWidth: 2.0, lineCap: .round)
            )

            var activeArc = Path()
            activeArc.addArc(
                center: center,
                radius: radius,
                startAngle: .degrees(startDeg),
                endAngle: .degrees(needleDeg),
                clockwise: false
            )
            context.stroke(activeArc, with: .color(tint), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))

            // Needle
            let rad = needleDeg * .pi / 180.0
            let tip = CGPoint(
                x: center.x + CGFloat(cos(rad)) * (radius - 1.0),
                y: center.y + CGFloat(sin(rad)) * (radius - 1.0)
            )
            var needle = Path()
            needle.move(to: center)
            needle.addLine(to: tip)
            context.stroke(
                needle,
                with: .color(isGlassSurface ? Color.white.opacity(0.95) : Color.primary),
                style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
            )

            // Center pivot
            let hubRect = CGRect(x: center.x - 1.8, y: center.y - 1.8, width: 3.6, height: 3.6)
            context.fill(Path(ellipseIn: hubRect), with: .color(tint))
        }
    }
}

/// Full tachometer instrument dial shown in the credit gauge popover.
struct TachometerLargeDial: View {
    var rpm: Int
    var fraction: Double
    var tint: Color

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
            context.stroke(track, with: .color(.primary.opacity(0.14)), style: StrokeStyle(lineWidth: 7, lineCap: .round))

            // Low-credit warning zone (500 - 2.5k RPM)
            var redZone = Path()
            redZone.addArc(center: center, radius: radius, startAngle: .degrees(startDeg), endAngle: .degrees(startDeg + spanDeg * 0.16), clockwise: false)
            context.stroke(redZone, with: .color(.red.opacity(0.45)), style: StrokeStyle(lineWidth: 7, lineCap: .round))

            // Active RPM arc
            var active = Path()
            active.addArc(center: center, radius: radius, startAngle: .degrees(startDeg), endAngle: .degrees(needleDeg), clockwise: false)
            context.stroke(active, with: .color(tint), style: StrokeStyle(lineWidth: 7, lineCap: .round))

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
            context.stroke(needle, with: .color(.primary), style: StrokeStyle(lineWidth: 2.4, lineCap: .round))

            let hub = CGRect(x: center.x - 4.5, y: center.y - 4.5, width: 9, height: 9)
            context.fill(Path(ellipseIn: hub), with: .color(tint))
        }
        .overlay(alignment: .bottom) {
            Text("\(Int((fraction * 100.0).rounded()))%")
                .font(.system(size: 11, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(.secondary)
        }
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
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
        nsView.state = .active
    }
}

struct LiquidGlassCardBackground: View {
    var cornerRadius: CGFloat
    var isDarkTopPill: Bool
    var isDropTargeted: Bool = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            LiquidGlassBlurBackground(
                material: .hudWindow,
                blendingMode: .withinWindow
            )

            if isDarkTopPill {
                // Dark obsidian top fading into smoky frosted glass at the bottom (matching Screenshot 14.04.21 & orb1.gif)
                LinearGradient(
                    stops: [
                        .init(color: Color(red: 0.04, green: 0.04, blue: 0.06, opacity: 0.95), location: 0.0),
                        .init(color: Color(red: 0.12, green: 0.12, blue: 0.15, opacity: 0.88), location: 0.52),
                        .init(color: Color(red: 0.36, green: 0.35, blue: 0.39, opacity: 0.78), location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                // Subtle bottom inner glass refraction sheen
                LinearGradient(
                    colors: [
                        Color.clear,
                        Color.white.opacity(0.14)
                    ],
                    startPoint: .center,
                    endPoint: .bottom
                )
            } else {
                // Translucent smoky frosted glass card for the lower control deck
                LinearGradient(
                    stops: [
                        .init(color: Color(red: 0.39, green: 0.38, blue: 0.42, opacity: 0.72), location: 0.0),
                        .init(color: Color(red: 0.48, green: 0.47, blue: 0.51, opacity: 0.62), location: 0.55),
                        .init(color: Color(red: 0.55, green: 0.54, blue: 0.58, opacity: 0.56), location: 1.0)
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )

                LinearGradient(
                    colors: [
                        Color.white.opacity(0.10),
                        Color.clear,
                        Color.white.opacity(0.08)
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
                            colors: [
                                Color.white.opacity(isDarkTopPill ? 0.38 : 0.48),
                                Color.white.opacity(0.22),
                                Color.white.opacity(isDarkTopPill ? 0.52 : 0.38)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    ),
                lineWidth: isDropTargeted ? 2.0 : 1.1
            )
        )
        .shadow(
            color: Color.black.opacity(isDarkTopPill ? 0.26 : 0.18),
            radius: isDarkTopPill ? 18 : 16,
            y: isDarkTopPill ? 8 : 7
        )
    }
}

/// The 3D Liquid Glass Sphere / Voice Orb that the top input pill morphs into
/// when the microphone button is clicked (`orb1.gif`, frames 6–22).
struct LiquidGlassVoiceOrbView: View {
    var isRecording: Bool
    var isTranscribing: Bool
    var duration: TimeInterval
    var onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            ZStack {
                // Soft outer ambient glass halo
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [
                                Color.black.opacity(0.28),
                                Color(red: 0.22, green: 0.58, blue: 0.95).opacity(0.10),
                                Color.clear
                            ],
                            center: .center,
                            startRadius: 32,
                            endRadius: 58
                        )
                    )
                    .frame(width: 114, height: 114)

                // Core 96x96 3D Liquid Glass Sphere
                ZStack {
                    LiquidGlassBlurBackground(
                        material: .hudWindow,
                        blendingMode: .withinWindow
                    )

                    // Base sphere gradient: glossy obsidian-black upper hemisphere, smoky silver-frosted glass lower hemisphere
                    LinearGradient(
                        stops: [
                            .init(color: Color(red: 0.02, green: 0.02, blue: 0.04, opacity: 0.98), location: 0.0),
                            .init(color: Color(red: 0.05, green: 0.06, blue: 0.09, opacity: 0.95), location: 0.44),
                            .init(color: Color(red: 0.56, green: 0.56, blue: 0.60, opacity: 0.58), location: 0.72),
                            .init(color: Color(red: 0.74, green: 0.74, blue: 0.78, opacity: 0.50), location: 1.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )

                    // 60fps undulating chromatic plasma horizon wave (icy sky-blue top bloom, blazing white core ribbon, warm amber-gold bottom bloom)
                    PlasmaHorizonWaveCanvas(isCircularOrb: true)

                    // Top-left 3D glass dome specular highlight
                    Ellipse()
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.26),
                                    Color.white.opacity(0.04),
                                    Color.clear
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .frame(width: 62, height: 30)
                        .offset(y: -26)
                        .blur(radius: 2)

                    // Bottom inner crescent glass reflection
                    Circle()
                        .trim(from: 0.08, to: 0.42)
                        .stroke(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.10),
                                    Color.white.opacity(0.65),
                                    Color.white.opacity(0.10)
                                ],
                                startPoint: .leading,
                                endPoint: .trailing
                            ),
                            style: StrokeStyle(lineWidth: 2.2, lineCap: .round)
                        )
                        .frame(width: 88, height: 88)
                }
                .frame(width: 92, height: 92)
                .clipShape(Circle())
                .overlay(
                    Circle()
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.45),
                                    Color.white.opacity(0.22),
                                    Color.white.opacity(0.68)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: 1.3
                        )
                        .frame(width: 92, height: 92)
                )
                .shadow(color: Color.black.opacity(0.32), radius: 18, y: 9)
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .focusEffectDisabled()
        .help(
            isTranscribing
                ? "Transcribing voice via `muse voice transcribe`…"
                : "Listening (\(String(format: "%d:%02d", Int(duration) / 60, Int(duration) % 60))) — click Orb or press Esc to transcribe"
        )
    }
}

/// 60fps animated chromatic plasma wave rendered inside the contracting pill (Frames 3–5)
/// and across the equator of the 3D Liquid Glass Voice Orb (Frames 6–22 of `orb1.gif`).
struct PlasmaHorizonWaveCanvas: View {
    var isCircularOrb: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            Canvas { context, size in
                let midY = size.height * (isCircularOrb ? 0.53 : 0.56)
                let width = size.width
                let steps = 48

                func waveY(xNorm: Double, phaseOffset: Double, ampScale: Double) -> CGFloat {
                    // Envelope tapers gently near edges inside the sphere
                    let edgeEnvelope = isCircularOrb
                        ? sin(xNorm * .pi)
                        : (0.45 + 0.55 * sin(xNorm * .pi))
                    let primary = sin(xNorm * .pi * 2.15 - t * 3.8 + phaseOffset)
                    let secondary = 0.45 * cos(xNorm * .pi * 3.4 + t * 2.6 - phaseOffset * 0.7)
                    let amp = (isCircularOrb ? 6.5 : 5.0) * ampScale * edgeEnvelope
                    return midY + CGFloat(primary + secondary) * CGFloat(amp)
                }

                func buildRibbonPath(phaseOffset: Double, yOffset: CGFloat, thickness: CGFloat, ampScale: Double = 1.0) -> Path {
                    var path = Path()
                    for i in 0...steps {
                        let u = Double(i) / Double(steps)
                        let x = CGFloat(u) * width
                        let y = waveY(xNorm: u, phaseOffset: phaseOffset, ampScale: ampScale) + yOffset - thickness * 0.5
                        if i == 0 {
                            path.move(to: CGPoint(x: x, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                    for i in (0...steps).reversed() {
                        let u = Double(i) / Double(steps)
                        let x = CGFloat(u) * width
                        let y = waveY(xNorm: u, phaseOffset: phaseOffset + 0.35, ampScale: ampScale) + yOffset + thickness * 0.5
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                    path.closeSubpath()
                    return path
                }

                // 1. Deep upper sky-blue / cyan atmospheric bloom
                var deepCyanCtx = context
                deepCyanCtx.addFilter(.blur(radius: isCircularOrb ? 11 : 13))
                let deepCyanPath = buildRibbonPath(phaseOffset: 0.0, yOffset: -9, thickness: isCircularOrb ? 22 : 18, ampScale: 1.15)
                deepCyanCtx.fill(
                    deepCyanPath,
                    with: .linearGradient(
                        Gradient(colors: [
                            Color(red: 0.08, green: 0.55, blue: 1.0, opacity: 0.85),
                            Color(red: 0.28, green: 0.82, blue: 1.0, opacity: 0.95),
                            Color(red: 0.08, green: 0.55, blue: 1.0, opacity: 0.85)
                        ]),
                        startPoint: CGPoint(x: 0, y: midY - 12),
                        endPoint: CGPoint(x: width, y: midY - 4)
                    )
                )

                // 2. Warm lower amber-gold / orange atmospheric bloom
                var amberCtx = context
                amberCtx.addFilter(.blur(radius: isCircularOrb ? 9 : 11))
                let amberPath = buildRibbonPath(phaseOffset: 0.5, yOffset: 7, thickness: isCircularOrb ? 16 : 14, ampScale: 1.05)
                amberCtx.fill(
                    amberPath,
                    with: .linearGradient(
                        Gradient(colors: [
                            Color(red: 1.0, green: 0.52, blue: 0.12, opacity: 0.80),
                            Color(red: 1.0, green: 0.74, blue: 0.26, opacity: 0.92),
                            Color(red: 1.0, green: 0.52, blue: 0.12, opacity: 0.80)
                        ]),
                        startPoint: CGPoint(x: 0, y: midY + 4),
                        endPoint: CGPoint(x: width, y: midY + 14)
                    )
                )

                // 3. Mid cyan-white transition glow
                var midGlowCtx = context
                midGlowCtx.addFilter(.blur(radius: 5.0))
                let midGlowPath = buildRibbonPath(phaseOffset: 0.2, yOffset: -2, thickness: 11, ampScale: 1.0)
                midGlowCtx.fill(
                    midGlowPath,
                    with: .color(Color(red: 0.65, green: 0.92, blue: 1.0, opacity: 0.92))
                )

                // 4. Blazing white plasma core ribbon
                var coreCtx = context
                coreCtx.addFilter(.blur(radius: 1.8))
                let corePath = buildRibbonPath(phaseOffset: 0.15, yOffset: 0, thickness: isCircularOrb ? 6.5 : 5.5, ampScale: 0.95)
                coreCtx.fill(
                    corePath,
                    with: .color(Color.white.opacity(0.98))
                )
            }
        }
    }
}

