//
//  HugeIcon.swift
//  MuseCode
//
//  Icons from Hugeicons (free "Stroke Rounded" set, MIT licensed) and
//  SessionIcons (curated session icon set under Assets.xcassets/SessionIcons).
//

import AppKit
import SwiftUI

/// A Hugeicons or SessionIcons glyph drawn at a consistent, Dynamic Type-aware size.
struct HugeIcon: View {
    var name: String
    /// Overrides the default size for large decorative glyphs (empty states).
    var size: CGFloat?

    @ScaledMetric(relativeTo: .body) private var scaledSize: CGFloat = 14

    var body: some View {
        hugeIconImage(name)
            .resizable()
            .scaledToFit()
            .frame(width: size ?? scaledSize, height: size ?? scaledSize)
    }
}

/// The Hugeicons or SessionIcons glyph as a template `Image` that always obeys SwiftUI `.foregroundStyle(...)`.
func hugeIconImage(_ name: String) -> Image {
    Image(nsImage: .huge(name))
        .renderingMode(.template)
}

extension Label where Title == Text, Icon == Image {
    init(_ titleKey: LocalizedStringKey, huge name: String) {
        self.init { Text(titleKey) } icon: { hugeIconImage(name) }
    }

    init<S: StringProtocol>(_ title: S, huge name: String) {
        self.init { Text(title) } icon: { hugeIconImage(name) }
    }
}

extension NSImage {
    private static let hugeIconCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 256
        return cache
    }()

    /// Resolves a glyph from `Assets.xcassets/Hugeicons` or `Assets.xcassets/SessionIcons` with an in-memory cache.
    static func huge(_ name: String) -> NSImage {
        let key = name as NSString
        if let cached = hugeIconCache.object(forKey: key) {
            return cached
        }
        for assetName in [name, "Hugeicons/\(name)", "SessionIcons/\(name)"] {
            if let image = NSImage(named: assetName) {
                image.isTemplate = true
                hugeIconCache.setObject(image, forKey: key)
                return image
            }
        }
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let cwdRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("MuseCode")
        for root in [repoRoot, cwdRoot] {
            for folder in ["Hugeicons", "SessionIcons"] {
                let svgURL = root
                    .appendingPathComponent("Assets.xcassets/\(folder)/\(name).imageset/\(name).svg")
                if FileManager.default.fileExists(atPath: svgURL.path),
                   let image = NSImage(contentsOf: svgURL) {
                    image.isTemplate = true
                    hugeIconCache.setObject(image, forKey: key)
                    return image
                }
            }
        }
        if let sfSymbol = NSImage(systemSymbolName: name, accessibilityDescription: nil) {
            sfSymbol.isTemplate = true
            hugeIconCache.setObject(sfSymbol, forKey: key)
            return sfSymbol
        }
        let fallback = NSImage()
        fallback.isTemplate = true
        return fallback
    }
}
