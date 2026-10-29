import AppKit
import CoreMedia
import SwiftUI

/// A slim lane under the ruler showing a timeline's named sections.
/// Double-click empty space to make one five seconds long, double-click a
/// section to rename it (a click elsewhere saves the name, Escape cancels),
/// drag it to move it (Option-drag to copy it) and its edges to resize it.
/// Click selects it for Delete. Drawn, like the ruler, only across the visible part of the
/// timeline.
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
    /// Where an Option-drag would put a copy of a section with its start at
    /// a time, and making it.
    let resolveCopy: (UUID, CMTime) -> TimelineSection?
    let onCopy: (UUID, CMTime) -> Void
    let onSetEdge: (UUID, SectionEdge, CMTime) -> Void
    let onRename: (UUID, String) -> Void
    let onDelete: (UUID) -> Void
    let onSnapIndicator: (CMTime?) -> Void

    static let height: CGFloat = 20

    /// A move or resize in progress. After a drop it stays up until the
    /// edited section comes back down from the project, so the section
    /// doesn't flash back to where it was for a frame.
    @State private var draft: TimelineSection?
    /// Counts drops, so a timeout from an earlier one can't clear a later
    /// one's draft; nil when no drop is waiting for its edit.
    @State private var pendingDrop: Int?
    @State private var dropCount = 0
    @State private var clickMonitor: Any?
    /// Where an Option-drag's copy would land, the section staying put.
    @State private var copyDraft: TimelineSection?
    /// Whether a section is being moved (not resized), for the drop line.
    @State private var isMoving = false
    @State private var editingID: UUID?
    @State private var draftName = ""
    @FocusState private var isNameFocused: Bool

    private let space = "sectionLane"
    private let handleWidth: CGFloat = 6

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.22)
                .contentShape(Rectangle())
                .gesture(SpatialTapGesture(count: 2, coordinateSpace: .named(space)).onEnded { value in
                    let start = snapped(time(atX: value.location.x), excluding: nil)
                    if let id = onCreate(start, CMTimeAdd(start, EditingProject.defaultSectionLength)) { beginRename(id, name: "") }
                })
            ForEach(sections) { section in
                sectionView(section, shown: draft?.id == section.id ? draft ?? section : section)
            }
            if let copyDraft {
                copyPreview(copyDraft)
            }
            // Where the moved section, or its copy, will start.
            if isMoving, let landing = copyDraft ?? draft {
                InsertionLine(axis: .vertical)
                    .frame(height: Self.height)
                    .offset(x: viewport.x(atSeconds: landing.start.seconds) - 3.5)
            }
        }
        .frame(width: viewport.width, height: Self.height, alignment: .topLeading)
        .clipped()
        .coordinateSpace(.named(space))
        .onChange(of: sections) { _, _ in
            if pendingDrop != nil { endDrop() }
        }
        .onChange(of: editingID) { _, id in
            id == nil ? stopClickMonitor() : startClickMonitor()
        }
        .onDisappear {
            commitRename()
            stopClickMonitor()
        }
        .help("Sections: double-click empty space to add one, double-click one to rename it")
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sections")
    }

    /// `section` as the project has it, drawn as `shown` (the draft while
    /// dragging). The gestures measure from `section`: measuring from the
    /// draft would add each drag step to the last one's result, so the
    /// section ran away from the pointer and its drop was never saved.
    private func sectionView(_ section: TimelineSection, shown: TimelineSection) -> some View {
        let minX = viewport.x(atSeconds: shown.start.seconds)
        let maxX = viewport.x(atSeconds: shown.end.seconds)
        // Narrow sections keep a middle to grab for moving.
        let handle = min(handleWidth, max(2, (maxX - minX) / 3))
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
                    .onExitCommand { cancelRename() }
                    // Its whole name is selected (`FieldTextSelection`).
                    .onAppear { isNameFocused = true }
                    .onChange(of: isNameFocused) { _, focused in if !focused { commitRename() } }
            } else {
                Text(section.name)
                    .font(Design.Typeface.label.weight(.medium))
                    .foregroundStyle(Design.textOnColor)
                    .lineLimit(1)
                    .padding(.horizontal, Design.Space.tight)
            }
            edgeHandle(section, edge: .start, atX: 0, width: handle)
            edgeHandle(section, edge: .end, atX: maxX - minX, width: handle)
        }
        .frame(width: max(2, maxX - minX), height: Self.height - 4, alignment: .leading)
        .contentShape(Rectangle())
        // The move is the section's own gesture, so an edge handle's resize
        // (on a view inside it) takes precedence instead of both running:
        // as a simultaneous gesture, grabbing an edge also moved the
        // section, and the two fought over the draft.
        .gesture(moveGesture(section))
        // Selecting happens on the mouse-down itself. SwiftUI's tap gestures
        // held a single click back while they waited to see whether a
        // second one followed. The system's click count gives the
        // double-click, with the user's own double-click interval.
        .simultaneousGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .named(space)).onChanged { _ in
                guard let event = NSApp.currentEvent, event.type == .leftMouseDown else { return }
                onSelect(section.id)
                if event.clickCount == 2 { beginRename(section.id, name: section.name) }
            }
        )
        .contextMenu {
            Button("Rename…") { beginRename(section.id, name: section.name) }
            Button("Delete Section", role: .destructive) { onDelete(section.id) }
        }
        .accessibilityElement(children: editingID == section.id ? .contain : .ignore)
        .accessibilityLabel("Section \(section.name)")
        .accessibilityValue("from \(section.start.formatted) to \(section.end.formatted)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction { onSelect(section.id) }
        .accessibilityActions {
            Button("Rename section") { beginRename(section.id, name: section.name) }
            Button("Delete section") { onDelete(section.id) }
        }
        .offset(x: minX, y: 2)
    }

    private func edgeHandle(_ section: TimelineSection, edge: SectionEdge, atX x: CGFloat, width: CGFloat) -> some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: width, height: Self.height - 4)
            .contentShape(Rectangle())
            .offset(x: x - width / 2)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named(space))
                    .onChanged { value in
                        let original = edge == .start ? section.start : section.end
                        let proposed = CMTimeAdd(original, delta(value.translation.width))
                        let target = snap(proposed, section.id)
                        onSnapIndicator(target)
                        showDraft(resolveEdge(section.id, edge, target ?? proposed))
                    }
                    .onEnded { _ in
                        onSnapIndicator(nil)
                        if let draft, draft != section {
                            commitDrop { onSetEdge(section.id, edge, edge == .start ? draft.start : draft.end) }
                        } else {
                            endDrop()
                        }
                    }
            )
            .pointerStyle(.columnResize)
    }

    /// An Option-drag's copy where it would land: the section's colour,
    /// lighter and outlined in dashes, as a clip's is.
    private func copyPreview(_ copy: TimelineSection) -> some View {
        let minX = viewport.x(atSeconds: copy.start.seconds)
        let maxX = viewport.x(atSeconds: copy.end.seconds)
        return RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous)
            .fill(Design.section.opacity(0.45))
            .overlay {
                RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous)
                    .strokeBorder(Design.textOnColor.opacity(0.9), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }
            .overlay(alignment: .leading) {
                Text(copy.name)
                    .font(Design.Typeface.label.weight(.medium))
                    .foregroundStyle(Design.textOnColor)
                    .lineLimit(1)
                    .padding(.horizontal, Design.Space.tight)
            }
            .frame(width: max(2, maxX - minX), height: Self.height - 4)
            .offset(x: minX, y: 2)
            .decorative()
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
                isMoving = true
                // Option leaves the section where it is and shows its copy.
                if CopyDragCursor.update() {
                    showDraft(nil)
                    copyDraft = resolveCopy(section.id, start)
                } else {
                    copyDraft = nil
                    showDraft(resolveMove(section.id, start))
                }
            }
            .onEnded { _ in
                onSnapIndicator(nil)
                isMoving = false
                CopyDragCursor.end()
                if let copy = copyDraft {
                    copyDraft = nil
                    onCopy(section.id, copy.start)
                } else if let draft, draft.start != section.start {
                    commitDrop { onMove(section.id, draft.start) }
                } else {
                    endDrop()
                }
            }
    }

    private func showDraft(_ section: TimelineSection?) {
        pendingDrop = nil
        draft = section
    }

    /// Commits a drop and keeps showing the draft until the edited section
    /// arrives. If it never does (the edit was refused), the draft goes
    /// after a moment.
    private func commitDrop(_ commit: () -> Void) {
        dropCount += 1
        let drop = dropCount
        pendingDrop = drop
        commit()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            if pendingDrop == drop { endDrop() }
        }
    }

    private func endDrop() {
        pendingDrop = nil
        draft = nil
    }

    private func beginRename(_ id: UUID, name: String) {
        onSelect(id)
        draftName = name
        editingID = id
    }

    private func cancelRename() {
        editingID = nil
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    /// A click anywhere outside the name field ends the edit and saves it,
    /// as in Finder. Focus loss alone missed clicks on views that don't
    /// take focus, leaving the field open and keeping every key press.
    private func startClickMonitor() {
        stopClickMonitor()
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { event in
            nonisolated(unsafe) let event = event
            MainActor.assumeIsolated {
                guard let window = event.window else { return }
                if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor,
                   let hit = window.contentView?.hitTest(event.locationInWindow), hit.isDescendant(of: editor) || hit === editor {
                    return
                }
                commitRename()
                window.makeFirstResponder(nil)
            }
            return event
        }
    }

    private func stopClickMonitor() {
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }
        clickMonitor = nil
    }

    /// An empty name keeps the one it had.
    private func commitRename() {
        guard let id = editingID else { return }
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        editingID = nil
        if !name.isEmpty { onRename(id, name) }
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
