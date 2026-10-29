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

    /// Same size as the transcript content and the sidebar menu — the app's one
    /// reading size (`Typography.baseSize`), so the box you type into and the words
    /// you are answering are set at the same scale.
    static let fontSize: CGFloat = Typography.baseSize

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

    final class Coordinator: NSObject, NSTextViewDelegate {
        /// Command-Return does not reach a text view as a newline command at all
        /// — measured, it arrives as `noop:`, a selector AppKit does not declare
        /// in its headers. It is matched by name, and if a future macOS stops
        /// sending it we simply fall through and do nothing, which is what
        /// `noop:` means anyway.
        private static let noopSelector = Selector(("noop:"))

        var parent: ComposerTextView
        weak var textView: NSTextView?
        var lastFocusTick = 0
        var isProgrammaticChange = false

        init(parent: ComposerTextView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard !isProgrammaticChange, let textView else { return }
            parent.text = textView.string
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

        if textView.string != text {
            context.coordinator.isProgrammaticChange = true
            let selected = textView.selectedRange()
            textView.string = text
            let limit = (text as NSString).length
            textView.setSelectedRange(NSRange(location: min(selected.location, limit), length: 0))
            context.coordinator.isProgrammaticChange = false
        }

        if context.coordinator.lastFocusTick != focusTick {
            context.coordinator.lastFocusTick = focusTick
            DispatchQueue.main.async {
                textView.window?.makeFirstResponder(textView)
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
        if subview !== glowingCaret,
           String(describing: type(of: subview)).localizedCaseInsensitiveContains("InsertionIndicator") {
            subview.isHidden = true
            subview.alphaValue = 0
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateCaretGeometryAndVisibility(resetBlink: true)
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
            glowingCaret.isHidden = true
        }
        return ok
    }

    override func didChangeText() {
        super.didChangeText()
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
            if String(describing: type(of: sub)).localizedCaseInsensitiveContains("InsertionIndicator") {
                sub.isHidden = true
                sub.alphaValue = 0
            }
        }
        updateCaretGeometryAndVisibility(resetBlink: false)
    }

    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
        // Suppress the stock 1px system caret; position our custom glowing capsule caret instead.
        updateCaretGeometryAndVisibility(resetBlink: false)
    }

    override func updateInsertionPointStateAndRestartTimer(_ restartFlag: Bool) {
        super.updateInsertionPointStateAndRestartTimer(restartFlag)
        updateCaretGeometryAndVisibility(resetBlink: restartFlag)
    }

    private func startBlinkTimer() {
        blinkTimer?.invalidate()
        blinkTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self else { return }
            let elapsed = ProcessInfo.processInfo.systemUptime - self.lastActivityTime
            if elapsed < 0.55 {
                self.glowingCaret.alphaValue = 1.0
            } else {
                // Smooth sinusoidal pulse/blink so the glow breathes naturally
                let phase = (elapsed - 0.55) * .pi * 1.85
                let alpha = CGFloat(0.5 + 0.5 * cos(phase))
                self.glowingCaret.alphaValue = max(0.08, min(1.0, alpha))
            }
        }
    }

    /// Computes the exact insertion point rect in the text view's coordinate system.
    func currentCaretRect() -> NSRect {
        let lineH = ComposerTextView.lineHeight
        let origin = textContainerOrigin
        let padding = textContainer?.lineFragmentPadding ?? 0

        guard let layoutManager = layoutManager,
              let textContainer = textContainer else {
            return NSRect(x: origin.x + padding, y: origin.y, width: 2.5, height: lineH)
        }

        layoutManager.ensureLayout(for: textContainer)
        let charRange = selectedRange()
        let textLength = (string as NSString).length

        if textLength == 0 {
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

    private func updateCaretGeometryAndVisibility(resetBlink: Bool) {
        if resetBlink {
            lastActivityTime = ProcessInfo.processInfo.systemUptime
            glowingCaret.alphaValue = 1.0
        }
        let isFocused = (window?.firstResponder === self) && isEditable && selectedRange().length == 0
        glowingCaret.isHidden = !isFocused
        guard isFocused else { return }

        if blinkTimer == nil {
            startBlinkTimer()
        }

        let bleed: CGFloat = 6
        let caretRect = currentCaretRect()
        let frame = NSRect(
            x: caretRect.minX - bleed,
            y: caretRect.minY - bleed,
            width: 2.5 + bleed * 2,
            height: caretRect.height + bleed * 2
        )
        if glowingCaret.frame != frame {
            glowingCaret.frame = frame
        }
        glowingCaret.needsDisplay = true
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

        let bleed: CGFloat = 6
        let barWidth: CGFloat = 2.4
        let barHeight = max(14, bounds.height - bleed * 2)
        let barRect = CGRect(
            x: (bounds.width - barWidth) / 2,
            y: bleed,
            width: barWidth,
            height: barHeight
        )
        let centerX = barRect.midX
        let topFocus = CGPoint(x: centerX, y: barRect.minY + barHeight * 0.25)
        let bottomFocus = CGPoint(x: centerX, y: barRect.minY + barHeight * 0.75)
        let midFocus = CGPoint(x: centerX, y: barRect.midY)

        let colorSpace = CGColorSpaceCreateDeviceRGB()

        // 1. Tight upper icy-cyan / sky-blue radial bloom (fades to 0.0 inside bleed so it never clips into a box)
        if let topGradient = CGGradient(
            colorsSpace: colorSpace,
            colors: [
                NSColor(srgbRed: 0.62, green: 0.88, blue: 1.0, alpha: 0.42).cgColor,
                NSColor(srgbRed: 0.45, green: 0.78, blue: 1.0, alpha: 0.14).cgColor,
                NSColor(srgbRed: 0.45, green: 0.78, blue: 1.0, alpha: 0.0).cgColor
            ] as CFArray,
            locations: [0.0, 0.45, 1.0]
        ) {
            ctx.drawRadialGradient(
                topGradient,
                startCenter: topFocus,
                startRadius: 0.4,
                endCenter: topFocus,
                endRadius: 4.8,
                options: []
            )
        }

        // 2. Tight lower warm golden-amber radial bloom (fades to 0.0 inside bleed so it never clips into a box)
        if let bottomGradient = CGGradient(
            colorsSpace: colorSpace,
            colors: [
                NSColor(srgbRed: 1.0, green: 0.78, blue: 0.44, alpha: 0.48).cgColor,
                NSColor(srgbRed: 1.0, green: 0.68, blue: 0.32, alpha: 0.16).cgColor,
                NSColor(srgbRed: 1.0, green: 0.68, blue: 0.32, alpha: 0.0).cgColor
            ] as CFArray,
            locations: [0.0, 0.45, 1.0]
        ) {
            ctx.drawRadialGradient(
                bottomGradient,
                startCenter: bottomFocus,
                startRadius: 0.4,
                endCenter: bottomFocus,
                endRadius: 5.0,
                options: []
            )
        }

        // 3. Tight luminous halo around the capsule bar
        ctx.saveGState()
        ctx.setShadow(
            offset: .zero,
            blur: 3.2,
            color: NSColor(srgbRed: 1.0, green: 0.88, blue: 0.68, alpha: 0.65).cgColor
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
