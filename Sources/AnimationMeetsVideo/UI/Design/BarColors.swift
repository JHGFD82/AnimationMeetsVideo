import AppKit
import SwiftUI

// Drawing the colors a person gives bars (docs/bar-colors.md, "Drawing").
extension Design {
    static func color(_ color: BarColor) -> Color {
        let c = color.components
        return Color(.sRGB, red: c.red, green: c.green, blue: c.blue)
    }

    /// The tone a clip is drawn in: its own color, else its tone by kind,
    /// a Music layer's being the music tone. The one place this is decided,
    /// so the timeline and the Motion Designer can't disagree.
    static func tone(of clip: TimelineClip, info: ResolvedClipInfo?, on kind: LayerKind) -> Color {
        if let color = clip.color { return Design.color(color) }
        return kind == .music ? ClipTone.music.color : ClipTone.of(info, streams: clip.streams).color
    }

    /// What is under a bar where its label sits.
    enum InkSurface {
        /// The track area's rows: `Surface.sunken`.
        case track
        /// The time rail's lanes (sections, the loop bar): their black at
        /// 22% over `Surface.raised`.
        case rail
    }

    /// The color of a bar's name and glyphs. A bar with no color of its
    /// own keeps `textOnColor`, checked against the default tones. On a
    /// color the person gave it, white or black, whichever stands out
    /// more from the fill as drawn where the label sits (`clipFill`'s top
    /// stop over `surface`): white text can't be read on a pale color.
    /// Pure white, not `textOnColor`, so the better of the two holds 4.5:1
    /// whatever the color.
    static func ink(on color: BarColor?, selected: Bool, enabled: Bool = true, over surface: InkSurface) -> Color {
        guard let color else { return textOnColor }
        let contrast = inkContrast(on: color, selected: selected, enabled: enabled, over: surface)
        return contrast.white >= contrast.black ? .white : .black
    }

    /// The contrast of white and black text with `color` drawn as a bar's
    /// fill over `surface`, for `ink` and its tests.
    static func inkContrast(on color: BarColor, selected: Bool, enabled: Bool = true, over surface: InkSurface) -> (white: Double, black: Double) {
        var tone = color.components
        if !enabled {
            // As `Color.greyed()`: its luma, in every channel.
            let luma = 0.2126 * tone.red + 0.7152 * tone.green + 0.0722 * tone.blue
            tone = (luma, luma, luma)
        }
        // `clipFill`'s top stop: the tone at 62%, or selected, darkened to
        // 78.6% at 93.6%.
        let scale = selected ? 0.786 : 1
        let alpha = selected ? 0.936 : 0.62
        let under = surfaceComponents(surface)
        func blend(_ top: Double, _ bottom: Double) -> Double { top * scale * alpha + bottom * (1 - alpha) }
        let luminance = BarColor.luminance(
            red: blend(tone.red, under.red), green: blend(tone.green, under.green), blue: blend(tone.blue, under.blue)
        )
        return (BarColor.contrast(1, luminance), BarColor.contrast(0, luminance))
    }

    private static func surfaceComponents(_ surface: InkSurface) -> (red: Double, green: Double, blue: Double) {
        func srgb(_ color: Color) -> (red: Double, green: Double, blue: Double) {
            guard let c = NSColor(color).usingColorSpace(.sRGB) else { return (0.1, 0.1, 0.1) }
            return (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
        }
        switch surface {
        case .track:
            return srgb(Surface.sunken.color)
        case .rail:
            // The lane's black at 22% over the raised rail.
            let raised = srgb(Surface.raised.color)
            return (raised.red * 0.78, raised.green * 0.78, raised.blue * 0.78)
        }
    }
}
