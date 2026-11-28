import CoreMedia
import Foundation

/// How the project's window was left: the timeline open, for each
/// timeline shown, its playhead, zoom, scroll, the clip selected and its
/// loop region, and
/// what the browser remembers (`Browser`). Kept in
/// the package as `view-state.json`, beside `project.json` rather than in it,
/// so moving around is never an edit: no undo step, no unsaved change, no
/// backup. See docs/project-package.md, "View state".
struct ViewState: Equatable {
    /// Where one timeline was left.
    struct Timeline: Equatable {
        var time: CMTime = .zero
        /// The clip selected, which the inspector shows; nil for none.
        var selection: TimelineSelection?
        /// The chosen zoom in points per second; nil when fitted to the window.
        var zoomedPixelsPerSecond: Double?
        var scrollX: Double = 0
        /// How far down each area of layers was scrolled, in points.
        var areaOffsets: [LayerKind: Double] = [:]
        /// The stretch playback repeats; nil for none. See
        /// docs/loop-region.md, "Saving".
        var loop: LoopRegion?
        /// Which parameters each clip has in the timeline's rows, and the
        /// effects folded closed there. See docs/parameter-rows.md.
        var parameterRows = TimelineParameterRows()
    }

    /// What the browser remembers of how it was left: the range last
    /// picked of each clip and timeline filmstrip, picked again as the
    /// selection comes back to it, and the timelines whose nested
    /// timelines the Timelines tab's tree hides. See docs/browser.md.
    struct Browser: Equatable {
        /// In seconds into each clip (an asset, or one of its scenes).
        var clipRanges: [BrowserItemID: SecondsSpan] = [:]
        /// In seconds into each timeline.
        var timelineRanges: [UUID: SecondsSpan] = [:]
        var collapsedTimelines: Set<UUID> = []

        var isEmpty: Bool { clipRanges.isEmpty && timelineRanges.isEmpty && collapsedTimelines.isEmpty }

        /// Without what `project` no longer has: media taken out, timelines
        /// deleted. A scene that is gone though its asset isn't is dropped
        /// by the Clips tab, which knows the scenes.
        func kept(in project: EditingProject) -> Browser {
            let assets = Set(project.clips.map(\.id))
            var kept = self
            kept.clipRanges = clipRanges.filter { assets.contains($0.key.assetID) }
            kept.timelineRanges = timelineRanges.filter { project.timeline(id: $0.key) != nil }
            kept.collapsedTimelines = collapsedTimelines.filter { project.timeline(id: $0) != nil }
            return kept
        }
    }

    /// The timeline open in the window.
    var openTimelineID: UUID?
    var timelines: [UUID: Timeline] = [:]
    var browser = Browser()
}

/// Reading and writing `view-state.json`. It is only where things were left,
/// so any trouble reading it (missing, damaged, another version) starts
/// afresh rather than stopping the project from opening.
enum ViewStateFile {
    static let fileName = "view-state.json"
    static let currentVersion = 1

    static func url(in packageURL: URL) -> URL {
        packageURL.appending(path: fileName)
    }

    static func read(from packageURL: URL) -> ViewState {
        guard let data = try? Data(contentsOf: url(in: packageURL)),
              let file = try? JSONDecoder().decode(FileShape.self, from: data),
              file.formatVersion == currentVersion
        else { return ViewState() }
        return file.state
    }

    /// Writes `state`, and has the package's `.gitignore` list the file,
    /// for a project made before it was kept: it is one person's view, and
    /// changes at every move.
    static func write(_ state: ViewState, to packageURL: URL) throws {
        try JSONFile.encode(FileShape(state)).write(to: url(in: packageURL), options: .atomic)
        try? ProjectStore.ignore(fileName, in: packageURL)
    }

    /// The file as written: IDs as strings, so they key JSON objects.
    private struct FileShape: Codable {
        struct Selection: Codable {
            var layer: UUID
            var clip: UUID
            var transition: String?
        }

        struct Timeline: Codable {
            var playhead: ProjectFile.TimeEntry
            var zoom: Double?
            var scroll: Double
            var areaScroll: [String: Double]
            var selection: Selection?
            /// Absent from files written before there were loop regions.
            var loop: Loop?
            /// Absent while no clip has rows, and from files written before
            /// there were parameter rows.
            var rows: Rows?
        }

        /// Which parameters each clip has in the timeline's rows, by clip.
        struct Rows: Codable {
            var picked: [String: [ParameterRowKey]]?
            var removed: [String: [ParameterRowKey]]?
            var closed: [String]?

            init(_ rows: TimelineParameterRows) {
                func keyed(_ sets: [UUID: Set<ParameterRowKey>]) -> [String: [ParameterRowKey]]? {
                    sets.isEmpty ? nil : Dictionary(uniqueKeysWithValues: sets.map { id, keys in
                        (id.uuidString, keys.sorted { ($0.effectKind, $0.ordinal, $0.control) < ($1.effectKind, $1.ordinal, $1.control) })
                    })
                }
                picked = keyed(rows.picked)
                removed = keyed(rows.removed)
                closed = rows.closed.isEmpty ? nil : rows.closed.sorted()
            }

            var rows: TimelineParameterRows {
                func sets(_ keyed: [String: [ParameterRowKey]]?) -> [UUID: Set<ParameterRowKey>] {
                    Dictionary((keyed ?? [:]).compactMap { key, keys in UUID(uuidString: key).map { ($0, Set(keys)) } }, uniquingKeysWith: { first, _ in first })
                }
                return TimelineParameterRows(picked: sets(picked), removed: sets(removed), closed: Set(closed ?? []))
            }
        }

        /// A loop region. Read leniently: a damaged one reads with its
        /// parts missing and is dropped, rather than failing the file
        /// and losing everything else in it.
        struct Loop: Codable {
            var start: ProjectFile.TimeEntry?
            var end: ProjectFile.TimeEntry?
            var on: Bool?
            /// `"#RRGGBB"`; absent for the loop's tone. One that doesn't
            /// read is dropped, leaving the region in its tone.
            var color: String?

            init(_ region: LoopRegion) {
                start = ProjectFile.TimeEntry(region.start)
                end = ProjectFile.TimeEntry(region.end)
                on = region.isOn
                color = region.color?.hex
            }

            init(from decoder: Decoder) {
                let container = try? decoder.container(keyedBy: CodingKeys.self)
                start = try? container?.decodeIfPresent(ProjectFile.TimeEntry.self, forKey: .start)
                end = try? container?.decodeIfPresent(ProjectFile.TimeEntry.self, forKey: .end)
                on = try? container?.decodeIfPresent(Bool.self, forKey: .on)
                color = try? container?.decodeIfPresent(String.self, forKey: .color)
            }

            /// Nil unless both times read and the end is after the start.
            var region: LoopRegion? {
                guard let start = start?.time, let end = end?.time,
                      start.isNumeric, end.isNumeric, end > start
                else { return nil }
                return LoopRegion(start: start, end: end, isOn: on ?? true, color: color.flatMap(BarColor.init(hex:)))
            }
        }

        struct Span: Codable {
            var start: Double
            var end: Double
        }

        /// Left out when there is nothing to remember, and absent from
        /// files written before the browser remembered anything.
        struct Browser: Codable {
            /// Keyed by the asset's ID, then `#` and the scene's ID for a scene.
            var clipRanges: [String: Span]?
            var timelineRanges: [String: Span]?
            var collapsedTimelines: [UUID]?
        }

        var formatVersion: Int
        var openTimeline: UUID?
        var timelines: [String: Timeline]
        var browser: Browser?

        init(_ state: ViewState) {
            formatVersion = ViewStateFile.currentVersion
            openTimeline = state.openTimelineID
            timelines = Dictionary(uniqueKeysWithValues: state.timelines.compactMap { id, kept in
                // A time that can't be written exactly starts the timeline at 0.
                let time = kept.time.isNumeric ? kept.time : .zero
                return (id.uuidString, Timeline(
                    playhead: ProjectFile.TimeEntry(time),
                    zoom: kept.zoomedPixelsPerSecond,
                    scroll: kept.scrollX,
                    areaScroll: Dictionary(uniqueKeysWithValues: kept.areaOffsets.map { ($0.key.rawValue, $0.value) }),
                    selection: kept.selection.map { selection in
                        Selection(
                            layer: selection.layerID, clip: selection.timelineClipID,
                            transition: selection.transitionEdge.map { $0 == .leading ? "leading" : "trailing" }
                        )
                    },
                    // Only a region that reads back: the file can't hold
                    // a time that isn't numeric.
                    loop: kept.loop.flatMap { region in
                        region.start.isNumeric && region.end.isNumeric && region.end > region.start ? Loop(region) : nil
                    },
                    rows: kept.parameterRows.isEmpty ? nil : Rows(kept.parameterRows)
                ))
            })
            let kept = state.browser
            browser = kept.isEmpty ? nil : Browser(
                clipRanges: kept.clipRanges.isEmpty ? nil : Dictionary(uniqueKeysWithValues: kept.clipRanges.map { item, span in
                    (Self.key(of: item), Span(start: span.start, end: span.end))
                }),
                timelineRanges: kept.timelineRanges.isEmpty ? nil : Dictionary(uniqueKeysWithValues: kept.timelineRanges.map { id, span in
                    (id.uuidString, Span(start: span.start, end: span.end))
                }),
                collapsedTimelines: kept.collapsedTimelines.isEmpty ? nil : kept.collapsedTimelines.sorted { $0.uuidString < $1.uuidString }
            )
        }

        private static func key(of item: BrowserItemID) -> String {
            switch item {
            case .asset(let id): id.uuidString
            case .scene(let asset, let scene): "\(asset.uuidString)#\(scene)"
            }
        }

        private static func item(of key: String) -> BrowserItemID? {
            let parts = key.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            guard let asset = UUID(uuidString: String(parts[0])) else { return nil }
            return parts.count == 2 ? .scene(asset: asset, scene: String(parts[1])) : .asset(asset)
        }

        private static func span(_ span: Span) -> SecondsSpan? {
            // A damaged file's ranges are left out rather than picked.
            span.start.isFinite && span.end.isFinite && span.end > span.start ? SecondsSpan(start: span.start, end: span.end) : nil
        }

        var state: ViewState {
            var state = ViewState(openTimelineID: openTimeline)
            for (key, kept) in timelines {
                guard let id = UUID(uuidString: key) else { continue }
                state.timelines[id] = ViewState.Timeline(
                    time: kept.playhead.time,
                    selection: kept.selection.map { selection in
                        TimelineSelection(
                            timelineID: id, layerID: selection.layer, timelineClipID: selection.clip,
                            transitionEdge: selection.transition.flatMap { $0 == "leading" ? .leading : $0 == "trailing" ? .trailing : nil }
                        )
                    },
                    zoomedPixelsPerSecond: kept.zoom,
                    scrollX: kept.scroll,
                    areaOffsets: Dictionary(uniqueKeysWithValues: kept.areaScroll.compactMap { key, value in
                        LayerKind(rawValue: key).map { ($0, value) }
                    }),
                    loop: kept.loop?.region,
                    parameterRows: kept.rows?.rows ?? TimelineParameterRows()
                )
            }
            if let browser {
                for (key, kept) in browser.clipRanges ?? [:] {
                    guard let item = Self.item(of: key), let span = Self.span(kept) else { continue }
                    state.browser.clipRanges[item] = span
                }
                for (key, kept) in browser.timelineRanges ?? [:] {
                    guard let id = UUID(uuidString: key), let span = Self.span(kept) else { continue }
                    state.browser.timelineRanges[id] = span
                }
                state.browser.collapsedTimelines = Set(browser.collapsedTimelines ?? [])
            }
            return state
        }
    }
}
