import AppKit
import CoreMedia
import SwiftUI

/// The song in the beat match panel: a ruler to scrub, a strip of sections,
/// and the waveform with its beats. Pinch or ⌘= and ⌘- zoom, down to single
/// samples; scrolling pans.
///
/// - Ruler: click or drag to move the playhead.
/// - Section strip: drag on unmarked song to draw a section of the chosen
///   kind, drag an edge to move it, click a section to select it, and
///   double-click a gap to fill it.
/// - Waveform: click a beat to select it and drag it to move it (which pins
///   it); click elsewhere to move the playhead; double-click to add a beat
///   (an anchor, before the section is filled), or while drawing sections,
///   to fill the gap.
struct BeatMatchWaveform: View {
    @Bindable var session: BeatMatchSession

    @State private var drag: Drag?
    /// Where a drag is now, for previews.
    @State private var dragX: CGFloat = 0

    private enum Drag {
        case scrub
        case draw(from: Double)
        case edge(UUID, BeatMap.Edge)
        case beat(CMTime, grab: CGFloat)
        case pressSection(UUID)
        case pressWave
        case pressStrip
    }

    static let rulerHeight: CGFloat = 18
    /// The section strip matches the timeline's section lane.
    static let stripHeight: CGFloat = SectionLane.height
    /// How close, on screen, the pointer must be to grab an edge or a beat,
    /// and to click in against a neighbour.
    static let reach: CGFloat = 6

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, size in
                draw(in: &context, size: size)
            }
            .background(Design.Surface.sunken.color)
            .overlay(alignment: .topLeading) { sectionStrip(width: geometry.size.width) }
            .clipped()
            .contentShape(Rectangle())
            .gesture(dragGesture(height: geometry.size.height))
            .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { value in
                doubleClick(at: value.location)
            })
            // A resize arrow over what a drag moves sideways: a section's
            // edge, or a beat. A section itself doesn't move as a whole.
            .onContinuousHover { phase in
                switch phase {
                case .active(let point) where drag == nil:
                    (resizes(at: point) ? NSCursor.resizeLeftRight : NSCursor.arrow).set()
                case .active:
                    break
                case .ended:
                    NSCursor.arrow.set()
                }
            }
            .background(
                TimelineInputMonitor(
                    onMagnify: { factor, _, x, _ in session.zoom(by: factor, aboutX: x) },
                    onScroll: { deltaX, deltaY, _, _ in
                        session.scroll(byPoints: abs(deltaX) >= abs(deltaY) ? deltaX : -deltaY)
                        return true
                    }
                )
            )
            .onChange(of: geometry.size.width, initial: true) { _, width in session.viewWidth = width }
        }
        .accessibilityElement()
        .accessibilityLabel("Waveform of \(session.assetName)")
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(.allowsDirectInteraction)
        .accessibilityAction(named: "Play or pause") { session.togglePlayback() }
        .accessibilityAction(named: "Add a beat at the playhead") { session.addBeatAtPlayhead() }
        .accessibilityAction(named: "Fill the gap at the playhead") { session.fillGap(at: session.playhead) }
        .accessibilityAction(named: "Select the next beat") { session.selectBeat(step: 1) }
        .accessibilityAction(named: "Select the previous beat") { session.selectBeat(step: -1) }
        .accessibilityAction(named: "Move the selected beat 1 millisecond later") { session.nudgeSelected(by: 0.001) }
        .accessibilityAction(named: "Move the selected beat 1 millisecond earlier") { session.nudgeSelected(by: -0.001) }
        .accessibilityAction(named: "Delete the selected beat") { session.deleteSelectedBeat() }
    }

    private var accessibilityValue: String {
        var parts = ["Playhead at \(Self.timeText(session.playhead))"]
        if let beat = session.selectedMappedBeat {
            parts.append("beat \(beat.position) selected at \(Self.timeText(beat.time.seconds))\(beat.isPinned ? ", pinned" : "")")
        }
        parts.append("\(session.map.sections.count) sections")
        return parts.joined(separator: ", ")
    }

    // MARK: Drawing

    private func draw(in context: inout GraphicsContext, size: CGSize) {
        let waveTop = Self.rulerHeight + Self.stripHeight
        let waveRect = CGRect(x: 0, y: waveTop, width: size.width, height: max(0, size.height - waveTop))
        drawRuler(in: &context, width: size.width)
        if let loop = session.loopRange {
            let x0 = session.x(of: loop.lowerBound), x1 = session.x(of: loop.upperBound)
            context.fill(Path(CGRect(x: x0, y: waveTop, width: x1 - x0, height: waveRect.height)), with: .color(Design.accent.opacity(0.08)))
        }
        // Each layer is held to its own area, whatever the samples say.
        context.drawLayer { layer in
            layer.clip(to: Path(waveRect))
            drawWave(in: &layer, rect: waveRect)
            drawBeats(in: &layer, rect: waveRect)
        }
        let x = session.x(of: session.playhead)
        var line = Path()
        line.move(to: CGPoint(x: x, y: 0))
        line.addLine(to: CGPoint(x: x, y: size.height))
        context.stroke(line, with: .color(Design.playhead), lineWidth: 1.5)
    }

    private func drawRuler(in context: inout GraphicsContext, width: CGFloat) {
        context.fill(Path(CGRect(x: 0, y: 0, width: width, height: Self.rulerHeight)), with: .color(Design.Surface.raised.color))
        let spacing = Self.labelSpacing(secondsPerPoint: session.secondsPerPoint)
        let first = (session.visibleStart / spacing).rounded(.down) * spacing
        var seconds = first
        var ticks = Path()
        while session.x(of: seconds) < width {
            let x = session.x(of: seconds)
            ticks.move(to: CGPoint(x: x, y: Self.rulerHeight - 5))
            ticks.addLine(to: CGPoint(x: x, y: Self.rulerHeight))
            if seconds >= 0 {
                context.draw(
                    Text(Self.timeText(seconds, spacing: spacing)).font(Design.Typeface.numericMicro).foregroundStyle(Design.textSecondary),
                    at: CGPoint(x: x + 3, y: 2), anchor: .topLeading
                )
            }
            seconds += spacing
        }
        context.stroke(ticks, with: .color(Design.textTertiary), lineWidth: 1)
    }

    private func drawWave(in context: inout GraphicsContext, rect: CGRect) {
        guard let audio = session.audio, rect.height > 0 else { return }
        // Scaled to the song's loudest sample, so it fills the area and
        // never runs past it.
        let middle = rect.midY, half = rect.height / 2 * 0.92 / CGFloat(audio.peak)
        let samplesPerPoint = session.secondsPerPoint * audio.sampleRate
        let color = Design.ClipTone.music.color
        if let level = audio.level(forSamplesPerPoint: samplesPerPoint) {
            var shape = Path()
            for column in 0..<Int(rect.width) {
                let from = audio.sample(atSeconds: session.seconds(atX: CGFloat(column)))
                let to = from + samplesPerPoint
                let low = max(0, Int(from) / level.samplesPerBucket), high = min(level.high.count, Int(to.rounded(.up)) / level.samplesPerBucket + 1)
                guard low < high else { continue }
                let top = level.high[low..<high].max() ?? 0, bottom = level.low[low..<high].min() ?? 0
                shape.addRect(CGRect(x: CGFloat(column), y: middle - CGFloat(top) * half, width: 1, height: max(1, CGFloat(top - bottom) * half)))
            }
            context.fill(shape, with: .color(color))
        } else {
            // Close in: the samples themselves, joined, with dots once they
            // are a few points apart.
            let first = max(0, Int(audio.sample(atSeconds: session.visibleStart)) - 1)
            let last = min(audio.samples.count - 1, Int(audio.sample(atSeconds: session.seconds(atX: rect.width))) + 1)
            guard first <= last else { return }
            var line = Path(), dots = Path()
            for index in first...last {
                let point = CGPoint(x: session.x(of: audio.seconds(atSample: index)), y: middle - CGFloat(audio.samples[index]) * half)
                if index == first { line.move(to: point) } else { line.addLine(to: point) }
                if samplesPerPoint < 0.34 { dots.addEllipse(in: CGRect(x: point.x - 1.5, y: point.y - 1.5, width: 3, height: 3)) }
            }
            context.stroke(line, with: .color(color), lineWidth: 1)
            context.fill(dots, with: .color(color))
        }
        var axis = Path()
        axis.move(to: CGPoint(x: 0, y: middle))
        axis.addLine(to: CGPoint(x: rect.width, y: middle))
        context.stroke(axis, with: .color(Design.textTertiary.opacity(0.4)), lineWidth: 1)
    }

    /// The sections, drawn as the timeline's section lane draws its own:
    /// bronze chips with the kind (and measure and tempo, once known) for a
    /// name. Drawn only; the waveform's drag does the editing.
    private func sectionStrip(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.22)
            ForEach(session.map.sections) { section in
                let (x0, x1) = shownEdges(of: section)
                if x1 > 0, x0 < width {
                    sectionChip(section, width: max(2, x1 - x0))
                        .offset(x: x0, y: 2)
                }
            }
            if case .draw(let from) = drag {
                let x0 = session.x(of: from)
                RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous)
                    .strokeBorder(Design.section, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    .frame(width: abs(dragX - x0), height: Self.stripHeight - 4)
                    .offset(x: min(dragX, x0), y: 2)
            }
        }
        .frame(width: width, height: Self.stripHeight, alignment: .topLeading)
        .clipped()
        .offset(y: Self.rulerHeight)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// A section's edges on screen, following an edge being dragged.
    private func shownEdges(of section: BeatSection) -> (CGFloat, CGFloat) {
        var x0 = session.x(of: section.start.seconds), x1 = session.x(of: section.end.seconds)
        if case .edge(let id, let edge) = drag, id == section.id {
            if edge == .start { x0 = dragX } else { x1 = dragX }
        }
        return (x0, x1)
    }

    private func sectionChip(_ section: BeatSection, width: CGFloat) -> some View {
        let isSelected = session.selectedSectionID == section.id
        return RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous)
            .fill(Design.clipFill(Design.section, selected: isSelected))
            .overlay {
                RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous)
                    .strokeBorder(isSelected ? Design.textOnColor.opacity(0.95) : Design.section.opacity(0.85), lineWidth: isSelected ? 1.5 : 1)
            }
            .overlay {
                RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous)
                    .strokeBorder(Design.bevelEdge, lineWidth: 1)
            }
            .overlay(alignment: .leading) {
                Text(label(of: section))
                    .font(Design.Typeface.label.weight(.medium))
                    .foregroundStyle(Design.textOnColor)
                    .lineLimit(1)
                    .padding(.horizontal, Design.Space.tight)
            }
            .opacity(section.kind == .none ? 0.6 : 1)
            .frame(width: width, height: Self.stripHeight - 4)
            .clipped()
    }

    private func label(of section: BeatSection) -> String {
        var parts = [section.kind.name]
        if section.kind != .none {
            if section.isMeasureSet { parts.append("\(section.beatsPerMeasure) beats a measure") }
            if section.isConfirmed, let gap = BeatFitting.medianGap(of: section.beats.map(\.time.seconds)) {
                parts.append(String(format: "%.2f BPM", 60 / gap))
            }
        }
        return parts.joined(separator: " · ")
    }

    private func drawBeats(in context: inout GraphicsContext, rect: CGRect) {
        let visible = session.visibleStart...session.seconds(atX: rect.width)
        var beats = Path(), downbeats = Path(), anchors = Path(), handles = Path()
        var selected: CGFloat?
        for section in session.map.sections where section.kind != .none {
            for beat in section.beats {
                var seconds = beat.time.seconds
                if case .beat(let time, let grab) = drag, time == beat.time { seconds = session.seconds(atX: dragX - grab) }
                guard visible.contains(seconds) else { continue }
                let x = session.x(of: seconds)
                var line = Path()
                line.move(to: CGPoint(x: x, y: rect.minY))
                line.addLine(to: CGPoint(x: x, y: rect.maxY))
                if session.selectedBeat == beat.time {
                    selected = x
                } else if !section.isConfirmed {
                    anchors.addPath(line)
                } else if beat.isDownbeat {
                    downbeats.addPath(line)
                } else {
                    beats.addPath(line)
                }
                if beat.isPinned {
                    handles.addPath(Path { path in
                        path.move(to: CGPoint(x: x, y: rect.minY))
                        path.addLine(to: CGPoint(x: x + 4, y: rect.minY + 5))
                        path.addLine(to: CGPoint(x: x, y: rect.minY + 10))
                        path.addLine(to: CGPoint(x: x - 4, y: rect.minY + 5))
                        path.closeSubpath()
                    })
                }
            }
        }
        context.stroke(beats, with: .color(Design.beat.opacity(0.55)), lineWidth: 1)
        context.stroke(downbeats, with: .color(Design.beat), lineWidth: 2)
        context.stroke(anchors, with: .color(Design.keyframe), lineWidth: 1.5)
        context.fill(handles, with: .color(Design.keyframe))
        if let selected {
            var line = Path()
            line.move(to: CGPoint(x: selected, y: rect.minY))
            line.addLine(to: CGPoint(x: selected, y: rect.maxY))
            context.stroke(line, with: .color(Design.accent), lineWidth: 2)
        }
    }

    // MARK: Pointer

    private func dragGesture(height: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                dragX = value.location.x
                if drag == nil { drag = begin(at: value.startLocation) }
                switch drag {
                case .scrub: session.seek(to: session.seconds(atX: value.location.x))
                case .pressSection, .pressWave, .pressStrip:
                    // A press that moves on unmarked song draws; on the wave it scrubs.
                    if abs(value.translation.width) > 3 {
                        if case .pressStrip = drag {
                            drag = .draw(from: session.seconds(atX: value.startLocation.x))
                        } else if case .pressWave = drag {
                            drag = .scrub
                        }
                    }
                default: break
                }
            }
            .onEnded { value in
                defer { drag = nil }
                let seconds = session.seconds(atX: value.location.x)
                let snap = Double(Self.reach) * session.secondsPerPoint
                switch drag {
                case .draw(let from):
                    session.drawSection(from: from, to: seconds, snap: snap)
                case .edge(let id, let edge):
                    session.moveEdge(edge, of: id, to: seconds, snap: snap)
                case .beat(let time, let grab):
                    if abs(value.translation.width) > 1 {
                        session.moveBeat(at: time, to: session.seconds(atX: value.location.x - grab))
                    }
                case .pressSection(let id):
                    session.selectedSectionID = id
                case .pressWave:
                    session.selectedBeat = nil
                    session.seek(to: seconds)
                case .pressStrip:
                    session.selectedSectionID = nil
                case .scrub, nil:
                    break
                }
            }
    }

    /// Whether a drag from `point` moves an edge or a beat sideways.
    private func resizes(at point: CGPoint) -> Bool {
        guard point.y >= Self.rulerHeight else { return false }
        if point.y < Self.rulerHeight + Self.stripHeight {
            return session.map.sections.contains { section in
                abs(session.x(of: section.start.seconds) - point.x) <= Self.reach
                    || abs(session.x(of: section.end.seconds) - point.x) <= Self.reach
            }
        }
        let reach = CMTime(seconds: Double(Self.reach) * session.secondsPerPoint, preferredTimescale: 192_000)
        return session.map.nearestBeat(to: BeatFitting.time(session.seconds(atX: point.x), sampleRate: 192_000), within: reach) != nil
    }

    /// What a press at `point` starts.
    private func begin(at point: CGPoint) -> Drag {
        if point.y < Self.rulerHeight {
            session.seek(to: session.seconds(atX: point.x))
            return .scrub
        }
        let seconds = session.seconds(atX: point.x)
        if point.y < Self.rulerHeight + Self.stripHeight {
            for section in session.map.sections {
                if abs(session.x(of: section.start.seconds) - point.x) <= Self.reach {
                    session.selectedSectionID = section.id
                    return .edge(section.id, .start)
                }
                if abs(session.x(of: section.end.seconds) - point.x) <= Self.reach {
                    session.selectedSectionID = section.id
                    return .edge(section.id, .end)
                }
            }
            if let index = session.map.sectionIndex(containing: BeatFitting.time(seconds, sampleRate: 48_000)) {
                return .pressSection(session.map.sections[index].id)
            }
            return .pressStrip
        }
        let reach = CMTime(seconds: Double(Self.reach) * session.secondsPerPoint, preferredTimescale: 192_000)
        if let beat = session.map.nearestBeat(to: BeatFitting.time(seconds, sampleRate: 192_000), within: reach) {
            session.selectedBeat = beat.time
            if let index = session.map.sectionIndex(containing: beat.time) {
                session.selectedSectionID = session.map.sections[index].id
            }
            return .beat(beat.time, grab: point.x - session.x(of: beat.time.seconds))
        }
        return .pressWave
    }

    private func doubleClick(at point: CGPoint) {
        guard point.y >= Self.rulerHeight else { return }
        let seconds = session.seconds(atX: point.x)
        if point.y < Self.rulerHeight + Self.stripHeight || session.step == .drawSections {
            session.fillGap(at: seconds)
        } else {
            session.addBeat(at: seconds)
        }
    }

    // MARK: Text

    /// Ruler labels at least 70 points apart, on round steps.
    static func labelSpacing(secondsPerPoint: Double) -> Double {
        let wanted = secondsPerPoint * 70
        let steps = [0.0001, 0.0002, 0.0005, 0.001, 0.002, 0.005, 0.01, 0.02, 0.05, 0.1, 0.2, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300]
        return steps.first { $0 >= wanted } ?? 600
    }

    /// Minutes, seconds and as many decimals as `spacing` needs.
    static func timeText(_ seconds: Double, spacing: Double = 0.001) -> String {
        let decimals = spacing >= 1 ? 0 : min(4, Int((-log10(spacing)).rounded(.up)))
        let minutes = Int(seconds / 60)
        let rest = seconds - Double(minutes) * 60
        let secondsText = String(format: "%0\(decimals == 0 ? 2 : decimals + 3).\(decimals)f", rest)
        return "\(minutes):\(secondsText)"
    }
}
