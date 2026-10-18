import AppKit
import QuartzCore
import SwiftUI

/// The level of every audio track together, left and right, beside the
/// timeline while it plays: green to −18 dBFS, yellow to −6, red above, a
/// mark holding the recent peak, and a lamp on top of each channel that
/// lights once it reaches full scale (click to clear), and under them the
/// short-term loudness (the last three seconds, in LUFS). Reads what the
/// player's audio taps measured at the playhead (`MixLevelMeter`).
///
/// The scale is drawn once; only the bars and peak marks move, as Core
/// Animation layers (`MeterBars`), so a frame of the meter is a few layer
/// frames rather than a redraw.
struct AudioMeterView: View {
    let playback: PlaybackModel

    /// Not observed: it changes on every frame the schedule below draws.
    @State private var ballistics: BallisticsBox
    /// Redraws once after the clip lamps are cleared while paused.
    @State private var clearedCount = 0

    /// Shown in place of a measured loudness, for a snapshot.
    private let shownLoudness: Double?

    /// - Parameters:
    ///   - showing: What the meter starts at, for a snapshot.
    ///   - loudness: The loudness to show instead of the player's.
    init(playback: PlaybackModel, showing: MeterBallistics = MeterBallistics(), loudness: Double? = nil) {
        self.playback = playback
        _ballistics = State(initialValue: BallisticsBox(value: showing))
        shownLoudness = loudness
    }

    var body: some View {
        let box = ballistics
        SwiftUI.TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !playback.isPlaying && box.isSettled)) { context in
            let time = playback.player.currentTime().seconds
            let meter = box.advance(
                to: context.date.timeIntervalSinceReferenceDate,
                peak: playback.isPlaying ? playback.mixMeter.reading(at: time).peak : nil
            )
            let loudness = shownLoudness ?? (playback.isPlaying ? playback.mixMeter.loudness(at: time) : nil)
            VStack(spacing: Design.Space.tight) {
                HStack(spacing: 3) {
                    lamp(meter.clipped[0])
                    lamp(meter.clipped[1])
                }
                .padding(.leading, 16)
                .contentShape(Rectangle())
                .onTapGesture {
                    box.value.resetClips()
                    clearedCount += 1
                }
                .help("Lights when a channel reaches full scale; click to clear")
                .accessibilityElement()
                .accessibilityLabel("Clip lamps")
                .accessibilityValue(meter.clipped.contains(true) ? "Clipped" : "Clear")
                .accessibilityAddTraits(.isButton)
                .accessibilityHint("Clears the lamps")
                ZStack {
                    MeterScale(showsMarks: false)
                    MeterBars(meter: meter)
                    MeterScale(showsMarks: true)
                }
                .id(clearedCount)
                .accessibilityElement()
                .accessibilityLabel("Audio level")
                .accessibilityValue("left \(Self.spoken(meter.level[0])), right \(Self.spoken(meter.level[1]))")
                loudnessReadout(loudness)
            }
        }
        .padding(.vertical, Design.Space.step)
        .padding(.horizontal, Design.Space.tight)
        .frame(maxHeight: .infinity)
        .background(Design.Surface.base.color)
        .help("Every audio track together, left and right, in dBFS")
    }

    /// A level as VoiceOver reads it: "−12 decibels", or "silent".
    private static func spoken(_ decibels: Double) -> String {
        decibels <= MeterBallistics.floor ? "silent" : "\(Int(decibels.rounded())) decibels"
    }

    /// The short-term loudness, or a dash while nothing is playing.
    private func loudnessReadout(_ lufs: Double?) -> some View {
        VStack(spacing: 0) {
            Text(lufs.map(Loudness.label) ?? "–")
                .font(Design.Typeface.numericMicro)
                .foregroundStyle(lufs == nil ? Design.textTertiary : Design.textPrimary)
            Text("LUFS")
                .font(Design.Typeface.micro)
                .foregroundStyle(Design.textTertiary)
        }
        .padding(.leading, MeterLayout.scaleWidth)
        .frame(maxWidth: .infinity)
        .help("Short-term loudness: every track together over the last three seconds, in LUFS")
        .accessibilityElement()
        .accessibilityLabel("Loudness")
        .accessibilityValue(lufs.map { $0.isFinite ? "\(Int($0.rounded())) LUFS" : "silent" } ?? "not playing")
    }

    private func lamp(_ lit: Bool) -> some View {
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
            .fill(lit ? Design.statusDanger : Design.Surface.well.color)
            .frame(width: 12, height: 6)
    }
}

/// Where the meter's parts sit, shared by the scale and the bars.
private enum MeterLayout {
    static let scaleWidth: CGFloat = 16
    static let barWidth: CGFloat = 12
    static let gap: CGFloat = 3
    static let marks: [Double] = [0, -6, -12, -18, -24, -36, -48]
    /// Green to −18 dBFS, yellow to −6, red above.
    static let zones: [(from: Double, to: Double, color: Color)] = [
        (MeterBallistics.floor, -18, Design.statusDone),
        (-18, -6, Design.statusWarning),
        (-6, 0, Design.statusDanger),
    ]

    static func barX(_ channel: Int) -> CGFloat {
        scaleWidth + CGFloat(channel) * (barWidth + gap)
    }

    static func y(ofDecibels decibels: Double, height: CGFloat) -> CGFloat {
        let fraction = (min(max(decibels, MeterBallistics.floor), 0) - MeterBallistics.floor) / -MeterBallistics.floor
        return height * CGFloat(1 - fraction)
    }
}

/// The meter's still parts: the numbers and the empty wells under the
/// bars, or the marks across them. Nothing here changes as the level
/// does, so SwiftUI redraws it only when the meter is resized.
private struct MeterScale: View {
    let showsMarks: Bool

    var body: some View {
        Canvas { context, size in
            if showsMarks {
                for mark in MeterLayout.marks {
                    let y = MeterLayout.y(ofDecibels: mark, height: size.height)
                    context.fill(
                        Path(CGRect(x: MeterLayout.scaleWidth, y: y, width: MeterLayout.barWidth * 2 + MeterLayout.gap, height: 0.5)),
                        with: .color(Color.black.opacity(0.35))
                    )
                }
                return
            }
            for mark in MeterLayout.marks {
                let y = MeterLayout.y(ofDecibels: mark, height: size.height)
                context.draw(
                    Text(mark == 0 ? "0" : "\(Int(-mark))").font(Design.Typeface.numericScale).foregroundStyle(Design.textTertiary),
                    at: CGPoint(x: MeterLayout.scaleWidth - 3, y: min(max(y, 5), size.height - 5)), anchor: .trailing
                )
            }
            for channel in 0..<2 {
                let well = CGRect(x: MeterLayout.barX(channel), y: 0, width: MeterLayout.barWidth, height: size.height)
                context.fill(Path(well), with: .color(Design.Surface.well.color))
            }
        }
        .allowsHitTesting(false)
    }
}

/// The bars and peak marks, as layers whose frames are set each frame.
private struct MeterBars: NSViewRepresentable {
    let meter: MeterBallistics

    func makeNSView(context: Context) -> BarsView { BarsView() }

    func updateNSView(_ view: BarsView, context: Context) {
        view.show(meter)
    }

    final class BarsView: NSView {
        /// Per channel, one layer for each zone of colour.
        private var zones: [[CALayer]] = []
        private var heldMarks: [CALayer] = []
        private let zoneColors = MeterLayout.zones.map { NSColor($0.color).cgColor }
        private var shown = MeterBallistics()

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            for _ in 0..<2 {
                let channel = zoneColors.map { color in
                    let zone = CALayer()
                    zone.backgroundColor = color
                    zone.isHidden = true
                    layer?.addSublayer(zone)
                    return zone
                }
                zones.append(channel)
                let held = CALayer()
                held.isHidden = true
                layer?.addSublayer(held)
                heldMarks.append(held)
            }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        override var isFlipped: Bool { true }

        /// A readout: the lamps above take the clicks.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            show(shown)
        }

        func show(_ meter: MeterBallistics) {
            shown = meter
            let height = bounds.height
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for channel in 0..<2 {
                let x = MeterLayout.barX(channel)
                let level = meter.level[channel]
                for (index, zone) in MeterLayout.zones.enumerated() {
                    let layer = zones[channel][index]
                    guard level > zone.from else {
                        layer.isHidden = true
                        continue
                    }
                    let top = MeterLayout.y(ofDecibels: min(level, zone.to), height: height)
                    let bottom = MeterLayout.y(ofDecibels: zone.from, height: height)
                    layer.frame = CGRect(x: x, y: top, width: MeterLayout.barWidth, height: bottom - top)
                    layer.isHidden = false
                }
                let held = meter.held[channel]
                let mark = heldMarks[channel]
                if held > MeterBallistics.floor {
                    let y = MeterLayout.y(ofDecibels: held, height: height)
                    mark.frame = CGRect(x: x, y: y, width: MeterLayout.barWidth, height: 1.5)
                    mark.backgroundColor = MeterLayout.zones.indices.last { held > MeterLayout.zones[$0].from }
                        .map { zoneColors[$0] } ?? NSColor(Design.textSecondary).cgColor
                    mark.isHidden = false
                } else {
                    mark.isHidden = true
                }
            }
            CATransaction.commit()
        }
    }
}

/// Holds the meter's movement between frames without making each frame
/// a state change.
private final class BallisticsBox {
    var value: MeterBallistics

    init(value: MeterBallistics) {
        self.value = value
    }

    /// Nothing left to fall: the schedule can stop while paused.
    var isSettled: Bool {
        value.level == SIMD2(repeating: MeterBallistics.floor) && value.held == SIMD2(repeating: MeterBallistics.floor)
    }

    func advance(to now: Double, peak: SIMD2<Float>?) -> MeterBallistics {
        value.update(peak: peak, at: now)
        return value
    }
}
