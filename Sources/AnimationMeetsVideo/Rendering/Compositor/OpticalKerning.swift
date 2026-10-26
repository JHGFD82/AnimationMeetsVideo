import CoreGraphics
import CoreText
import Foundation
import Synchronization

/// Optical kerning: spacing each pair of letters from their shapes rather
/// than the font's kerning pairs, as Illustrator's Optical kerning does
/// (see docs/graphic-layers.md, "Optical kerning"). Core Text has none.
///
/// Each glyph's side profiles are found once: in each of `bands`
/// horizontal bands across the font's height, how far in from its left
/// and right edges its ink starts. The space between two letters is the
/// mean over the bands of the gap between the first's right ink and the
/// second's left ink, a band where either has no ink counting as
/// `openGap` (so the open side of a "T" or "L" doesn't count as a gulf).
/// Each pair is then moved so its space matches a reference pair's: "HH"
/// between capitals, "nn" otherwise, so "AV" and "To" close up and "HH"
/// stays as the font's designer spaced it.
enum OpticalKerning {
    /// Horizontal bands a glyph's height is measured in.
    static let bands = 48
    /// A band where a letter has no ink counts as this much space, in ems.
    static let openGap = 0.25
    /// No pair moves more than this, in ems.
    static let limit = 0.15

    /// One glyph's ink, band by band from the top: how far its leftmost
    /// and rightmost ink are from its origin, in ems; nil where it has
    /// none. And its advance in ems.
    struct Profile: Sendable {
        var left: [Double?]
        var right: [Double?]
        var advance: Double
    }

    /// How far, in pixels, the second of two letters should move toward
    /// (below 0) or away from the first, both in `font`.
    static func adjustment(_ first: CGGlyph, _ second: CGGlyph, in font: CTFont, capitals: Bool) -> Double {
        let size = CTFontGetSize(font)
        guard size > 0 else { return 0 }
        let a = profile(first, font), b = profile(second, font)
        let reference = referencePair(font, capitals: capitals)
        let target = space(reference.0, reference.1)
        let measured = space(a, b)
        return ((target - measured).clamped(between: -limit, and: limit)) * size
    }

    /// The mean space between `a`'s right ink and `b`'s left ink, set
    /// side by side by `a`'s advance, in ems.
    static func space(_ a: Profile, _ b: Profile) -> Double {
        var total = 0.0, counted = 0
        for band in 0..<bands {
            let gap: Double
            if let right = a.right[band], let left = b.left[band] {
                gap = min(openGap, (a.advance - right) + left)
            } else if a.right[band] == nil, b.left[band] == nil {
                // Neither letter reaches this height.
                continue
            } else {
                gap = openGap
            }
            total += gap
            counted += 1
        }
        return counted > 0 ? total / Double(counted) : 0
    }

    private static func referencePair(_ font: CTFont, capitals: Bool) -> (Profile, Profile) {
        var characters: [UniChar] = Array((capitals ? "H" : "n").utf16)
        var glyph = CGGlyph(0)
        CTFontGetGlyphsForCharacters(font, &characters, &glyph, 1)
        let profile = profile(glyph, font)
        return (profile, profile)
    }

    /// Profiles found so far, by font, size and glyph.
    private static let profiles = Mutex<[String: Profile]>([:])

    /// `glyph`'s profile in `font`, rasterized once.
    static func profile(_ glyph: CGGlyph, _ font: CTFont) -> Profile {
        let matrix = CTFontGetMatrix(font)
        let key = "\(CTFontCopyPostScriptName(font)) \(CTFontGetSize(font)) \(matrix.a) \(matrix.d) \(glyph)"
        if let known = profiles.withLock({ $0[key] }) { return known }
        let made = rasterizedProfile(glyph, font)
        profiles.withLock { cache in
            if cache.count > 4096 { cache.removeAll() }
            cache[key] = made
        }
        return made
    }

    /// Draws the glyph's outline into a bitmap `bands` rows tall spanning
    /// the font's ascent and descent, and reads each row's ink from either
    /// side.
    private static func rasterizedProfile(_ glyph: CGGlyph, _ font: CTFont) -> Profile {
        let size = CTFontGetSize(font)
        var glyphCopy = glyph
        var advance = CGSize.zero
        CTFontGetAdvancesForGlyphs(font, .horizontal, &glyphCopy, &advance, 1)
        let empty = Profile(left: Array(repeating: nil, count: bands), right: Array(repeating: nil, count: bands), advance: advance.width / size)
        guard let outline = CTFontCreatePathForGlyph(font, glyph, nil) else { return empty }
        let ascent = CTFontGetAscent(font), descent = CTFontGetDescent(font)
        let height = ascent + descent
        let box = outline.boundingBoxOfPath
        guard height > 0, !box.isEmpty else { return empty }
        // A pixel per band row, and as many across as keep pixels square.
        let scale = Double(bands) / height
        let left = min(0, box.minX), right = max(advance.width, box.maxX)
        let width = max(1, Int(((right - left) * scale).rounded(.up)) + 2)
        var pixels = [UInt8](repeating: 0, count: width * bands)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: bands, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            // Bitmap rows run from the bottom; the descent sits at row 0.
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -left + 1 / scale, y: descent)
            context.addPath(outline)
            context.setFillColor(gray: 1, alpha: 1)
            context.fillPath()
            return true
        }
        guard drawn else { return empty }
        var lefts = [Double?](repeating: nil, count: bands), rights = lefts
        for band in 0..<bands {
            // The bitmap's memory starts with its top row.
            let row = pixels[(band * width)..<((band + 1) * width)]
            guard let first = row.firstIndex(where: { $0 > 127 }), let last = row.lastIndex(where: { $0 > 127 }) else { continue }
            let x0 = Double(first - band * width), x1 = Double(last - band * width + 1)
            lefts[band] = (x0 / scale + left - 1 / scale) / size
            rights[band] = (x1 / scale + left - 1 / scale) / size
        }
        return Profile(left: lefts, right: rights, advance: advance.width / size)
    }
}
