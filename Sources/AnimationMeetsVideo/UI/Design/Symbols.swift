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
        /// Showing a song's beat markers.
        static let beats = "lines.measurement.vertical"
        /// Snapping dragged edges and points to what's near.
        static let snap = "arrow.right.and.line.vertical.and.arrow.left"
        /// Skimming: the frame under the pointer shown as it moves.
        static let skim = "cursorarrow.motionlines"

        static let zoomIn = "plus.magnifyingglass"
        static let zoomOut = "minus.magnifyingglass"
        static let zoomToFit = "arrow.left.and.right.square"
        /// Fit along both axes, as a graph's values and time.
        static let zoomToFitBoth = "arrow.up.left.and.down.right.magnifyingglass"

        /// A popover of how a panel shows things: thumbnails, zoom,
        /// preview quality. Never what the project contains.
        static let viewOptions = "slider.horizontal.2.square"
        /// Settings that change the project: a timeline's frame and rate.
        static let settings = "gearshape"
        static let add = "plus"
        static let close = "xmark"
        static let remove = "minus.circle"
        static let edit = "pencil"
        /// Starting over, and a value put back where it began
        /// (`RowResetButton`): both take back what was changed.
        static let startOver = "arrow.counterclockwise"
        static let undo = "arrow.uturn.backward"
        static let redo = "arrow.uturn.forward"

        /// Showing the viewer full screen on another display.
        static let externalDisplay = "display"

        /// A saved stack of effects, in the library's Presets tab.
        static let preset = "bookmark"

        /// Recording a take onto the timeline.
        static let record = "record.circle"

        /// Something asked for that wasn't done (`RefusalNotice`).
        static let refused = "exclamationmark.circle"
        /// Something that needs a look: a missing file, a failed read, a
        /// paste that changed things, a sheet's warning. Outlined, as the
        /// refusal and the sheets' other callouts are, in every size.
        static let warning = "exclamationmark.triangle"

        /// Bringing another open graph into a graph editor panel.
        static let linkGraph = "link.badge.plus"
        /// Drawing each of a graph's components on a value scale of its
        /// own. Not the text leading's glyph, which looks alike.
        static let separateScales = "ruler"
    }
}
