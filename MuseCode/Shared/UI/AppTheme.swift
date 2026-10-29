//
//  AppTheme.swift
//  PiCode
//
//  PiCode's background palette.
//
//  The light appearance keeps the system's own window backgrounds. The dark
//  appearance uses two flat greys, so that stacked surfaces stay legible without
//  leaning on vibrancy:
//
//    - `background` — #181818. The base the app sits on: the transcript, the
//      content header's band, the terminal panel, the package browser.
//    - `elevated`   — #212121. One step above the base, for the columns and
//      cards laid on top of it: the sidebar, the inspector, the composer box.
//
//  Both resolve per appearance through `NSColor(name:)`, so a single view has no
//  `colorScheme` checks and the two values live in exactly one place.
//

import AppKit
import SwiftUI

enum AppTheme {
    /// The base chat area background: deep obsidian (#050607) in the dark appearance
    /// matching `UntiSlehd 8.png` & `UntiSDDtlehd 8.png`, and the system's text
    /// background in the light one.
    static let background = adaptive(dark: 0x050607, light: NSColor(white: 1, alpha: 1))

    private static let chatBackgroundCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 8
        return cache
    }()

    /// Loads the high-resolution chat area background artwork (`chat-bg-forest` or `chat-bg-midnight`)
    /// from the app bundle's asset catalog or disk fallback (`Assets.xcassets/ChatBackgrounds`).
    static func chatBackgroundImage(for style: PreferencesStore.ChatBackground) -> NSImage? {
        guard let assetName = style.assetName else { return nil }
        let key = assetName as NSString
        if let cached = chatBackgroundCache.object(forKey: key) {
            return cached
        }
        for candidate in [assetName, "ChatBackgrounds/\(assetName)"] {
            if let img = NSImage(named: candidate) {
                chatBackgroundCache.setObject(img, forKey: key)
                return img
            }
        }
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let cwdRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("MuseCode")
        for root in [repoRoot, cwdRoot] {
            let pngURL = root.appendingPathComponent("Assets.xcassets/ChatBackgrounds/\(assetName).imageset/\(assetName).png")
            if FileManager.default.fileExists(atPath: pngURL.path),
               let img = NSImage(contentsOf: pngURL) {
                chatBackgroundCache.setObject(img, forKey: key)
                return img
            }
        }
        return nil
    }

    /// A surface one step above the base: #212121 in the dark appearance, the
    /// system's text background in the light one.
    static let elevated = adaptive(dark: 0x212121, light: NSColor(white: 0.98, alpha: 1))

    /// The composer box: #212121 in the dark appearance. In the light one it
    /// keeps the fixed dark grey the box has always had, because the box is
    /// deliberately dark in every appearance.
    static let composerFill = adaptive(
        dark: 0x343434,
        light: NSColor(white: 1, alpha: 1)
    )

    /// The composer's outline: a faint light edge on the dark box, a grey
    /// hairline on the white one.
    static let composerStroke = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.04)
            : NSColor(white: 0, alpha: 0.10)
    })

    /// The composer's drop shadow: deep on dark, soft on light.
    static let composerShadow = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 0, alpha: 0.25)
            : NSColor(white: 0, alpha: 0.07)
    })

    /// The emphasised pill button: white on dark, near-black on light.
    static let prominentPillFill = adaptive(dark: 0xFFFFFF, light: NSColor(white: 0.1, alpha: 1))
    static let prominentPillText = adaptive(dark: 0x111111, light: NSColor(white: 1, alpha: 1))

    /// Sparing Meta/Muse accent blue (#0077FF) for user prompt bubbles,
    /// "See more" expansion pills, and the active send/stop action button.
    static let accentBlue = Color(nsColor: NSColor(rgb: 0x0077FF))

    /// The cards on a settings page: a step above the page in the dark
    /// appearance, white with a hairline in the light one.
    static let settingsCard = adaptive(dark: 0x212121, light: NSColor(white: 1, alpha: 1))

    /// The window's own chrome: the band behind the traffic lights, the icon
    /// rail, and the thin frame around the content card. One step lighter than
    /// the sidebar so the card reads as set into it.
    /// Translucent, so the window's vibrancy (`WindowVibrancy`) shows through
    /// the way it does through a Finder sidebar.
    static let chrome = translucent(dark: 0x333333, light: NSColor(white: 0.945, alpha: 1), alpha: 0.55)

    /// The sessions sidebar and the settings menu column: the elevated surface's
    /// tint, translucent so the window's vibrancy shows through.
    static let sidebar = translucent(dark: 0x212121, light: NSColor(white: 0.98, alpha: 1), alpha: 0.6)

    /// The selected icon in the rail, and the selected row in the sidebar.
    static let railSelection = adaptive(dark: 0x444444, light: NSColor(white: 0.898, alpha: 1))

    /// The context strip the composer sits on (project, runtime, branch).
    static let composerContextFill = adaptive(dark: 0x272727, light: NSColor(white: 0.96, alpha: 1))

    /// The hairline around the content card and between its panes.
    static let cardStroke = adaptive(dark: 0x3c3c3c, light: NSColor(white: 0.90, alpha: 1))

    /// The pill behind an inline code span: a flat step up from the transcript,
    /// with no outline.
    static let inlineCodeFill = adaptive(dark: 0x303030, light: NSColor(white: 0.94, alpha: 1))

    /// A hovered or active row in the sidebar: a faint lift of the primary
    /// colour, a touch lighter in the light appearance so it reads as a tint of
    /// the column rather than a grey block.
    static let sidebarRowHighlight = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(white: 1, alpha: 0.08)
            : NSColor(white: 0, alpha: 0.055)
    })

    /// The icon on an error notice: red in the dark appearance, the label colour
    /// in the light one.
    static let errorCardIcon = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor.systemRed
            : NSColor.labelColor
    })

    /// `adaptive`, at `alpha` opacity in both appearances.
    static func translucent(dark: UInt32, light: NSColor, alpha: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(rgb: dark).withAlphaComponent(alpha)
                : light.withAlphaComponent(alpha)
        })
    }

    /// `dark` in the dark appearance, `light` in the light one. The provider is
    /// consulted every time AppKit needs the colour, so a system appearance
    /// change repaints without PiCode tracking it.
    static func adaptive(dark: UInt32, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? NSColor(rgb: dark)
                : light
        })
    }
}

/// The sidebar column's fill: a translucent tint over the window's vibrancy,
/// so the desktop behind the window shows through as it does in Finder.
struct SidebarColumnBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(AppTheme.sidebar)
    }
}

/// The window's own backdrop: the system's behind-window blur, the standard
/// macOS translucency. It dims with the window when the window is inactive.
/// The chrome and the sidebar are tinted over it; the conversation pane stays
/// opaque so the transcript keeps its contrast.
struct WindowVibrancy: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = WindowConfiguratorVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        (nsView as? WindowConfiguratorVisualEffectView)?.configureWindowIfNeeded()
    }
}

private final class WindowConfiguratorVisualEffectView: NSVisualEffectView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configureWindowIfNeeded()
    }

    func configureWindowIfNeeded() {
        guard let window else { return }
        window.titlebarSeparatorStyle = .none
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        if window.toolbar == nil {
            let toolbar = NSToolbar(identifier: "MuseEmptyTitlebarToolbar")
            toolbar.showsBaselineSeparator = false
            window.toolbar = toolbar
        } else {
            window.toolbar?.showsBaselineSeparator = false
            // Remove any SwiftUI-injected navigation separator items next to traffic lights
            while let items = window.toolbar?.items, !items.isEmpty {
                window.toolbar?.removeItem(at: 0)
            }
        }
    }
}

extension NSColor {
    /// An opaque sRGB colour from `0xRRGGBB`.
    convenience init(rgb: UInt32) {
        self.init(
            srgbRed: CGFloat((rgb >> 16) & 0xff) / 255,
            green: CGFloat((rgb >> 8) & 0xff) / 255,
            blue: CGFloat(rgb & 0xff) / 255,
            alpha: 1
        )
    }
}

// MARK: - Chat Area Background & Liquid Glass Environment Geometry (`UntiSlehd 8.png` & `UntiSDDtlehd 8.png`)

private struct SessionPaneSizeEnvironmentKey: EnvironmentKey {
    static let defaultValue: CGSize = CGSize(width: 1147, height: 820)
}

private struct ChatBackgroundEnvironmentKey: EnvironmentKey {
    static let defaultValue: PreferencesStore.ChatBackground = .forestGlass
}

private struct HasRootChatBackgroundEnvironmentKey: EnvironmentKey {
    static let defaultValue: Bool = false
}

extension EnvironmentValues {
    var sessionPaneSize: CGSize {
        get { self[SessionPaneSizeEnvironmentKey.self] }
        set { self[SessionPaneSizeEnvironmentKey.self] = newValue }
    }

    var chatBackground: PreferencesStore.ChatBackground {
        get { self[ChatBackgroundEnvironmentKey.self] }
        set { self[ChatBackgroundEnvironmentKey.self] = newValue }
    }

    var hasRootChatBackground: Bool {
        get { self[HasRootChatBackgroundEnvironmentKey.self] }
        set { self[HasRootChatBackgroundEnvironmentKey.self] = newValue }
    }
}

/// Renders the active Muse chat area background (`Forest Glass` from `UntiSDDtlehd 8.png`,
/// `Midnight Glow` from `UntiSlehd 8.png`, or `Obsidian Black`).
struct MuseChatBackgroundView: View {
    var style: PreferencesStore.ChatBackground

    var body: some View {
        GeometryReader { proxy in
            let w = max(1, proxy.size.width)
            let h = max(1, proxy.size.height)
            ZStack {
                switch style {
                case .forestGlass:
                    Color(red: 0.031, green: 0.035, blue: 0.031)
                case .midnightGlow, .solidBlack:
                    Color(red: 0.004, green: 0.008, blue: 0.012)
                }

                if let nsImage = AppTheme.chatBackgroundImage(for: style) {
                    Image(nsImage: nsImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: w, height: h, alignment: .center)
                        .clipped()
                }
            }
            .frame(width: w, height: h)
        }
        .allowsHitTesting(false)
    }
}
