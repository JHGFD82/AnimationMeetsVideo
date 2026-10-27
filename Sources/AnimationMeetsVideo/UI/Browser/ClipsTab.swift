import AppKit
import CoreMedia
import SwiftUI

extension Notification.Name {
    /// Asks the browser to show a stretch of an asset (a `MediaPiece`, the
    /// notification's object) in its Clips tab, from a timeline clip's
    /// Show in Clips Browser. Only the browser whose project has the asset
    /// answers.
    static let revealInBrowser = Notification.Name("AnimationMeetsVideo.revealInBrowser")
}

/// Something listed in the Clips tab: a whole asset, or one of its scenes.
enum BrowserItemID: Hashable {
    case asset(UUID)
    case scene(asset: UUID, scene: String)

    var assetID: UUID {
        switch self {
        case .asset(let id), .scene(let id, _): id
        }
    }
}

/// One clip of the Clips tab as it is drawn: the asset or scene, and the
/// stretch of the asset's original time it stands for. Equatable, so rows
/// showing it can skip redrawing; the asset compares cheaply while it is
/// unchanged, its arrays sharing storage.
struct BrowserEntry: Identifiable, Equatable {
    var id: BrowserItemID
    var clip: MediaClip
    var start: CMTime
    var duration: CMTime
    /// The scene's number, for scenes.
    var sceneNumber: Int?
    var setByHand = false

    var seconds: Double { duration.seconds }

    /// The parts of `ranges` (in the asset's original time) inside this
    /// clip, in seconds into it, joined where they overlap or touch.
    func seconds(within ranges: [CMTimeRange]) -> [SecondsSpan] {
        let from = start.seconds, to = from + seconds
        let spans = ranges.map { SecondsSpan(start: max($0.start.seconds, from) - from, end: min($0.end.seconds, to) - from) }
        // A range wholly outside the clip comes out backwards.
        return FilmstripLayout.joined(spans.filter { $0.end > $0.start })
    }

    func piece(from a: Double = 0, to b: Double? = nil) -> MediaPiece {
        let timescale = max(duration.timescale, 600)
        let end = b.map { CMTimeAdd(start, CMTime(seconds: $0, preferredTimescale: timescale)) } ?? CMTimeAdd(start, duration)
        return MediaPiece(assetID: clip.id, start: CMTimeAdd(start, CMTime(seconds: a, preferredTimescale: timescale)), end: end)
    }
}

/// The browser's Clips tab: every asset as a filmstrip. A video is one
/// clip until its scenes are found, with their progress across its top,
/// and is then replaced by its scenes under its name. See docs/browser.md.
struct ClipsTab: View {
    /// The project, read and edited through an object SwiftUI doesn't
    /// watch: the tab redraws when the browser does, which compares what it
    /// shows, not at every edit (see `BrowserPanel`).
    let access: ProjectAccess
    let activeTimelineID: UUID
    @Binding var selection: TimelineSelection?
    let analysis: AssetAnalysis
    let replacement: MediaReplacementController
    let packageURL: URL?
    /// Footage to pick and scroll to, from Show in Clips Browser; set back
    /// to nil once it is shown.
    @Binding var revealing: MediaPiece?
    /// Opens the import dialog, from a double-click off the clips.
    let onImport: () -> Void

    @AppStorage(Preferences.thumbnailInterval) private var interval = ThumbnailInterval.all
    @AppStorage(Preferences.thumbnailSize) private var thumbnailSize = ThumbnailSize.medium
    /// Off, the pointer moving over a strip leaves the viewer alone, and a
    /// click shows the frame clicked instead.
    @AppStorage(Preferences.browserSkimming) private var skimming = true
    @AppStorage(Preferences.browserMutesAddedSound) private var mutesAddedSound = false
    @AppStorage(Preferences.browserSort) private var sort = BrowserSort.added
    /// What is picked, where the arrow keys move from, and the range being
    /// dragged out.
    @State private var interaction = ClipsTabInteraction()
    /// The list's width, in steps of `widthStep`.
    @State private var width: CGFloat = 240
    @State private var height: CGFloat = 0
    @State private var sensitivityTarget: SensitivityTarget?
    @State private var coverageCache = SceneCoverageCache()
    @State private var memos = Memos()
    @State private var rowActions = ClipRowActions()
    /// The asset whose name is being edited, in its title or heading.
    @State private var renamingAsset: UUID?
    /// The line Show in Clips Browser scrolls to once the list has drawn
    /// what it picked; nil once there.
    @State private var pendingScroll: LineID?
    @FocusState private var focused: Bool
    /// Shows the clip under the pointer in the viewer; absent where there
    /// is no viewer to show it (previews, tests).
    @Environment(BrowserSkim.self) private var skim: BrowserSkim?
    /// Splits and merges scenes, showing what is picked here; absent where
    /// there is no editor (previews, tests).
    @Environment(SceneSplitter.self) private var splitter: SceneSplitter?
    /// Files on their way in, listed after the clips.
    @Environment(MediaImports.self) private var imports: MediaImports?
    /// Find All's panel; absent where there is no editor (previews, tests).
    @Environment(UsesFinder.self) private var finder: UsesFinder?
    /// Removing media the timelines use, waiting to be agreed to.
    @State private var pendingRemoval: RemovalRequest?

    private typealias Snapshot = ClipsTabModel.Snapshot
    private typealias Line = ClipsTabModel.Line
    private typealias LineID = ClipsTabModel.LineID

    private var project: EditingProject {
        get { access.value }
        nonmutating set { access.binding.wrappedValue = newValue }
    }

    private static let padding: CGFloat = 10
    /// Live resizing changes the width a point at a time; the strips are
    /// laid out again only once it has changed by this much.
    private static let widthStep: CGFloat = 4

    // MARK: - Entries

    /// The snapshot, what the timelines use and the lines, each kept until
    /// what it is worked out from changes. Most redraws are only the
    /// selection, the pointer or a key moving, which change none of them;
    /// SwiftUI doesn't watch the project, so the keys say what changed.
    @MainActor
    private final class Memos {
        let snapshot = Memo<ClipsTabModel.SnapshotKey, Snapshot>()
        let used = Memo<ClipsTabModel.UsedKey, [UUID: [CMTimeRange]]>()
        let lines = Memo<ClipsTabModel.LinesKey, [Line]>()
    }

    /// Everything listed, as the project is now: worked out again only when
    /// the media, the sort, the sensitivity or the scores changed.
    private func makeSnapshot() -> Snapshot {
        let project = project
        let key = ClipsTabModel.SnapshotKey(
            clips: project.clips, sort: sort, defaultSensitivity: project.defaultSensitivity, tracks: analysis.tracks
        )
        return memos.snapshot.value(for: key) {
            ClipsTabModel.makeSnapshot(clips: key.clips, sort: key.sort, tracks: key.tracks) { clip, track in
                coverageCache.coverage(of: clip, in: project, track: track)
            }
        }
    }

    /// The snapshot the list last drew, for clicks, drags and VoiceOver
    /// between redraws.
    private var drawnSnapshot: Snapshot { memos.snapshot.latest ?? makeSnapshot() }

    private func lines(_ snapshot: Snapshot) -> [Line] {
        let project = project
        // What the project's timelines use of each asset, for the red line.
        let used = memos.used.value(for: ClipsTabModel.UsedKey(clips: project.clips, timelines: project.timelines)) {
            ClipsTabModel.usedRanges(of: project.clips, in: project)
        }
        let key = ClipsTabModel.LinesKey(
            snapshotRevision: memos.snapshot.revision, usedRevision: memos.used.revision,
            width: width, interval: interval, thumbnailSize: thumbnailSize
        )
        return memos.lines.value(for: key) {
            ClipsTabModel.lines(snapshot: snapshot, used: used, layoutProvider: layout(of:))
        }
    }

    private var cellSize: CGSize {
        CGSize(width: (thumbnailSize.height * 16 / 9).rounded(), height: thumbnailSize.height)
    }

    private func layout(of entry: BrowserEntry) -> FilmstripLayout {
        FilmstripLayout(duration: entry.seconds, interval: interval, cellSize: cellSize, width: width - Self.padding * 2)
    }

    // MARK: - Body

    var body: some View {
        let snapshot = makeSnapshot()
        let order = snapshot.order
        let picked = interaction.picked
        let _ = pointRowActions()
        ScrollViewReader { scroller in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines(snapshot)) { line in
                        switch line {
                        case .heading(let clip, let count):
                            heading(clip, sceneCount: count)
                                .padding(.top, Design.Space.group)
                        case .title(let entry, let isUsed):
                            title(entry, isUsed: isUsed, picked: picked, snapshot: snapshot)
                                .padding(.top, Design.Space.step)
                                .padding(.bottom, Design.Space.tight)
                        case .strip(let entry, let layout, let row, let used):
                            stripRow(entry, layout: layout, row: row, used: used, picked: picked, snapshot: snapshot)
                                .padding(.bottom, FilmstripLayout.rowSpacing)
                        case .note(_, let note):
                            Text(note)
                                .font(Design.Typeface.label)
                                .foregroundStyle(Design.statusWarning)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if let imports {
                        ImportingClips(imports: imports)
                    }
                }
                // Show in Clips Browser scrolls once the list has drawn
                // what it picked, which on switching to the tab is only now.
                .task(id: pendingScroll) {
                    guard let target = pendingScroll else { return }
                    withAnimation(Design.Motion.respecting(Design.Motion.glide)) {
                        scroller.scrollTo(target, anchor: .top)
                    }
                    pendingScroll = nil
                }
                .padding(.horizontal, Self.padding)
                .padding(.bottom, Design.Space.group)
                // Clicking off the clips, below them included, picks nothing;
                // a double-click there imports media.
                .frame(maxWidth: .infinity, minHeight: height, alignment: .topLeading)
                .contentShape(Rectangle())
                .onTapGesture(count: 2, perform: onImport)
                .onTapGesture {
                    focused = true
                    interaction.picked.clear()
                }
            }
            .onChange(of: revealing, initial: true) { _, piece in
                guard let piece else { return }
                revealing = nil
                reveal(piece)
            }
        }
        .onGeometryChange(for: CGSize.self) { $0.size } action: {
            let stepped = ($0.width / Self.widthStep).rounded(.down) * Self.widthStep
            if stepped != width { width = stepped }
            height = $0.height
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow, .return, .escape, .delete, .deleteForward, "i", "o"]) { press in
            handleKey(press, snapshot: snapshot) ? .handled : .ignored
        }
        // Delete and Select All in the Edit menu, while the browser is the
        // active panel (see `EditCommands`).
        .focusedSceneValue(\.browserEditActions, EditMenuActions(
            delete: { if !removeSelection(snapshot) { NSSound.beep() } },
            selectAll: { interaction.picked.selectAll(in: order) },
            state: [AnyHashable(picked.revision), AnyHashable(memos.snapshot.revision)]
        ))
        // Leaving the browser gives the viewer back to the timeline; so does
        // leaving it from the keyboard. Without skimming, a frame clicked
        // stays shown until the browser loses the keyboard, so the pointer
        // can go to look at it.
        .onHover { inside in
            if !inside, skimming { skim?.end() }
        }
        .onChange(of: focused) { _, focused in
            if !focused { skim?.end() }
        }
        .onChange(of: order) { _, order in
            interaction.picked.keep(only: order)
            coverageCache.keep(only: Set(project.clips.map(\.id)))
        }
        // Only what the person picks: a scene renamed by an edit dropping
        // out of the selection leaves the splitter where it is.
        .onChange(of: picked.revision) { _, _ in
            let ids = interaction.picked.ordered(in: order)
            let focus = ClipsTabModel.splitterFocus(for: ids, snapshot: snapshot)
            splitter?.follow(focus, selecting: focus.map { ClipsTabModel.sceneIDs(ids, of: $0.assetID) } ?? [])
        }
        .removalConfirmation($pendingRemoval, finder: finder)
        .sheet(item: $sensitivityTarget) { target in
            SensitivitySheet(project: access.binding, target: target, track: analysis.tracks[target.assetID])
        }
        .sunken(.sunken)
    }

    // MARK: - Show in Clips Browser

    /// Picks the footage a timeline clip plays (see
    /// `ClipsTabInteraction.revealSelection`) and scrolls to it.
    private func reveal(_ piece: MediaPiece) {
        guard let first = interaction.revealSelection(for: piece, snapshot: makeSnapshot()) else { return }
        pendingScroll = Line.titleID(of: first)
    }

    // MARK: - Rows

    /// Points the rows' actions at this redraw's state: rows that aren't
    /// drawn again keep the same object, so they act on it too.
    private func pointRowActions() {
        rowActions.perform = { action, entry in perform(action, on: entry) }
        rowActions.isRenaming = { renamingAsset == $0 }
        rowActions.pressBegan = { entry, layout, point, flags in
            focused = true
            return interaction.pressBegan(entry: entry, layout: layout, point: point, flags: flags)
        }
        rowActions.pressed = { press, entry, layout in
            let effect = interaction.pressed(press, entry: entry, layout: layout, order: drawnSnapshot.order, skimming: skimming)
            if case .skim(let entry, let seconds) = effect { skim(entry, at: seconds) }
        }
        rowActions.dragText = { entry, layout, point in dragText(entry, layout: layout, at: point) }
        rowActions.isOnHandle = { entry, layout, point in interaction.picked.handle(of: entry.id, at: point, in: layout) != nil }
        rowActions.hover = { entry, layout, point in
            if skimming, let point { skim(entry, at: layout.seconds(at: point)) }
        }
    }

    private func perform(_ action: ClipRowActions.Action, on entry: BrowserEntry) {
        switch action {
        case .select:
            interaction.picked.click(entry.id)
        case .mouseDown:
            focused = true
            interaction.click(entry.id, flags: NSApp.currentEvent?.modifierFlags ?? [], order: drawnSnapshot.order)
        case .addToTimeline:
            addToTimeline(ClipsTabModel.piecesToAdd(from: entry.id, snapshot: drawnSnapshot, picked: interaction.picked))
        case .skimForward:
            skimStep(entry, seconds: 1)
        case .skimBack:
            skimStep(entry, seconds: -1)
        case .setRangeStart:
            interaction.setRangeEnd(.start, of: entry, skim: skimState)
        case .setRangeEnd:
            interaction.setRangeEnd(.end, of: entry, skim: skimState)
        case .rename:
            renamingAsset = entry.clip.id
        case .removeFromProject:
            if entry.sceneNumber != nil || !removeFromProject([entry.clip.id]) { NSSound.beep() }
        case .findAll:
            findAll(findQuery(for: entry))
        case .setRenaming(let editing):
            renamingAsset = editing ? entry.clip.id : nil
        case .commitName(let name):
            project.renameMedia(entry.clip.id, to: name)
        }
    }

    /// A clip's title, with its menu and what VoiceOver reads and does with
    /// the clip around it, in that order. Those follow the whole selection,
    /// so they are applied here at every redraw rather than kept in the row;
    /// the actions go through `rowActions` like the row's own.
    private func title(
        _ entry: BrowserEntry, isUsed: Bool, picked: BrowserSelection<BrowserItemID>, snapshot: Snapshot
    ) -> some View {
        let isSelected = picked.contains(entry.id)
        let actions = rowActions
        return ClipTitleRow(
            entry: entry, isSelected: isSelected, nameIsSelected: isSelected && picked.range == nil,
            isRenaming: entry.sceneNumber == nil && renamingAsset == entry.clip.id,
            analysis: analysis, replacement: replacement, actions: actions
        )
        .equatable()
        .contextMenu { menu(for: entry, snapshot: snapshot) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityName(entry, isUsed: isUsed, picked: picked))
        .accessibilityValue(isSelected ? "selected" : "")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityAction { actions.perform(.select, entry) }
        .accessibilityAction(named: "Add to Timeline") { actions.perform(.addToTimeline, entry) }
        .accessibilityAction(named: "Skim Forward") { actions.perform(.skimForward, entry) }
        .accessibilityAction(named: "Skim Back") { actions.perform(.skimBack, entry) }
        .accessibilityAction(named: "Set Range Start") { actions.perform(.setRangeStart, entry) }
        .accessibilityAction(named: "Set Range End") { actions.perform(.setRangeEnd, entry) }
        .accessibilityAction(named: "Rename") { actions.perform(.rename, entry) }
        .accessibilityAction(named: "Remove from Project") { actions.perform(.removeFromProject, entry) }
        .accessibilityAction(named: "Find All") { actions.perform(.findAll, entry) }
    }

    private func accessibilityName(_ entry: BrowserEntry, isUsed: Bool, picked: BrowserSelection<BrowserItemID>) -> String {
        var parts = [entry.sceneNumber.map { "Scene \($0) of \(entry.clip.name)" } ?? entry.clip.name, ClipsTabModel.durationText(entry)]
        if isUsed { parts.append("used in a timeline") }
        if let range = picked.range, range.item == entry.id {
            parts.append("range \(ClipsTabModel.timecode(range.start, entry)) to \(ClipsTabModel.timecode(range.end, entry))")
        }
        return parts.joined(separator: ", ")
    }

    /// An asset's name, edited in place while `renamingAsset` names it.
    private func assetName(_ clip: MediaClip, isSelected: Bool?) -> some View {
        InlineNameField(
            name: clip.name,
            isEditing: Binding(
                get: { renamingAsset == clip.id },
                set: { editing in renamingAsset = editing ? clip.id : nil }
            ),
            isSelected: isSelected,
            onCommit: { project.renameMedia(clip.id, to: $0) }
        )
    }

    /// A video's name over its scenes: not a clip itself, but where the
    /// video's own menu is.
    private func heading(_ clip: MediaClip, sceneCount: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: Design.Space.tight) {
                // Not a clip, so never selected: renamed from its menu.
                assetName(clip, isSelected: nil)
                    .font(Design.Typeface.label.weight(.semibold))
                    .foregroundStyle(Design.textPrimary)
                Text(sceneCount == 1 ? "1 scene" : "\(sceneCount) scenes")
                    .font(Design.Typeface.micro)
                    .foregroundStyle(Design.textTertiary)
            }
            AssetStatusLine(analysis: analysis, replacement: replacement, clip: clip)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .contextMenu {
            Button("Add Whole Clip to Timeline") {
                addToTimeline([MediaPiece(assetID: clip.id, start: .zero, end: clip.duration)])
            }
            findAllButton([findQuery(for: clip)])
            assetMenu(clip)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityAction(named: "Add Whole Clip to Timeline") {
            addToTimeline([MediaPiece(assetID: clip.id, start: .zero, end: clip.duration)])
        }
        .accessibilityAction(named: "Rename") { renamingAsset = clip.id }
        .accessibilityAction(named: "Remove from Project") { if !removeFromProject([clip.id]) { NSSound.beep() } }
        .accessibilityAction(named: "Find All") { findAll(findQuery(for: clip)) }
    }

    // MARK: - Strips

    private func stripRow(
        _ entry: BrowserEntry, layout: FilmstripLayout, row: Int, used: [SecondsSpan], picked: BrowserSelection<BrowserItemID>,
        snapshot: Snapshot
    ) -> some View {
        let range = picked.range?.item == entry.id ? picked.range : nil
        return ClipStripRow(
            entry: entry, layout: layout, row: row,
            isSelected: picked.contains(entry.id) && range == nil,
            range: range.map { SecondsSpan(start: $0.start, end: $0.end) },
            used: used,
            detection: row == 0 && entry.id == .asset(entry.clip.id) ? analysis : nil,
            skim: skim, actions: rowActions
        )
        .equatable()
        .contextMenu { menu(for: entry, snapshot: snapshot) }
        // The title line is the clip for VoiceOver; the pictures add nothing.
        .accessibilityHidden(true)
    }

    /// What a drag from `point` carries (see
    /// `ClipsTabInteraction.draggedPieces`), with its picture.
    private func dragText(_ entry: BrowserEntry, layout: FilmstripLayout, at point: CGPoint) -> (text: String, image: NSImage)? {
        // Dragged to the timeline, the viewer goes back to showing it.
        skim?.end()
        interaction.pickForDrag(entry: entry, layout: layout, at: point)
        let pieces = interaction.draggedPieces(entry: entry, layout: layout, at: point, snapshot: drawnSnapshot)
        guard let first = pieces.first, let clip = project.mediaClip(id: first.assetID) else { return nil }
        let image = BrowserDragImage.make(
            picture: Self.dragPicture(of: clip, at: first.start, height: cellSize.height), symbol: "waveform",
            tone: NSColor(Design.ClipTone.of(.media(clip), streams: .videoAndAudio).color), size: cellSize, count: pieces.count
        )
        return (MediaDragPayload.beginDrag(pieces).text, image)
    }

    /// The clip's picture nearest `start` already made (a range seldom
    /// starts where a thumbnail does); nil for sound, or none made yet.
    private static func dragPicture(of clip: MediaClip, at start: CMTime, height: CGFloat) -> NSImage? {
        guard clip.kind.hasPictures, let url = clip.url else { return nil }
        return FrameThumbnails.nearestCached(url: url, time: clip.fileTime(forSourceTime: start), height: height)
    }

    // MARK: - Skimming

    private func skimTarget(_ entry: BrowserEntry) -> BrowserSkim.Target {
        BrowserSkim.Target(item: entry.id, clip: entry.clip, start: entry.start, duration: entry.duration)
    }

    /// Shows `entry` at `seconds` into it in the viewer, on its nearest frame.
    private func skim(_ entry: BrowserEntry, at seconds: Double) {
        skim?.skim(skimTarget(entry), at: entry.snapped(seconds))
    }

    /// What the keys read of the viewer's skimming.
    private var skimState: ClipsTabInteraction.Skim {
        guard let skim else { return .none }
        return ClipsTabInteraction.Skim(item: skim.target?.item.base as? BrowserItemID, seconds: skim.seconds, isActive: skim.isActive)
    }

    /// Moves `entry`'s skim position by `seconds`, from its start when it
    /// isn't skimmed yet.
    private func skimStep(_ entry: BrowserEntry, seconds: Double) {
        skim(entry, at: (skimState.seconds(in: entry) ?? 0) + seconds)
    }

    // MARK: - Keys

    /// See `ClipsTabInteraction.handleKey`; this carries out what it asks.
    private func handleKey(_ press: KeyPress, snapshot: Snapshot) -> Bool {
        let outcome = interaction.handleKey(press.key, modifiers: press.modifiers, snapshot: snapshot, skim: skimState)
        guard case .handled(let effects) = outcome else { return false }
        for effect in effects {
            switch effect {
            case .skim(let entry, let seconds): skim(entry, at: seconds)
            case .step(let frames): skim?.step(frames: frames)
            case .endSkim: skim?.end()
            case .addToTimeline(let pieces): addToTimeline(pieces)
            case .removeSelection: if !removeSelection(snapshot) { NSSound.beep() }
            }
        }
        return true
    }

    // MARK: - Menus

    @ViewBuilder
    private func menu(for entry: BrowserEntry, snapshot: Snapshot) -> some View {
        let picked = interaction.picked
        let ids = picked.dragged(from: entry.id, in: snapshot.order)
        Button(ids.count > 1 ? "Add \(ids.count) Clips to Timeline" : "Add to Timeline") {
            addToTimeline(ClipsTabModel.piecesToAdd(from: entry.id, snapshot: snapshot, picked: interaction.picked))
        }
        findAllButton(ids.compactMap { snapshot.byID[$0] }.map(findQuery(for:)))
        if ids.count == 1 {
            switch entry.id {
            case .asset:
                assetMenu(entry.clip)
            case .scene(let assetID, _):
                sceneMenu(entry, assetID: assetID, scenes: snapshot.scenes(of: assetID))
            }
        } else {
            let sceneIDs = ClipsTabModel.sceneIDs(ids, of: entry.clip.id)
            let scenes = snapshot.scenes(of: entry.clip.id)
            if sceneIDs.count == ids.count {
                Divider()
                Button("Split Scenes…") { splitter?.show(ClipsTabModel.splitterFocus(for: ids, snapshot: snapshot), selecting: sceneIDs) }
                if !ClipsTabModel.cutsToRemove(Set(sceneIDs), in: scenes).isEmpty {
                    Button("Merge Selected Scenes") { mergeScenes(Set(sceneIDs), assetID: entry.clip.id, scenes: scenes) }
                }
            }
            let assets = picked.contains(entry.id) ? ClipsTabModel.wholeAssetsPicked(snapshot: snapshot, picked: picked) : []
            if !assets.isEmpty {
                Divider()
                Button(assets.count > 1 ? "Remove \(assets.count) Clips from Project" : "Remove from Project") {
                    removeFromProject(assets)
                }
            }
        }
    }

    @ViewBuilder
    private func assetMenu(_ clip: MediaClip) -> some View {
        Button("Rename") { renamingAsset = clip.id }
        if clip.kind == .video {
            Divider()
            Button("Split Scenes…") {
                splitter?.show(SceneSplitter.Focus(assetID: clip.id, start: .zero, end: clip.duration))
            }
            if clip.skipsSceneDetection {
                Button("Detect Scenes") { project.setDetectsScenes(true, ofAsset: clip.id) }
            } else {
                Button("Cut Sensitivity…") {
                    sensitivityTarget = SensitivityTarget(assetID: clip.id)
                }
                .disabled(analysis.tracks[clip.id] == nil)
                AnalysisIdleButton(title: "Find Scenes Again", analysis: analysis, assetID: clip.id) {
                    analysis.reanalyze(clip, in: project)
                }
                // Stops a search under way, too; undoable, as any edit.
                Button("Don't Detect Scenes") { project.setDetectsScenes(false, ofAsset: clip.id) }
            }
        }
        if let problem = analysis.persistenceProblem(for: clip.id) {
            Button(problem.kind == .unreadableProject ? "Retry Reading Results" : "Retry Saving Results") {
                Task { await analysis.retryPersistence() }
            }
        }
        if analysis.firstFailure(for: clip.id) != nil {
            AnalysisIdleButton(title: "Retry Failed Analysis", analysis: analysis, assetID: clip.id) {
                analysis.retryFailures(for: clip.id, in: project)
            }
        }
        Divider()
        ReplaceMediaMenuItems(clip: clip, project: access.binding, analysis: analysis, controller: replacement, packageURL: packageURL)
        Divider()
        // Asks first when the timelines use it.
        Button("Remove from Project") { removeFromProject([clip.id]) }
    }

    /// Find All for `queries`, disabled when none of them is used, or
    /// where there is no panel to show them.
    private func findAllButton(_ queries: [UsesFinder.Query]) -> some View {
        Button("Find All") { finder?.show(queries) }
            .disabled(finder == nil || queries.allSatisfy { project.uses(of: $0.item, within: $0.range).isEmpty })
    }

    /// Opens Find All on `query`; a beep where there is no panel.
    private func findAll(_ query: UsesFinder.Query) {
        if let finder { finder.show([query]) } else { NSSound.beep() }
    }

    /// What Find All looks for from a clip: the whole asset's uses, or a
    /// scene's, those playing some of its stretch of the asset.
    private func findQuery(for entry: BrowserEntry) -> UsesFinder.Query {
        guard let number = entry.sceneNumber else { return findQuery(for: entry.clip) }
        return UsesFinder.Query(
            item: .media(entry.clip.id), range: CMTimeRange(start: entry.start, duration: entry.duration),
            name: "Scene \(number) of \(entry.clip.name)"
        )
    }

    private func findQuery(for clip: MediaClip) -> UsesFinder.Query {
        UsesFinder.Query(item: .media(clip.id), range: nil, name: clip.name)
    }

    @ViewBuilder
    private func sceneMenu(_ entry: BrowserEntry, assetID: UUID, scenes: [SceneRange]) -> some View {
        Divider()
        Button("Split Scenes…") {
            splitter?.show(
                SceneSplitter.Focus(assetID: assetID, start: entry.start, end: CMTimeAdd(entry.start, entry.duration)),
                selecting: ClipsTabModel.sceneIDs([entry.id], of: assetID)
            )
        }
        if case .scene(_, let sceneID) = entry.id {
            Button("Merge with Previous Scene") { mergeScenes([sceneID], assetID: assetID, scenes: scenes) }
                .disabled(ClipsTabModel.cutsToRemove([sceneID], in: scenes).isEmpty)
        }
    }

    // MARK: - Editing

    private func addToTimeline(_ pieces: [MediaPiece]) {
        guard let result = project.addPieces(pieces, intoTimeline: activeTimelineID, mutingSound: mutesAddedSound),
              let clipID = result.clipIDs.first else { return }
        selection = TimelineSelection(timelineID: activeTimelineID, layerID: result.layerID, timelineClipID: clipID)
    }

    /// Takes the media wholly selected out of the project; false when no
    /// asset is wholly selected.
    private func removeSelection(_ snapshot: Snapshot) -> Bool {
        removeFromProject(ClipsTabModel.wholeAssetsPicked(snapshot: snapshot, picked: interaction.picked))
    }

    /// Takes the assets out of the project, undoably; their files stay where
    /// they are. When the timelines use any of them, it asks first, saying
    /// how many uses go with them (`RemovalRequest`). False with none.
    @discardableResult
    private func removeFromProject(_ assetIDs: [UUID]) -> Bool {
        let project = project
        let clips = assetIDs.compactMap { project.mediaClip(id: $0) }
        guard !clips.isEmpty else { return false }
        let ids = clips.map(\.id)
        let used = clips.map { ($0, project.uses(of: .media($0.id))) }.filter { !$0.1.isEmpty }
        guard !used.isEmpty else {
            remove(ids)
            return true
        }
        pendingRemoval = RemovalRequest(
            removing: clips.map(\.name), noun: "clip", action: "Remove",
            uses: used.flatMap(\.1), in: project,
            queries: used.map { findQuery(for: $0.0) }, perform: { remove(ids) }
        )
        return true
    }

    private func remove(_ assetIDs: [UUID]) {
        if let skimmed = skim?.target?.item.base as? BrowserItemID, assetIDs.contains(skimmed.assetID) { skim?.end() }
        project.removeMedia(assetIDs)
    }

    private func mergeScenes(_ sceneIDs: Set<String>, assetID: UUID, scenes: [SceneRange]) {
        let cuts = ClipsTabModel.cutsToRemove(sceneIDs, in: scenes)
        project.editScenesFollowingClips(ofAsset: assetID, track: analysis.tracks[assetID]) { edits in
            for cut in cuts { edits.removeCut(cut) }
        }
        interaction.picked.clear()
    }
}
