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
        /// Each point's held peak, with Peak Hold on, in Spectrum and Level.
        var peaks: [Double]?
        var side: WaveformSide
        /// The right channel's, with Stereo set to Split or Two, which is
        /// drawn in the right channel's color.
        var isRight = false
        /// Where it is drawn: the shape's points, or a meter's own place.
        var geometry: Baseline
    }

    /// The paints of `step`, hearing `sound`, over a frame `frame` in its
    /// own pixels. None until the sound has been heard.
    static func paints(_ step: WaveformStep, sound: WaveformSound?, frame: CGRect, audio: WaveformAudio = .shared) -> [Paint] {
        var setup = step.setup
        setup.samples = pointCount(setup)
        guard let sound, !sound.sources.isEmpty, setup.samples >= 2 else { return [] }
        let gain = pow(10, setup.gain / 20)
        func measured(_ channel: Int?) -> (values: [Double], peaks: [Double]?) {
            let raw = raw(setup, sound: sound, at: step.time, channel: channel, audio: audio)
            return (raw.values.map { $0 * gain }, raw.peaks?.map { $0 * gain })
        }
        func values(_ channel: Int?) -> [Double] { measured(channel).values }
        if setup.mode == .spectrogram {
            return heatMap(setup, sound: sound, at: step.time, gain: gain, frame: frame, audio: audio)
        }
        if setup.stereo == .xy, setup.mode == .wave {
            return figure(setup, left: values(0), right: values(1), frame: frame)
        }
        var waves: [Wave]
        if setup.mode == .level {
            // A meter for the mix, or one a channel side by side.
            let channels: [Int?] = setup.stereo == .mixed ? [nil] : [0, 1]
            guard let meters = Baseline(setup, count: channels.count, centered: true) else { return [] }
            waves = channels.enumerated().map { index, channel in
                let level = measured(channel)
                return Wave(
                    values: level.values, peaks: level.peaks, side: setup.side, isRight: index == 1,
                    geometry: meters.slice(index)
                )
            }
        } else {
            guard let geometry = Baseline(setup, count: setup.samples) else { return [] }
            switch setup.stereo {
            case .mixed, .xy:
                let mixed = measured(nil)
                waves = [Wave(values: mixed.values, peaks: mixed.peaks, side: setup.side, geometry: geometry)]
            case .split:
                let outer: WaveformSide = setup.side == .other ? .other : .one
                let left = measured(0), right = measured(1)
                waves = [
                    Wave(values: left.values.map(abs), peaks: left.peaks, side: outer, geometry: geometry),
                    Wave(values: right.values.map(abs), peaks: right.peaks, side: outer == .one ? .other : .one, isRight: true, geometry: geometry),
                ]
            case .two:
                let left = measured(0), right = measured(1)
                waves = [
                    Wave(values: left.values, peaks: left.peaks, side: setup.side, geometry: geometry),
                    Wave(values: right.values, peaks: right.peaks, side: setup.side, isRight: true, geometry: geometry),
                ]
            }
        }
        // A gradient lies over the whole waveform as it is drawn now.
        var placed: [(wave: Wave, points: [CGPoint], under: [CGPoint])] = []
        for wave in waves {
            let reach = wave.values.map { $0 * setup.height }
            let geometry = wave.geometry
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
            paints += drawn(setup, wave: wave, points: points, under: under, bounds: bounds, frame: frame)
        }
        return paints
    }

    /// How many points `setup` draws: from Spacing, the pixels between
    /// them along the shape, when it is set (in Wave and Spectrum), else
    /// Samples.
    static func pointCount(_ setup: WaveformSetup) -> Int {
        guard setup.spacing > 0, setup.mode == .wave || setup.mode == .spectrum else { return setup.samples }
        let length: Double
        switch setup.shape {
        case .line: length = hypot(Double(setup.end.x - setup.start.x), Double(setup.end.y - setup.start.y))
        case .radial: length = setup.radius * abs(setup.sweep) * .pi / 180
        }
        return Int((length / setup.spacing).rounded()).clamped(between: 2, and: 4096)
    }

    // MARK: Sound

    /// Each point's value before gain: the wave over the window (averaged
    /// with the windows just before over Time Smoothing), or in Spectrum
    /// and Level the measure at the frame's time through its attack and
    /// release, with the peaks Peak Hold keeps.
    private static func raw(
        _ setup: WaveformSetup, sound: WaveformSound, at time: Double, channel: Int?, audio: WaveformAudio
    ) -> (values: [Double], peaks: [Double]?) {
        switch setup.mode {
        case .wave:
            guard setup.timeSmoothing > 0 else { return (wave(setup, sound: sound, at: time, channel: channel, audio: audio), nil) }
            let step = WaveformAudio.gridStep
            let looks = min(Int((setup.timeSmoothing * 3 / step).rounded(.up)), 30)
            var sum = [Double](repeating: 0, count: setup.samples), weights = 0.0
            for k in 0...looks {
                let weight = exp(-Double(k) * step / setup.timeSmoothing)
                let window = wave(setup, sound: sound, at: time - Double(k) * step, channel: channel, audio: audio)
                for i in sum.indices { sum[i] += window[i] * weight }
                weights += weight
            }
            return (sum.map { $0 / weights }, nil)
        case .spectrum, .level:
            let bands = setup.scale.frequencies(setup.samples, from: max(setup.lowFrequency, 1), to: max(setup.highFrequency, setup.lowFrequency * 1.01))
            var hasher = Hasher()
            hasher.combine(setup.mode)
            hasher.combine(setup.floor)
            if setup.mode == .spectrum { hasher.combine(bands) }
            let settings = hasher.finalize()
            let measure: (Double) -> [Double] = setup.mode == .level
                ? { [audio.level(sound, at: $0, channel: channel, floor: setup.floor)] }
                : { audio.spectrum(sound, at: $0, bands: bands, channel: channel, floor: setup.floor) }
            return envelope(setup, now: measure(time), at: time) { grid in
                audio.measured(sound, grid: grid, channel: channel, settings: settings, measure)
            }
        case .spectrogram:
            return ([], nil)
        }
    }

    /// The measure `now` at `time` through `setup`'s attack, release and
    /// peak hold, looking back at the measures on the grid before it
    /// (`earlier`, by grid point): each point rises over the attack (an
    /// average of the moments before, newer ones counting more), falls
    /// back no faster than the release lets it (the loudest of the
    /// moments before, each faded by how long ago it was), and its peak is
    /// the loudest of the moments within the hold.
    static func envelope(
        _ setup: WaveformSetup, now: [Double], at time: Double, earlier: (Int) -> [Double]
    ) -> (values: [Double], peaks: [Double]?) {
        guard setup.attack > 0 || setup.release > 0 || setup.peakHold > 0 else { return (now, nil) }
        let step = WaveformAudio.gridStep
        let reach = max(setup.release * 3, setup.attack * 5, setup.peakHold)
        let looks = min(Int((reach / step).rounded(.up)) + 1, 250)
        let newest = Int((time / step).rounded(.down))
        // Oldest first, then now.
        var moments: [(ago: Double, values: [Double])] = (0..<looks).reversed().map { k in
            let grid = newest - k
            return (time - Double(grid) * step, earlier(grid))
        }
        moments.append((0, now))
        // Rising over the attack.
        if setup.attack > 0 {
            var smoothed = moments[0].values
            for m in moments.indices.dropFirst() {
                let share = 1 - exp(-(moments[m - 1].ago - moments[m].ago) / setup.attack)
                for i in smoothed.indices where i < moments[m].values.count {
                    smoothed[i] += (moments[m].values[i] - smoothed[i]) * share
                }
                moments[m].values = smoothed
            }
        }
        var values = moments[moments.count - 1].values
        if setup.release > 0 {
            for moment in moments where moment.ago > 0 && moment.ago <= setup.release * 3 {
                let fade = exp(-moment.ago / setup.release)
                for i in values.indices where i < moment.values.count { values[i] = max(values[i], moment.values[i] * fade) }
            }
        }
        guard setup.peakHold > 0 else { return (values, nil) }
        var peaks = values
        for moment in moments where moment.ago <= setup.peakHold {
            for i in peaks.indices where i < moment.values.count { peaks[i] = max(peaks[i], moment.values[i]) }
        }
        return (values, peaks)
    }

    /// Wave's points over the window around `time`, filtered to its range.
    private static func wave(_ setup: WaveformSetup, sound: WaveformSound, at time: Double, channel: Int?, audio: WaveformAudio) -> [Double] {
        let n = setup.samples
        let first = time - setup.window * setup.align.before
        let spacing = setup.window / Double(n - 1)
        // Heard through an EQ, or filtered to a range, the window is read
        // sample by sample.
        guard let filters = bandFilters(setup) ?? (sound.hasEqualizers ? [] : nil) else {
            let times = (0..<n).map { first + spacing * Double($0) }
            return audio.mix(sound, at: times, channel: channel, span: spacing)
        }
        return filtered(sound, from: first, spacing: spacing, points: n, channel: channel, through: filters, audio: audio)
    }

    // MARK: Spectrogram

    /// Spectrogram: the spectrum over the window before `time`, a column a
    /// moment on the grid, oldest at the shape's start, and its bands (as
    /// many as Samples, at most 128) up from the baseline to the Height.
    /// Each cell is colored by how loud it is: the Fill's gradient at that
    /// level, or its color that opaque. Cells of one shade are one area.
    private static func heatMap(
        _ setup: WaveformSetup, sound: WaveformSound, at time: Double, gain: Double, frame: CGRect, audio: WaveformAudio
    ) -> [Paint] {
        let step = WaveformAudio.gridStep
        let rows = setup.samples.clamped(between: 2, and: 128)
        let wanted = max(setup.window / step, 2)
        let columns = Int(wanted.rounded()).clamped(between: 2, and: 200)
        let stride = max(1, Int((wanted / Double(columns)).rounded()))
        guard let edges = Baseline(setup, count: columns + 1, open: true) else { return [] }
        let bands = setup.scale.frequencies(rows, from: max(setup.lowFrequency, 1), to: max(setup.highFrequency, setup.lowFrequency * 1.01))
        var hasher = Hasher()
        hasher.combine(WaveformMode.spectrum)
        hasher.combine(setup.floor)
        hasher.combine(bands)
        let settings = hasher.finalize()
        let newest = Int((time / step).rounded(.down))
        let channel: Int? = nil
        // How far up each row's edges are: from the baseline out, or about
        // it mirrored.
        let height = setup.height
        func reach(_ row: Int) -> Double {
            let t = Double(row) / Double(rows)
            switch setup.side {
            case .one: return height * t
            case .other: return -height * t
            case .both: return height * (2 * t - 1)
            }
        }
        let shades = 32
        var areas = [CGMutablePath](repeating: CGMutablePath(), count: shades + 1).map { _ in CGMutablePath() }
        for column in 0..<columns {
            let grid = newest - (columns - 1 - column) * stride
            let levels = audio.measured(sound, grid: grid, channel: channel, settings: settings) {
                audio.spectrum(sound, at: $0, bands: bands, channel: channel, floor: setup.floor)
            }
            for row in 0..<rows {
                let level = (levels[row] * gain).clamped(between: 0, and: 1)
                let shade = Int((level * Double(shades)).rounded())
                guard shade > 0 else { continue }
                let low = reach(row), high = reach(row + 1)
                let a = edges.point(column, low), b = edges.point(column + 1, low)
                let c = edges.point(column + 1, high), d = edges.point(column, high)
                areas[shade].addLines(between: [a, b, c, d])
                areas[shade].closeSubpath()
            }
        }
        var paints: [Paint] = []
        for shade in 1...shades where !areas[shade].isEmpty {
            let level = Double(shade) / Double(shades)
            let color: [Double]
            if let gradient = setup.fillGradient {
                color = gradient.gradient.color(at: level, repeats: .hold, blend: gradient.style.blend)
            } else if let fill = setup.fill, fill.count == 4 {
                color = [fill[0], fill[1], fill[2], fill[3] * level]
            } else {
                continue
            }
            paints.append((areas[shade] as CGPath, color, nil))
        }
        return paints
    }

    /// The filters that keep a Wave to its frequency range, as the EQ's
    /// cuts are made (`Biquad.pass`, twice each side, 24 dB an octave);
    /// nil while the range is the whole of what is heard.
    static func bandFilters(_ setup: WaveformSetup) -> [Biquad]? {
        let rate = WaveformAudio.Samples.rate
        var filters: [Biquad] = []
        let q = 0.5.squareRoot()
        if setup.lowFrequency > Spectrogram.lowestFrequency * 1.05 {
            let cut = Biquad.pass(highPass: true, frequency: setup.lowFrequency, q: q, sampleRate: rate)
            filters += [cut, cut]
        }
        if setup.highFrequency < Spectrogram.highestFrequency * 0.95 {
            let cut = Biquad.pass(highPass: false, frequency: setup.highFrequency, q: q, sampleRate: rate)
            filters += [cut, cut]
        }
        return filters.isEmpty ? nil : filters
    }

    /// How long before the window the filters run, so they have settled by
    /// its start.
    static let filterLeadIn = 0.05

    /// The Wave's points through `filters`: every sample of the window
    /// (and the lead-in before it) mixed, filtered, and each point the
    /// sample of its stretch furthest from silence.
    private static func filtered(
        _ sound: WaveformSound, from first: Double, spacing: Double, points n: Int, channel: Int?, through filters: [Biquad],
        audio: WaveformAudio
    ) -> [Double] {
        let rate = WaveformAudio.Samples.rate
        let start = first - filterLeadIn
        let count = Int(((spacing * Double(n - 1) + filterLeadIn) * rate).rounded(.up)) + 1
        var signal = audio.mix(sound, at: (0..<count).map { start + Double($0) / rate }, channel: channel)
        for filter in filters { signal = run(signal, through: filter) }
        return (0..<n).map { i in
            let from = Int(((first + spacing * Double(i) - start) * rate).rounded())
            let to = min(max(from + Int(spacing * rate), from + 1), signal.count)
            guard from >= 0, from < signal.count else { return 0 }
            var peak = 0.0
            for k in from..<to where abs(signal[k]) > abs(peak) { peak = signal[k] }
            return peak
        }
    }

    /// `signal` through one biquad, from rest.
    static func run(_ signal: [Double], through filter: Biquad) -> [Double] {
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        return signal.map { x in
            let y = filter.b0 * x + filter.b1 * x1 + filter.b2 * x2 - filter.a1 * y1 - filter.a2 * y2
            (x2, x1, y2, y1) = (x1, x, y1, y)
            return y
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

        /// `count` points along `setup`'s shape: from end to end (round a
        /// full ring, closed, unless `open`), or `centered` each in the
        /// middle of its share, as a meter's are.
        init?(_ setup: WaveformSetup, count n: Int, centered: Bool = false, open: Bool = false) {
            guard n >= 1, n >= 2 || centered else { return nil }
            func along(_ i: Int, of parts: Double) -> Double { centered ? (Double(i) + 0.5) / Double(n) : Double(i) / parts }
            switch setup.shape {
            case .line:
                let dx = Double(setup.end.x - setup.start.x), dy = Double(setup.end.y - setup.start.y)
                let length = (dx * dx + dy * dy).squareRoot()
                guard length > 0 else { return nil }
                // Up from a line drawn left to right.
                let normal = CGVector(dx: dy / length, dy: -dx / length)
                bases = (0..<n).map { i in
                    let t = along(i, of: Double(n - 1))
                    return CGPoint(x: Double(setup.start.x) + dx * t, y: Double(setup.start.y) + dy * t)
                }
                normals = Array(repeating: normal, count: n)
                closed = false
                spacing = length / Double(n)
            case .radial:
                guard setup.radius > 0, setup.sweep != 0 else { return nil }
                closed = abs(setup.sweep) >= 360 && !open && !centered
                let parts = Double(closed ? n : n - 1)
                let angles = (0..<n).map { (setup.angle + setup.sweep * along($0, of: parts)) * .pi / 180 }
                // Clockwise from straight up, on a frame whose y goes down.
                normals = angles.map { CGVector(dx: sin($0), dy: -cos($0)) }
                bases = normals.map { CGPoint(x: Double(setup.center.x) + setup.radius * $0.dx, y: Double(setup.center.y) + setup.radius * $0.dy) }
                spacing = setup.radius * abs(setup.sweep) / Double(centered ? n : max(n - 1, 1)) * .pi / 180
            }
        }

        /// Point `i` alone, as a meter's place.
        func slice(_ i: Int) -> Baseline {
            var one = self
            one.bases = [bases[i]]
            one.normals = [normals[i]]
            one.closed = false
            return one
        }

        /// The points `reach` pixels up (or out) from each base.
        func points(_ reach: [Double]) -> [CGPoint] {
            bases.indices.map { i in point(i, i < reach.count ? reach[i] : 0) }
        }

        /// `reach` pixels up (or out) from base `i`.
        func point(_ i: Int, _ reach: Double) -> CGPoint {
            CGPoint(x: Double(bases[i].x) + Double(normals[i].dx) * reach, y: Double(bases[i].y) + Double(normals[i].dy) * reach)
        }
    }

    // MARK: Drawing

    private static func drawn(
        _ setup: WaveformSetup, wave: Wave, points: [CGPoint], under: [CGPoint], bounds: CGRect, frame: CGRect
    ) -> [Paint] {
        let geometry = wave.geometry
        // Each channel's colors: the right one's of its own with Two.
        let fill = wave.isRight ? setup.rightColor : setup.fill
        let stroke = wave.isRight ? setup.rightColor : setup.stroke
        let fillGradient = wave.isRight ? nil : setup.fillGradient?.placed(item: bounds, frame: frame)
        let strokeGradient = wave.isRight ? nil : setup.strokeGradient?.placed(item: bounds, frame: frame)
        func shown(_ color: [Double]?) -> [Double]? { color.flatMap { $0.count == 4 && $0[3] > 0 ? $0 : nil } }
        // How far a point reaches, from the baseline to the full Height.
        let full = abs(setup.height)
        func level(_ i: Int) -> Double {
            guard full > 0 else { return 0 }
            let reach = hypot(Double(points[i].x - under[i].x), Double(points[i].y - under[i].y))
            return (reach / (full * (wave.side == .both ? 2 : 1))).clamped(between: 0, and: 1)
        }
        // By level: each point in the color its Fill's gradient has at how
        // far it reaches.
        func leveled(_ level: Double, fallback: [Double]?) -> [Double]? {
            if !wave.isRight, let gradient = setup.fillGradient {
                return gradient.gradient.color(at: level, repeats: .hold, blend: gradient.style.blend)
            }
            return shown(fallback)
        }
        let byLevel = setup.coloring == .byLevel || setup.mode == .level
        // Which way is out from base `i`, toward its point.
        func outward(_ i: Int) -> CGVector {
            let sign: Double = wave.side == .other ? -1 : 1
            return CGVector(dx: Double(geometry.normals[i].dx) * sign, dy: Double(geometry.normals[i].dy) * sign)
        }
        var paints: [Paint] = []
        switch setup.mode == .level ? .bars : setup.draw {
        case .lines:
            if setup.fillsToBaseline, fillGradient != nil || shown(fill) != nil {
                paints.append((filledArea(points, under, smooth: setup.smooth), shown(fill) ?? [0, 0, 0, 0], fillGradient))
            }
            guard setup.lineWidth > 0, strokeGradient != nil || shown(stroke) != nil else { break }
            var lines = [points]
            if wave.side == .both { lines.append(under) }
            for line in lines {
                if byLevel {
                    for i in 0..<(line.count - 1) {
                        let piece = CGMutablePath()
                        piece.move(to: line[i])
                        piece.addLine(to: line[i + 1])
                        guard let color = leveled(level(i), fallback: stroke) else { continue }
                        paints.append((Self.stroked(piece, width: setup.lineWidth), color, nil))
                    }
                } else {
                    let path = CGMutablePath()
                    add(line, to: path, smooth: setup.smooth, closed: geometry.closed)
                    paints.append((Self.stroked(path, width: setup.lineWidth), shown(stroke) ?? [0, 0, 0, 0], strokeGradient))
                }
            }
        case .area:
            guard fillGradient != nil || shown(fill) != nil else { break }
            paints.append((filledArea(points, under, smooth: setup.smooth), shown(fill) ?? [0, 0, 0, 0], fillGradient))
        case .dots:
            guard setup.dotSize > 0 else { break }
            let r = setup.dotSize / 2
            var dots = points
            if wave.side == .both { dots += under }
            let all = CGMutablePath()
            for (i, dot) in dots.enumerated() {
                let circle = CGRect(x: Double(dot.x) - r, y: Double(dot.y) - r, width: r * 2, height: r * 2)
                if byLevel {
                    guard let color = leveled(level(i % points.count), fallback: fill) else { continue }
                    paints.append((CGPath(ellipseIn: circle, transform: nil), color, nil))
                } else {
                    all.addEllipse(in: circle)
                }
            }
            if !byLevel, !all.isEmpty, fillGradient != nil || shown(fill) != nil {
                paints.append((all as CGPath, shown(fill) ?? [0, 0, 0, 0], fillGradient))
            }
        case .particles:
            // Dots on the way out to each point, growing and coming in.
            guard setup.dotSize > 0, fillGradient != nil || shown(fill) != nil else { break }
            for fraction in [0.25, 0.5, 0.75, 1.0] {
                let r = setup.dotSize * (0.4 + 0.6 * fraction) / 2
                let all = CGMutablePath()
                for i in points.indices {
                    var ends = [points[i]]
                    if wave.side == .both { ends.append(under[i]) }
                    let base = geometry.bases[i]
                    for end in ends {
                        let x = Double(base.x) + Double(end.x - base.x) * fraction, y = Double(base.y) + Double(end.y - base.y) * fraction
                        all.addEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
                    }
                }
                var color = shown(fill) ?? [0, 0, 0, 0]
                if color.count == 4 { color[3] *= fraction }
                var gradient = fillGradient
                if var faded = gradient {
                    for k in faded.fill.gradient.stops.indices { faded.fill.gradient.stops[k].color[3] *= fraction }
                    gradient = faded
                }
                paints.append((all as CGPath, color, gradient))
            }
        case .bars, .rays:
            let isRays = setup.mode != .level && setup.draw == .rays
            let width = isRays ? setup.lineWidth : geometry.spacing * setup.barWidth
            guard width > 0 else { break }
            let cap: CGLineCap = isRays || setup.barEnds == .round ? .round : .butt
            let color = isRays ? stroke : fill
            let gradient = isRays ? strokeGradient : fillGradient
            let all = CGMutablePath()
            for i in points.indices {
                let bar = CGMutablePath()
                bar.move(to: under[i])
                bar.addLine(to: points[i])
                let area = bar.copy(strokingWithWidth: width, lineCap: cap, lineJoin: .miter, miterLimit: 10)
                if byLevel {
                    if !isRays, !wave.isRight, let shaded = shadedAlong(i, geometry: geometry, outward: outward(i), full: full, setup: setup, frame: frame) {
                        // Shaded up its length, its tip in its level's color.
                        paints.append((area, [0, 0, 0, 0], shaded))
                    } else if let color = leveled(level(i), fallback: color) {
                        paints.append((area, color, nil))
                    }
                } else {
                    all.addPath(bar)
                }
            }
            if !byLevel, !all.isEmpty, gradient != nil || shown(color) != nil {
                paints.append((all.copy(strokingWithWidth: width, lineCap: cap, lineJoin: .miter, miterLimit: 10), shown(color) ?? [0, 0, 0, 0], gradient))
            }
            // Peak Hold: a mark across each bar where its peak is.
            if let peaks = wave.peaks {
                let thickness = max(2, min(6, width * 0.25))
                let marks = CGMutablePath()
                var leveledMarks: [Paint] = []
                for i in points.indices where i < peaks.count {
                    let reach = abs(peaks[i] * setup.height)
                    guard reach > 0 else { continue }
                    var ends = [reach]
                    if wave.side == .both { ends.append(-reach) }
                    let out = outward(i)
                    let across = CGVector(dx: -out.dy * width / 2, dy: out.dx * width / 2)
                    for end in ends {
                        let middle = CGPoint(x: Double(geometry.bases[i].x) + Double(out.dx) * end, y: Double(geometry.bases[i].y) + Double(out.dy) * end)
                        let mark = CGMutablePath()
                        mark.move(to: CGPoint(x: middle.x - across.dx, y: middle.y - across.dy))
                        mark.addLine(to: CGPoint(x: middle.x + across.dx, y: middle.y + across.dy))
                        if byLevel, let color = leveled((reach / max(full, 1e-9)).clamped(between: 0, and: 1), fallback: color) {
                            leveledMarks.append((Self.stroked(mark, width: thickness), color, nil))
                        } else {
                            marks.addPath(mark)
                        }
                    }
                }
                paints += leveledMarks
                if !marks.isEmpty, gradient != nil || shown(color) != nil {
                    paints.append((Self.stroked(marks, width: thickness), shown(color) ?? [0, 0, 0, 0], gradient))
                }
            }
        }
        return paints
    }

    /// The space between `points` and `under` (the baseline, or the
    /// mirrored points), as one area.
    private static func filledArea(_ points: [CGPoint], _ under: [CGPoint], smooth: Bool) -> CGPath {
        let area = CGMutablePath()
        add(points, to: area, smooth: smooth, closed: false)
        if under.count == points.count, zip(under, points).contains(where: { $0 != $1 }), !under.isEmpty {
            // Mirrored, the far side is smoothed too.
            let back = Array(under.reversed())
            area.addLine(to: back[0])
            if smooth {
                let rest = CGMutablePath()
                add(back, to: rest, smooth: true, closed: false)
                area.addPath(rest)
            } else {
                for point in back.dropFirst() { area.addLine(to: point) }
            }
        }
        area.closeSubpath()
        return area
    }

    /// Bar `i` shaded up its length by the Fill's gradient: from its base
    /// (the gradient's start) to the full Height (its end), so its tip has
    /// its level's color; reflected about the base when mirrored.
    private static func shadedAlong(
        _ i: Int, geometry: Baseline, outward: CGVector, full: Double, setup: WaveformSetup, frame: CGRect
    ) -> GradientPaint? {
        guard let fill = setup.fillGradient, full > 0, frame.width > 0, frame.height > 0 else { return nil }
        let base = geometry.bases[i]
        let tip = CGPoint(x: Double(base.x) + Double(outward.dx) * full, y: Double(base.y) + Double(outward.dy) * full)
        func share(_ point: CGPoint) -> CGPoint {
            CGPoint(x: (point.x - frame.minX) / frame.width, y: (point.y - frame.minY) / frame.height)
        }
        var gradient = fill.gradient
        gradient.start = share(base)
        gradient.end = share(tip)
        let style = PaintStyle(kind: .linear, repeats: setup.side == .both ? .reflect : .hold, blend: fill.style.blend, space: .frame)
        return GradientFill(gradient: gradient, style: style).placed(item: frame, frame: frame)
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
