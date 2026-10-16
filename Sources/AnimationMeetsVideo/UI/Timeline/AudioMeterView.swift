import SwiftUI

/// The level of every audio track together, left and right, beside the
/// timeline while it plays: green to −18 dBFS, yellow to −6, red above, a
/// mark holding the recent peak, and a lamp on top of each channel that
/// lights once it reaches full scale (click to clear). Reads what the
/// player's audio taps measured at the playhead (`MixLevelMeter`).
struct AudioMeterView: View {
    let playback: PlaybackModel

    /// Not observed: it changes on every frame the schedule below draws.
    @State private var ballistics = BallisticsBox()
    /// Redraws once after the clip lamps are cleared while paused.
    @State private var clearedCount = 0

    private static let marks: [Double] = [0, -6, -12, -18, -24, -36, -48]

    var body: some View {
        let box = ballistics
        SwiftUI.TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !playback.isPlaying && box.isSettled)) { context in
            let meter = box.advance(
                to: context.date.timeIntervalSinceReferenceDate,
                peak: playback.isPlaying ? playback.mixMeter.reading(at: playback.player.currentTime().seconds).peak : nil
            )
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
                Canvas { context, size in draw(meter, in: &context, size: size) }
                    .id(clearedCount)
                    .accessibilityElement()
                    .accessibilityLabel("Audio level")
                    .accessibilityValue("left \(Self.spoken(meter.level[0])), right \(Self.spoken(meter.level[1]))")
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

    private func lamp(_ lit: Bool) -> some View {
        RoundedRectangle(cornerRadius: 1.5, style: .continuous)
            .fill(lit ? Design.statusDanger : Design.Surface.well.color)
            .frame(width: 12, height: 6)
    }

    private func y(ofDecibels decibels: Double, height: CGFloat) -> CGFloat {
        let fraction = (min(max(decibels, MeterBallistics.floor), 0) - MeterBallistics.floor) / -MeterBallistics.floor
        return height * CGFloat(1 - fraction)
    }

    private func draw(_ meter: MeterBallistics, in context: inout GraphicsContext, size: CGSize) {
        let scaleWidth: CGFloat = 16
        let barWidth: CGFloat = 12
        let gap: CGFloat = 3
        for mark in Self.marks {
            let y = y(ofDecibels: mark, height: size.height)
            context.draw(
                Text(mark == 0 ? "0" : "\(Int(-mark))").font(.system(size: 8, design: .monospaced)).foregroundStyle(Design.textTertiary),
                at: CGPoint(x: scaleWidth - 3, y: min(max(y, 5), size.height - 5)), anchor: .trailing
            )
        }
        let zones: [(from: Double, to: Double, color: Color)] = [
            (MeterBallistics.floor, -18, Design.statusDone),
            (-18, -6, Design.statusWarning),
            (-6, 0, Design.statusDanger),
        ]
        for channel in 0..<2 {
            let x = scaleWidth + CGFloat(channel) * (barWidth + gap)
            context.fill(Path(CGRect(x: x, y: 0, width: barWidth, height: size.height)), with: .color(Design.Surface.well.color))
            let level = meter.level[channel]
            for zone in zones where level > zone.from {
                let top = y(ofDecibels: min(level, zone.to), height: size.height)
                let bottom = y(ofDecibels: zone.from, height: size.height)
                context.fill(Path(CGRect(x: x, y: top, width: barWidth, height: bottom - top)), with: .color(zone.color))
            }
            if meter.held[channel] > MeterBallistics.floor {
                let y = y(ofDecibels: meter.held[channel], height: size.height)
                let color = zones.last { meter.held[channel] > $0.from }?.color ?? Design.textSecondary
                context.fill(Path(CGRect(x: x, y: y, width: barWidth, height: 1.5)), with: .color(color))
            }
        }
        for mark in Self.marks {
            let y = y(ofDecibels: mark, height: size.height)
            context.fill(
                Path(CGRect(x: scaleWidth, y: y, width: barWidth * 2 + gap, height: 0.5)),
                with: .color(Color.black.opacity(0.35))
            )
        }
    }
}

/// Holds the meter's movement between frames without making each frame
/// a state change.
private final class BallisticsBox {
    var value = MeterBallistics()

    /// Nothing left to fall: the schedule can stop while paused.
    var isSettled: Bool {
        value.level == SIMD2(repeating: MeterBallistics.floor) && value.held == SIMD2(repeating: MeterBallistics.floor)
    }

    func advance(to now: Double, peak: SIMD2<Float>?) -> MeterBallistics {
        value.update(peak: peak, at: now)
        return value
    }
}
