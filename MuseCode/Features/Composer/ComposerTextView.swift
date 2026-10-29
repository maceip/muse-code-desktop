//
//  ComposerTextView.swift
//  PiCode
//
//  AppKit-backed plain-text editor for the composer.
//
//  AppKit is used instead of SwiftUI's TextField/TextEditor because the send key,
//  suggestion navigation, and Escape behavior must be decided before the text
//  system inserts anything — exactly what `doCommandBy` provides.
//

import AppKit
import SwiftUI

struct ComposerTextView: NSViewRepresentable {
    /// Where the text actually starts inside the view, exposed so the placeholder
    /// overlay can put itself on exactly the same spot without a magic number.
    static let textInset = NSSize(width: 2, height: 2)

    /// Prominent reading size (`18.5pt`) matching the `Search or Ask` Liquid Glass
    /// input capsule in `Screen Recording 2026-10-28 at 23.23.35.mov`.
    static let fontSize: CGFloat = 18.5

    /// The composer input pill uses a dark smoked Liquid Glass surface in both
    /// light and dark appearances, so text and placeholder use crisp light ink.
    static let textColor = NSColor(srgbRed: 0.96, green: 0.96, blue: 0.98, alpha: 1.0)
    static let caretColor = textColor
    static let placeholderColor = NSColor(srgbRed: 0.86, green: 0.86, blue: 0.90, alpha: 0.56)

    private static func adaptive(dark: NSColor, light: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    /// Starts at one sleek line in the Liquid Glass input pill and expands up to
    /// six lines before scrolling.
    static let minimumLines = 1
    static let maximumLines = 6

    /// One line of this view's own font, as AppKit lays it out. Derived rather
    /// than hardcoded: the font is what decides it, and a metric that silently
    /// stops matching the font is how a "two line" box ends up showing one and a
    /// half lines.
    static let lineHeight = ceil(NSLayoutManager().defaultLineHeight(for: .systemFont(ofSize: fontSize)))

    /// The height this view needs to show `lines` lines, insets included.
    static func height(forLines lines: Int) -> CGFloat {
        CGFloat(lines) * lineHeight + textInset.height * 2
    }

    @Binding var text: String
    var placeholder: String
    var focusTick: Int
    var sendKey: PreferencesStore.SendKey
    var suggestionsActive: Bool
    var isEnabled: Bool

    var onSend: () -> Void
    var onFollowUp: () -> Void
    var onEscape: () -> Void
    var onMoveSuggestion: (Int) -> Void
    var onAcceptSuggestion: () -> Void
    var onUserDirectEdit: (() -> Void)? = nil

    final class Coordinator: NSObject, NSTextViewDelegate {
        /// Command-Return does not reach a text view as a newline command at all
        /// — measured, it arrives as `noop:`, a selector AppKit does not declare
        /// in its headers. It is matched by name, and if a future macOS stops
        /// sending it we simply fall through and do nothing, which is what
        /// `noop:` means anyway.
        private static let noopSelector = Selector(("noop:"))

        var parent: ComposerTextView
        weak var textView: NSTextView?
        var lastFocusTick = -1
        var isProgrammaticChange = false

        init(parent: ComposerTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard !isProgrammaticChange, let textView else { return }
            parent.text = textView.string
            parent.onUserDirectEdit?()
        }

        /// Which modifiers are down *now*. The selector alone cannot answer this:
        /// a plain text view reports Shift-Return as plain `insertNewline:` and
        /// Command-Return as `noop:`, so the modifiers are the only reliable
        /// signal. `Tools/SmokeTest/run-composer.sh` pins this table down.
        private var currentModifiers: NSEvent.ModifierFlags {
            (NSApp.currentEvent?.modifierFlags ?? []).intersection(.deviceIndependentFlagsMask)
        }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)),
                 #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)),
                 Coordinator.noopSelector:
                if parent.suggestionsActive {
                    parent.onAcceptSuggestion()
                    return true
                }

                let modifiers = currentModifiers
                if modifiers.contains(.option) {
                    parent.onFollowUp()
                    return true
                }
                // Shift always means "add a line", in both send-key modes.
                if modifiers.contains(.shift) { return false }

                switch parent.sendKey {
                case .returnKey where !modifiers.contains(.command):
                    parent.onSend()
                    return true
                case .commandReturn where modifiers.contains(.command):
                    parent.onSend()
                    return true
                default:
                    // The chord that does not send adds a line. Command-Return
                    // reaches us as `noop:`, which would otherwise do nothing.
                    if selector == Coordinator.noopSelector {
                        textView.insertNewline(nil)
                        return true
                    }
                    return false
                }

            case #selector(NSResponder.cancelOperation(_:)):
                parent.onEscape()
                return true

            case #selector(NSResponder.moveUp(_:)):
                guard parent.suggestionsActive else { return false }
                parent.onMoveSuggestion(-1)
                return true

            case #selector(NSResponder.moveDown(_:)):
                guard parent.suggestionsActive else { return false }
                parent.onMoveSuggestion(1)
                return true

            case #selector(NSResponder.deleteBackward(_:)):
                return false

            default:
                return false
            }
        }

    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    /// The height the editor actually wants: as many lines as are in it, held
    /// between `minimumLines` and `maximumLines`.
    ///
    /// Without this the view reports no size of its own and SwiftUI hands it the
    /// largest height allowed, so the box was always as tall as `maxHeight` —
    /// measured, a one-line prompt sat in a 220pt box (see §10).
    ///
    /// The text container is deliberately left alone here. Setting its size inside
    /// this call (to "make sure" the width is current) invalidates layout while
    /// SwiftUI is asking, and the heights come back stale: measured, a three-line
    /// prompt reported its one-line height and the box collapsed as you typed.
    /// `widthTracksTextView` already keeps the container the right width.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard let textView = nsView.documentView as? NSTextView,
              let container = textView.textContainer,
              let layout = textView.layoutManager else { return nil }
        layout.ensureLayout(for: container)
        let used = layout.usedRect(for: container).height
        let height = min(max(used + Self.textInset.height * 2, Self.height(forLines: Self.minimumLines)),
                         Self.height(forLines: Self.maximumLines))
        return CGSize(width: proposal.width ?? nsView.frame.width, height: height)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let textView = PlaceholderTextView()
        textView.placeholder = placeholder
        textView.placeholderColor = Self.placeholderColor
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.font = .systemFont(ofSize: Self.fontSize)
        textView.textColor = Self.textColor
        textView.insertionPointColor = .clear
        textView.textContainerInset = Self.textInset
        textView.drawsBackground = false
        textView.string = text
        textView.isEditable = isEnabled
        textView.isSelectable = true
        textView.usesFindBar = false

        // Pi's composer accepts plain text; newlines and paths are literal.
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]

        scrollView.documentView = textView
        scrollView.wantsLayer = true
        scrollView.layer?.masksToBounds = false
        scrollView.contentView.wantsLayer = true
        scrollView.contentView.layer?.masksToBounds = false
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? NSTextView else { return }

        (textView as? PlaceholderTextView)?.placeholder = placeholder
        textView.isEditable = isEnabled

        if !textView.hasMarkedText(), textView.string != text {
            context.coordinator.isProgrammaticChange = true
            let oldLength = (textView.string as NSString).length
            let selected = textView.selectedRange()
            textView.string = text
            let limit = (text as NSString).length
            let newLocation = selected.location >= oldLength ? limit : min(selected.location, limit)
            textView.setSelectedRange(NSRange(location: newLocation, length: 0))
            context.coordinator.isProgrammaticChange = false
        }

        if context.coordinator.lastFocusTick != focusTick {
            context.coordinator.lastFocusTick = focusTick
            DispatchQueue.main.async {
                guard let window = textView.window else { return }
                if window.firstResponder !== textView {
                    window.makeFirstResponder(textView)
                }
                (textView as? PlaceholderTextView)?.refreshCaretState()
            }
        }
    }
}

/// The composer's text view, with the placeholder drawn in the text system's own
/// coordinates and a custom luminous capsule caret (`GlowingCaretView`) with an
/// icy-blue upper bloom and warm amber-gold lower bloom matching `cursor.png`.
final class PlaceholderTextView: NSTextView {
    var placeholder: String = ""
    var placeholderColor: NSColor = ComposerTextView.placeholderColor

    private let glowingCaret = GlowingCaretView(frame: .zero)
    private var blinkTimer: Timer?
    private var lastActivityTime: TimeInterval = ProcessInfo.processInfo.systemUptime
    private var isUpdatingCaret = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureGlowingCaret()
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
        configureGlowingCaret()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configureGlowingCaret()
    }

    deinit {
        blinkTimer?.invalidate()
    }

    override func paste(_ sender: Any?) {
        // Always paste plain UTF-8 text directly to avoid main-thread RTF/HTML WebKit pasteboard conversion hangs.
        super.pasteAsPlainText(sender)
    }

    private func configureGlowingCaret() {
        wantsLayer = true
        layer?.masksToBounds = false
        glowingCaret.wantsLayer = true
        glowingCaret.layer?.backgroundColor = NSColor.clear.cgColor
        glowingCaret.layer?.isOpaque = false
        glowingCaret.layer?.masksToBounds = false
        glowingCaret.isHidden = true
        addSubview(glowingCaret)
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        // Keep NSTextInsertionIndicator unhidden and alpha=1.0 so macOS Dictation (CampoLightweightUI)
        // validates its positioningView layout rect, while setting its tint color to .clear so our
        // custom GlowingCaretView renders the visible luminous cursor bar.
        if subview !== glowingCaret,
           let indicator = subview as? NSTextInsertionIndicator {
            indicator.color = .clear
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            blinkTimer?.invalidate()
            blinkTimer = nil
        } else {
            updateCaretGeometryAndVisibility(resetBlink: true)
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window, self.isEditable else { return }
                if window.firstResponder == nil || window.firstResponder === window {
                    window.makeFirstResponder(self)
                }
                self.updateCaretGeometryAndVisibility(resetBlink: true)
            }
        }
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok {
            startBlinkTimer()
            updateCaretGeometryAndVisibility(resetBlink: true)
        }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok {
            blinkTimer?.invalidate()
            blinkTimer = nil
            updateCaretGeometryAndVisibility(resetBlink: false)
        }
        return ok
    }

    override func didChangeText() {
        super.didChangeText()
        updateCaretGeometryAndVisibility(resetBlink: true)
    }

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        updateCaretGeometryAndVisibility(resetBlink: true)
    }

    override func unmarkText() {
        super.unmarkText()
        updateCaretGeometryAndVisibility(resetBlink: true)
    }

    override func setSelectedRanges(
        _ ranges: [NSValue],
        affinity: NSSelectionAffinity,
        stillSelecting stillSelectingFlag: Bool
    ) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelectingFlag)
        updateCaretGeometryAndVisibility(resetBlink: true)
    }

    override func layout() {
        super.layout()
        for sub in subviews where sub !== glowingCaret {
            if let indicator = sub as? NSTextInsertionIndicator {
                indicator.color = .clear
            }
        }
        updateCaretGeometryAndVisibility(resetBlink: false, ensureLayout: false)
    }

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        // Call super with .clear so AppKit updates NSTextInsertionIndicator's geometry for
        // macOS Dictation (CampoLightweightUI) without drawing the stock 1px caret.
        super.drawInsertionPoint(in: rect, color: .clear, turnedOn: flag)
    }

    override func updateInsertionPointStateAndRestartTimer(_ restartFlag: Bool) {
        super.updateInsertionPointStateAndRestartTimer(restartFlag)
        updateCaretGeometryAndVisibility(resetBlink: restartFlag)
    }

    func refreshCaretState() {
        updateCaretGeometryAndVisibility(resetBlink: true)
    }

    private func startBlinkTimer() {
        blinkTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.085, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard !self.glowingCaret.isHidden, self.window?.isKeyWindow == true else { return }
            let elapsed = ProcessInfo.processInfo.systemUptime - self.lastActivityTime
            let targetAlpha: CGFloat
            if elapsed < 0.55 {
                targetAlpha = 1.0
            } else {
                // Smooth sinusoidal pulse/blink so the glow breathes naturally
                let phase = (elapsed - 0.55) * .pi * 1.85
                let alpha = CGFloat(0.5 + 0.5 * cos(phase))
                targetAlpha = max(0.08, min(1.0, alpha))
            }
            if abs(self.glowingCaret.alphaValue - targetAlpha) > 0.015 {
                self.glowingCaret.alphaValue = targetAlpha
            }
        }
        timer.tolerance = 0.025
        blinkTimer = timer
    }

    /// Computes the exact insertion point rect in the text view's coordinate system.
    func currentCaretRect(ensureLayout: Bool = true) -> NSRect {
        let lineH = ComposerTextView.lineHeight
        let origin = textContainerOrigin
        let padding = textContainer?.lineFragmentPadding ?? 0

        guard let layoutManager = layoutManager,
              let textContainer = textContainer else {
            return NSRect(x: origin.x + padding, y: origin.y, width: 2.5, height: lineH)
        }

        if ensureLayout {
            layoutManager.ensureLayout(for: textContainer)
        }
        let charRange = selectedRange()
        let textLength = (string as NSString).length

        if textLength == 0 || layoutManager.numberOfGlyphs == 0 {
            return NSRect(x: origin.x + padding, y: origin.y, width: 2.5, height: lineH)
        }

        let clampedLoc = min(charRange.location, textLength)

        // If cursor is right after a trailing newline, move to the start of the next line
        if clampedLoc == textLength, clampedLoc > 0,
           (string as NSString).character(at: clampedLoc - 1) == 10 {
            let prevGlyph = layoutManager.glyphIndexForCharacter(at: clampedLoc - 1)
            let prevLineRect = layoutManager.lineFragmentRect(forGlyphAt: prevGlyph, effectiveRange: nil)
            return NSRect(
                x: origin.x + padding,
                y: origin.y + prevLineRect.maxY,
                width: 2.5,
                height: lineH
            )
        }

        if clampedLoc < textLength {
            let glyphIndex = layoutManager.glyphIndexForCharacter(at: clampedLoc)
            let lineRect = layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: nil)
            let glyphLoc = layoutManager.location(forGlyphAt: glyphIndex)
            return NSRect(
                x: origin.x + lineRect.minX + glyphLoc.x,
                y: origin.y + lineRect.minY,
                width: 2.5,
                height: max(lineH, lineRect.height)
            )
        } else {
            let lastGlyph = layoutManager.glyphIndexForCharacter(at: textLength - 1)
            let lineRect = layoutManager.lineFragmentRect(forGlyphAt: lastGlyph, effectiveRange: nil)
            let glyphRect = layoutManager.boundingRect(
                forGlyphRange: NSRange(location: lastGlyph, length: 1),
                in: textContainer
            )
            return NSRect(
                x: origin.x + glyphRect.maxX,
                y: origin.y + lineRect.minY,
                width: 2.5,
                height: max(lineH, lineRect.height)
            )
        }
    }

    private func updateCaretGeometryAndVisibility(resetBlink: Bool, ensureLayout: Bool = true) {
        guard !isUpdatingCaret else { return }
        isUpdatingCaret = true
        defer { isUpdatingCaret = false }

        if resetBlink {
            lastActivityTime = ProcessInfo.processInfo.systemUptime
            glowingCaret.alphaValue = 1.0
        }
        let isFocusedOrEmpty = ((window?.firstResponder === self) || string.isEmpty)
            && isEditable
            && selectedRange().length == 0
            && !hasMarkedText()
        glowingCaret.isHidden = !isFocusedOrEmpty
        guard isFocusedOrEmpty else { return }

        if blinkTimer == nil && (window?.firstResponder === self) {
            startBlinkTimer()
        } else if window?.firstResponder !== self {
            glowingCaret.alphaValue = 1.0
        }

        let bleed: CGFloat = 14
        let caretRect = currentCaretRect(ensureLayout: ensureLayout)
        let frame = NSRect(
            x: caretRect.minX - bleed,
            y: caretRect.minY - bleed,
            width: 2.5 + bleed * 2,
            height: caretRect.height + bleed * 2
        )
        let sizeChanged = glowingCaret.frame.size != frame.size
        if glowingCaret.frame != frame {
            glowingCaret.frame = frame
        }
        if sizeChanged {
            glowingCaret.needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: ComposerTextView.fontSize),
            .foregroundColor: placeholderColor
        ]
        let origin = textContainerOrigin
        // Real glyphs start one `lineFragmentPadding` inside the container, so the
        // placeholder has to as well or it hangs left of the text it stands in for.
        let x = origin.x + (textContainer?.lineFragmentPadding ?? 0)
        (placeholder as NSString).draw(at: NSPoint(x: x, y: origin.y), withAttributes: attributes)
    }
}

/// Renders the glowing rounded-capsule cursor with a cool icy-blue upper bloom,
/// a warm amber-gold lower bloom, and a bright white core (`cursor.png`), without
/// any rectangular background or clipped halo box.
final class GlowingCaretView: NSView {
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        defer { ctx.restoreGState() }

        ctx.clear(bounds)

        let bleed: CGFloat = 14
        let barWidth: CGFloat = 2.4
        let barHeight = max(16, bounds.height - bleed * 2)
        let barRect = CGRect(
            x: (bounds.width - barWidth) / 2,
            y: bleed,
            width: barWidth,
            height: barHeight
        )
        let centerX = barRect.midX
        let topFocus = CGPoint(x: centerX, y: barRect.minY + barHeight * 0.24)
        let bottomFocus = CGPoint(x: centerX, y: barRect.minY + barHeight * 0.78)
        let midFocus = CGPoint(x: centerX, y: barRect.midY)

        let colorSpace = CGColorSpaceCreateDeviceRGB()

        // 1. Soft upper icy-cyan / sky-blue radial bloom illuminating the dark pill (`Und 9.jpg` & `Untitled 9.jpg`, fades to 0.0 inside bleed)
        if let topGradient = CGGradient(
            colorsSpace: colorSpace,
            colors: [
                NSColor(srgbRed: 0.52, green: 0.88, blue: 1.0, alpha: 0.56).cgColor,
                NSColor(srgbRed: 0.36, green: 0.76, blue: 1.0, alpha: 0.22).cgColor,
                NSColor(srgbRed: 0.28, green: 0.68, blue: 1.0, alpha: 0.0).cgColor
            ] as CFArray,
            locations: [0.0, 0.45, 1.0]
        ) {
            ctx.drawRadialGradient(
                topGradient,
                startCenter: topFocus,
                startRadius: 0.4,
                endCenter: topFocus,
                endRadius: 11.5,
                options: []
            )
        }

        // 2. Soft lower warm golden-amber / orange radial bloom (`Und 9.jpg` & `Untitled 9.jpg`, fades to 0.0 inside bleed)
        if let bottomGradient = CGGradient(
            colorsSpace: colorSpace,
            colors: [
                NSColor(srgbRed: 1.0, green: 0.74, blue: 0.36, alpha: 0.62).cgColor,
                NSColor(srgbRed: 1.0, green: 0.58, blue: 0.20, alpha: 0.26).cgColor,
                NSColor(srgbRed: 1.0, green: 0.48, blue: 0.12, alpha: 0.0).cgColor
            ] as CFArray,
            locations: [0.0, 0.45, 1.0]
        ) {
            ctx.drawRadialGradient(
                bottomGradient,
                startCenter: bottomFocus,
                startRadius: 0.4,
                endCenter: bottomFocus,
                endRadius: 12.0,
                options: []
            )
        }

        // 3. Tight luminous halo around the capsule bar
        ctx.saveGState()
        ctx.setShadow(
            offset: .zero,
            blur: 4.5,
            color: NSColor(srgbRed: 1.0, green: 0.86, blue: 0.64, alpha: 0.78).cgColor
        )
        let corePath = CGPath(
            roundedRect: barRect,
            cornerWidth: barWidth / 2,
            cornerHeight: barWidth / 2,
            transform: nil
        )
        ctx.addPath(corePath)
        ctx.setFillColor(NSColor.white.cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        // 4. Crisp bright white capsule core with subtle vertical sheen
        ctx.saveGState()
        ctx.addPath(corePath)
        ctx.clip()
        if let coreGradient = CGGradient(
            colorsSpace: colorSpace,
            colors: [
                NSColor(srgbRed: 0.96, green: 0.99, blue: 1.0, alpha: 1.0).cgColor,
                NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1.0).cgColor,
                NSColor(srgbRed: 1.0, green: 0.97, blue: 0.90, alpha: 1.0).cgColor
            ] as CFArray,
            locations: [0.0, 0.5, 1.0]
        ) {
            ctx.drawLinearGradient(
                coreGradient,
                start: CGPoint(x: midFocus.x, y: barRect.minY),
                end: CGPoint(x: midFocus.x, y: barRect.maxY),
                options: []
            )
        }
        ctx.restoreGState()
    }
}
