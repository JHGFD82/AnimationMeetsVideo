import AppKit
import Observation
import SwiftUI

/// Manages a borderless window pinned to an external `NSScreen`'s full frame.
/// It can mirror the primary editor's playhead/selection ("synced") or carry
/// its own independent timeline/selection while editing the same shared
/// project ("independent") — a second display can act as a reference view
/// while edits from either window land in the one project.
@MainActor
@Observable
final class ExternalDisplayController {
    private var windowController: NSWindowController?

    var isActive: Bool { windowController != nil }

    func start(
        on screen: NSScreen,
        project: Binding<EditingProject>,
        projectState: ProjectState?,
        primaryTimelineID: Binding<UUID>,
        primarySelection: Binding<TimelineSelection?>,
        sharedPlayback: PlaybackModel,
        annotations: AnnotationModel,
        analysis: AssetAnalysis,
        undoManager: UndoManager?
    ) {
        stop()

        let window = KeyableBorderlessWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.setFrame(screen.frame, display: true)
        window.level = .normal
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.hasShadow = false
        window.isOpaque = true
        window.backgroundColor = .black
        window.editorUndoManager = undoManager

        let content = ExternalViewerContent(
            project: project,
            primaryTimelineID: primaryTimelineID,
            primarySelection: primarySelection,
            sharedPlayback: sharedPlayback,
            annotations: annotations,
            analysis: analysis,
            onSyncChange: { [weak window] synced in window?.markupUndoManager = synced ? annotations.undoManager : nil },
            onClose: { [weak self] in self?.stop() }
        )
        // Its own window, so the editor's environment doesn't reach it: a
        // drag held in either window is drawn in both.
        window.contentView = NSHostingView(rootView: content.environment(projectState))
        window.makeKeyAndOrderFront(nil)

        windowController = NSWindowController(window: window)
    }

    func stop() {
        windowController?.window?.orderOut(nil)
        windowController = nil
    }
}

/// Borderless windows refuse key status by default, which would prevent the
/// annotation overlay (and the independent editor surface) from reliably
/// receiving mouse/keyboard events.
private final class KeyableBorderlessWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// The editor window's undo, which ⌘Z here undoes with: edits made in
    /// this window land in the same project and its history, and the
    /// window's own undo manager had nothing on it.
    weak var editorUndoManager: UndoManager?
    /// The markup's undo, used instead while the window shows the markup
    /// (synced), where the strokes are what is edited.
    weak var markupUndoManager: UndoManager?
    override var undoManager: UndoManager? { markupUndoManager ?? editorUndoManager ?? super.undoManager }
}

private struct ExternalViewerContent: View {
    @Binding var project: EditingProject
    @Binding var primaryTimelineID: UUID
    @Binding var primarySelection: TimelineSelection?
    let sharedPlayback: PlaybackModel
    let annotations: AnnotationModel
    let analysis: AssetAnalysis
    /// Whether the window shows the synced viewer and its markup, or a
    /// second editor; it undoes the one it shows.
    let onSyncChange: (Bool) -> Void
    let onClose: () -> Void

    @State private var isSynced = true
    @State private var independentPlayback = PlaybackModel()
    @State private var independentTimelineID: UUID?
    @State private var independentSelection: TimelineSelection?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Toggle("Sync with primary", isOn: $isSynced)
                    .toggleStyle(.switch)
                Spacer()
                if isSynced {
                    Button("Remove last stroke") { annotations.removeLastStroke() }
                        .buttonStyle(.bordered)
                        .disabled(annotations.strokes.isEmpty)
                        .help("Undo with ⌘Z, redo with ⇧⌘Z")
                    Button("Clear markup") { annotations.clear() }
                        .buttonStyle(.bordered)
                        .disabled(annotations.strokes.isEmpty)
                }
                Button("Close") { onClose() }
                    .buttonStyle(.bordered)
            }
            .font(Design.Typeface.body)
            .foregroundStyle(Design.textPrimary)
            .padding(.horizontal, Design.Space.rail)
            .padding(.vertical, Design.Space.group)
            .rail(.raised)

            if isSynced {
                ZStack {
                    Color.black.ignoresSafeArea()
                    ViewerLayerView(display: sharedPlayback.display)
                        .ignoresSafeArea()
                    AnnotationOverlay(model: annotations)
                        .ignoresSafeArea()
                }
            } else {
                TimelineEditorSurface(
                    project: $project,
                    timelineID: independentTimelineID ?? primaryTimelineID,
                    selectTimeline: { independentTimelineID = $0 },
                    selection: $independentSelection,
                    playback: independentPlayback,
                    analysis: analysis
                )
            }
        }
        // Synced, this window is a projection surface and stays pure
        // black; independent, it is a second editor, so it takes the same
        // fixed dark chrome as the main one.
        .background(isSynced ? Color.black : Design.Surface.base.color)
        .preferredColorScheme(.dark)
        .tint(Design.accent)
        .onAppear {
            if independentTimelineID == nil {
                independentTimelineID = primaryTimelineID
            }
            onSyncChange(isSynced)
        }
        .onChange(of: isSynced) { _, synced in onSyncChange(synced) }
    }
}
