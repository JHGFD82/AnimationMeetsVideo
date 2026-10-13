import AVFoundation
import CoreMedia
import Foundation

struct EditingProject: Identifiable, Equatable {
    let id: UUID
    var name: String
    var clips: [MediaClip]
    var timelines: [Timeline]
    var rootTimelineID: UUID
    /// Cut sensitivity for assets that don't override it, from 0 (only
    /// obvious cuts) to 1 (small changes count).
    var defaultSensitivity = SceneDetector.balancedSensitivity

    static var empty: EditingProject {
        let main = Timeline(
            name: "Main",
            layers: [],
            frameSize: CGSize(width: 1920, height: 1080),
            frameRate: 24,
            colorSpace: .rec709
        )
        return EditingProject(id: UUID(), name: "Untitled Project", clips: [], timelines: [main], rootTimelineID: main.id)
    }

    /// Copies each asset's file location from `other`, leaving everything else
    /// alone. Used after a save moves media into the package, so edits made
    /// while the save was running are kept.
    mutating func applyMediaLocations(from other: EditingProject) {
        for clip in other.clips {
            if let index = clips.firstIndex(where: { $0.id == clip.id }) {
                clips[index].url = clip.url
                clips[index].acceptedStamp = clip.acceptedStamp
            }
        }
    }

    func timeline(id: UUID) -> Timeline? {
        timelines.first { $0.id == id }
    }

    func mediaClip(id: UUID) -> MediaClip? {
        clips.first { $0.id == id }
    }

    func resolvedInfo(for source: ClipSource) -> ResolvedClipInfo? {
        switch source {
        case .media(let mediaID):
            guard let clip = mediaClip(id: mediaID) else { return nil }
            return .media(clip)
        case .timeline(let timelineID):
            guard let timeline = timeline(id: timelineID) else { return nil }
            return .timeline(timeline)
        }
    }

    /// Adds an imported file to the media pool. It stays in the library
    /// until the person puts it on a timeline.
    mutating func addMedia(_ clip: MediaClip) {
        clips.append(clip)
    }

    /// Puts a whole asset on a new layer at the top of the stack, After
    /// Effects-style — each placed piece of footage gets its own layer
    /// rather than merging into a shared track.
    @discardableResult
    mutating func placeAsset(_ assetID: UUID, intoTimeline timelineID: UUID) -> (layerID: UUID, clipID: UUID)? {
        guard let clip = mediaClip(id: assetID),
              let index = timelines.firstIndex(where: { $0.id == timelineID })
        else {
            return nil
        }
        let timelineClip = TimelineClip(source: .media(clip.id), startOffset: .zero, trimStart: .zero, trimEnd: clip.duration)
        let layer = TimelineLayer(customName: nil, clips: [timelineClip])
        timelines[index].layers.insert(layer, at: 0)
        return (layer.id, timelineClip.id)
    }

    /// Adds a file to the media pool and places it on a timeline in one
    /// step. Importing in the app only adds to the pool; this is for setting
    /// up projects in code, such as in tests.
    @discardableResult
    mutating func importClip(_ clip: MediaClip, intoTimeline timelineID: UUID) -> (layerID: UUID, clipID: UUID)? {
        addMedia(clip)
        return placeAsset(clip.id, intoTimeline: timelineID)
    }

    @discardableResult
    mutating func addTimeline(name: String, frameSize: CGSize, frameRate: Double, colorSpace: ProjectColorSpace) -> UUID {
        let timeline = Timeline(name: name, layers: [], frameSize: frameSize, frameRate: frameRate, colorSpace: colorSpace)
        timelines.append(timeline)
        return timeline.id
    }

    mutating func updateTimelineSettings(_ id: UUID, name: String, frameSize: CGSize, frameRate: Double, colorSpace: ProjectColorSpace) {
        guard let index = timelines.firstIndex(where: { $0.id == id }) else { return }
        timelines[index].name = name
        timelines[index].frameSize = frameSize
        timelines[index].frameRate = frameRate
        timelines[index].colorSpace = colorSpace
    }

    /// A timeline can't be embedded into itself or into any timeline it
    /// already contains (directly or transitively) — that would be a cycle.
    func canEmbed(_ timelineID: UUID, into targetTimelineID: UUID) -> Bool {
        if timelineID == targetTimelineID { return false }
        guard let nested = timeline(id: timelineID), nested.duration > .zero else { return false }
        var visited: Set<UUID> = []
        collectNestedTimelineIDs(startingFrom: timelineID, visited: &visited)
        return !visited.contains(targetTimelineID)
    }

    private func collectNestedTimelineIDs(startingFrom timelineID: UUID, visited: inout Set<UUID>) {
        guard visited.insert(timelineID).inserted, let timeline = timeline(id: timelineID) else { return }
        for layer in timeline.layers {
            for clip in layer.clips {
                if case .timeline(let nestedID) = clip.source {
                    collectNestedTimelineIDs(startingFrom: nestedID, visited: &visited)
                }
            }
        }
    }

    @discardableResult
    mutating func embedTimeline(_ timelineID: UUID, intoTimeline targetTimelineID: UUID) -> (layerID: UUID, clipID: UUID)? {
        guard canEmbed(timelineID, into: targetTimelineID),
              let nested = timeline(id: timelineID),
              nested.duration > .zero,
              let index = timelines.firstIndex(where: { $0.id == targetTimelineID })
        else {
            return nil
        }
        let timelineClip = TimelineClip(source: .timeline(timelineID), startOffset: .zero, trimStart: .zero, trimEnd: nested.duration)
        let layer = TimelineLayer(customName: nil, clips: [timelineClip])
        timelines[index].layers.insert(layer, at: 0)
        return (layer.id, timelineClip.id)
    }

    /// Repositions a clip within its layer by setting its absolute start
    /// time — the drag-to-move interaction in the timeline UI. Where it
    /// lands is `resolvedStart(ofMoving:in:layer:to:)`; a move onto a layer
    /// with no gap big enough is rejected.
    mutating func moveClip(_ id: UUID, in timelineID: UUID, layer layerID: UUID, to newStart: CMTime) {
        guard let start = resolvedStart(ofMoving: id, in: timelineID, layer: layerID, to: newStart),
              let tIndex = timelines.firstIndex(where: { $0.id == timelineID }),
              let lIndex = timelines[tIndex].layers.firstIndex(where: { $0.id == layerID }),
              let cIndex = timelines[tIndex].layers[lIndex].clips.firstIndex(where: { $0.id == id })
        else {
            return
        }
        timelines[tIndex].layers[lIndex].clips[cIndex].startOffset = start
        timelines[tIndex].layers[lIndex].clips.sort { $0.startOffset < $1.startOffset }
    }

    /// Splits the clip at a timeline-space time (e.g. the playhead). The time
    /// must fall strictly inside the clip's placed range.
    mutating func split(_ id: UUID, in timelineID: UUID, layer layerID: UUID, atTimelineTime time: CMTime) {
        guard let tIndex = timelines.firstIndex(where: { $0.id == timelineID }),
              let lIndex = timelines[tIndex].layers.firstIndex(where: { $0.id == layerID }),
              let clip = timelines[tIndex].layers[lIndex].clips.first(where: { $0.id == id })
        else {
            return
        }
        let sourceTime = CMTimeAdd(clip.trimStart, CMTimeSubtract(time, clip.startOffset))
        Self.split(&timelines[tIndex].layers[lIndex].clips, id: id, at: sourceTime)
    }

    mutating func deleteClip(_ id: UUID, in timelineID: UUID, layer layerID: UUID) {
        guard let tIndex = timelines.firstIndex(where: { $0.id == timelineID }),
              let lIndex = timelines[tIndex].layers.firstIndex(where: { $0.id == layerID })
        else {
            return
        }
        timelines[tIndex].layers[lIndex].clips.removeAll { $0.id == id }
        if timelines[tIndex].layers[lIndex].clips.isEmpty {
            timelines[tIndex].layers.remove(at: lIndex)
        }
    }

    mutating func split(_ id: UUID, in timelineID: UUID, layer layerID: UUID, at time: CMTime) {
        guard let tIndex = timelines.firstIndex(where: { $0.id == timelineID }),
              let lIndex = timelines[tIndex].layers.firstIndex(where: { $0.id == layerID })
        else {
            return
        }
        Self.split(&timelines[tIndex].layers[lIndex].clips, id: id, at: time)
    }

    mutating func renameLayer(_ layerID: UUID, in timelineID: UUID, to name: String?) {
        guard let tIndex = timelines.firstIndex(where: { $0.id == timelineID }),
              let lIndex = timelines[tIndex].layers.firstIndex(where: { $0.id == layerID })
        else {
            return
        }
        timelines[tIndex].layers[lIndex].customName = name
    }

    mutating func moveLayer(_ layerID: UUID, in timelineID: UUID, by offset: Int) {
        guard let tIndex = timelines.firstIndex(where: { $0.id == timelineID }),
              let index = timelines[tIndex].layers.firstIndex(where: { $0.id == layerID })
        else {
            return
        }
        let newIndex = index + offset
        guard timelines[tIndex].layers.indices.contains(newIndex) else { return }
        timelines[tIndex].layers.swapAt(index, newIndex)
    }

    mutating func setAutoMatteEnabled(_ enabled: Bool, for id: UUID, in timelineID: UUID, layer layerID: UUID) {
        guard let tIndex = timelines.firstIndex(where: { $0.id == timelineID }),
              let lIndex = timelines[tIndex].layers.firstIndex(where: { $0.id == layerID }),
              let cIndex = timelines[tIndex].layers[lIndex].clips.firstIndex(where: { $0.id == id })
        else {
            return
        }
        timelines[tIndex].layers[lIndex].clips[cIndex].autoMatteEnabled = enabled
    }

    /// Drags the clip's leading edge, non-destructively revealing or hiding
    /// source frames. Unlike a plain move, trimming the start keeps the
    /// clip's *end* fixed in time; see `resolvedTrimStart(of:in:layer:to:)`.
    mutating func trimClipStart(_ id: UUID, in timelineID: UUID, layer layerID: UUID, to proposedTrimStart: CMTime) {
        guard let trimmed = resolvedTrimStart(of: id, in: timelineID, layer: layerID, to: proposedTrimStart) else { return }
        replaceClip(trimmed, in: timelineID, layer: layerID)
    }

    /// Drags the clip's trailing edge; the start stays fixed and only the
    /// trimmed-out duration changes. See `resolvedTrimEnd(of:in:layer:to:)`.
    mutating func trimClipEnd(_ id: UUID, in timelineID: UUID, layer layerID: UUID, to proposedTrimEnd: CMTime) {
        guard let trimmed = resolvedTrimEnd(of: id, in: timelineID, layer: layerID, to: proposedTrimEnd) else { return }
        replaceClip(trimmed, in: timelineID, layer: layerID)
    }

    private mutating func replaceClip(_ clip: TimelineClip, in timelineID: UUID, layer layerID: UUID) {
        guard let tIndex = timelines.firstIndex(where: { $0.id == timelineID }),
              let lIndex = timelines[tIndex].layers.firstIndex(where: { $0.id == layerID }),
              let cIndex = timelines[tIndex].layers[lIndex].clips.firstIndex(where: { $0.id == clip.id })
        else {
            return
        }
        timelines[tIndex].layers[lIndex].clips[cIndex] = clip
    }

    private static func split(_ clips: inout [TimelineClip], id: UUID, at time: CMTime) {
        guard let index = clips.firstIndex(where: { $0.id == id }) else { return }
        let clip = clips[index]
        guard time > clip.trimStart, time < clip.trimEnd else { return }
        // The split point is in trim-relative coordinates; convert it to how
        // far into the clip's absolute placement that point falls, so the
        // second half starts exactly where the first half now ends — no gap
        // introduced by splitting, even though either half can be dragged
        // apart afterward.
        let offsetIntoClip = CMTimeSubtract(time, clip.trimStart)
        let secondStart = CMTimeAdd(clip.startOffset, offsetIntoClip)
        // Both halves copy the clip, so they keep the streams it plays.
        var first = clip
        first.id = UUID()
        first.trimEnd = time
        var second = clip
        second.id = UUID()
        second.startOffset = secondStart
        second.trimStart = time
        clips.replaceSubrange(index...index, with: [first, second])
    }
}

/// A named sequence of numbered layers, After Effects-style. Timelines can
/// embed one another (nested/compound-clip style) via `ClipSource.timeline`.
struct Timeline: Identifiable, Equatable {
    var id = UUID()
    var name: String
    /// Index 0 is the topmost layer — matches After Effects' convention
    /// where newer/higher layers composite over lower ones.
    var layers: [TimelineLayer]
    var frameSize: CGSize
    var frameRate: Double
    var colorSpace: ProjectColorSpace

    var duration: CMTime {
        layers.map(\.duration).max(by: { $0.seconds < $1.seconds }) ?? .zero
    }

    var timebaseSummary: String {
        "\(Int(frameSize.width))×\(Int(frameSize.height)) · \(String(format: "%.2f", frameRate)) fps · \(colorSpace.rawValue)"
    }

    func layer(id: UUID) -> TimelineLayer? {
        layers.first { $0.id == id }
    }

    /// The clip in the given layer whose [startOffset, endOffset) range
    /// covers `time`, if any — nil if `time` falls in a gap.
    func clip(at time: CMTime, layer layerID: UUID) -> TimelineClip? {
        guard let layer = layer(id: layerID) else { return nil }
        return layer.clips.first { time >= $0.startOffset && time < $0.endOffset }
    }
}

struct TimelineLayer: Identifiable, Equatable {
    var id = UUID()
    /// User-assigned name, if any. Falls back to the footage/nested
    /// timeline's own name when nil.
    var customName: String?
    var clips: [TimelineClip]
    /// Position, scale, rotation and opacity, keyframed in this timeline's
    /// time. Ignored for layers with no pictures.
    var transform = LayerTransform.identity

    var duration: CMTime {
        clips.map(\.endOffset).max(by: { $0.seconds < $1.seconds }) ?? .zero
    }
}

enum ClipSource: Equatable {
    case media(UUID)
    case timeline(UUID)
}

/// A placement of a clip (raw media or a nested timeline) on a layer, with
/// its own non-destructive trim range and an independent, draggable
/// position in time — clips are not forced to be back-to-back or to start
/// at the timeline's t=0.
struct TimelineClip: Identifiable, Equatable {
    var id = UUID()
    var source: ClipSource
    var startOffset: CMTime
    var trimStart: CMTime
    var trimEnd: CMTime
    /// Non-destructive Vision-based foreground matte. Currently disabled in
    /// the UI pending a working live-preview capture pipeline; kept on the
    /// model since it's harmless and non-destructive by construction.
    var autoMatteEnabled: Bool = false
    /// Which of a media file's streams this clip plays. Always
    /// `.videoAndAudio` for nested timelines.
    var streams: ClipStreams = .videoAndAudio

    var trimmedDuration: CMTime {
        CMTimeSubtract(trimEnd, trimStart)
    }

    var endOffset: CMTime {
        CMTimeAdd(startOffset, trimmedDuration)
    }
}

/// Which streams of a media file a clip plays. A video with sound plays
/// both, linked, until its audio is detached: then the picture stays as a
/// `.video` clip and the sound moves to an `.audio` clip on its own layer.
enum ClipStreams: String {
    case videoAndAudio
    case video
    case audio
}

/// What a `TimelineClip` resolves to, for display and playback.
enum ResolvedClipInfo {
    case media(MediaClip)
    case timeline(Timeline)

    var name: String {
        switch self {
        case .media(let clip): clip.name
        case .timeline(let timeline): timeline.name
        }
    }

    var systemImage: String {
        switch self {
        case .media(let clip): clip.kind.systemImage
        case .timeline: "rectangle.stack"
        }
    }

    var summary: String {
        switch self {
        case .media(let clip): clip.formatSummary
        case .timeline(let timeline): "Nested Timeline · \(timeline.timebaseSummary)"
        }
    }

    var isVideo: Bool {
        switch self {
        case .media(let clip): clip.kind == .video
        case .timeline(let timeline): !timeline.layers.isEmpty
        }
    }

    var isHDR: Bool {
        switch self {
        case .media(let clip): clip.colorSpace.isHDR
        case .timeline(let timeline): timeline.colorSpace.isHDR
        }
    }
}

struct MediaClip: Identifiable, Equatable {
    var id = UUID()
    var name: String
    var kind: MediaKind
    var url: URL?
    var duration: CMTime
    var frameRate: Double
    var colorSpace: ProjectColorSpace
    var codecName: String
    /// Whether the file has an audio track, which is what beat detection reads.
    /// True for audio files and for videos with sound.
    var hasAudio = false
    /// Hand-made changes to this asset's scene list. Detected cuts are not
    /// stored; they are recomputed from the saved change scores.
    var sceneEdits = SceneEdits()
    /// How much later a moment is in the current file than in the original:
    /// original time `t` is at `t + alignmentOffset` in the file. Trims,
    /// scenes and cuts stay in original time; this is added when reading.
    var alignmentOffset = CMTime.zero
    /// Files this asset used to point at, newest last. Only paths are kept,
    /// so a person can point the asset back at an earlier file.
    var previousPaths: [String] = []
    /// Size and modification time of the file when the project last accepted
    /// it. A different stamp on opening means it was swapped outside the app.
    var acceptedStamp: FileStamp?
    /// True once the person chose to forget the original. Its reference data
    /// is deleted at the next save and not captured again from whatever file
    /// is there now.
    var referenceForgotten = false

    /// True once the asset points at a file other than the one it was
    /// imported with, or at the same file realigned after it changed.
    var wasReplaced: Bool { !previousPaths.isEmpty || alignmentOffset != .zero }

    /// Where original time `time` is in the current file.
    func fileTime(forSourceTime time: CMTime) -> CMTime {
        CMTimeAdd(time, alignmentOffset)
    }

    var formatSummary: String {
        "\(kind.rawValue) · \(codecName) · \(colorSpace.rawValue)"
    }
}

enum MediaKind: String {
    case video = "Video"
    case audio = "Audio"

    var systemImage: String {
        switch self {
        case .video: "film"
        case .audio: "waveform"
        }
    }
}

enum ProjectColorSpace: String, CaseIterable, Identifiable {
    case rec709 = "Rec. 709"
    case rec2020PQ = "Rec. 2020 PQ HDR"
    case rec2020HLG = "Rec. 2020 HLG"

    var id: Self { self }

    var isHDR: Bool {
        switch self {
        case .rec709: false
        case .rec2020PQ, .rec2020HLG: true
        }
    }
}

extension CMTime {
    var formatted: String {
        guard isNumeric else { return "--:--" }
        let totalSeconds = max(0, seconds)
        let tenths = Int((totalSeconds * 10).rounded())
        return String(format: "%02ld:%02ld.%ld", (tenths / 10) / 60, (tenths / 10) % 60, tenths % 10)
    }

    /// hh:mm:ss:ff timecode using the given frame rate for the frames field.
    func timecode(frameRate: Double) -> String {
        guard isNumeric, frameRate > 0 else { return "00:00:00:00" }
        let totalSeconds = max(0, seconds)
        let framesPerSecond = max(1, Int(frameRate.rounded()))
        let totalFrames = Int((totalSeconds * frameRate).rounded())
        let frames = totalFrames % framesPerSecond
        let totalWholeSeconds = totalFrames / framesPerSecond
        let secs = totalWholeSeconds % 60
        let mins = (totalWholeSeconds / 60) % 60
        let hours = totalWholeSeconds / 3600
        return String(format: "%02d:%02d:%02d:%02d", hours, mins, secs, frames)
    }

    /// The same timecode with leading zero-valued fields dropped (always
    /// keeping at least seconds:frames) and the leftmost remaining field's
    /// own leading zero stripped — "00:00:05:00" -> "5:00",
    /// "00:12:05:00" -> "12:05:00".
    func compactTimecode(frameRate: Double) -> String {
        let parts = timecode(frameRate: frameRate).split(separator: ":").map(String.init)
        var startIndex = 0
        while startIndex < parts.count - 2 && parts[startIndex] == "00" {
            startIndex += 1
        }
        var kept = Array(parts[startIndex...])
        if let first = kept.first {
            kept[0] = String(Int(first) ?? 0)
        }
        return kept.joined(separator: ":")
    }
}
