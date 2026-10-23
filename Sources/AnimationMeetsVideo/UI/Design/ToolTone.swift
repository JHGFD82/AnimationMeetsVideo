import SwiftUI

extension Design {
    /// Each tool with a timeline of its own, beside the main one, set apart
    /// by a tone: a glyph at the start of its header and a hairline along
    /// the top of its time area (`toolEdge`). Everything else — the ruler,
    /// the playhead, the zoom controls — is the main timeline's, so going
    /// from one to another feels like the same editor in another room.
    ///
    /// Hue means category (see `Design`), so a tool's tone is the clip
    /// tone of what it shapes, not a new colour: the scene splitter cuts
    /// video, the beat matcher maps music, the motion designer shapes
    /// motion as graphics are, and the graph editor shapes effects as
    /// adjustment layers carry them. The main timeline, where they all
    /// come back to, has none.
    enum ToolTone {
        case sceneSplitter, beatMatcher, motionDesigner, graphEditor

        var color: Color {
            switch self {
            case .sceneSplitter: ClipTone.video.color
            case .beatMatcher: ClipTone.music.color
            case .motionDesigner: ClipTone.graphic.color
            case .graphEditor: ClipTone.adjustment.color
            }
        }

        var systemImage: String {
            switch self {
            case .sceneSplitter: "scissors"
            case .beatMatcher: "metronome"
            case .motionDesigner: "point.topleft.down.to.point.bottomright.curvepath"
            case .graphEditor: "chart.xyaxis.line"
            }
        }

        /// The tool's name, which its window's title also starts with.
        var name: String {
            switch self {
            case .sceneSplitter: "Scene Splitter"
            case .beatMatcher: "Beat Match"
            case .motionDesigner: "Motion Designer"
            case .graphEditor: "Graph Editor"
            }
        }
    }
}

/// The tool's glyph in its tone, at the start of its header. Decoration:
/// the window's title already names the tool, so VoiceOver skips it.
struct ToolGlyph: View {
    let tone: Design.ToolTone

    var body: some View {
        Image(systemName: tone.systemImage)
            .font(Design.Typeface.icon)
            .foregroundStyle(tone.color)
            .frame(width: 18)
            .help(tone.name)
            .accessibilityHidden(true)
    }
}

extension View {
    /// A hairline in the tool's tone along the top of its time area.
    func toolEdge(_ tone: Design.ToolTone) -> some View {
        overlay(alignment: .top) {
            Rectangle()
                .fill(tone.color.opacity(0.7))
                .frame(height: 2)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }
}
