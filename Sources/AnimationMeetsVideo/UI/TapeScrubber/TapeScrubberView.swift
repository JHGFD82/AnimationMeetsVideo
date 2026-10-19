import SwiftUI

/// The Tape Scrubber: the ridged edge of a dial standing out of a slit in
/// a box, seen straight on. Grabbing the dial and dragging it sideways runs
/// the main timeline's sound like tape, slowly at first and faster the
/// further it is dragged, backwards to the left (`TapeScrub.rate`). The
/// dial turns under the pointer. See docs/audio.md, "Tape scrubbing".
struct TapeScrubberView: View {
    let playback: PlaybackModel
    /// False while a timeline other than Main is open: the dial is dimmed
    /// and doesn't turn.
    let isAvailable: Bool

    /// How far the dial has turned, in points along its rim.
    @State private var turn: CGFloat = 0
    /// `turn` when the dial was grabbed; nil while it isn't held.
    @State private var turnAtGrab: CGFloat?
    /// The arrow key running the tape, if one is.
    @State private var heldKey: KeyEquivalent?
    @State private var burst: Task<Void, Never>?

    static let slit = CGSize(width: 320, height: 40)

    var body: some View {
        RidgedDial(turn: turn)
            .frame(width: Self.slit.width, height: Self.slit.height)
            .opacity(isAvailable ? 1 : 0.35)
            .contentShape(Rectangle())
            .gesture(drag, including: isAvailable ? .all : .none)
            .pointerStyle(isAvailable ? (turnAtGrab == nil ? .grabIdle : .grabActive) : nil)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Self.box)
            .help(isAvailable ? "" : "The tape scrubber plays the Main timeline. Open it to scrub.")
            .focusable(isAvailable)
            .focusEffectDisabled()
            .onKeyPress(keys: [.leftArrow, .rightArrow], phases: [.down, .repeat, .up], action: handleKey)
            .onChange(of: isAvailable) { _, available in
                if !available { letGo() }
            }
            .onDisappear { letGo() }
            .accessibilityElement()
            .accessibilityLabel("Tape scrubber")
            .accessibilityValue(isAvailable ? "" : "Only for the Main timeline")
            .accessibilityHint("Drag sideways to play the sound like tape, faster the further you drag. Hold the Left or Right Arrow key to play it backward or forward.")
            .accessibilityAdjustableAction { direction in
                guard isAvailable else { return }
                switch direction {
                case .increment: playBurst(rate: 1)
                case .decrement: playBurst(rate: -1)
                @unknown default: break
                }
            }
    }

    /// The box's face: dark, lit a little from above.
    private static var box: some View {
        LinearGradient(colors: [Design.hex(0x262B32), Design.hex(0x15181C)], startPoint: .top, endPoint: .bottom)
    }

    private var drag: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if turnAtGrab == nil { turnAtGrab = turn }
                turn = (turnAtGrab ?? 0) + value.translation.width
                playback.scrubTape(rate: TapeScrub.rate(forDrag: value.translation.width))
            }
            .onEnded { _ in
                turnAtGrab = nil
                playback.releaseTape()
            }
    }

    /// Holding an arrow key runs the tape at normal speed that way, four
    /// times with Shift, until it is let go.
    private func handleKey(_ press: KeyPress) -> KeyPress.Result {
        guard isAvailable else { return .ignored }
        switch press.phase {
        case .down:
            heldKey = press.key
            let rate = press.modifiers.contains(.shift) ? 4.0 : 1.0
            playback.scrubTape(rate: press.key == .leftArrow ? -rate : rate)
        case .up:
            if heldKey == press.key {
                heldKey = nil
                playback.releaseTape()
            }
        default:
            break
        }
        return .handled
    }

    /// Half a second of tape at `rate`, for VoiceOver's adjust.
    private func playBurst(rate: Double) {
        burst?.cancel()
        playback.scrubTape(rate: rate)
        burst = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            playback.releaseTape()
        }
    }

    private func letGo() {
        burst?.cancel()
        if turnAtGrab != nil || heldKey != nil { playback.releaseTape() }
        turnAtGrab = nil
        heldKey = nil
    }
}
