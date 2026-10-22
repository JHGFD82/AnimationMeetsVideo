import AppKit
import CoreMedia
import SwiftUI

/// The scene splitter's panel: the picture, a ruler over a filmstrip of the
/// scenes shown to skim, click and zoom along, the transport, Merge and
/// Split, and the cut sensitivity of the stretch. As tall as what it holds.
/// See `SceneSplitter`.
struct SceneSplitterView: View {
    @Bindable var splitter: SceneSplitter

    static let pictureHeight: CGFloat = 220

    var body: some View {
        Group {
            if let media = splitter.media, splitter.span != nil {
                content(media)
            } else {
                placeholder
            }
        }
        .padding(Design.Space.group)
        .frame(minWidth: 520, maxWidth: .infinity)
        .fixedSize(horizontal: false, vertical: true)
        .background(Design.Surface.base.color)
        .preferredColorScheme(.dark)
        .tint(Design.accent)
        // The scores arriving, or being found again, change the scenes.
        .onChange(of: splitter.track?.times.count) { _, _ in splitter.refresh() }
        .onChange(of: splitter.skim.isPlaying) { _, playing in
            if !playing { splitter.playDidStop() }
        }
        .alert(
            embedTitle,
            isPresented: Binding(get: { splitter.pendingEdit != nil }, set: { if !$0 { splitter.cancelPendingEdit() } }),
            presenting: splitter.pendingEdit
        ) { _ in
            Button("Cancel", role: .cancel) { splitter.cancelPendingEdit() }
            Button("Embed and Split") { splitter.confirmPendingEdit() }
        } message: { _ in
            Text("Their keyframes run across the new cut. Each will be put into a timeline of its own and split there, and its animation applied to that embedded timeline, so it stays one animation.")
        }
    }

    private var embedTitle: String {
        let count = splitter.pendingEdit?.clipCount ?? 0
        return count == 1 ? "1 animated clip will be embedded" : "\(count) animated clips will be embedded"
    }

    private var placeholder: some View {
        VStack(spacing: Design.Space.step) {
            Image(systemName: "scissors")
                .font(Design.Typeface.glyphLarge)
                .foregroundStyle(Design.textTertiary)
                .accessibilityHidden(true)
            Text("Select a video or its scenes in the browser to split or merge them here.")
                .font(Design.Typeface.body)
                .foregroundStyle(Design.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Design.Space.sheet * 2)
    }

    // MARK: - Content

    private func content(_ media: MediaClip) -> some View {
        VStack(alignment: .leading, spacing: Design.Space.step) {
            header(media)
            PlayerLayerView(player: splitter.skim.player)
                .frame(maxWidth: .infinity)
                .frame(height: Self.pictureHeight)
                .background(Design.Surface.well.color)
                .overlay {
                    Rectangle().strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                }
                .accessibilityHidden(true)
            ScrubArea(splitter: splitter, media: media)
            transport(media)
            editing
            Groove()
            sensitivity
        }
    }

    private func header(_ media: MediaClip) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Design.Space.step) {
            Text(media.name)
                .font(Design.Typeface.panelTitle)
                .foregroundStyle(Design.textPrimary)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
            Text(scenesText)
                .font(Design.Typeface.label)
                .foregroundStyle(Design.textSecondary)
            Spacer()
            if splitter.track == nil, media.kind == .video {
                Text("Finding scenes…")
                    .font(Design.Typeface.label)
                    .foregroundStyle(Design.textSecondary)
            }
        }
    }

    private var scenesText: String {
        let numbers = splitter.scenes.compactMap(splitter.number(of:))
        guard let first = numbers.first, let last = numbers.last else { return "" }
        return first == last ? "Scene \(first)" : "Scenes \(first)–\(last)"
    }

    // MARK: - Transport

    private func transport(_ media: MediaClip) -> some View {
        HStack(spacing: Design.Space.step) {
            Button { splitter.step(frames: -1) } label: { Image(systemName: "backward.frame.fill") }
                .accessibilityLabel("Back one frame")
                .help("Move the marker back one frame (←, Shift for ten)")
            Button { splitter.togglePlay() } label: {
                Image(systemName: splitter.skim.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 16)
                    .contentTransition(.symbolEffect(.replace))
            }
            .accessibilityLabel(splitter.skim.isPlaying ? "Pause" : "Play")
            .help("Play from the marker, or pause (Space)")
            Button { splitter.step(frames: 1) } label: { Image(systemName: "forward.frame.fill") }
                .accessibilityLabel("Forward one frame")
                .help("Move the marker forward one frame (→, Shift for ten)")
            Text(splitter.markerTime.map { $0.compactTimecode(frameRate: media.frameRate) } ?? "")
                .font(Design.Typeface.timecode)
                .foregroundStyle(Design.marker)
                .accessibilityLabel("Marker")
            Spacer()
            Button { splitter.zoom(by: 1 / 1.5) } label: { Image(systemName: "minus.magnifyingglass") }
                .accessibilityLabel("Zoom out")
                .help("Zoom out (-)")
                .disabled(splitter.zoom <= 1)
            Slider(
                value: Binding(get: { log(splitter.zoom) }, set: { splitter.setZoom(exp($0)) }),
                in: 0...max(log(splitter.maximumZoom), 0.001)
            )
            .frame(width: 90)
            .controlSize(.small)
            .disabled(splitter.maximumZoom <= 1)
            .accessibilityLabel("Zoom")
            .accessibilityValue("\(Int((splitter.zoom * 100).rounded())) percent")
            Button { splitter.zoom(by: 1.5) } label: { Image(systemName: "plus.magnifyingglass") }
                .accessibilityLabel("Zoom in")
                .help("Zoom in (=), or pinch the strip")
                .disabled(splitter.zoom >= splitter.maximumZoom)
            Toggle(isOn: $splitter.isSoundOn) {
                Image(systemName: splitter.isSoundOn ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .frame(width: 18)
            }
            .toggleStyle(.button)
            .accessibilityLabel("Sound")
            .accessibilityValue(splitter.isSoundOn ? "on" : "off")
            .help(splitter.isSoundOn ? "Skimming and playing are heard. Click to silence them." : "Skimming and playing are silent. Click to hear them.")
        }
        .buttonStyle(.borderless)
        .font(Design.Typeface.icon)
    }

    // MARK: - Merging and splitting

    private var editing: some View {
        HStack(spacing: Design.Space.step) {
            Button("Merge") { splitter.merge() }
                .disabled(splitter.mergeable == nil)
                .help("Join the picked scenes into one: click one, then Shift-click another (M)")
            Text(pickedText)
                .font(Design.Typeface.label)
                .foregroundStyle(Design.textSecondary)
            Spacer()
            Button("Split into new clip") { splitter.split() }
                .buttonStyle(.borderedProminent)
                .tint(Design.accentFill)
                .disabled(splitter.splitTime == nil)
                .help("Start a new clip at the frame shown (S)")
        }
    }

    private var pickedText: String {
        let count = splitter.selection.items.count
        switch count {
        case 0: return "Click scenes to pick them"
        case 1: return "1 scene picked"
        default: return splitter.mergeable == nil ? "\(count) picked, not side by side" : "\(count) scenes picked"
        }
    }

    // MARK: - Sensitivity

    private var sensitivity: some View {
        HStack(spacing: Design.Space.step) {
            Text("Cut sensitivity")
                .font(Design.Typeface.groupTitle)
                .foregroundStyle(Design.textPrimary)
                .help("Finds the cuts again between the outer edges of the scenes shown. Cuts you made by hand stay.")
            Text("Fewer")
                .font(Design.Typeface.label)
                .foregroundStyle(Design.textSecondary)
                .accessibilityHidden(true)
            SensitivitySlider(splitter: splitter)
            Text("More")
                .font(Design.Typeface.label)
                .foregroundStyle(Design.textSecondary)
                .accessibilityHidden(true)
            Text(splitter.scenes.count == 1 ? "1 scene" : "\(splitter.scenes.count) scenes")
                .font(Design.Typeface.numericSmall)
                .foregroundStyle(splitter.draftSensitivity == nil ? Design.textSecondary : Design.accent)
                .frame(minWidth: 64, alignment: .trailing)
        }
        .disabled(splitter.track == nil)
    }
}

/// The sensitivity slider: dragging shows the scenes it would make, and
/// letting go applies it. A change that isn't a drag (VoiceOver, the
/// keyboard) applies at once.
private struct SensitivitySlider: View {
    let splitter: SceneSplitter
    @State private var isDragging = false

    var body: some View {
        Slider(
            value: Binding(
                get: { splitter.sensitivity },
                set: { value in
                    if isDragging {
                        splitter.drag(sensitivity: value)
                    } else {
                        splitter.applySensitivity(value)
                    }
                }
            ),
            in: 0...1,
            onEditingChanged: { editing in
                isDragging = editing
                if !editing, let value = splitter.draftSensitivity { splitter.applySensitivity(value) }
            }
        )
        .controlSize(.small)
        .accessibilityLabel("Cut sensitivity")
        .accessibilityValue("\(Int((splitter.sensitivity * 100).rounded())) percent, \(splitter.scenes.count) scene\(splitter.scenes.count == 1 ? "" : "s")")
        .accessibilityHint("Higher finds more cuts")
    }
}

// MARK: - The ruler and strip

/// A ruler over a filmstrip of the scenes shown, zoomed by `zoom` and
/// scrolled sideways. Moving the pointer over the strip skims, leaving the
/// marker where it is; a click puts the marker on the frame and picks the
/// scene (Shift and Command as in the browser), and dragging moves the
/// marker. A click on the ruler moves the marker only. Pinching zooms.
private struct ScrubArea: View {
    let splitter: SceneSplitter
    let media: MediaClip
    @State private var viewport: CGFloat = 560
    @State private var offset: CGFloat = 0
    @State private var scroll = ScrollPosition(edge: .leading)
    @State private var isPressing = false
    @State private var zoomBase: Double?

    static let rulerHeight: CGFloat = 18
    static let stripHeight: CGFloat = 54
    private static var cellWidth: CGFloat { (stripHeight * 16 / 9).rounded() }

    private var contentWidth: CGFloat { viewport * CGFloat(splitter.zoom) }
    private var length: Double { max(splitter.length, 1e-6) }
    private var start: CMTime { splitter.span?.start ?? .zero }

    private func x(ofSeconds seconds: Double) -> CGFloat { CGFloat(seconds / length) * contentWidth }
    private func x(of time: CMTime) -> CGFloat { x(ofSeconds: CMTimeSubtract(time, start).seconds) }
    private func seconds(atX x: CGFloat) -> Double {
        guard contentWidth > 0 else { return 0 }
        return min(max(Double(x / contentWidth), 0), 1) * length
    }

    /// What is on screen, in content points, with a little to spare.
    private var visible: ClosedRange<CGFloat> { (offset - 40)...(offset + viewport + 40) }

    var body: some View {
        ScrollView(.horizontal) {
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    ruler
                    strip
                }
                lines
            }
            .frame(width: contentWidth, height: Self.rulerHeight + Self.stripHeight, alignment: .topLeading)
        }
        .scrollPosition($scroll)
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, new in offset = new }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            viewport = width
            splitter.stripWidth = width
        }
        .frame(height: Self.rulerHeight + Self.stripHeight + 10, alignment: .top)
        .background(Design.Surface.sunken.color)
        .clipShape(RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous))
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { value in
                    let base = zoomBase ?? splitter.zoom
                    zoomBase = base
                    splitter.setZoom(base * value.magnification)
                }
                .onEnded { _ in zoomBase = nil }
        )
        // Zooming keeps the marker where it is on screen, or the middle
        // when the marker is off it.
        .onChange(of: splitter.zoom) { old, new in rezoom(from: old, to: new) }
        // The marker moving off screen (stepping, playing) brings it back.
        .onChange(of: splitter.markerSeconds) { _, seconds in
            guard let seconds else { return }
            let markerX = x(ofSeconds: seconds)
            if markerX < offset || markerX > offset + viewport { scrollTo(markerX - viewport * 0.3) }
        }
        .accessibilityElement()
        .accessibilityLabel("Scenes")
        .accessibilityValue(accessibilityValue)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: splitter.step(frames: 1)
            case .decrement: splitter.step(frames: -1)
            @unknown default: break
            }
        }
        .accessibilityAction(named: "Pick Scene at Marker") { splitter.pickAtMarker() }
        .accessibilityAction(named: "Add Scenes up to Marker") { splitter.pickAtMarker(modifiers: .shift) }
        .accessibilityAction(named: "Split into New Clip") { splitter.split() }
        .accessibilityAction(named: "Merge") { splitter.merge() }
        .accessibilityAction(named: "Previous Cut") { splitter.jumpToCut(.previous) }
        .accessibilityAction(named: "Next Cut") { splitter.jumpToCut(.next) }
        .accessibilityAction(named: "Zoom In") { splitter.zoom(by: 1.5) }
        .accessibilityAction(named: "Zoom Out") { splitter.zoom(by: 1 / 1.5) }
    }

    private func rezoom(from old: Double, to new: Double) {
        guard old > 0 else { return }
        let oldWidth = viewport * CGFloat(old)
        let markerX = splitter.markerSeconds.map { CGFloat($0 / length) * oldWidth }
        let anchor = markerX.flatMap { (offset...offset + viewport).contains($0) ? $0 : nil } ?? offset + viewport / 2
        let onScreen = anchor - offset
        scrollTo(anchor * CGFloat(new / old) - onScreen, width: viewport * CGFloat(new))
    }

    private func scrollTo(_ x: CGFloat, width: CGFloat? = nil) {
        let limit = max((width ?? contentWidth) - viewport, 0)
        scroll.scrollTo(x: min(max(x, 0), limit))
    }

    // MARK: Ruler

    /// Ticks and timecodes grouped as the timeline's ruler groups them,
    /// drawn for the part on screen only, since zoomed in the strip can be
    /// far wider than anything should draw at once.
    private var ruler: some View {
        let from = max(visible.lowerBound, 0), to = min(visible.upperBound, contentWidth)
        let rate = splitter.frameRate
        let perFrame = contentWidth / CGFloat(length * rate)
        let firstFrame = start.seconds * rate
        return Canvas { context, size in
            let ticks = RulerTicks(frameRate: rate, pixelsPerFrame: perFrame)
            let step = ticks.framesPerTick
            var frame = Int(((firstFrame + Double(from / perFrame)) / Double(step)).rounded(.down)) * step
            while true {
                let x = CGFloat(Double(frame) - firstFrame) * perFrame - from
                if x > size.width { break }
                defer { frame += step }
                guard x >= -1 else { continue }
                let level = ticks.level(ofFrame: frame)
                let height: CGFloat = level == .label ? 8 : (level == .mid ? 5 : 3)
                context.fill(Path(CGRect(x: x, y: size.height - height, width: 1, height: height)), with: .color(Design.textTertiary))
                if level == .label {
                    let label = CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(max(1, Int(rate.rounded()))))
                    context.draw(
                        Text(label.compactTimecode(frameRate: rate)).font(Design.Typeface.numericScale).foregroundStyle(Design.textSecondary),
                        at: CGPoint(x: x + 3, y: 1), anchor: .topLeading
                    )
                }
            }
        }
        .frame(width: max(to - from, 0), height: Self.rulerHeight)
        .offset(x: from)
        .frame(width: contentWidth, height: Self.rulerHeight, alignment: .leading)
        .background(Design.Surface.raised.color)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { splitter.placeMarker(atSeconds: seconds(atX: $0.location.x)) }
        )
    }

    // MARK: Strip

    private var strip: some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(splitter.scenes.enumerated()), id: \.element.id) { index, scene in
                let left = x(of: scene.start), right = x(of: scene.end)
                if right >= visible.lowerBound, left <= visible.upperBound {
                    segment(scene, index: index, left: left, right: right)
                }
            }
        }
        .frame(width: contentWidth, height: Self.stripHeight, alignment: .topLeading)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let point): splitter.hover(atSeconds: seconds(atX: point.x))
            case .ended: splitter.hover(atSeconds: nil)
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if !isPressing {
                        isPressing = true
                        splitter.click(atSeconds: seconds(atX: value.startLocation.x), modifiers: NSEvent.modifierFlags)
                    } else if abs(value.translation.width) > 2 {
                        splitter.placeMarker(atSeconds: seconds(atX: value.location.x))
                    }
                }
                .onEnded { _ in isPressing = false }
        )
    }

    /// One scene: its pictures from its first frame on, its number, a line
    /// at the cut that starts it, and an outline when picked. Only the part
    /// on screen is built.
    private func segment(_ scene: SceneRange, index: Int, left: CGFloat, right: CGFloat) -> some View {
        let shownLeft = max(left, visible.lowerBound), shownRight = min(right, visible.upperBound)
        let isPicked = splitter.selection.contains(scene.id)
        let cell = Self.cellWidth
        let firstCell = max(0, Int(((shownLeft - left) / cell).rounded(.down)))
        let lastCell = max(firstCell, Int(((shownRight - left) / cell).rounded(.up)))
        return ZStack(alignment: .topLeading) {
            ForEach(firstCell..<lastCell, id: \.self) { n in
                let cellLeft = left + CGFloat(n) * cell
                FilmstripThumbnail(url: media.url, time: thumbnailTime(atX: cellLeft), height: Self.stripHeight)
                    .frame(width: cell, height: Self.stripHeight)
                    .offset(x: cellLeft - shownLeft)
            }
            if isPicked {
                Rectangle().fill(Design.accent.opacity(0.22))
            }
            if left >= visible.lowerBound, let number = splitter.number(of: scene) {
                HStack(spacing: 2) {
                    Text("\(number)")
                        .font(Design.Typeface.numericTag)
                    if scene.origin == .manual {
                        Image(systemName: "hand.point.up.left")
                            .font(Design.Typeface.glyphTiny)
                    }
                }
                .foregroundStyle(Design.textOnColor)
                .padding(.horizontal, 3)
                .padding(.vertical, 1)
                .background(Color.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 2))
                .padding(3)
                .accessibilityHidden(true)
            }
            if index > 0, left >= visible.lowerBound {
                Rectangle()
                    .fill(Design.hairline)
                    .frame(width: 2)
            }
            if isPicked {
                Rectangle()
                    .strokeBorder(Design.accent, lineWidth: 2)
            }
        }
        .frame(width: max(shownRight - shownLeft, 1), height: Self.stripHeight, alignment: .topLeading)
        .clipped()
        .offset(x: shownLeft)
        .allowsHitTesting(false)
    }

    /// The frame a picture at `x` shows: the footage's frame there, in the
    /// file's time.
    private func thumbnailTime(atX x: CGFloat) -> CMTime {
        let rate = splitter.frameRate
        let time = CMTimeAdd(start, CMTime(seconds: seconds(atX: x), preferredTimescale: 6000))
        let frame = (time.seconds * rate).rounded(.down)
        return media.fileTime(forSourceTime: CMTime(seconds: frame / rate, preferredTimescale: 6000))
    }

    // MARK: Lines

    /// The marker, yellow, through the ruler and strip with a head in the
    /// ruler; and while skimming, a thin line where the pointer is.
    private var lines: some View {
        ZStack(alignment: .topLeading) {
            if let skimming = splitter.skimming, !splitter.skim.isPlaying {
                Rectangle()
                    .fill(Design.textPrimary.opacity(0.8))
                    .frame(width: 1, height: Self.stripHeight)
                    .offset(x: x(ofSeconds: skimming), y: Self.rulerHeight)
            }
            if let seconds = splitter.markerSeconds {
                let markerX = x(ofSeconds: seconds)
                Rectangle()
                    .fill(Design.marker)
                    .frame(width: 2, height: Self.rulerHeight + Self.stripHeight)
                    .offset(x: markerX - 1)
                Path { path in
                    path.move(to: CGPoint(x: 0, y: 0))
                    path.addLine(to: CGPoint(x: 10, y: 0))
                    path.addLine(to: CGPoint(x: 5, y: 7))
                    path.closeSubpath()
                }
                .fill(Design.marker)
                .frame(width: 10, height: 7)
                .offset(x: markerX - 5)
            }
        }
        .allowsHitTesting(false)
    }

    private var accessibilityValue: String {
        var parts: [String] = []
        if let time = splitter.markerTime {
            if let scene = splitter.scene(at: time), let number = splitter.number(of: scene) {
                parts.append("marker in scene \(number)")
            }
            parts.append(time.compactTimecode(frameRate: splitter.frameRate))
        }
        let picked = splitter.selection.items.count
        if picked > 0 { parts.append(picked == 1 ? "1 scene picked" : "\(picked) scenes picked") }
        parts.append(splitter.scenes.count == 1 ? "1 scene shown" : "\(splitter.scenes.count) scenes shown")
        return parts.joined(separator: ", ")
    }
}
