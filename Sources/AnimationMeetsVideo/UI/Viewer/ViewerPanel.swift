import SwiftUI

/// The viewer: the picture, its notices, and the transport under it.
///
/// Nothing in this body reads the player's time, which changes 30 times a
/// second while playing; reading it here would rebuild the whole panel,
/// menus and overlays included, on every tick. The two things that show
/// the time are views of their own (`ViewerPicture`, `ViewerTimecode`),
/// so only they follow it.
struct ViewerPanel: View {
    let playback: PlaybackModel
    let hasContent: Bool
    let frameSize: CGSize
    let frameRate: Double
    let buildError: String?
    /// Which files are missing, shown at the foot of the picture while
    /// their clips play as gaps.
    var offlineNotice: String?
    /// A slipped clip's first and last frames, shown over the picture.
    let trimPreview: TrimPreviewModel
    /// Says the picture isn't the finished timeline, with a way back
    /// (Show Up to Here).
    var banner: String?
    var onClearBanner: () -> Void = {}
    /// A clip skimmed in the browser, shown in place of the timeline;
    /// absent in windows without a browser.
    @Environment(BrowserSkim.self) private var skim: BrowserSkim?

    private var isSkimming: Bool { skim?.isActive ?? false }

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
                    picture { ViewerPicture(playback: playback, frameRate: frameRate) }
                } else {
                    picture { MetalPreviewView() }
                    ContentUnavailableView("No clips yet", systemImage: "film",
                                           description: Text("Import media into the Clips list (⌘I), then drag a scene onto the timeline."))
                }
                if let skim, skim.isActive {
                    SkimPicture(skim: skim)
                        .padding(36)
                }
                if trimPreview.isActive {
                    TrimPreviewOverlay(model: trimPreview, frameRate: frameRate, aspectRatio: aspectRatio)
                        .padding(24)
                }
                if let banner {
                    HStack(spacing: Design.Space.close) {
                        Image(systemName: "eye")
                        Text(banner).font(Design.Typeface.bodyEmphasis)
                        Button("Show All", action: onClearBanner)
                            .controlSize(.small)
                    }
                    .padding(.horizontal, Design.Space.step)
                    .padding(.vertical, Design.Space.tight)
                    .background(Design.statusWarning.opacity(0.92), in: Capsule())
                    .foregroundStyle(Color.black.opacity(0.85))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, 10)
                }
                if let offlineNotice {
                    Label(offlineNotice, systemImage: "externaldrive.badge.exclamationmark")
                        .font(Design.Typeface.label)
                        .foregroundStyle(Design.textPrimary)
                        .padding(.horizontal, Design.Space.step)
                        .padding(.vertical, Design.Space.tight)
                        .beveledChip(fill: Design.statusWarning.opacity(0.28))
                        .frame(maxHeight: .infinity, alignment: .bottom)
                        .padding(.bottom, Design.Space.group)
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
                // While a clip is skimmed, Space plays it rather than the
                // timeline.
                let playing = isSkimming ? skim?.isPlaying == true : playback.isPlaying
                Button {
                    if let skim, skim.isActive { skim.togglePlay() } else { playback.togglePlayback() }
                } label: {
                    Image(systemName: playing ? Design.Symbol.pause : Design.Symbol.play)
                        .frame(width: 20)
                        .contentTransition(.symbolEffect(.replace))
                }
                .keyboardShortcut(.space, modifiers: [])
                .help(isSkimming ? "Play/Pause the skimmed clip (Space)" : "Play/Pause (Space)")
                .accessibilityLabel(playing ? "Pause" : "Play")
                .disabled(!hasContent && !isSkimming)

                ViewerTimecode(playback: playback, frameRate: frameRate)
                Spacer()
                Menu {
                    Toggle("Motion Blur in Preview", isOn: Binding(
                        get: { playback.motionBlurInPreview },
                        set: { playback.motionBlurInPreview = $0 }
                    ))
                } label: {
                    Image(systemName: Design.Symbol.viewOptions)
                }
                .menuStyle(.borderlessButton)
                // A borderless menu draws its glyph in the tint; quiet it
                // to match the other icon buttons.
                .tint(Design.textSecondary)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Preview options. Motion Blur in Preview draws clips' motion blur in the viewer; export and renders always draw it.")
                qualityMenu
            }
            .padding(.horizontal, Design.Space.rail)
            .padding(.vertical, Design.Space.close)
            .rail(.raised)
        }
        // Skimming takes the viewer, so the timeline stops playing; where
        // its playhead was is kept.
        .onChange(of: isSkimming) { _, skimming in
            if skimming, playback.isPlaying { playback.togglePlayback() }
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

/// The player's picture, with the time as its accessibility value. A view
/// of its own so following the time rebuilds only this.
private struct ViewerPicture: View {
    let playback: PlaybackModel
    let frameRate: Double

    var body: some View {
        PlayerLayerView(player: playback.player, still: playback.cover)
            .accessibilityElement()
            .accessibilityLabel("Viewer")
            .accessibilityValue(playback.currentTime.timecode(frameRate: frameRate))
            .accessibilityAddTraits(.isImage)
    }
}

/// The playhead's timecode under the picture: the one number meant to be
/// read from across the desk. A view of its own so following the time
/// rebuilds only this.
private struct ViewerTimecode: View {
    let playback: PlaybackModel
    let frameRate: Double

    var body: some View {
        Text(playback.currentTime.timecode(frameRate: frameRate))
            .font(Design.Typeface.timecode)
            .foregroundStyle(Design.textPrimary)
    }
}

/// The skimmed clip in the viewer, over the timeline's picture, with its
/// name and the time skimmed to. A view of its own, since the time changes
/// with every move of the pointer.
private struct SkimPicture: View {
    let skim: BrowserSkim

    var body: some View {
        let target = skim.target
        let rate = target?.frameRate ?? 0
        let time = rate > 0 ? skim.sourceTime.timecode(frameRate: rate) : skim.sourceTime.formatted
        ZStack(alignment: .bottom) {
            Color.black
            if target?.hasPictures == true {
                PlayerLayerView(player: skim.player)
            } else {
                Image(systemName: MediaKind.audio.systemImage)
                    .font(.system(size: 40))
                    .foregroundStyle(Design.textTertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack(spacing: Design.Space.close) {
                Text(target?.name ?? "")
                    .font(Design.Typeface.label)
                    .foregroundStyle(Design.textPrimary)
                    .lineLimit(1)
                Text(time)
                    .font(Design.Typeface.numericSmall)
                    .foregroundStyle(Design.textPrimary)
            }
            .padding(.horizontal, Design.Space.step)
            .padding(.vertical, Design.Space.tight)
            .beveledChip(fill: Color.black.opacity(0.6))
            .padding(.bottom, Design.Space.group)
        }
        .accessibilityElement()
        .accessibilityLabel("Viewer, skimming \(target?.name ?? "")")
        .accessibilityValue(time)
        .accessibilityAddTraits(.isImage)
    }
}
