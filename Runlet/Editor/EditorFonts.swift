import AppKit
import CoreText
import RunletCore

/// Everything the editor's appearance depends on; `CodeEditorView` re-applies it to a tab's
/// persistent editor whenever it changes.
struct EditorPreferences: Equatable {
    var fontSize: CGFloat = 13
    /// Font family; nil is the system monospaced font.
    var fontName: String?
    var lineHeight: CGFloat = 1.15
    var ligatures = false
    var softWrap = false
    var tabWidth = 4
    var insertSpaces = true
    var dark = false

    init() {}

    init(settings: AppSettings, dark: Bool) {
        fontSize = settings.fontSize
        fontName = settings.editorFontName
        lineHeight = settings.lineHeight
        ligatures = settings.ligatures
        softWrap = settings.softWrap
        tabWidth = settings.tabWidth
        insertSpaces = settings.insertSpaces
        self.dark = dark
    }
}

/// Editor font resolution and the list of installed fixed-pitch families.
enum EditorFonts {
    /// The editor font: `family` when installed, otherwise the system monospaced font.
    ///
    /// Programming fonts (Fira Code, JetBrains Mono, Iosevka, Monaspace…) draw their
    /// ligatures through contextual alternates (`calt`), which `.ligature` does not control,
    /// so with ligatures off the font also turns contextual alternates and common ligatures off.
    static func font(family: String?, size: CGFloat, ligatures: Bool) -> NSFont {
        var font = family.flatMap { NSFontManager.shared.font(withFamily: $0, traits: [], weight: 5, size: size) }
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        if !ligatures {
            let descriptor = font.fontDescriptor.addingAttributes([.featureSettings: [
                [NSFontDescriptor.FeatureKey.typeIdentifier: kContextualAlternatesType, NSFontDescriptor.FeatureKey.selectorIdentifier: kContextualAlternatesOffSelector],
                [NSFontDescriptor.FeatureKey.typeIdentifier: kLigaturesType, NSFontDescriptor.FeatureKey.selectorIdentifier: kCommonLigaturesOffSelector],
            ]])
            font = NSFont(descriptor: descriptor, size: size) ?? font
        }
        return font
    }

    /// Whether a font family is installed.
    static func isInstalled(_ family: String) -> Bool {
        NSFontManager.shared.availableMembers(ofFontFamily: family)?.isEmpty == false
    }

    /// Installed fixed-pitch font families, sorted (hidden system families excluded).
    /// Uses Core Text, so it can run off the main thread.
    nonisolated static func monospacedFamilies() -> [String] {
        let names = (CTFontManagerCopyAvailableFontFamilyNames() as? [String]) ?? []
        let families = names.filter { !$0.hasPrefix(".") && isFixedPitch(family: $0) }
        return Array(Set(families)).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// The monospace trait, or (because fonts such as JetBrains Mono and Hack don't set it)
    /// equal advances for narrow and wide characters.
    nonisolated private static func isFixedPitch(family: String) -> Bool {
        let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary)
        let font = CTFontCreateWithFontDescriptor(descriptor, 12, nil)
        if CTFontGetSymbolicTraits(font).contains(.traitMonoSpace) { return true }
        let sample = Array("il.MW0_".utf16)
        var glyphs = [CGGlyph](repeating: 0, count: sample.count)
        guard CTFontGetGlyphsForCharacters(font, sample, &glyphs, sample.count) else { return false }
        var advances = [CGSize](repeating: .zero, count: sample.count)
        CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advances, sample.count)
        guard let first = advances.first?.width, first > 0 else { return false }
        return advances.allSatisfy { abs($0.width - first) < 0.01 }
    }
}
