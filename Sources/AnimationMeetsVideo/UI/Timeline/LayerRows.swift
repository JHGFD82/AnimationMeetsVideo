import CoreMedia
import SwiftUI

extension EditingProject {
    /// A layer's name as shown in the timeline: its own name, else its first
    /// clip's, else "Layer N".
    func displayName(of layer: TimelineLayer, number: Int) -> String {
        if let customName = layer.customName, !customName.isEmpty { return customName }
        if let firstClip = layer.clips.first, let info = resolvedInfo(for: firstClip.source) { return info.name }
        return "Layer \(number)"
    }
}

struct LayerHeaderRow: View {
    let number: Int
    let layer: TimelineLayer
    let project: EditingProject
    let height: CGFloat
    let canMoveUp: Bool
    let canMoveDown: Bool
    /// Nil for layers without transform properties (audio), which get no arrow.
    let isExpanded: Bool?
    let onToggleExpanded: () -> Void
    let onRename: (String?) -> Void
    let onMove: (Int) -> Void

    @State private var isEditingName = false
    @State private var draftName: String = ""
    @FocusState private var isNameFieldFocused: Bool

    private var displayName: String {
        project.displayName(of: layer, number: number)
    }

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if let isExpanded {
                    Button(action: onToggleExpanded) {
                        Image(systemName: "chevron.right")
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                            .frame(width: 12, height: 12)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(isExpanded ? "Hide transform properties" : "Show transform properties (P, S, R, T)")
                } else {
                    Color.clear
                }
            }
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 12)
            Text("\(number)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 18, alignment: .trailing)
            if isEditingName {
                TextField("Name", text: $draftName)
                    .font(.caption)
                    .textFieldStyle(.plain)
                    .focused($isNameFieldFocused)
                    .onSubmit { commitRename() }
                    .onAppear { isNameFieldFocused = true }
                    // onSubmit only fires on Return — clicking away to end
                    // editing without pressing Return previously left the
                    // field stuck open and never fell back to the footage
                    // name when left blank. Committing on focus-loss too
                    // fixes that.
                    .onChange(of: isNameFieldFocused) { _, focused in
                        if !focused { commitRename() }
                    }
            } else {
                Text(displayName)
                    .font(.caption)
                    .lineLimit(1)
                    .onTapGesture(count: 2) {
                        draftName = layer.customName ?? ""
                        isEditingName = true
                    }
            }
        }
        .padding(.horizontal, 8)
        .frame(height: height, alignment: .leading)
        .contextMenu {
            Button("Move Layer Up") { onMove(-1) }
                .disabled(!canMoveUp)
            Button("Move Layer Down") { onMove(1) }
                .disabled(!canMoveDown)
        }
    }

    private func commitRename() {
        guard isEditingName else { return }
        onRename(draftName.isEmpty ? nil : draftName)
        isEditingName = false
    }
}

struct LayerClipRow: View {
    let layer: TimelineLayer
    let project: EditingProject
    let selection: TimelineSelection?
    let pixelsPerSecond: CGFloat
    let width: CGFloat
    let height: CGFloat
    let onSelectClip: (TimelineClip) -> Void
    let onMoveClip: (UUID, CMTime) -> Void
    let onTrimClipStart: (UUID, CMTime) -> Void
    let onTrimClipEnd: (UUID, CMTime) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(layer.clips) { clip in
                let isSelected = selection?.layerID == layer.id && selection?.timelineClipID == clip.id
                ClipBlockView(
                    clip: clip,
                    info: project.resolvedInfo(for: clip.source),
                    isSelected: isSelected,
                    pixelsPerSecond: pixelsPerSecond,
                    height: height,
                    onSelect: { onSelectClip(clip) },
                    onMove: { newStart in onMoveClip(clip.id, newStart) },
                    onTrimStart: { newTrimStart in onTrimClipStart(clip.id, newTrimStart) },
                    onTrimEnd: { newTrimEnd in onTrimClipEnd(clip.id, newTrimEnd) }
                )
            }
        }
        // offset() shifts rendering without changing the size a view reports
        // to its parent, so without an explicit width here the row would
        // size itself to its (un-offset) widest clip rather than spanning
        // the full timeline — leaving every clip's absolute x-position
        // anchored to the wrong origin instead of true timeline time 0.
        .frame(width: width, height: height, alignment: .topLeading)
    }
}

/// Colors a clip by its layer type, After Effects/Premiere-style — video is
/// purple, audio gets its own color, nested timelines (compound clips) get
/// another. Image and text layers aren't modeled yet, but will slot into
/// this same switch (green/orange per the design) once they exist.
private func clipTypeColor(for info: ResolvedClipInfo?) -> Color {
    switch info {
    case .media(let mediaClip):
        switch mediaClip.kind {
        case .video: .purple
        case .audio: .teal
        }
    case .timeline:
        .indigo
    case nil:
        .gray
    }
}

/// A single clip block, positioned by absolute offset (not sequential flow)
/// so a clip's on-screen position always matches its `startOffset`.
/// Draggable in its middle to move it in time, and draggable at either edge
/// to non-destructively trim `trimStart`/`trimEnd` — while trimming, a
/// translucent, outlined ghost in the layer's type color shows the full
/// before/after extent so the trimmed-away sliver stays visible until
/// release.
struct ClipBlockView: View {
    let clip: TimelineClip
    let info: ResolvedClipInfo?
    let isSelected: Bool
    let pixelsPerSecond: CGFloat
    let height: CGFloat
    let onSelect: () -> Void
    let onMove: (CMTime) -> Void
    let onTrimStart: (CMTime) -> Void
    let onTrimEnd: (CMTime) -> Void

    @GestureState private var moveTranslation: CGFloat = 0
    @GestureState private var leftTrimTranslation: CGFloat = 0
    @GestureState private var rightTrimTranslation: CGFloat = 0

    private let handleWidth: CGFloat = 8

    private var typeColor: Color { clipTypeColor(for: info) }

    var body: some View {
        let baseX = clip.startOffset.seconds * pixelsPerSecond
        let baseWidth = max(2, clip.trimmedDuration.seconds * pixelsPerSecond)
        let liveX = baseX + moveTranslation + leftTrimTranslation
        let liveWidth = max(4, baseWidth - leftTrimTranslation + rightTrimTranslation)
        let isTrimming = leftTrimTranslation != 0 || rightTrimTranslation != 0
        let unionMinX = min(baseX, liveX)
        let unionMaxX = max(baseX + baseWidth, liveX + liveWidth)

        ZStack(alignment: .topLeading) {
            if isTrimming {
                Rectangle()
                    .fill(typeColor.opacity(0.25))
                    .overlay(Rectangle().strokeBorder(typeColor, lineWidth: 1))
                    .frame(width: max(2, unionMaxX - unionMinX), height: height)
                    .offset(x: unionMinX)
                    .allowsHitTesting(false)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if case .timeline = clip.source {
                        Image(systemName: "rectangle.stack")
                            .font(.caption2)
                    }
                    Text(info?.name ?? "Unknown")
                        .font(.caption)
                        .lineLimit(1)
                }
                Text(clip.trimmedDuration.formatted)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.leading, 4)
            .frame(width: liveWidth, height: height, alignment: .leading)
            .background(typeColor.opacity(isSelected ? 0.6 : 0.35))
            .overlay(Rectangle().strokeBorder(isSelected ? Color.white.opacity(0.9) : typeColor.opacity(0.8), lineWidth: isSelected ? 1.5 : 0.75))
            .offset(x: liveX)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating($moveTranslation) { value, state, _ in
                        state = value.translation.width
                    }
                    .onEnded { value in
                        let distance = hypot(value.translation.width, value.translation.height)
                        if distance < 3 {
                            onSelect()
                        } else {
                            let deltaSeconds = Double(value.translation.width / pixelsPerSecond)
                            let newStart = CMTimeAdd(clip.startOffset, CMTime(seconds: deltaSeconds, preferredTimescale: 600))
                            onMove(newStart)
                        }
                    }
            )

            // Edge handles are layered on top so grabbing within a few
            // points of either side trims that edge instead of moving the
            // whole clip (SwiftUI resolves overlapping gestures to the
            // topmost hit-testable view at the touch point).
            trimHandle(edge: .leading, liveX: liveX, liveWidth: liveWidth)
            trimHandle(edge: .trailing, liveX: liveX, liveWidth: liveWidth)
        }
        .frame(height: height, alignment: .topLeading)
    }

    private enum Edge { case leading, trailing }

    private func trimHandle(edge: Edge, liveX: CGFloat, liveWidth: CGFloat) -> some View {
        let handleX = edge == .leading ? liveX - handleWidth / 2 : liveX + liveWidth - handleWidth / 2
        return Rectangle()
            .fill(Color.clear)
            .frame(width: handleWidth, height: height)
            .contentShape(Rectangle())
            .offset(x: handleX)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .updating(edge == .leading ? $leftTrimTranslation : $rightTrimTranslation) { value, state, _ in
                        state = value.translation.width
                    }
                    .onEnded { value in
                        let distance = hypot(value.translation.width, value.translation.height)
                        if distance < 3 {
                            onSelect()
                            return
                        }
                        let deltaSeconds = Double(value.translation.width / pixelsPerSecond)
                        let delta = CMTime(seconds: deltaSeconds, preferredTimescale: 600)
                        switch edge {
                        case .leading:
                            onTrimStart(CMTimeAdd(clip.trimStart, delta))
                        case .trailing:
                            onTrimEnd(CMTimeAdd(clip.trimEnd, delta))
                        }
                    }
            )
            .pointerStyle(.columnResize)
    }
}
