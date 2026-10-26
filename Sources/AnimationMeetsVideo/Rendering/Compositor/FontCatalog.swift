import CoreText
import Foundation
import Synchronization

/// The fonts installed on this Mac, by family and style, for picking a
/// Text effect's font.
enum FontCatalog {
    /// One style of a family: its PostScript name, which a Text effect
    /// keeps, and what the family calls it ("Bold Italic").
    struct Style: Hashable, Identifiable {
        var fontName: String
        var name: String
        var id: String { fontName }
    }

    /// Every family that can be picked, in alphabetical order. The
    /// system's hidden ones (named with a leading dot) are left out.
    static func families() -> [String] {
        let names = CTFontManagerCopyAvailableFontFamilyNames() as? [String] ?? []
        return names.filter { !$0.hasPrefix(".") }.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// A family's styles, lightest first, upright before italic.
    static func styles(ofFamily family: String) -> [Style] {
        let descriptor = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary)
        let matches = CTFontDescriptorCreateMatchingFontDescriptors(descriptor, nil) as? [CTFontDescriptor] ?? []
        let styles = matches.compactMap { match -> (style: Style, weight: Double, slanted: Bool)? in
            guard let name = CTFontDescriptorCopyAttribute(match, kCTFontNameAttribute) as? String else { return nil }
            let styleName = CTFontDescriptorCopyAttribute(match, kCTFontStyleNameAttribute) as? String ?? name
            let traits = CTFontDescriptorCopyAttribute(match, kCTFontTraitsAttribute) as? [CFString: Any] ?? [:]
            let weight = (traits[kCTFontWeightTrait] as? NSNumber)?.doubleValue ?? 0
            let symbolic = (traits[kCTFontSymbolicTrait] as? NSNumber)?.uint32Value ?? 0
            let slanted = symbolic & CTFontSymbolicTraits.traitItalic.rawValue != 0
            return (Style(fontName: name, name: styleName), weight, slanted)
        }
        var seen = Set<String>()
        return styles
            .sorted { ($0.weight, $0.slanted ? 1 : 0, $0.style.name) < ($1.weight, $1.slanted ? 1 : 0, $1.style.name) }
            .map(\.style)
            .filter { seen.insert($0.fontName).inserted }
    }

    /// Whether the font named `fontName` is installed. When it isn't, Core
    /// Text draws with a substitute, whose name differs.
    static func isInstalled(_ fontName: String) -> Bool {
        let font = CTFontCreateWithName(fontName as CFString, 12, nil)
        return CTFontCopyPostScriptName(font) as String == fontName
    }

    /// The family and style of the font named `fontName`, as a Text effect's
    /// font is shown: what Core Text substitutes when it isn't installed.
    static func familyAndStyle(of fontName: String) -> (family: String, style: String) {
        let font = CTFontCreateWithName(fontName as CFString, 12, nil)
        let family = CTFontCopyFamilyName(font) as String
        let style = CTFontCopyName(font, kCTFontStyleNameKey).map { $0 as String } ?? ""
        return (family, style)
    }

    /// Whether the font named `fontName` has the OpenType feature `tag`
    /// ("smcp", "sups"). Core Text keeps only the features a font has, so a
    /// copy of it asked for the feature says.
    static func supports(_ fontName: String, feature tag: String) -> Bool {
        let key = "\(fontName) \(tag)"
        if let known = features.withLock({ $0[key] }) { return known }
        let base = CTFontCreateWithName(fontName as CFString, 12, nil)
        let asked = CTFontDescriptorCreateWithAttributes([
            kCTFontFeatureSettingsAttribute: [[kCTFontOpenTypeFeatureTag: tag, kCTFontOpenTypeFeatureValue: 1]],
        ] as CFDictionary)
        let settings = CTFontCopyFeatureSettings(CTFontCreateCopyWithAttributes(base, 12, nil, asked)) as? [[CFString: Any]] ?? []
        let has = settings.contains { $0[kCTFontOpenTypeFeatureTag] as? String == tag }
        features.withLock { $0[key] = has }
        return has
    }

    /// What `supports` found, by font and tag.
    private static let features = Mutex<[String: Bool]>([:])

    /// The style of `family` nearest `fontName`'s: the one with the same
    /// style name, or else the first, for when the family is changed.
    static func fontName(inFamily family: String, like fontName: String) -> String? {
        let styles = styles(ofFamily: family)
        let wanted = familyAndStyle(of: fontName).style
        return (styles.first { $0.name == wanted } ?? styles.first { $0.name == "Regular" } ?? styles.first)?.fontName
    }
}
