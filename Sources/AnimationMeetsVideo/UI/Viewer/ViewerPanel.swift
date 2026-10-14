import SwiftUI

struct ViewerPanel: View {
    let playback: PlaybackModel
    let hasContent: Bool
    let frameSize: CGSize
    let frameRate: Double
    let buildError: String?
    /// A slipped clip's first and last frames, shown over the picture.
    let trimPreview: TrimPreviewModel

    private var aspectRatio: CGFloat {
        frameSize.width > 0 && frameSize.height > 0 ? frameSize.width / frameSize.height : 16.0 / 9.0
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                // The well is the darkest surface in the app and the only
                // one with nothing behind it, so the composition's own
                // frame edge stays visible even on a black frame.
                Design.Surface.well.color
                if hasContent {
                    picture { PlayerLayerView(player: playback.player) }
                } else {
                    picture { MetalPreviewView() }
                    ContentUnavailableView("No clips yet", systemImage: "film",
                                           description: Text("Drag a scene from the library onto the timeline."))
                }
                if trimPreview.isActive {
                    TrimPreviewOverlay(model: trimPreview, frameRate: frameRate, aspectRatio: aspectRatio)
                        .padding(24)
                }
                if let buildError {
                    Label(buildError, systemImage: "exclamationmark.triangle.fill")
                        .font(Design.Typeface.body)
                        .padding(Design.Space.group)
                        .background(Design.statusDanger.opacity(0.92), in: RoundedRectangle(cornerRadius: Design.Radius.panel, style: .continuous))
                        .foregroundStyle(Design.textOnColor)
                        .padding(48)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: Design.Space.group) {
                Button {
                    playback.togglePlayback()
                } label: {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 20)
                        .contentTransition(.symbolEffect(.replace))
                }
                .keyboardShortcut(.space, modifiers: [])
                .help("Play/Pause (Space)")
                .disabled(!hasContent)

                // The one number meant to be read from across the desk.
                Text(playback.currentTime.timecode(frameRate: frameRate))
                    .font(Design.Typeface.timecode)
                    .foregroundStyle(Design.textPrimary)
                Spacer()
                qualityMenu
            }
            .padding(.horizontal, Design.Space.rail)
            .padding(.vertical, Design.Space.close)
            .rail(.raised)
        }
    }

    /// The composition, inset from the well with a cut edge so the frame
    /// boundary reads whatever the content is. Deliberately no drop
    /// shadow: it would force the video surface through an offscreen pass
    /// on every frame, and the hairline already does the job.
    private func picture<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .aspectRatio(aspectRatio, contentMode: .fit)
            .overlay {
                Rectangle()
                    .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .padding(36)
    }

    /// Auto shows the size it's drawing at while that isn't full.
    private var qualityMenu: some View {
        Picker(selection: Binding(get: { playback.quality }, set: { playback.quality = $0 })) {
            ForEach(PreviewQuality.allCases) { quality in
                Text(quality.label).tag(quality)
            }
        } label: {
            EmptyView()
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .fixedSize()
        .overlay(alignment: .leading) {
            if playback.quality == .auto, playback.level != .full {
                Text(playback.level.label)
                    .font(Design.Typeface.numericSmall)
                    .foregroundStyle(Design.statusWarning)
                    .offset(x: -18)
            }
        }
        .help("Viewer quality. Smaller sizes play complex timelines smoothly; Auto draws full size when paused and steps down only while playback can't keep up.")
    }
}
