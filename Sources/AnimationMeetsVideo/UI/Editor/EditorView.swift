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
    /// A clip skimmed in the browser, which the viewer shows.
    @State private var skim = BrowserSkim()
    /// The project as the browser reads and edits it (see `browserProject`).
    @State private var browserAccess = ProjectAccess()

    /// `selection` is the clip selected to begin with: none in the app,
    /// one for a benchmark hosting the editor with its effects showing.
    init(
        project: Binding<EditingProject>,
        history: ProjectHistory,
        analysis: AssetAnalysis,
        replacement: MediaReplacementController,
        packageURL: URL?,
        selection: TimelineSelection? = nil
    ) {
        self._project = project
        self.history = history
        self.analysis = analysis
        self.replacement = replacement
        self.packageURL = packageURL
        self._activeTimelineID = State(initialValue: project.wrappedValue.rootTimelineID)
        self._selection = State(initialValue: selection)
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
            .environment(skim)
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
            skim.end()
            beatMatch.discardAndClose()
        }
        .onChange(of: project) { _, newValue in projectDidChange(newValue) }
        .onReceive(NotificationCenter.default.publisher(for: .spectrogramsChanged)) { _ in analysisArrived() }
        .onChange(of: analysis.beats, initial: true) { _, beats in
            if DetectedBeats.shared.update(beats) { analysisArrived() }
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

    /// Records an edit for undo and brings the view state along. Keyframing
    /// effects whose clip or beats moved make their keyframes again first,
    /// so they join this edit's undo step: this runs again with the result,
    /// which records it.
    private func projectDidChange(_ newValue: EditingProject) {
        var refreshed = newValue
        if refreshed.refreshKeyframing() {
            project = refreshed
            return
        }
        history.projectDidChange(newValue)
        keepViewStateValid(for: newValue)
        beatMatch.update(project: newValue)
    }

    /// Keyframing effects waiting on analysis make their keyframes: Audio
    /// Keys when a file's spectrogram arrives, Beat Keys when its detected
    /// beats do. That is the analysis arriving, not an edit, so it is made
    /// in the undo baseline too rather than recorded.
    private func analysisArrived() {
        var refreshed = project
        guard refreshed.refreshKeyframing() else { return }
        history.adopt { $0.refreshKeyframing() }
        project = refreshed
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

extension EditorView: Equatable {
    /// Whether the editor was made from the same things: the app's history,
    /// analysis and replacement (the same objects) and package. The project
    /// binding is left out: it reaches the same state each time, and the
    /// editor follows the project through it. Without this, the app's scene,
    /// which SwiftUI runs again whenever any of the app's state changes,
    /// rebuilt the whole editor at every edit (the app marks it
    /// `.equatable()`).
    nonisolated static func == (lhs: EditorView, rhs: EditorView) -> Bool {
        MainActor.assumeIsolated {
            lhs.history === rhs.history && lhs.analysis === rhs.analysis
                && lhs.replacement === rhs.replacement && lhs.packageURL == rhs.packageURL
        }
    }
}

/// A project kept where SwiftUI doesn't watch it, with the way to edit it,
/// for a view that redraws on comparing what it shows rather than on every
/// edit (see `EditorView.browserProject`).
final class ProjectAccess: @unchecked Sendable {
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
