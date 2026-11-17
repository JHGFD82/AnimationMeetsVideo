import AppKit
import Observation
import SwiftUI

/// Manages a borderless window pinned to an external `NSScreen`'s full frame.
/// It can mirror the primary editor's playhead/selection ("synced") or carry
/// its own independent timeline/selection while editing the same shared
/// project ("independent") — a second display can act as a reference view
/// while edits from either window land in the one project.
///
/// Synced, the picture has the viewer's canvas over it (`ViewerCanvas`),
/// with the primary's timeline and selection and the editor's
/// `ViewerCanvasState`, so its handles edit the selected clip and a drag
/// on either display is drawn on both. Its zoom and place are its own;
/// Fit fills the screen.
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
        canvasState: ViewerCanvasState,
        analysis: AssetAnalysis,
        history: ProjectHistory?,
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
            canvasState: canvasState,
            analysis: analysis,
            onClose: { [weak self] in self?.stop() }
        )
        // Its own window, so the editor's environment doesn't reach it: a
        // drag held in either window is drawn in both, and one made here is
        // a step of the project's history.
        window.contentView = NSHostingView(rootView: content.environment(projectState).environment(\.projectHistory, history))
        window.makeKeyAndOrderFront(nil)

        windowController = NSWindowController(window: window)
    }

    func stop() {
        windowController?.window?.orderOut(nil)
        windowController = nil
    }
}

/// Borderless windows refuse key status by default, which would prevent the
/// viewer's canvas (and the independent editor surface) from reliably
/// receiving mouse/keyboard events.
private final class KeyableBorderlessWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// The editor window's undo, which ⌘Z here undoes with: edits made in
    /// this window land in the same project and its history, and the
    /// window's own undo manager had nothing on it.
    weak var editorUndoManager: UndoManager?
    override var undoManager: UndoManager? { editorUndoManager ?? super.undoManager }
}

/// The external display's window: its top bar, and the synced picture
/// with the viewer's canvas, or a second editor.
struct ExternalViewerContent: View {
    @Binding var project: EditingProject
    @Binding var primaryTimelineID: UUID
    @Binding var primarySelection: TimelineSelection?
    let sharedPlayback: PlaybackModel
    let canvasState: ViewerCanvasState
    let analysis: AssetAnalysis
    let onClose: () -> Void

    @State private var isSynced = true
    @State private var independentPlayback = PlaybackModel()
    @State private var independentTimelineID: UUID?
    @State private var independentSelection: TimelineSelection?
    /// The synced picture's zoom and place, this display's own. Fit fills
    /// the screen, with no margin.
    @State private var framing = ViewerFraming(fitMargin: 0)
    /// Stand-ins while the editor's surface isn't shown to follow (see
    /// `ViewerCanvasState.follow`).
    @State private var ownPlayhead = PlayheadState()
    @State private var ownEffects = EffectsPanelState()
    @AppStorage(Preferences.viewerHandles) private var showsHandles = false

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Toggle("Sync with primary", isOn: $isSynced)
                    .toggleStyle(.switch)
                if isSynced {
                    Toggle("Show Handles", isOn: $showsHandles)
                        .toggleStyle(.switch)
                        .help("Show handles on the clip selected in the timeline (H)")
                    ViewerToolPicker(state: canvasState)
                }
                Spacer()
                Button("Close") { onClose() }
                    .buttonStyle(.bordered)
            }
            .font(Design.Typeface.body)
            .foregroundStyle(Design.textPrimary)
            .padding(.horizontal, Design.Space.rail)
            .padding(.vertical, Design.Space.group)
            .rail(.raised)

            if isSynced {
                synced
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
        }
    }

    /// The primary's picture with the viewer's canvas over it, edge to edge.
    private var synced: some View {
        let timeline = project.timeline(id: primaryTimelineID)
        let frameSize = timeline?.frameSize ?? CGSize(width: 16, height: 9)
        return ZStack {
            Color.black
            FramedPicture(
                playback: sharedPlayback, frameRate: timeline?.frameRate ?? 24, frameSize: frameSize, framing: framing,
                showsEdge: false
            )
            ViewerCanvas(
                framing: framing, frameSize: frameSize, playback: sharedPlayback,
                handles: ViewerHandlesSource(
                    project: $project, timelineID: primaryTimelineID, selection: primarySelection,
                    effectsState: canvasState.effects ?? ownEffects, playhead: canvasState.playhead ?? ownPlayhead,
                    state: canvasState
                )
            )
            ViewerFramingChips(framing: framing)
        }
        .clipped()
        .ignoresSafeArea()
    }
}
