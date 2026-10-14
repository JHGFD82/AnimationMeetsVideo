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
                activeTimelineID: $activeTimelineID,
                selection: $selection,
                playback: playback,
                annotations: annotations,
                externalDisplay: externalDisplay,
                analysis: analysis
            )
            Divider()
            TimelineEditorSurface(project: $project, timelineID: $activeTimelineID, selection: $selection, playback: playback, analysis: analysis) {
                HStack(spacing: 0) {
                    LibrarySidebar(
                        project: $project, activeTimelineID: $activeTimelineID, selection: $selection,
                        analysis: analysis, replacement: replacement, packageURL: packageURL
                    )
                    .frame(width: 260)
                    Divider()
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: project.id) { _, _ in
            activeTimelineID = project.rootTimelineID
            selection = nil
        }
        .onChange(of: project) { _, newValue in
            history.projectDidChange(newValue)
            keepViewStateValid(for: newValue)
        }
        .onChange(of: AssetAnalysis.inputs(of: project)) { _, _ in analysis.analyzeMissing(in: project) }
        .onAppear {
            connectHistory()
            analysis.analyzeMissing(in: project)
        }
        .onChange(of: undoManager) { _, _ in connectHistory() }
    }

    private func connectHistory() {
        history.undoManager = undoManager
        history.restore = { project = $0 }
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
