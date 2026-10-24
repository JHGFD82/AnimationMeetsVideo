import AppKit
import CoreMedia
import SwiftUI

/// The scene splitter's panel: the picture, which takes whatever room the
/// panel has, the transport, Merge and Split, the cut sensitivity of the
/// stretch, and along the bottom a ruler over a filmstrip of the scenes
/// shown to skim, click and zoom along. See `SceneSplitter`.
///
/// What changes as the pointer moves (the skim line, the marker, the frame
/// Split would cut at) is read only by small views of its own, so skimming
/// redraws those and not the strip.
struct SceneSplitterView: View {
    @Bindable var splitter: SceneSplitter

    var body: some View {
        Group {
            if let media = splitter.media, splitter.span != nil {
                content(media)
            } else {
                placeholder
            }
        }
        .frame(minWidth: 520, maxWidth: .infinity, minHeight: 420, maxHeight: .infinity)
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
        .padding(Design.Space.sheet)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func content(_ media: MediaClip) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Design.Space.step) {
                SplitterHeader(splitter: splitter, media: media)
                // Fills the room left; the frame is fitted inside it.
                PlayerLayerView(player: splitter.skim.player)
                    .frame(maxWidth: .infinity, minHeight: 120, maxHeight: .infinity)
                    .background(Design.Surface.well.color)
                    .accessibilityHidden(true)
                SplitterTransport(splitter: splitter, frameRate: media.frameRate)
                SplitterEditing(splitter: splitter)
                SplitterSensitivity(splitter: splitter)
            }
            .padding(Design.Space.group)
            Groove()
            ScrubArea(splitter: splitter, media: media)
                .toolEdge(.sceneSplitter)
        }
    }
}

// MARK: - Header and controls

private struct SplitterHeader: View {
    let splitter: SceneSplitter
    let media: MediaClip

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Design.Space.step) {
            ToolGlyph(tone: .sceneSplitter)
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
        guard let first = splitter.scenes.first.flatMap(splitter.number(of:)),
              let last = splitter.scenes.last.flatMap(splitter.number(of:))
        else { return "" }
        return first == last ? "Scene \(first)" : "Scenes \(first)–\(last)"
    }
}

private struct SplitterTransport: View {
    @Bindable var splitter: SceneSplitter
    let frameRate: Double

    var body: some View {
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
            Text(splitter.markerTime.map { $0.compactTimecode(frameRate: frameRate) } ?? "")
                .font(Design.Typeface.timecode)
                .foregroundStyle(Design.marker)
                .accessibilityLabel("Marker")
            Spacer()
            ZoomControls(
                fraction: Binding(
                    get: { ZoomScale.fraction(of: splitter.zoom, in: 1...max(splitter.maximumZoom, 1)) },
                    set: { splitter.setZoom(ZoomScale.zoom(atFraction: $0, in: 1...max(splitter.maximumZoom, 1))) }
                ),
                keys: .plain,
                zoomOut: { splitter.zoom(by: 1 / 1.5) }, zoomIn: { splitter.zoom(by: 1.5) },
                fit: ({ splitter.setZoom(1) }, "Fit the whole stretch")
            )
            .disabled(splitter.maximumZoom <= 1)
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
}

private struct SplitterEditing: View {
    let splitter: SceneSplitter

    var body: some View {
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
}

private struct SplitterSensitivity: View {
    let splitter: SceneSplitter

    var body: some View {
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

/// Where the stretch shown lies across the strip: its content width and
/// the part of it on screen.
private struct StripGeometry {
    var contentWidth: CGFloat
    var length: Double
    var offset: CGFloat
    var viewport: CGFloat

    func x(ofSeconds seconds: Double) -> CGFloat { CGFloat(seconds / length) * contentWidth }

    func seconds(atX x: CGFloat) -> Double {
        guard contentWidth > 0 else { return 0 }
        return Double(x / contentWidth).clamped(between: 0, and: 1) * length
    }

    /// What is on screen, in content points, with a little to spare.
    var visible: ClosedRange<CGFloat> { (offset - 40)...(offset + viewport + 40) }
}

/// A ruler over a filmstrip of the scenes shown, zoomed by `zoom` and
/// scrolled sideways, along the bottom of the panel. Moving the pointer over
/// the strip skims, leaving the marker where it is; a click puts the marker
/// on the frame and picks the scene (Shift and Command as in the browser),
/// and dragging moves the marker. A click on the ruler moves the marker
/// only. Pinching zooms.
private struct ScrubArea: View {
    let splitter: SceneSplitter
    let media: MediaClip
    @State private var viewport: CGFloat = 560
    @State private var offset: CGFloat = 0
    @State private var scroll = ScrollPosition(edge: .leading)
    @State private var isPressing = false
    @State private var zoomBase: Double?

    static let rulerHeight: CGFloat = 18
    static let stripHeight: CGFloat = 58
    /// Space between two scenes' tiles, so where one ends is plain.
    static let gap: CGFloat = 4
    private static let cellHeight = stripHeight - 6
    private static var cellWidth: CGFloat { (cellHeight * 16 / 9).rounded() }

    private var geometry: StripGeometry {
        StripGeometry(contentWidth: viewport * CGFloat(splitter.zoom), length: max(splitter.length, 1e-6), offset: offset, viewport: viewport)
    }

    private var start: CMTime { splitter.span?.start ?? .zero }

    private func x(of time: CMTime) -> CGFloat { geometry.x(ofSeconds: CMTimeSubtract(time, start).seconds) }

    var body: some View {
        let geometry = geometry
        ScrollView(.horizontal) {
            ZStack(alignment: .topLeading) {
                VStack(spacing: 0) {
                    ruler(geometry)
                    strip(geometry)
                }
                MarkerLines(splitter: splitter, geometry: geometry, reveal: reveal)
            }
            .frame(width: geometry.contentWidth, height: Self.rulerHeight + Self.stripHeight, alignment: .topLeading)
        }
        .scrollPosition($scroll)
        .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.x } action: { _, new in offset = new }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
            viewport = width
            splitter.stripWidth = width
        }
        .frame(height: Self.rulerHeight + Self.stripHeight + 10, alignment: .top)
        .background(Design.Surface.sunken.color)
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
        .accessibilityHidden(true)
        .overlay { ScrubAccessibility(splitter: splitter) }
    }

    private func rezoom(from old: Double, to new: Double) {
        guard old > 0 else { return }
        let oldWidth = viewport * CGFloat(old)
        let length = max(splitter.length, 1e-6)
        let markerX = splitter.markerSeconds.map { CGFloat($0 / length) * oldWidth }
        let anchor = markerX.flatMap { (offset...offset + viewport).contains($0) ? $0 : nil } ?? offset + viewport / 2
        let onScreen = anchor - offset
        scrollTo(anchor * CGFloat(new / old) - onScreen, width: viewport * CGFloat(new))
    }

    /// Scrolls `x` (content points) into view when it is off screen.
    private func reveal(_ x: CGFloat) {
        if x < offset || x > offset + viewport { scrollTo(x - viewport * 0.3) }
    }

    private func scrollTo(_ x: CGFloat, width: CGFloat? = nil) {
        let limit = max((width ?? geometry.contentWidth) - viewport, 0)
        scroll.scrollTo(x: min(max(x, 0), limit))
    }

    // MARK: Ruler

    /// Ticks and timecodes grouped as the timeline's ruler groups them, and
    /// a tall tick at each cut, drawn for the part on screen only, since
    /// zoomed in the strip can be far wider than anything should draw at
    /// once.
    private func ruler(_ geometry: StripGeometry) -> some View {
        let from = max(geometry.visible.lowerBound, 0), to = min(geometry.visible.upperBound, geometry.contentWidth)
        let rate = splitter.frameRate
        let perFrame = geometry.contentWidth / CGFloat(geometry.length * rate)
        let firstFrame = start.seconds * rate
        let cuts = splitter.scenes.dropFirst().map { x(of: $0.start) - from }
        return Canvas { context, size in
            for cut in cuts where cut >= -2 && cut <= size.width + 2 {
                context.fill(Path(CGRect(x: cut - 1, y: 0, width: 2, height: size.height)), with: .color(Design.textSecondary))
            }
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
        .frame(width: geometry.contentWidth, height: Self.rulerHeight, alignment: .leading)
        .background(Design.Surface.raised.color)
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { splitter.placeMarker(atSeconds: geometry.seconds(atX: $0.location.x)) }
        )
    }

    // MARK: Strip

    private func strip(_ geometry: StripGeometry) -> some View {
        let visible = geometry.visible
        return ZStack(alignment: .topLeading) {
            ForEach(splitter.scenes, id: \.id) { scene in
                let left = x(of: scene.start), right = x(of: scene.end)
                if right >= visible.lowerBound, left <= visible.upperBound {
                    tile(scene, left: left, right: right, geometry: geometry)
                }
            }
        }
        .frame(width: geometry.contentWidth, height: Self.stripHeight, alignment: .topLeading)
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            switch phase {
            case .active(let point): splitter.hover(atSeconds: geometry.seconds(atX: point.x))
            case .ended: splitter.hover(atSeconds: nil)
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if !isPressing {
                        isPressing = true
                        splitter.click(atSeconds: geometry.seconds(atX: value.startLocation.x), modifiers: NSEvent.modifierFlags)
                    } else if abs(value.translation.width) > 2 {
                        splitter.placeMarker(atSeconds: geometry.seconds(atX: value.location.x))
                    }
                }
                .onEnded { _ in isPressing = false }
        )
    }

    /// One scene as a tile of its own, set apart from its neighbours by a
    /// gap: its pictures from its first frame on, its number, and an outline
    /// when picked. Only the part on screen is built.
    private func tile(_ scene: SceneRange, left: CGFloat, right: CGFloat, geometry: StripGeometry) -> some View {
        let inset = min(Self.gap / 2, max((right - left) / 4, 0))
        let tileLeft = left + inset, tileRight = right - inset
        let shownLeft = max(tileLeft, geometry.visible.lowerBound), shownRight = min(tileRight, geometry.visible.upperBound)
        let isPicked = splitter.selection.contains(scene.id)
        let cells = thumbnailCells(scene, tileLeft: tileLeft, shownLeft: shownLeft, shownRight: shownRight, geometry: geometry)
        return ZStack(alignment: .topLeading) {
            Design.Surface.raised.color
            ForEach(cells, id: \.index) { cell in
                FilmstripThumbnail(url: media.url, time: cell.time, height: Self.cellHeight, keepsPictureWhileLoading: true)
                    .frame(width: Self.cellWidth, height: Self.cellHeight)
                    .offset(x: cell.x - shownLeft)
            }
            if isPicked {
                Design.accent.opacity(0.22)
            }
            if tileLeft >= geometry.visible.lowerBound, let number = splitter.number(of: scene) {
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
            }
        }
        .frame(width: max(shownRight - shownLeft, 1), height: Self.cellHeight, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous)
                .strokeBorder(isPicked ? Design.accent : Design.bevelLightStrong, lineWidth: isPicked ? 2 : 1)
        }
        .offset(x: shownLeft, y: (Self.stripHeight - Self.cellHeight) / 2)
        .allowsHitTesting(false)
    }

    /// The pictures of a tile on screen. Each shows a frame on a grid of a
    /// power of two frames from the scene's start, the finest that gives
    /// every picture its own frame; so while zooming the frames asked for
    /// mostly stay the same, and come from the thumbnail cache instead of
    /// being decoded again at each step.
    private func thumbnailCells(
        _ scene: SceneRange, tileLeft: CGFloat, shownLeft: CGFloat, shownRight: CGFloat, geometry: StripGeometry
    ) -> [(index: Int, x: CGFloat, time: CMTime)] {
        let width = Self.cellWidth
        let perSecond = Double(geometry.contentWidth) / geometry.length
        guard perSecond > 0 else { return [] }
        let frame = 1 / splitter.frameRate
        var gridFrames = 1.0
        while gridFrames * 2 * frame <= Double(width) / perSecond { gridFrames *= 2 }
        let grid = gridFrames * frame
        let sceneLength = CMTimeSubtract(scene.end, scene.start).seconds
        let first = max(0, Int(((shownLeft - tileLeft) / width).rounded(.down)))
        let last = max(first, Int(((shownRight - tileLeft) / width).rounded(.up)))
        return (first..<last).map { index in
            let x = tileLeft + CGFloat(index) * width
            let into = min((Double(x - tileLeft) / perSecond / grid).rounded(.up) * grid, max(sceneLength - frame, 0))
            let source = CMTimeAdd(scene.start, CMTime(seconds: into, preferredTimescale: 6000))
            return (index, x, media.fileTime(forSourceTime: source))
        }
    }
}

/// The marker, yellow, through the ruler and strip with a head in the
/// ruler; and while skimming, a thin line where the pointer is. A view of
/// its own, so the pointer moving redraws only these lines. Brings the
/// marker back into view when stepping or playing takes it off screen.
private struct MarkerLines: View {
    let splitter: SceneSplitter
    let geometry: StripGeometry
    let reveal: (CGFloat) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            if let skimming = splitter.skimming, !splitter.skim.isPlaying {
                Rectangle()
                    .fill(Design.textPrimary.opacity(0.85))
                    .frame(width: 1, height: ScrubArea.stripHeight)
                    .offset(x: geometry.x(ofSeconds: skimming), y: ScrubArea.rulerHeight)
            }
            if let seconds = splitter.markerSeconds {
                let markerX = geometry.x(ofSeconds: seconds)
                Rectangle()
                    .fill(Design.marker)
                    .frame(width: 2, height: ScrubArea.rulerHeight + ScrubArea.stripHeight)
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
        .onChange(of: splitter.markerSeconds) { _, seconds in
            if let seconds { reveal(geometry.x(ofSeconds: seconds)) }
        }
    }
}

/// The strip for VoiceOver: one adjustable element over it (a frame a
/// step) that reads the marker and the picks, with the picks, Split,
/// Merge, the cut jumps and zoom as actions. Apart from the strip, so what
/// it reads changing doesn't redraw the pictures.
private struct ScrubAccessibility: View {
    let splitter: SceneSplitter

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel("Scenes")
            .accessibilityValue(value)
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

    private var value: String {
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
