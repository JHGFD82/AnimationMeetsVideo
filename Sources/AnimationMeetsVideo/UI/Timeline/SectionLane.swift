import CoreMedia
import SwiftUI

/// A slim lane under the ruler showing a timeline's named sections. Drag
/// across empty space to make one (double-click makes one five seconds
/// long), double-click a section to rename it, drag it to move it and its
/// edges to resize it. Click selects it for Delete. Drawn, like the ruler,
/// only across the visible part of the timeline.
struct SectionLane: View {
    let sections: [TimelineSection]
    let viewport: TimelineViewport
    let selectedID: UUID?
    /// The snap target near a time, leaving out a section's own edges; nil
    /// with snapping off or nothing near.
    let snap: (CMTime, UUID?) -> CMTime?
    let resolveMove: (UUID, CMTime) -> TimelineSection?
    let resolveEdge: (UUID, SectionEdge, CMTime) -> TimelineSection?
    let onSelect: (UUID) -> Void
    /// Makes a section over a range and returns its ID, or nil without room.
    let onCreate: (CMTime, CMTime) -> UUID?
    let onMove: (UUID, CMTime) -> Void
    let onSetEdge: (UUID, SectionEdge, CMTime) -> Void
    let onRename: (UUID, String) -> Void
    let onDelete: (UUID) -> Void
    let onSnapIndicator: (CMTime?) -> Void

    static let height: CGFloat = 20

    /// A move or resize in progress.
    @State private var draft: TimelineSection?
    /// A section being drawn across empty space.
    @State private var creating: (start: CMTime, end: CMTime)?
    @State private var editingID: UUID?
    @State private var draftName = ""
    @FocusState private var isNameFocused: Bool

    private let space = "sectionLane"
    private let handleWidth: CGFloat = 6

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.22)
                .contentShape(Rectangle())
                .gesture(createGesture)
                .simultaneousGesture(SpatialTapGesture(count: 2, coordinateSpace: .named(space)).onEnded { value in
                    let start = snapped(time(atX: value.location.x), excluding: nil)
                    if let id = onCreate(start, CMTimeAdd(start, EditingProject.defaultSectionLength)) { beginRename(id, name: "") }
                })
            ForEach(sections) { section in
                sectionView(draft?.id == section.id ? draft ?? section : section)
            }
            if let creating {
                let minX = viewport.x(atSeconds: creating.start.seconds)
                let maxX = viewport.x(atSeconds: creating.end.seconds)
                RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous)
                    .strokeBorder(Design.section, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    .frame(width: max(2, maxX - minX), height: Self.height - 4)
                    .offset(x: minX, y: 2)
                    .allowsHitTesting(false)
            }
        }
        .frame(width: viewport.width, height: Self.height, alignment: .topLeading)
        .clipped()
        .coordinateSpace(.named(space))
        .help("Sections: drag across empty space to add one, double-click one to rename it")
    }

    private func sectionView(_ section: TimelineSection) -> some View {
        let minX = viewport.x(atSeconds: section.start.seconds)
        let maxX = viewport.x(atSeconds: section.end.seconds)
        let isSelected = selectedID == section.id
        return ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous)
                .fill(Design.clipFill(Design.section, selected: isSelected))
                .overlay {
                    RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous)
                        .strokeBorder(isSelected ? Design.textOnColor.opacity(0.95) : Design.section.opacity(0.85), lineWidth: isSelected ? 1.5 : 1)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous)
                        .strokeBorder(Design.bevelEdge, lineWidth: 1)
                }
            if editingID == section.id {
                TextField(section.name, text: $draftName)
                    .textFieldStyle(.plain)
                    .font(Design.Typeface.label)
                    .padding(.horizontal, Design.Space.tight)
                    .focused($isNameFocused)
                    .onSubmit { commitRename() }
                    .onChange(of: isNameFocused) { _, focused in if !focused { commitRename() } }
            } else {
                Text(section.name)
                    .font(Design.Typeface.label.weight(.medium))
                    .foregroundStyle(Design.textOnColor)
                    .lineLimit(1)
                    .padding(.horizontal, Design.Space.tight)
            }
            edgeHandle(section, edge: .start, atX: 0)
            edgeHandle(section, edge: .end, atX: maxX - minX)
        }
        .frame(width: max(2, maxX - minX), height: Self.height - 4, alignment: .leading)
        .contentShape(Rectangle())
        .gesture(TapGesture(count: 2).onEnded { beginRename(section.id, name: section.name) }
            .exclusively(before: TapGesture().onEnded { onSelect(section.id) }))
        .simultaneousGesture(moveGesture(section))
        .contextMenu {
            Button("Rename…") { beginRename(section.id, name: section.name) }
            Button("Delete Section", role: .destructive) { onDelete(section.id) }
        }
        .offset(x: minX, y: 2)
    }

    private func edgeHandle(_ section: TimelineSection, edge: SectionEdge, atX x: CGFloat) -> some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: handleWidth, height: Self.height - 4)
            .contentShape(Rectangle())
            .offset(x: x - handleWidth / 2)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named(space))
                    .onChanged { value in
                        let original = edge == .start ? section.start : section.end
                        let proposed = CMTimeAdd(original, delta(value.translation.width))
                        let target = snap(proposed, section.id)
                        onSnapIndicator(target)
                        draft = resolveEdge(section.id, edge, target ?? proposed)
                    }
                    .onEnded { _ in
                        onSnapIndicator(nil)
                        if let draft {
                            onSetEdge(section.id, edge, edge == .start ? draft.start : draft.end)
                        }
                        draft = nil
                    }
            )
            .pointerStyle(.columnResize)
    }

    private func moveGesture(_ section: TimelineSection) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(space))
            .onChanged { value in
                var start = CMTimeAdd(section.start, delta(value.translation.width))
                let end = CMTimeAdd(start, section.duration)
                // Whichever end is nearer a target snaps.
                let byStart = snap(start, section.id)
                let byEnd = snap(end, section.id)
                let startGap = byStart.map { abs(CMTimeSubtract($0, start).seconds) } ?? .infinity
                let endGap = byEnd.map { abs(CMTimeSubtract($0, end).seconds) } ?? .infinity
                if let byStart, startGap <= endGap {
                    start = byStart
                    onSnapIndicator(byStart)
                } else if let byEnd {
                    start = CMTimeSubtract(byEnd, section.duration)
                    onSnapIndicator(byEnd)
                } else {
                    onSnapIndicator(nil)
                }
                draft = resolveMove(section.id, start)
            }
            .onEnded { _ in
                onSnapIndicator(nil)
                if let draft, draft.start != section.start { onMove(section.id, draft.start) }
                draft = nil
            }
    }

    private var createGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .named(space))
            .onChanged { value in
                let from = snapped(time(atX: value.startLocation.x), excluding: nil)
                let target = snap(time(atX: value.location.x), nil)
                onSnapIndicator(target)
                let to = target ?? time(atX: value.location.x)
                creating = (CMTimeMinimum(from, to), CMTimeMaximum(from, to))
            }
            .onEnded { _ in
                onSnapIndicator(nil)
                if let creating, creating.end > creating.start, let id = onCreate(creating.start, creating.end) {
                    beginRename(id, name: "")
                }
                creating = nil
            }
    }

    private func beginRename(_ id: UUID, name: String) {
        onSelect(id)
        draftName = name
        editingID = id
        isNameFocused = true
    }

    /// An empty name keeps the one it had.
    private func commitRename() {
        guard let id = editingID else { return }
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { onRename(id, name) }
        editingID = nil
    }

    private func time(atX x: CGFloat) -> CMTime {
        CMTime(seconds: max(0, viewport.seconds(atX: x)), preferredTimescale: 600)
    }

    private func snapped(_ time: CMTime, excluding owner: UUID?) -> CMTime {
        snap(time, owner) ?? time
    }

    private func delta(_ translation: CGFloat) -> CMTime {
        CMTime(seconds: Double(translation / viewport.pixelsPerSecond), preferredTimescale: 600)
    }
}
