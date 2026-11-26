import CoreGraphics
import Foundation

/// What a Waveform draws at one moment (see docs/waveform-effect.md), as
/// areas filled with a color or a gradient, in the frame's pixels, for
/// `ShapeRendering` to draw as it draws shapes: lines are stroked into
/// areas, dots and bars are areas.
enum WaveformDrawing {
    typealias Paint = (area: CGPath, color: [Double], gradient: GradientPaint?)

    /// One wave to draw: its value at each point (1 is full scale, signed
    /// in Wave), which way it rises, and its colors.
    private struct Wave {
        var values: [Double]
        var side: WaveformSide
        /// The right channel's, with Stereo set to Split or Two, which is
        /// drawn in the right channel's color.
        var isRight = false
    }

    /// The paints of `step`, hearing `sound`, over a frame `frame` in its
    /// own pixels. None until the sound has been heard.
    static func paints(_ step: WaveformStep, sound: WaveformSound?, frame: CGRect, audio: WaveformAudio = .shared) -> [Paint] {
        let setup = step.setup
        guard let sound, !sound.sources.isEmpty, setup.samples >= 2 else { return [] }
        let gain = pow(10, setup.gain / 20)
        func values(_ channel: Int?) -> [Double] {
            raw(setup, sound: sound, at: step.time, channel: channel, audio: audio).map { $0 * gain }
        }
        if setup.stereo == .xy, setup.mode == .wave {
            return figure(setup, left: values(0), right: values(1), frame: frame)
        }
        var waves: [Wave]
        switch setup.stereo {
        case .mixed, .xy: waves = [Wave(values: values(nil), side: setup.side)]
        case .split:
            let outer: WaveformSide = setup.side == .other ? .other : .one
            waves = [
                Wave(values: values(0).map(abs), side: outer),
                Wave(values: values(1).map(abs), side: outer == .one ? .other : .one, isRight: true),
            ]
        case .two: waves = [Wave(values: values(0), side: setup.side), Wave(values: values(1), side: setup.side, isRight: true)]
        }
        guard let geometry = Baseline(setup) else { return [] }
        // A gradient lies over the whole waveform as it is drawn now.
        var placed: [(wave: Wave, points: [CGPoint], under: [CGPoint])] = []
        for wave in waves {
            let reach = wave.values.map { $0 * setup.height }
            switch wave.side {
            case .one: placed.append((wave, geometry.points(reach), geometry.bases))
            case .other: placed.append((wave, geometry.points(reach.map { -$0 }), geometry.bases))
            case .both:
                let up = reach.map(abs)
                placed.append((wave, geometry.points(up), geometry.points(up.map { -$0 })))
            }
        }
        let all = placed.flatMap { $0.points + $0.under }
        let bounds = all.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
        var paints: [Paint] = []
        for (wave, points, under) in placed {
            paints += drawn(setup, wave: wave, points: points, under: under, geometry: geometry, bounds: bounds, frame: frame)
        }
        return paints
    }

    // MARK: Sound

    /// Each point's value before gain: the wave over the window, or the
    /// spectrum's level at each point's frequency, falling back over the
    /// release.
    private static func raw(_ setup: WaveformSetup, sound: WaveformSound, at time: Double, channel: Int?, audio: WaveformAudio) -> [Double] {
        let n = setup.samples
        switch setup.mode {
        case .wave:
            let first = time - setup.window * setup.align.before
            let spacing = setup.window / Double(n - 1)
            let times = (0..<n).map { first + spacing * Double($0) }
            return audio.mix(sound, at: times, channel: channel, span: spacing)
        case .spectrum:
            let low = max(setup.lowFrequency, 1), high = max(setup.highFrequency, low * 1.01)
            // Spaced by octave.
            let bands = (0..<n).map { low * pow(high / low, Double($0) / Double(n - 1)) }
            var levels = audio.spectrum(sound, at: time, bands: bands, channel: channel)
            guard setup.release > 0 else { return levels }
            // A point falls back no faster than the release lets it: the
            // loudest of the moments just before, each faded by how long
            // ago it was.
            let looks = 8
            let step = max(setup.release / Double(looks), 1.0 / 60)
            for k in 1...looks {
                let ago = step * Double(k)
                guard ago <= setup.release * 3 else { break }
                let fade = exp(-ago / setup.release)
                let earlier = audio.spectrum(sound, at: time - ago, bands: bands, channel: channel)
                for i in levels.indices { levels[i] = max(levels[i], earlier[i] * fade) }
            }
            return levels
        }
    }

    // MARK: Geometry

    /// Where each point's baseline is and which way is up from it: along
    /// a line from its start to its end, or round a ring.
    private struct Baseline {
        var bases: [CGPoint]
        var normals: [CGVector]
        /// Whether the points go all the way round, so the first follows
        /// the last.
        var closed: Bool
        /// The space between points along the baseline.
        var spacing: Double

        init?(_ setup: WaveformSetup) {
            let n = setup.samples
            switch setup.shape {
            case .line:
                let dx = Double(setup.end.x - setup.start.x), dy = Double(setup.end.y - setup.start.y)
                let length = (dx * dx + dy * dy).squareRoot()
                guard length > 0 else { return nil }
                // Up from a line drawn left to right.
                let normal = CGVector(dx: dy / length, dy: -dx / length)
                bases = (0..<n).map { i in
                    let t = Double(i) / Double(n - 1)
                    return CGPoint(x: Double(setup.start.x) + dx * t, y: Double(setup.start.y) + dy * t)
                }
                normals = Array(repeating: normal, count: n)
                closed = false
                spacing = length / Double(n)
            case .radial:
                guard setup.radius > 0, setup.sweep != 0 else { return nil }
                closed = abs(setup.sweep) >= 360
                let step = setup.sweep / Double(closed ? n : n - 1)
                let angles = (0..<n).map { (setup.angle + step * Double($0)) * .pi / 180 }
                // Clockwise from straight up, on a frame whose y goes down.
                normals = angles.map { CGVector(dx: sin($0), dy: -cos($0)) }
                bases = normals.map { CGPoint(x: Double(setup.center.x) + setup.radius * $0.dx, y: Double(setup.center.y) + setup.radius * $0.dy) }
                spacing = setup.radius * abs(step) * .pi / 180
            }
        }

        /// The points `reach` pixels up (or out) from each base.
        func points(_ reach: [Double]) -> [CGPoint] {
            bases.indices.map { i in
                CGPoint(x: Double(bases[i].x) + Double(normals[i].dx) * reach[i], y: Double(bases[i].y) + Double(normals[i].dy) * reach[i])
            }
        }
    }

    // MARK: Drawing

    private static func drawn(
        _ setup: WaveformSetup, wave: Wave, points: [CGPoint], under: [CGPoint], geometry: Baseline, bounds: CGRect, frame: CGRect
    ) -> [Paint] {
        // Each channel's colors: the right one's of its own with Two.
        let fill = wave.isRight ? setup.rightColor : setup.fill
        let stroke = wave.isRight ? setup.rightColor : setup.stroke
        let fillGradient = wave.isRight ? nil : setup.fillGradient?.placed(item: bounds, frame: frame)
        let strokeGradient = wave.isRight ? nil : setup.strokeGradient?.placed(item: bounds, frame: frame)
        func shown(_ color: [Double]?) -> [Double]? { color.flatMap { $0.count == 4 && $0[3] > 0 ? $0 : nil } }
        // By level: each point in the color its Fill's gradient has at how
        // far it reaches, from the baseline to the full Height.
        func level(_ i: Int) -> Double {
            guard setup.height != 0 else { return 0 }
            let reach = hypot(Double(points[i].x - under[i].x), Double(points[i].y - under[i].y))
            let full = abs(setup.height) * (setup.side == .both ? 2 : 1)
            return (reach / full).clamped(between: 0, and: 1)
        }
        func leveled(_ i: Int) -> [Double]? {
            if !wave.isRight, let gradient = setup.fillGradient {
                return gradient.gradient.color(at: level(i), repeats: .hold, blend: gradient.style.blend)
            }
            return shown(fill)
        }
        let byLevel = setup.coloring == .byLevel
        var paints: [Paint] = []
        switch setup.draw {
        case .lines:
            if setup.fillsToBaseline, fillGradient != nil || shown(fill) != nil {
                let area = CGMutablePath()
                add(points, to: area, smooth: setup.smooth, closed: false)
                for point in under.reversed() { area.addLine(to: point) }
                area.closeSubpath()
                paints.append((area as CGPath, shown(fill) ?? [0, 0, 0, 0], fillGradient))
            }
            guard setup.lineWidth > 0, strokeGradient != nil || shown(stroke) != nil else { break }
            var lines = [points]
            if setup.side == .both { lines.append(under) }
            for line in lines {
                if byLevel {
                    for i in 0..<(line.count - 1) {
                        let piece = CGMutablePath()
                        piece.move(to: line[i])
                        piece.addLine(to: line[i + 1])
                        guard let color = leveled(i) else { continue }
                        paints.append((Self.stroked(piece, width: setup.lineWidth), color, nil))
                    }
                } else {
                    let path = CGMutablePath()
                    add(line, to: path, smooth: setup.smooth, closed: geometry.closed)
                    paints.append((Self.stroked(path, width: setup.lineWidth), shown(stroke) ?? [0, 0, 0, 0], strokeGradient))
                }
            }
        case .dots:
            guard setup.dotSize > 0 else { break }
            let r = setup.dotSize / 2
            var dots = points
            if setup.side == .both { dots += under }
            let all = CGMutablePath()
            for (i, dot) in dots.enumerated() {
                let circle = CGRect(x: Double(dot.x) - r, y: Double(dot.y) - r, width: r * 2, height: r * 2)
                if byLevel {
                    guard let color = leveled(i % points.count) else { continue }
                    paints.append((CGPath(ellipseIn: circle, transform: nil), color, nil))
                } else {
                    all.addEllipse(in: circle)
                }
            }
            if !byLevel, !all.isEmpty, fillGradient != nil || shown(fill) != nil {
                paints.append((all as CGPath, shown(fill) ?? [0, 0, 0, 0], fillGradient))
            }
        case .bars:
            let width = geometry.spacing * setup.barWidth
            guard width > 0 else { break }
            let cap: CGLineCap = setup.barEnds == .round ? .round : .butt
            let all = CGMutablePath()
            for i in points.indices {
                let bar = CGMutablePath()
                bar.move(to: under[i])
                bar.addLine(to: points[i])
                if byLevel {
                    guard let color = leveled(i) else { continue }
                    paints.append((bar.copy(strokingWithWidth: width, lineCap: cap, lineJoin: .miter, miterLimit: 10), color, nil))
                } else {
                    all.addPath(bar)
                }
            }
            if !byLevel, !all.isEmpty, fillGradient != nil || shown(fill) != nil {
                paints.append((all.copy(strokingWithWidth: width, lineCap: cap, lineJoin: .miter, miterLimit: 10), shown(fill) ?? [0, 0, 0, 0], fillGradient))
            }
        }
        return paints
    }

    /// X–Y: left against right as a figure about the line's middle or the
    /// ring's center, as big as the Height, drawn as lines or dots.
    private static func figure(_ setup: WaveformSetup, left: [Double], right: [Double], frame: CGRect) -> [Paint] {
        let middle = setup.shape == .line
            ? CGPoint(x: (setup.start.x + setup.end.x) / 2, y: (setup.start.y + setup.end.y) / 2)
            : setup.center
        let points = left.indices.map { i in
            CGPoint(x: Double(middle.x) + left[i] * setup.height, y: Double(middle.y) - right[i] * setup.height)
        }
        let bounds = points.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
        if setup.draw == .lines {
            guard setup.lineWidth > 0, let stroke = setup.stroke ?? setup.strokeGradient?.gradient.stops.first?.color else { return [] }
            let path = CGMutablePath()
            add(points, to: path, smooth: setup.smooth, closed: false)
            return [(stroked(path, width: setup.lineWidth), stroke, setup.strokeGradient?.placed(item: bounds, frame: frame))]
        }
        let size = max(setup.draw == .dots ? setup.dotSize : setup.lineWidth, 1)
        let dots = CGMutablePath()
        for point in points { dots.addEllipse(in: CGRect(x: Double(point.x) - size / 2, y: Double(point.y) - size / 2, width: size, height: size)) }
        guard let fill = setup.fill ?? setup.fillGradient?.gradient.stops.first?.color else { return [] }
        return [(dots as CGPath, fill, setup.fillGradient?.placed(item: bounds, frame: frame))]
    }

    /// `points` joined, through each point, smoothed with Catmull–Rom
    /// curves when `smooth`; round to the first again when `closed`.
    private static func add(_ points: [CGPoint], to path: CGMutablePath, smooth: Bool, closed: Bool) {
        guard let first = points.first else { return }
        if path.isEmpty { path.move(to: first) } else { path.addLine(to: first) }
        let n = points.count
        let count = closed ? n : n - 1
        guard count > 0 else { return }
        for i in 0..<count {
            let p1 = points[i], p2 = points[(i + 1) % n]
            guard smooth else {
                path.addLine(to: p2)
                continue
            }
            let p0 = closed || i > 0 ? points[(i - 1 + n) % n] : p1
            let p3 = closed || i + 2 < n ? points[(i + 2) % n] : p2
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6, y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6, y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        if closed { path.closeSubpath() }
    }

    private static func stroked(_ path: CGPath, width: Double) -> CGPath {
        path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
    }
}
