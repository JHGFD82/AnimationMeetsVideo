/// The symbols for commands that appear in more than one place.
///
/// One symbol, one meaning: the same command shows the same glyph in every
/// panel, and no glyph stands for two things. Before these were named, the
/// adjustment layer's glyph also opened the library's thumbnail settings,
/// the colour effects' glyph also opened the timeline's view options, and
/// a transition's glyph opened the viewer's preview options. Symbols for
/// what a thing *is* (a clip kind, an effect category, a transition) stay
/// with the model type; these are for what a button *does*.
extension Design {
    enum Symbol {
        static let play = "play.fill"
        static let pause = "pause.fill"
        static let loop = "repeat"
        /// The beat tick.
        static let tick = "metronome"

        static let zoomIn = "plus.magnifyingglass"
        static let zoomOut = "minus.magnifyingglass"
        static let zoomToFit = "arrow.left.and.right.square"

        /// A popover of how a panel shows things: thumbnails, zoom,
        /// preview quality. Never what the project contains.
        static let viewOptions = "slider.horizontal.2.square"
        /// Settings that change the project: a timeline's frame and rate.
        static let settings = "gearshape"
        static let add = "plus"
        static let close = "xmark"
        static let remove = "minus.circle"
        static let edit = "pencil"
        static let startOver = "arrow.counterclockwise"

        /// Showing the viewer full screen on another display.
        static let externalDisplay = "display"

        /// A saved stack of effects, in the library's Presets tab.
        static let preset = "bookmark"
    }
}
