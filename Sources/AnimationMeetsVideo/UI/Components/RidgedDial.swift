import SwiftUI

/// A ridged dial's rim standing out of a slit, as the Tape Scrubber's: a
/// cylinder seen side on, its ridges bunching up and darkening toward the
/// slit's ends as the rim turns away, and sliding along as the dial turns.
/// Upright, it is the same dial turned on its side, its rim running down.
struct RidgedDial: View {
    /// How far the dial has turned, in points along its rim: rightward, or
    /// downward when upright.
    let turn: CGFloat
    var axis: Axis = .horizontal

    /// The share of a half turn the slit shows either way of the middle.
    private static let shown = 0.44 * Double.pi
    /// Ridges around the whole rim.
    private static let ridges = 96

    var body: some View {
        Canvas { context, size in
            var length = size
            if axis == .vertical {
                // Drawn lying down, then stood up: along the rim is down.
                context.translateBy(x: size.width, y: 0)
                context.rotate(by: .degrees(90))
                length = CGSize(width: size.height, height: size.width)
            }
            Self.draw(turn: turn, size: length, in: &context)
        }
        .accessibilityHidden(true)
    }

    private static func draw(turn: CGFloat, size: CGSize, in context: inout GraphicsContext) {
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
}
