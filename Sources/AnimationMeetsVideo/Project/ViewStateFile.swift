import CoreMedia
import Foundation

/// How the project's window was left: the timeline open, and for each
/// timeline shown, its playhead, zoom, scroll and the clip selected. Kept in
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
    }

    /// The timeline open in the window.
    var openTimelineID: UUID?
    var timelines: [UUID: Timeline] = [:]
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
        }

        var formatVersion: Int
        var openTimeline: UUID?
        var timelines: [String: Timeline]

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
                    }
                ))
            })
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
                    })
                )
            }
            return state
        }
    }
}
