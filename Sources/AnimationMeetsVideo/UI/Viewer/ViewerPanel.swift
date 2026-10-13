import SwiftUI

struct ViewerPanel: View {
    let playback: PlaybackModel
    let hasContent: Bool
    let frameSize: CGSize
    let frameRate: Double
    let buildError: String?

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
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Color(nsColor: .windowBackgroundColor))
        }
    }
}
