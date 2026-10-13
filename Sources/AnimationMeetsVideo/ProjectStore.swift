import CoreMedia
import Foundation

private struct ProjectFile: Codable {
    struct ClipSourceEntry: Codable {
        enum Kind: String, Codable { case media, timeline }
        var kind: Kind
        var index: Int
    }

    struct TimelineEntryClip: Codable {
        var source: ClipSourceEntry
        var startOffsetSeconds: Double
        var trimStartSeconds: Double
        var trimEndSeconds: Double
        var autoMatteEnabled: Bool
    }

    struct LayerEntry: Codable {
        var customName: String?
        var clips: [TimelineEntryClip]
    }

    struct TimelineEntry: Codable {
        var name: String
        var width: Double
        var height: Double
        var frameRate: Double
        var colorSpace: String
        var layers: [LayerEntry]
    }

    var name: String
    var clipURLs: [URL]
    var timelines: [TimelineEntry]
    var rootTimelineIndex: Int
}

struct ProjectLoadResult {
    var project: EditingProject
    /// Media files referenced by the project that couldn't be opened; clips
    /// using them were dropped from the timelines.
    var missingMedia: [URL]
}

enum ProjectStore {
    static func save(_ project: EditingProject, to url: URL) throws {
        let urlClips = project.clips.filter { $0.url != nil }
        let mediaIndexByID = Dictionary(uniqueKeysWithValues: urlClips.enumerated().map { ($1.id, $0) })
        let timelineIndexByID = Dictionary(uniqueKeysWithValues: project.timelines.enumerated().map { ($1.id, $0) })

        func sourceEntry(for source: ClipSource) -> ProjectFile.ClipSourceEntry? {
            switch source {
            case .media(let id):
                guard let index = mediaIndexByID[id] else { return nil }
                return ProjectFile.ClipSourceEntry(kind: .media, index: index)
            case .timeline(let id):
                guard let index = timelineIndexByID[id] else { return nil }
                return ProjectFile.ClipSourceEntry(kind: .timeline, index: index)
            }
        }

        func entries(for clips: [TimelineClip]) -> [ProjectFile.TimelineEntryClip] {
            clips.compactMap { clip in
                guard let source = sourceEntry(for: clip.source) else { return nil }
                return ProjectFile.TimelineEntryClip(
                    source: source,
                    startOffsetSeconds: clip.startOffset.seconds,
                    trimStartSeconds: clip.trimStart.seconds,
                    trimEndSeconds: clip.trimEnd.seconds,
                    autoMatteEnabled: clip.autoMatteEnabled
                )
            }
        }

        let timelineEntries = project.timelines.map { timeline in
            ProjectFile.TimelineEntry(
                name: timeline.name,
                width: timeline.frameSize.width,
                height: timeline.frameSize.height,
                frameRate: timeline.frameRate,
                colorSpace: timeline.colorSpace.rawValue,
                layers: timeline.layers.map { layer in
                    ProjectFile.LayerEntry(customName: layer.customName, clips: entries(for: layer.clips))
                }
            )
        }

        let file = ProjectFile(
            name: project.name,
            clipURLs: urlClips.map { $0.url! },
            timelines: timelineEntries,
            rootTimelineIndex: timelineIndexByID[project.rootTimelineID] ?? 0
        )
        let data = try JSONEncoder().encode(file)
        try data.write(to: url, options: .atomic)
    }

    static func load(from url: URL) async throws -> ProjectLoadResult {
        let data = try Data(contentsOf: url)
        let file = try JSONDecoder().decode(ProjectFile.self, from: data)

        var importedClips: [MediaClip?] = []
        var missingMedia: [URL] = []
        for clipURL in file.clipURLs {
            do {
                importedClips.append(try await MediaImporter.importClip(at: clipURL))
            } catch {
                importedClips.append(nil)
                missingMedia.append(clipURL)
            }
        }

        // Pass 1: create timelines with empty layers so their (fresh) ids
        // are known before resolving cross-timeline references in pass 2.
        var timelines: [Timeline] = file.timelines.map { entry in
            Timeline(
                name: entry.name,
                layers: [],
                frameSize: CGSize(width: entry.width, height: entry.height),
                frameRate: entry.frameRate,
                colorSpace: ProjectColorSpace(rawValue: entry.colorSpace) ?? .rec709
            )
        }
        let timelineIDs = timelines.map(\.id)

        func resolveSource(_ entry: ProjectFile.ClipSourceEntry) -> ClipSource? {
            switch entry.kind {
            case .media:
                guard importedClips.indices.contains(entry.index), let clip = importedClips[entry.index] else { return nil }
                return .media(clip.id)
            case .timeline:
                guard timelineIDs.indices.contains(entry.index) else { return nil }
                return .timeline(timelineIDs[entry.index])
            }
        }

        func timelineClips(from entries: [ProjectFile.TimelineEntryClip]) -> [TimelineClip] {
            entries.compactMap { entry in
                guard let source = resolveSource(entry.source) else { return nil }
                return TimelineClip(
                    source: source,
                    startOffset: CMTime(seconds: entry.startOffsetSeconds, preferredTimescale: 600),
                    trimStart: CMTime(seconds: entry.trimStartSeconds, preferredTimescale: 600),
                    trimEnd: CMTime(seconds: entry.trimEndSeconds, preferredTimescale: 600),
                    autoMatteEnabled: entry.autoMatteEnabled
                )
            }
        }

        for (index, entry) in file.timelines.enumerated() {
            timelines[index].layers = entry.layers.map { layerEntry in
                TimelineLayer(customName: layerEntry.customName, clips: timelineClips(from: layerEntry.clips))
            }
        }

        guard !timelineIDs.isEmpty else {
            throw ProjectStoreError.noTimelines
        }
        let rootID = timelineIDs.indices.contains(file.rootTimelineIndex)
            ? timelineIDs[file.rootTimelineIndex]
            : timelineIDs[0]

        let project = EditingProject(
            id: UUID(),
            name: file.name,
            clips: importedClips.compactMap { $0 },
            timelines: timelines,
            rootTimelineID: rootID
        )
        return ProjectLoadResult(project: project, missingMedia: missingMedia)
    }
}

enum ProjectStoreError: LocalizedError {
    case noTimelines

    var errorDescription: String? {
        switch self {
        case .noTimelines: "The project file doesn't contain any timelines."
        }
    }
}
