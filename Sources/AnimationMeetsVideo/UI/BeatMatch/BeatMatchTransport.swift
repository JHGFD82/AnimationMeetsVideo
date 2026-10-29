import SwiftUI

/// The beat match panel's transport. One line whatever the step, so the
/// waveform below never jumps: the tick's pitch and volume open in a
/// popover rather than adding a row. The song's volume, the tick and the
/// zoom are views of their own, so dragging one redraws only it.
struct BeatMatchTransport: View {
    @Bindable var session: BeatMatchSession
    @Binding var frequency: Double
    @Binding var volume: Double

    var body: some View {
        HStack(spacing: Design.Space.group) {
            HStack(spacing: Design.Space.step) {
                ToolGlyph(tone: .beatMatcher)
                Button(action: session.togglePlayback) {
                    Image(systemName: session.isPlaying ? Design.Symbol.pause : Design.Symbol.play)
                        .frame(width: 18)
                }
                .help(session.isPlaying ? "Pause (Space)" : "Play (Space)")
                .accessibilityLabel(session.isPlaying ? "Pause" : "Play")
                // Follows the player on its own, so playing redraws only
                // this: nothing else here reads the frame's date.
                SwiftUI.TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !session.isPlaying)) { context in
                    let time = BeatMatchWaveform.timeText(session.playhead(at: context.date))
                    Text(time)
                        .font(Design.Typeface.timecode)
                        .foregroundStyle(Design.textPrimary)
                        .frame(width: 92, alignment: .leading)
                        .help("Where the song is. With no beat selected, ← → move it a second.")
                        .accessibilityLabel("Playhead")
                        .accessibilityValue(time)
                }
                Toggle(isOn: $session.isLooping) {
                    Image(systemName: Design.Symbol.loop)
                }
                .toggleStyle(.icon)
                .disabled(session.selectedBeat == nil)
                .help(session.selectedBeat == nil
                      ? "Loop the two measures around the selected beat (L). Select a beat first."
                      : "Loop the two measures around the selected beat (L)")
                .accessibilityLabel("Loop around the selected beat")
            }
            Groove(axis: .vertical).frame(height: 18)
            SongVolume(session: session)
            TickControls(session: session, frequency: $frequency, volume: $volume)
            Spacer()
            Zoom(session: session)
        }
        .frame(minHeight: 28)
    }
}

private struct SongVolume: View {
    @Bindable var session: BeatMatchSession

    var body: some View {
        HStack(spacing: Design.Space.close) {
            Image(systemName: "music.note")
                .font(Design.Typeface.icon)
                .foregroundStyle(Design.textSecondary)
                .accessibilityHidden(true)
            Slider(value: $session.songVolume, in: 0...1)
                .controlSize(.small)
                .frame(width: 90)
                .help("The song's volume here; the timeline's mix is untouched")
                .accessibilityLabel("Song volume")
                .accessibilityValue("\(Int((session.songVolume * 100).rounded())) percent")
        }
    }
}

/// The tick and its settings, once there is a beat to tick on.
private struct TickControls: View {
    @Bindable var session: BeatMatchSession
    @Binding var frequency: Double
    @Binding var volume: Double

    @State private var showsSettings = false

    var body: some View {
        if session.hasBeats {
            HStack(spacing: 2) {
                Toggle(isOn: $session.clicksOn) {
                    Image(systemName: Design.Symbol.tick)
                }
                .toggleStyle(.icon)
                .help("Play a tick on every beat; downbeats an octave up")
                .accessibilityLabel("Tick on every beat")
                Button { showsSettings.toggle() } label: {
                    Image(systemName: "chevron.down").font(Design.Typeface.glyphSmall)
                }
                .buttonStyle(.icon)
                .help("The tick's pitch and volume")
                .accessibilityLabel("Tick settings")
                // The arrow on the button's bottom edge: the popover hangs
                // below, into the window, from the transport at its top.
                .popover(isPresented: $showsSettings, arrowEdge: .bottom) {
                    ClickToneControls(frequency: $frequency, volume: $volume) { session.clicks.preview() }
                        .frame(width: 300)
                        .padding(Design.Space.group)
                }
            }
        }
    }
}

private struct Zoom: View {
    @Bindable var session: BeatMatchSession

    var body: some View {
        ZoomControls(
            fraction: $session.zoomFraction, keys: .command,
            zoomOut: session.zoomOut, zoomIn: session.zoomIn,
            fit: (session.fit, "Fit the whole song")
        )
    }
}
