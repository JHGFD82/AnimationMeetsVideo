import CoreMedia
import SwiftUI

/// The scene splitter's panel: the picture, a strip of the scenes shown to
/// skim along, the transport, Split and the two merges, and the cut
/// sensitivity of the stretch. See `SceneSplitter`.
struct SceneSplitterView: View {
    @Bindable var splitter: SceneSplitter

    var body: some View {
        Group {
            if let media = splitter.media, let span = splitter.span {
                content(media, span: span)
            } else {
                placeholder
            }
        }
        .padding(Design.Space.sheet)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Design.Surface.base.color)
        .preferredColorScheme(.dark)
        .tint(Design.accent)
        // The scores arriving, or being found again, change the scenes.
        .onChange(of: splitter.track?.times.count) { _, _ in splitter.refresh() }
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Content

    private func content(_ media: MediaClip, span: (start: CMTime, end: CMTime)) -> some View {
        VStack(alignment: .leading, spacing: Design.Space.group) {
            header(media)
            PlayerLayerView(player: splitter.skim.player)
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .background(Design.Surface.well.color)
                .overlay {
                    Rectangle().strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                }
                .accessibilityHidden(true)
            SceneStrip(splitter: splitter, span: span, frameRate: media.frameRate)
                .frame(height: 44)
            transport(media)
            editing
            Groove()
            sensitivity
            Text("Changes are made at once; Undo takes them back. Clips on a timeline cut from these scenes are split and joined with them.")
                .font(Design.Typeface.label)
                .foregroundStyle(Design.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func header(_ media: MediaClip) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Design.Space.step) {
            Text(media.name)
                .font(Design.Typeface.title)
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
                .help("Back one frame (←, Shift for ten)")
            Button { splitter.togglePlay() } label: {
                Image(systemName: splitter.skim.isPlaying ? "pause.fill" : "play.fill")
                    .frame(width: 16)
                    .contentTransition(.symbolEffect(.replace))
            }
            .accessibilityLabel(splitter.skim.isPlaying ? "Pause" : "Play")
            .help("Play or pause (Space)")
            Button { splitter.step(frames: 1) } label: { Image(systemName: "forward.frame.fill") }
                .accessibilityLabel("Forward one frame")
                .help("Forward one frame (→, Shift for ten)")
            Text(splitter.position.map { $0.compactTimecode(frameRate: media.frameRate) } ?? "")
                .font(Design.Typeface.timecode)
                .foregroundStyle(Design.textPrimary)
                .accessibilityLabel("Position")
            Spacer()
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

    // MARK: - Splitting and merging

    private var editing: some View {
        HStack(spacing: Design.Space.step) {
            Button("Merge with Previous") { splitter.merge(.previous) }
                .disabled(splitter.cut(toMerge: .previous) == nil)
                .help("Join the scene shown to the one before it")
            Spacer()
            Button("Split Here") { splitter.split() }
                .buttonStyle(.borderedProminent)
                .tint(Design.accentFill)
                .disabled(splitter.splitTime == nil)
                .help("Start a new scene at the frame shown (S)")
            Spacer()
            Button("Merge with Next") { splitter.merge(.next) }
                .disabled(splitter.cut(toMerge: .next) == nil)
                .help("Join the scene shown to the one after it")
        }
        .controlSize(.regular)
    }

    // MARK: - Sensitivity

    private var sensitivity: some View {
        VStack(alignment: .leading, spacing: Design.Space.close) {
            HStack {
                Text("Cut sensitivity")
                    .font(Design.Typeface.groupTitle)
                    .foregroundStyle(Design.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Text(splitter.scenes.count == 1 ? "1 scene" : "\(splitter.scenes.count) scenes")
                    .font(Design.Typeface.numericSmall)
                    .foregroundStyle(splitter.draftSensitivity == nil ? Design.textSecondary : Design.accent)
            }
            HStack(spacing: Design.Space.step) {
                Text("Fewer cuts")
                    .font(Design.Typeface.label)
                    .foregroundStyle(Design.textSecondary)
                    .accessibilityHidden(true)
                SensitivitySlider(splitter: splitter)
                Text("More cuts")
                    .font(Design.Typeface.label)
                    .foregroundStyle(Design.textSecondary)
                    .accessibilityHidden(true)
            }
            .disabled(splitter.track == nil)
            Text("Finds the cuts again between the outer edges of the scenes shown. Cuts you made by hand stay.")
                .font(Design.Typeface.label)
                .foregroundStyle(Design.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
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
        .accessibilityLabel("Cut sensitivity")
        .accessibilityValue("\(Int((splitter.sensitivity * 100).rounded())) percent, \(splitter.scenes.count) scene\(splitter.scenes.count == 1 ? "" : "s")")
        .accessibilityHint("Higher finds more cuts")
    }
}

/// The scenes shown, side by side across the panel, with the cuts between
/// them and a line where the picture is. Moving the pointer over it skims;
/// pressing and dragging scrubs.
private struct SceneStrip: View {
    let splitter: SceneSplitter
    let span: (start: CMTime, end: CMTime)
    let frameRate: Double

    private var length: Double { max(CMTimeSubtract(span.end, span.start).seconds, 1e-6) }

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            ZStack(alignment: .topLeading) {
                ForEach(Array(splitter.scenes.enumerated()), id: \.element.id) { index, scene in
                    segment(scene, index: index, width: width, height: proxy.size.height)
                }
                if let position = splitter.position {
                    Rectangle()
                        .fill(Design.accent)
                        .frame(width: 2, height: proxy.size.height)
                        .offset(x: x(of: position, width: width) - 1)
                        .allowsHitTesting(false)
                }
            }
            // The segments are placed by offset, so the stack takes the
            // strip's whole size rather than its first segment's.
            .frame(width: width, height: proxy.size.height, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous))
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                if case .active(let point) = phase { splitter.skim(toSeconds: seconds(at: point.x, width: width)) }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { splitter.skim(toSeconds: seconds(at: $0.location.x, width: width)) }
            )
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
        .accessibilityAction(named: "Split Here") { splitter.split() }
        .accessibilityAction(named: "Merge with Previous") { splitter.merge(.previous) }
        .accessibilityAction(named: "Merge with Next") { splitter.merge(.next) }
        .accessibilityAction(named: "Previous Cut") { splitter.jumpToCut(.previous) }
        .accessibilityAction(named: "Next Cut") { splitter.jumpToCut(.next) }
    }

    private func segment(_ scene: SceneRange, index: Int, width: CGFloat, height: CGFloat) -> some View {
        let left = x(of: scene.start, width: width), right = x(of: scene.end, width: width)
        let isCurrent = splitter.currentScene?.id == scene.id
        return ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(isCurrent ? Design.accentMuted : (index.isMultiple(of: 2) ? Design.Surface.raised.color : Design.Surface.overlay.color))
            if right - left > 28, let number = splitter.number(of: scene) {
                HStack(spacing: 2) {
                    Text("\(number)")
                        .font(Design.Typeface.numericTag)
                    if scene.origin == .manual {
                        Image(systemName: "hand.point.up.left")
                            .font(Design.Typeface.glyphTiny)
                    }
                }
                .foregroundStyle(Design.textPrimary)
                .padding(.horizontal, Design.Space.tight)
                .padding(.top, 3)
            }
            // The cut that starts it.
            if index > 0 {
                Rectangle()
                    .fill(Design.hairline)
                    .frame(width: 2)
            }
        }
        .frame(width: max(right - left, 1), height: height)
        .offset(x: left)
        .allowsHitTesting(false)
    }

    private func x(of time: CMTime, width: CGFloat) -> CGFloat {
        CGFloat(CMTimeSubtract(time, span.start).seconds / length) * width
    }

    private func seconds(at x: CGFloat, width: CGFloat) -> Double {
        guard width > 0 else { return 0 }
        return min(max(Double(x / width), 0), 1) * length
    }

    private var accessibilityValue: String {
        var parts: [String] = []
        if let scene = splitter.currentScene, let number = splitter.number(of: scene) {
            parts.append("in scene \(number)")
        }
        if let position = splitter.position {
            parts.append(position.compactTimecode(frameRate: frameRate))
        }
        parts.append(splitter.scenes.count == 1 ? "1 scene shown" : "\(splitter.scenes.count) scenes shown")
        return parts.joined(separator: ", ")
    }
}
