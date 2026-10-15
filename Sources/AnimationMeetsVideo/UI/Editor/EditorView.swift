import SwiftUI

struct TimelineSelection: Equatable {
    var timelineID: UUID
    var layerID: UUID
    var timelineClipID: UUID
    /// Set when one of the clip's transitions is selected rather than the
    /// clip as a whole.
    var transitionEdge: TransitionEdge? = nil
}

struct EditorView: View {
    @Binding var project: EditingProject
    let history: ProjectHistory
    let analysis: AssetAnalysis
    let replacement: MediaReplacementController
    /// Where the project is saved; nil only while the start sheet is up.
    let packageURL: URL?
    @Environment(\.undoManager) private var undoManager
    @State private var activeTimelineID: UUID
    @State private var selection: TimelineSelection?
    @State private var playback = PlaybackModel()
    @State private var annotations = AnnotationModel()
    @State private var externalDisplay = ExternalDisplayController()
    @State private var renderer = RenderScheduler()

    init(
        project: Binding<EditingProject>,
        history: ProjectHistory,
        analysis: AssetAnalysis,
        replacement: MediaReplacementController,
        packageURL: URL?
    ) {
        self._project = project
        self.history = history
        self.analysis = analysis
        self.replacement = replacement
        self.packageURL = packageURL
        self._activeTimelineID = State(initialValue: project.wrappedValue.rootTimelineID)
    }

    var body: some View {
        // No split view: the library sits beside the viewer inside the
        // surface, so the timeline under them spans the whole window.
        VStack(spacing: 0) {
            EditorToolbar(
                project: $project,
                activeTimelineID: activeTimeline,
                selection: $selection,
                playback: playback,
                annotations: annotations,
                externalDisplay: externalDisplay,
                analysis: analysis,
                renderer: renderer
            )
            TimelineEditorSurface(project: $project, timelineID: activeTimeline, selection: $selection, playback: playback, analysis: analysis) {
                LibrarySidebar(
                    project: $project, activeTimelineID: activeTimeline, selection: $selection,
                    analysis: analysis, replacement: replacement, packageURL: packageURL
                )
                .frame(width: 260)
                .grooved(.trailing)
            }
            .environment(renderer)
        }
        .background(Design.Surface.base.color)
        // A picture can only be judged against a neutral dim surround, so
        // the editor is dark whatever the system appearance is. See
        // `DesignSystem`.
        .preferredColorScheme(.dark)
        .tint(Design.accent)
        .environment(\.projectHistory, history)
        .onChange(of: project.id) { _, _ in
            activeTimelineID = project.rootTimelineID
            selection = nil
        }
        .onChange(of: project) { _, newValue in
            history.projectDidChange(newValue)
            keepViewStateValid(for: newValue)
        }
        .onChange(of: AssetAnalysis.inputs(of: project)) { _, _ in analysis.analyzeMissing(in: project) }
        .onChange(of: packageURL, initial: true) { _, url in renderer.packageURL = url }
        .onAppear {
            connectHistory()
            analysis.analyzeMissing(in: project)
        }
        .onChange(of: undoManager) { _, _ in connectHistory() }
    }

    /// The timeline being edited, read against the current project: the
    /// stored ID until it names a timeline this project has, else the
    /// root. The stored ID catches up in `onChange(of: project.id)`, one
    /// update after a new project arrives. Showing the stale one for that
    /// update made the library list the root timeline and then remove it
    /// straight away, while it was still measuring the rows it had just
    /// inserted, which AppKit warns is a reentrant table update.
    private var activeTimeline: Binding<UUID> {
        Binding(
            get: { project.timeline(id: activeTimelineID) != nil ? activeTimelineID : project.rootTimelineID },
            set: { activeTimelineID = $0 }
        )
    }

    private func connectHistory() {
        history.undoManager = undoManager
        history.restore = { project = $0 }
        history.current = { project }
    }

    /// Undo and redo can remove the timeline or clip the view was pointing at.
    private func keepViewStateValid(for project: EditingProject) {
        if project.timeline(id: activeTimelineID) == nil {
            activeTimelineID = project.rootTimelineID
        }
        if let selection,
           project.timeline(id: selection.timelineID)?
               .layer(id: selection.layerID)?
               .clips.contains(where: { $0.id == selection.timelineClipID }) != true {
            self.selection = nil
        }
    }
}
