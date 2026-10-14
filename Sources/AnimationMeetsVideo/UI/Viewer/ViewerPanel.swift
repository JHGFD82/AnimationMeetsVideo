import SwiftUI

struct ViewerPanel: View {
    let playback: PlaybackModel
    let hasContent: Bool
    let frameSize: CGSize
    let frameRate: Double
    let buildError: String?
    /// A rippled clip's first and last frames, shown over the picture.
    let trimPreview: TrimPreviewModel

    // Deliberately darker than the surrounding window chrome and distinct
    // from pure black, so the composition's actual frame boundary stays
    // visible even when the video content itself is black.
    private let backdropColor = Color(white: 0.06)

    private var aspectRatio: CGFloat {
        frameSize.width > 0 && frameSize.height > 0 ? frameSize.width / frameSize.height : 16.0 / 9.0
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                backdropColor
                if hasContent {
                    PlayerLayerView(player: playback.player)
                        .aspectRatio(aspectRatio, contentMode: .fit)
                        .padding(36)
                } else {
                    MetalPreviewView()
                        .aspectRatio(aspectRatio, contentMode: .fit)
                        .padding(36)
                    ContentUnavailableView("No Clips", systemImage: "film")
                }
                if trimPreview.isActive {
                    TrimPreviewOverlay(model: trimPreview, frameRate: frameRate, aspectRatio: aspectRatio)
                        .padding(24)
                }
                if let buildError {
                    Label(buildError, systemImage: "exclamationmark.triangle.fill")
                        .padding(10)
                        .background(.red.opacity(0.85), in: RoundedRectangle(cornerRadius: 8))
                        .foregroundStyle(.white)
                        .padding(48)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack(spacing: 12) {
                Button {
                    playback.togglePlayback()
                } label: {
                    Image(systemName: playback.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 20)
                }
                .keyboardShortcut(.space, modifiers: [])
                .help("Play/Pause (Space)")
                .disabled(!hasContent)

                Text(playback.currentTime.timecode(frameRate: frameRate))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                qualityMenu
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Color(nsColor: .windowBackgroundColor))
        }
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
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .offset(x: -18)
            }
        }
        .help("Viewer quality. Smaller sizes play complex timelines smoothly; Auto draws full size when paused and steps down only while playback can't keep up.")
    }
}
