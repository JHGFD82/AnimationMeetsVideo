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
    @State private var beatMatch = BeatMatchController()
    @State private var tapeScrubber = TapeScrubberWindow()
    /// The project as the browser reads and edits it (see `browserProject`).
    @State private var browserAccess = ProjectAccess()

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

    /// The project for the browser, through an object SwiftUI doesn't
    /// watch, brought up to date at each redraw. Reading `project` itself, or
    /// a `Binding(get:set:)` made for each redraw, which SwiftUI takes as
    /// changed every time, would redraw the browser on every edit however
    /// its `==` compares; this way it redraws only when what it shows
    /// changes. Edits go to the project.
    private var browserProject: ProjectAccess {
        let access = browserAccess
        access.value = project
        let project = $project
        access.write = { project.wrappedValue = $0 }
        return access
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
            TimelineEditorSurface(
                project: $project, timelineID: activeTimeline.wrappedValue,
                selectTimeline: { [activeTimeline] in activeTimeline.wrappedValue = $0 }, selection: $selection,
                playback: playback, analysis: analysis, offlineMedia: replacement.missingMedia
            ) {
                BrowserPanel(
                    access: browserProject, activeTimelineID: activeTimeline.wrappedValue, selection: $selection,
                    analysis: analysis, replacement: replacement, packageURL: packageURL,
                    shown: BrowserPanel.Shown(structure: project.structure, activeTimelineID: activeTimelineID, selection: selection)
                )
                .equatable()
                .grooved(.trailing)
            }
            .environment(renderer)
        }
        // While a song is beat matched the editor is darkened and takes no
        // input; a click on it brings the panel back.
        .disabled(beatMatch.isActive)
        .overlay {
            if beatMatch.isActive {
                Color.black.opacity(0.55)
                    .contentShape(Rectangle())
                    .onTapGesture { beatMatch.bringToFront() }
                    .accessibilityLabel("Beat match is open")
                    .accessibilityHint("Bring the beat match panel to the front")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { beatMatch.bringToFront() }
            }
        }
        .environment(beatMatch)
        .background(Design.Surface.base.color)
        // A picture can only be judged against a neutral dim surround, so
        // the editor is dark whatever the system appearance is. See
        // `DesignSystem`.
        .preferredColorScheme(.dark)
        .tint(Design.accent)
        .environment(\.projectHistory, history)
        .focusedSceneValue(\.showTapeScrubber, TapeScrubberOpener { [tapeScrubber, playback] in tapeScrubber.show(playback: playback) })
        // The tape scrubber plays only the Main timeline.
        .onChange(of: activeTimeline.wrappedValue == project.rootTimelineID, initial: true) { _, isMain in
            tapeScrubber.isMainTimeline = isMain
        }
        .onDisappear { tapeScrubber.close() }
        .onChange(of: project.id) { _, _ in
            activeTimelineID = project.rootTimelineID
            selection = nil
            beatMatch.discardAndClose()
        }
        .onChange(of: project) { _, newValue in
            history.projectDidChange(newValue)
            keepViewStateValid(for: newValue)
            beatMatch.update(project: newValue)
        }
        .onChange(of: AssetAnalysis.inputs(of: project)) { _, _ in analysis.update(with: project) }
        .onChange(of: packageURL, initial: true) { _, url in renderer.packageURL = url }
        .onAppear {
            beatMatch.onEdit = { change in change(&project) }
            beatMatch.onOpen = { [playback] in playback.player.pause() }
            connectHistory()
            analysis.projectSource = { project }
            analysis.update(with: project)
        }
        .onChange(of: undoManager) { _, _ in connectHistory() }
        // A file that comes back can be analyzed again.
        .onChange(of: replacement.missingMedia) { _, _ in analysis.retryUnavailable(in: project) }
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

/// A project kept where SwiftUI doesn't watch it, with the way to edit it,
/// for a view that redraws on comparing what it shows rather than on every
/// edit (see `EditorView.browserProject`).
final class ProjectAccess {
    /// The project as of the owner's last redraw, or the last edit made
    /// through this.
    var value = EditingProject.empty
    /// Puts an edited project in place of the owner's.
    var write: (EditingProject) -> Void = { _ in }

    /// Reads and edits the project, for views below that take a binding.
    var binding: Binding<EditingProject> {
        Binding(get: { self.value }, set: { newValue in
            self.value = newValue
            self.write(newValue)
        })
    }
}
