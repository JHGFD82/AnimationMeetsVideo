import SwiftUI

/// The editor's visual vocabulary, in one place.
///
/// The app is dark-only on purpose, not as a style: a picture can only be
/// judged against a neutral, dim surround, so the chrome around the viewer
/// is a fixed low-lightness grey rather than whatever the system appearance
/// happens to be. `EditorView` pins the appearance; everything here assumes
/// it.
///
/// Three rules hold the look together:
///
/// 1. **Depth means function.** Surfaces run on one ladder from `well` (the
///    viewer backdrop) up to `floating` (sheets). Anything you *operate*
///    — rails, headers, buttons — sits on a raised surface with a bevel.
///    Anything you *look into* — the picture, the track area — is sunken.
///    `Surfaces.swift` turns a level into pixels.
/// 2. **Hue means category.** Clips are a cool family at matched lightness
///    so no clip type shouts over another; everything that marks a *time*
///    (playhead, snap, beats, keyframes) is one warm family at three
///    brightnesses; structure and status are desaturated so they stay
///    ambient. Nothing else gets a colour.
/// 3. **Quantities are monospaced.** Any number that can change under the
///    pointer — timecode, frame counts, field values — is set in `Font`'s
///    mono faces so it doesn't jitter while it updates.
enum Design {

    // MARK: - Surfaces

    /// The depth ladder. Each step is a near-constant lightness ratio with
    /// a slight blue cast, so stacked panels separate without any one
    /// reading as tinted.
    enum Surface {
        /// Behind the picture, and behind nothing else.
        case well
        /// Recessed areas you look into: the track area, list bodies.
        case sunken
        /// The body of a panel.
        case base
        /// Rails and headers: the things you operate.
        case raised
        /// Popovers and inspector groups, lifted off a panel.
        case overlay
        /// Sheets, which float over everything.
        case floating

        var color: Color {
            switch self {
            case .well: Design.hex(0x0E1013)
            case .sunken: Design.hex(0x14171B)
            case .base: Design.hex(0x1B1F24)
            case .raised: Design.hex(0x232830)
            case .overlay: Design.hex(0x2B313A)
            case .floating: Design.hex(0x343B45)
            }
        }
    }

    /// The dark line between surfaces. Paired with `bevelLight` below it,
    /// this is the groove that separates layers and panels.
    static let hairline = hex(0x0B0D10)
    /// The lit top edge of a raised surface.
    static let bevelLight = Color.white.opacity(0.07)
    /// The shaded bottom edge of a raised surface.
    static let bevelShade = Color.black.opacity(0.32)
    /// A stronger highlight, for things that should read as distinctly
    /// proud: clip blocks, the playhead's head, pressed controls.
    static let bevelLightStrong = Color.white.opacity(0.16)

    // MARK: - Ink

    /// Text tones keep at least 4.5:1 contrast (WCAG AA for small text) on
    /// every surface from `well` to `overlay`; most labels here are 10 or
    /// 11 points. `textTertiary` falls a little short on `floating`, so
    /// sheets use `textSecondary` for their notes.
    static let textPrimary = hex(0xE6E9EE)
    static let textSecondary = hex(0xA8B1BD)
    static let textTertiary = hex(0x939EAC)
    /// On a saturated fill — a selected clip, a prominent button.
    static let textOnColor = hex(0xF7F9FC)

    // MARK: - Accent

    /// Selection, focus and drop targets. A cool blue, chosen to stay
    /// legible against all three clip hues and to sit opposite the warm
    /// time family so a selected clip never reads as a time marker.
    static let accent = hex(0x4C8DFF)
    static let accentMuted = hex(0x2F5BA8)
    /// The accent as a button's fill, darkened so the white title on it
    /// reads at 4.9:1; the accent itself gives only 3.2:1. Filled buttons
    /// take it with `.tint`, and everything else keeps the accent.
    static let accentFill = hex(0x3B6EC7)

    // MARK: - Clips

    /// Clip fills, at matched perceptual lightness and chroma so a timeline
    /// of mixed types reads as one material in three tints.
    enum ClipTone {
        /// `audio` is sound; `music` is audio on a music layer, a greener
        /// neighbour of it so the two audio areas tell apart at a glance.
        case video, nested, audio, music, adjustment, graphic, unknown

        var color: Color {
            switch self {
            case .video: Design.hex(0x7C6BD6)
            case .nested: Design.hex(0x5B7BD5)
            case .audio: Design.hex(0x3F9E9A)
            case .music: Design.hex(0x5E9E4C)
            case .adjustment: Design.hex(0xB6609E)
            case .graphic: Design.hex(0xA86A28)
            case .unknown: Design.hex(0x6A7280)
            }
        }
    }

    // MARK: - Time

    /// Where you are. The hottest colour in the app, used nowhere else.
    static let playhead = hex(0xFF5A4D)
    /// Where an edge just caught. Bright, brief.
    static let snap = hex(0xFFC95C)
    /// Beats: the same warm family, dimmed so thousands of them stay quiet.
    static let beat = hex(0xE09A3C)
    /// Keyframes share the snap tone — both mean "a moment you placed".
    static let keyframe = hex(0xFFC95C)

    // MARK: - Structure and status

    /// Named sections under the ruler: warm, but bronzed and low-chroma so
    /// they read as labelling rather than as content.
    static let section = hex(0xB08A52)

    static let statusPending = hex(0xC8923A)
    static let statusDone = hex(0x4FA86B)
    static let statusWarning = hex(0xE0A33C)
    static let statusDanger = hex(0xE5564B)

    // MARK: - Metrics

    enum Radius {
        /// Clip blocks, section chips, small chips.
        static let chip: CGFloat = 3
        /// Buttons, tiles, grouped rows.
        static let control: CGFloat = 5
        /// Panels and popovers.
        static let panel: CGFloat = 8
        /// Sheets.
        static let sheet: CGFloat = 12
    }

    enum Space {
        static let hairline: CGFloat = 1
        /// Inside a chip.
        static let tight: CGFloat = 4
        /// Between related controls.
        static let close: CGFloat = 6
        /// Standard gutter inside a rail or row.
        static let step: CGFloat = 8
        /// Between groups in a panel.
        static let group: CGFloat = 12
        /// A rail's horizontal inset.
        static let rail: CGFloat = 14
        /// A sheet's inset.
        static let sheet: CGFloat = 20
        /// The label column every sheet lays its options out against, so
        /// controls line up down a dialog and across the app.
        static let sheetLabelColumn: CGFloat = 116
    }

    /// Widths sheets are allowed to be, so no two dialogs in the app are
    /// three points different from each other.
    enum SheetWidth {
        /// A question with one or two controls.
        static let compact: CGFloat = 400
        /// A form.
        static let standard: CGFloat = 460
        /// A form with a list or preview beside it.
        static let wide: CGFloat = 580
    }

    // MARK: - Type

    /// The scale. Sizes come from the macOS control metrics the app already
    /// lays out to; the weights and the mono rule are what carry the voice.
    enum Typeface {
        /// A sheet's title.
        static let title = Font.system(size: 15, weight: .semibold)
        /// A panel's name on its rail: "Library", "Timeline".
        static let panelTitle = Font.system(size: 12, weight: .semibold)
        /// A group heading inside a panel or sheet.
        static let groupTitle = Font.system(size: 11, weight: .semibold)
        static let body = Font.system(size: 12)
        static let bodyEmphasis = Font.system(size: 12, weight: .medium)
        static let label = Font.system(size: 11)
        static let micro = Font.system(size: 10)

        /// Rule: a number that can change under the pointer is monospaced.
        static let numeric = Font.system(size: 12, design: .monospaced)
        static let numericSmall = Font.system(size: 11, design: .monospaced)
        static let numericMicro = Font.system(size: 10, design: .monospaced)
        /// The viewer's running timecode: the one number big enough to read
        /// across the desk.
        static let timecode = Font.system(size: 13, weight: .medium, design: .monospaced)

        /// The start window's heading: the only text set larger than a
        /// sheet's title.
        static let display = Font.system(size: 19, weight: .semibold)
        /// Tiny labels drawn on the work itself: a layer's badge, a beat's
        /// number in its tag. Below 10 points, so only for a word or a
        /// figure that the shape around it also explains.
        static let tag = Font.system(size: 9, weight: .semibold)
        static let numericTag = Font.system(size: 9, weight: .bold, design: .monospaced)
        /// Two figures in a tag sized for one.
        static let numericTagCompact = Font.system(size: 8, weight: .bold, design: .monospaced)
        /// Scale readings on graphs and meters, which sit on the drawing.
        static let numericScale = Font.system(size: 9, design: .monospaced)

        /// Glyphs. `icon` is an icon button's symbol; `glyphSmall` and
        /// `glyphTiny` are disclosure chevrons and markers inside rows,
        /// sized to sit on a 10 or 11 point line.
        static let icon = Font.system(size: 13)
        static let glyphLarge = Font.system(size: 15)
        static let glyphSmall = Font.system(size: 9)
        static let glyphTiny = Font.system(size: 8)
    }

    // MARK: -

    static func hex(_ value: UInt32) -> Color {
        Color(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}

extension Design.ClipTone {
    /// The tone a clip is drawn in, from what it resolves to. Detached or
    /// audio-only streams of a video follow the audio tone, so what you
    /// hear and what you see are told apart by colour on every layer.
    static func of(_ info: ResolvedClipInfo?, streams: ClipStreams) -> Design.ClipTone {
        switch info {
        case .media(let mediaClip):
            switch mediaClip.kind {
            case .video: streams == .audio ? .audio : .video
            case .audio: .audio
            case .image: .video
            }
        case .timeline: .nested
        case .adjustment: .adjustment
        case .graphic: .graphic
        case nil: .unknown
        }
    }
}
