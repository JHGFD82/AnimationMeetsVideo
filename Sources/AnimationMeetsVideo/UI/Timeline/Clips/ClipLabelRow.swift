import SwiftUI

/// A clip's name and the marks beside it: what kind of source it is, its
/// sound, effects, paste changes, pass through, time and shutter settings.
/// Nothing in it depends on zoom, so the block marks it `.equatable()` and
/// a zoom redraws every clip's shape without building its label again.
struct ClipLabelRow: View, Equatable {
    var name: String
    var isNestedTimeline: Bool
    var isAudioStream: Bool
    var hasLinkedAudio: Bool
    var effectCount: Int
    var hasPasteChanges: Bool
    var passesThrough: Bool
    /// The clock's help text, nil for a clip with default time settings.
    var timeHelp: String?
    var hasShutter: Bool

    var body: some View {
        HStack(spacing: Design.Space.tight) {
            if isNestedTimeline {
                Image(systemName: "rectangle.stack")
                    .font(Design.Typeface.micro)
            } else if isAudioStream {
                Image(systemName: "waveform")
                    .font(Design.Typeface.micro)
            }
            Text(name)
                .font(Design.Typeface.label)
                .lineLimit(1)
                .layoutPriority(-1)
            HStack(spacing: Design.Space.tight) {
                if hasLinkedAudio {
                    Image(systemName: "speaker.wave.2.fill")
                        .font(Design.Typeface.micro)
                        .help("Plays its own sound; show it with the layer's waveform button")
                }
                if effectCount > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "wand.and.stars")
                        Text("\(effectCount)").font(Design.Typeface.numericMicro)
                    }
                    .font(Design.Typeface.micro)
                    .help("\(effectCount) effect\(effectCount == 1 ? "" : "s") in its stacks")
                }
                if hasPasteChanges {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(Design.Typeface.micro)
                        .help("Effects pasted onto this clip have changes to resolve before it can be exported")
                }
                if passesThrough {
                    Image(systemName: "square.stack.3d.down.right")
                        .font(Design.Typeface.micro)
                        .help("Passes through: its layers are drawn into the timeline it is placed in")
                }
                if let timeHelp {
                    Image(systemName: "clock")
                        .font(Design.Typeface.micro)
                        .help(timeHelp)
                }
                if hasShutter {
                    Image(systemName: "camera.aperture")
                        .font(Design.Typeface.micro)
                        .help("Motion blur or trails")
                }
            }
            // Quieter than the name, but no lower than 90%:
            // dimmer fails 4.5:1 on the fill (see `clipFill`).
            .foregroundStyle(Design.textOnColor.opacity(0.9))
        }
        .foregroundStyle(Design.textOnColor)
    }
}
