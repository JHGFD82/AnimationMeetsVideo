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
        DialInSlit(turn: turn)
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

/// The slit and the dial's rim in it. The rim is a cylinder seen side on:
/// its ridges bunch up and darken toward the slit's ends as the rim turns
/// away, and slide along as the dial turns.
private struct DialInSlit: View {
    /// How far the dial has turned, in points along its rim.
    let turn: CGFloat

    /// The share of a half turn the slit shows either way of the middle.
    private static let shown = 0.44 * Double.pi
    /// Ridges around the whole rim.
    private static let ridges = 96

    var body: some View {
        Canvas { context, size in
            let slit = CGRect(origin: .zero, size: size)
            let slitShape = Path(roundedRect: slit, cornerRadius: 5)
            context.fill(slitShape, with: .color(Design.hex(0x050607)))

            // The rim, a little inside the slit's lips.
            let rim = slit.insetBy(dx: 3, dy: 5)
            let radius = rim.width / 2 / sin(Self.shown)
            let middle = rim.midX
            /// How much of the light a part of the rim facing `angle` away
            /// from straight on catches.
            func light(_ angle: Double) -> Double { max(0, cos(angle)) }

            var shading: [Gradient.Stop] = []
            for step in 0...16 {
                let x = Double(step) / 16
                let angle = asin(min(1, max(-1, (x * 2 - 1) * sin(Self.shown))))
                let level = 0.08 + 0.32 * light(angle)
                shading.append(.init(color: Color(white: level), location: x))
            }
            context.fill(
                Path(roundedRect: rim, cornerRadius: 2),
                with: .linearGradient(Gradient(stops: shading), startPoint: CGPoint(x: rim.minX, y: 0), endPoint: CGPoint(x: rim.maxX, y: 0))
            )

            // The ridges, each a dark groove with a lit edge after it.
            let spacing = 2 * Double.pi / Double(Self.ridges)
            let phase = (Double(turn) / radius).truncatingRemainder(dividingBy: spacing)
            var angle = phase - (Double.pi / 2 / spacing).rounded(.up) * spacing
            while angle < Double.pi / 2 {
                defer { angle += spacing }
                guard abs(angle) < Self.shown else { continue }
                let x = middle + radius * sin(angle)
                let width = max(0.5, spacing * radius * cos(angle) * 0.35)
                let lit = light(angle)
                context.fill(
                    Path(CGRect(x: x - width / 2, y: rim.minY, width: width, height: rim.height)),
                    with: .color(Color(white: 0.02, opacity: 0.55 + 0.3 * lit))
                )
                context.fill(
                    Path(CGRect(x: x + width / 2, y: rim.minY, width: max(0.5, width * 0.6), height: rim.height)),
                    with: .color(Color(white: 0.55 + 0.4 * lit, opacity: 0.12 + 0.5 * lit * lit))
                )
            }

            // The lips' shadow across the rim's top and bottom, deeper at
            // the top, which overhangs it.
            context.fill(Path(rim), with: .linearGradient(
                Gradient(stops: [
                    .init(color: .black.opacity(0.75), location: 0),
                    .init(color: .clear, location: 0.3),
                    .init(color: .clear, location: 0.8),
                    .init(color: .black.opacity(0.45), location: 1),
                ]),
                startPoint: CGPoint(x: 0, y: rim.minY), endPoint: CGPoint(x: 0, y: rim.maxY)
            ))

            // The slit's edges: shadow under the top lip, light along the
            // bottom one.
            context.stroke(
                Path { $0.move(to: CGPoint(x: slit.minX + 5, y: slit.maxY - 0.5)); $0.addLine(to: CGPoint(x: slit.maxX - 5, y: slit.maxY - 0.5)) },
                with: .color(.white.opacity(0.14)), lineWidth: 1
            )
            context.stroke(slitShape, with: .color(.black.opacity(0.9)), lineWidth: 1)
        }
        .accessibilityHidden(true)
    }
}
