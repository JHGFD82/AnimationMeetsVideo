import CoreMedia
import Foundation

extension ProjectStore {
    /// Loads a package. `importMedia` reads a media file's metadata, by
    /// default with `MediaImporter` into this package; it is a parameter so
    /// tests can run without real footage. `projectFile` reads
    /// the edit from another file, such as a backup, instead of
    /// `project.json`; paths in it are still relative to the package.
    static func load(
        from packageURL: URL,
        projectFile: URL? = nil,
        importMedia: (@Sendable (URL) async throws -> MediaClip)? = nil
    ) async throws -> ProjectLoadResult {
        try validatePackage(at: packageURL)
        let importMedia = importMedia ?? { try await MediaImporter.importClip(at: $0, packageURL: packageURL) }
        let fileURL = projectFile ?? packageURL.appending(path: projectFileName)
        let data = try Data(contentsOf: fileURL)

        guard let version = JSONFile.formatVersion(of: data), version >= 1 else {
            throw ProjectStoreError.unsupportedVersion(nil)
        }
        // Older files aren't migrated, and newer ones can't be read.
        guard version == ProjectFile.currentVersion else {
            throw ProjectStoreError.unsupportedVersion(version)
        }
        let file = try JSONFile.decode(ProjectFile.self, from: data, shape: ProjectFile.shape, failure: ProjectStoreError.invalidFile)

        var importedClips: [UUID: MediaClip] = [:]
        var orderedIDs: [UUID] = []
        var missingMedia: [URL] = []
        var offlineMedia: [UUID] = []
        var changedMedia: [UUID] = []
        for asset in file.assets {
            let url = asset.path.hasPrefix("/")
                ? URL(fileURLWithPath: asset.path)
                : packageURL.appending(path: asset.path)
            var clip: MediaClip
            do {
                clip = try await importMedia(url)
                if let saved = asset.fileStamp, saved != FileStamp(url: url) { changedMedia.append(asset.id) }
            } catch {
                // Kept, offline: dropping it would lose its clips for good at
                // the next save, as when a drive simply isn't plugged in.
                missingMedia.append(url)
                offlineMedia.append(asset.id)
                clip = offlineClip(for: asset, at: url, in: packageURL, timelines: file.timelines)
            }
            clip.id = asset.id
            clip.name = asset.name
            clip.sceneEdits = asset.sceneEdits?.edits ?? SceneEdits()
            clip.beatMap = asset.beatMap?.map ?? BeatMap()
            clip.alignmentOffset = asset.alignmentOffset?.time ?? .zero
            clip.originalDuration = asset.originalDuration?.time
            clip.previousPaths = asset.previousPaths ?? []
            clip.referenceForgotten = asset.referenceForgotten ?? false
            clip.skipsSceneDetection = asset.skipsSceneDetection ?? false
            clip.acceptedStamp = asset.fileStamp ?? FileStamp(url: url)
            importedClips[asset.id] = clip
            orderedIDs.append(asset.id)
        }

        let timelineIDs = Set(file.timelines.map(\.id))

        func resolveSource(_ entry: ProjectFile.SourceEntry) -> ClipSource? {
            switch entry.kind {
            case .media: entry.id.flatMap { importedClips[$0] != nil ? ClipSource.media($0) : nil }
            case .timeline: entry.id.flatMap { timelineIDs.contains($0) ? ClipSource.timeline($0) : nil }
            case .adjustment: .adjustment
            case .graphic: .graphic
            }
        }

        let timelines: [Timeline] = file.timelines.map { entry in
            let layerIDs = Set(entry.layers.map(\.id))
            return Timeline(
                id: entry.id,
                name: entry.name,
                layers: entry.layers.map { layerEntry in
                    TimelineLayer(
                        id: layerEntry.id,
                        customName: layerEntry.customName,
                        kind: LayerKind(rawValue: layerEntry.kind) ?? .video,
                        clips: layerEntry.clips.compactMap { clipEntry in
                            guard let source = resolveSource(clipEntry.source) else { return nil }
                            return TimelineClip(
                                id: clipEntry.id,
                                source: source,
                                startOffset: clipEntry.startOffset.time,
                                trimStart: clipEntry.trimStart.time,
                                trimEnd: clipEntry.trimEnd.time,
                                autoMatteEnabled: clipEntry.autoMatteEnabled,
                                streams: clipEntry.streams.flatMap(ClipStreams.init(rawValue:)) ?? .videoAndAudio,
                                transitionIn: clipEntry.transitionIn?.transition,
                                transitionOut: clipEntry.transitionOut?.transition,
                                anchorPoint: clipEntry.anchorPoint?.property(default: .zero) {
                                    $0.count == 2 ? Vector2(x: $0[0], y: $0[1]) : nil
                                } ?? AnimatedValue(Vector2.zero),
                                effects: (clipEntry.effects ?? []).compactMap(\.effect).filter { !$0.kind.isAudio },
                                audioEffects: (clipEntry.audioEffects ?? []).compactMap(\.effect).filter(\.kind.isAudio),
                                volume: clipEntry.volume?.property(default: 0.0) { AudioLevel.clamped($0) } ?? AnimatedValue(0.0),
                                pan: clipEntry.pan?.property(default: 0.0) { AudioPan.clamped($0) } ?? AnimatedValue(0.0),
                                passThrough: clipEntry.passThrough ?? false,
                                time: clipEntry.time?.time ?? ClipTime(),
                                shutter: clipEntry.shutter?.shutter ?? ClipShutter(),
                                // A reach that names no layer of this timeline
                                // reaches every layer below. Older projects
                                // kept one reach for the whole layer.
                                reach: source == .adjustment
                                    ? (clipEntry.reach ?? layerEntry.reach).flatMap { layerIDs.contains($0) ? $0 : nil } : nil,
                                enabled: clipEntry.enabled ?? true,
                                soundMuted: clipEntry.soundMuted ?? false,
                                music: clipEntry.followsMusic == false ? nil : clipEntry.music?.attachment,
                                followsMusic: clipEntry.followsMusic ?? true
                            )
                        },
                        volume: layerEntry.volume?.property(default: 0.0) { AudioLevel.clamped($0) } ?? AnimatedValue(0.0),
                        pan: layerEntry.pan?.property(default: 0.0) { AudioPan.clamped($0) } ?? AnimatedValue(0.0),
                        audioEffects: (layerEntry.audioEffects ?? []).compactMap(\.effect).filter(\.kind.isAudio),
                        isAdjustment: layerEntry.adjustment ?? false
                    )
                },
                frameSize: CGSize(width: entry.width, height: entry.height),
                frameRate: entry.frameRate,
                colorSpace: ProjectColorSpace(rawValue: entry.colorSpace) ?? .rec709,
                sections: (entry.sections ?? [])
                    .map { TimelineSection(id: $0.id, name: $0.name, start: $0.start.time, end: $0.end.time) }
                    .filter { $0.end > $0.start }
                    .sorted { $0.start < $1.start },
                previewBackground: entry.previewBackground.map { $0.map { $0.clamped(between: 0, and: 1) } }
            )
        }

        guard let first = timelines.first else {
            throw ProjectStoreError.noTimelines
        }
        let rootID = timelineIDs.contains(file.rootTimelineID) ? file.rootTimelineID : first.id

        var project = EditingProject(
            id: file.id,
            name: file.name,
            clips: orderedIDs.compactMap { importedClips[$0] },
            timelines: timelines,
            rootTimelineID: rootID,
            defaultSensitivity: file.defaultSensitivity ?? EditingProject.balancedSensitivity,
            copiesMediaOnImport: file.copiesMediaOnImport ?? true,
            canvasMargin: file.canvasMargin ?? EditingProject.defaultCanvasMargin,
            jointAudioCrossfade: file.jointAudioCrossfade.flatMap(AudioCrossfade.init(rawValue:)) ?? .sCurve
        )
        project.alignClipLengthsToFrames()
        var scores: [UUID: ChangeScoreTrack] = [:]
        var references: [UUID: AssetReference] = [:]
        var beats: [UUID: BeatTrack] = [:]
        var sources = AnalysisSources()
        var original: [UUID: ChangeScoreTrack] = [:]
        var rejected: [UUID: [AnalysisKind: AnalysisRejection]] = [:]
        var thumbnailed: Set<UUID> = []
        for id in orderedIDs {
            // Results describe the file the asset has now, so they are used
            // only when their record matches the file the project accepted.
            let identity = importedClips[id]?.acceptedStamp
            switch readVerifiedBeats(for: id, in: packageURL, identity: identity) {
            case .valid(let track, let source): beats[id] = track; sources.beats[id] = source
            case .rejected(let reason): rejected[id, default: [:]][.beats] = reason
            case .absent: break
            }
            switch readVerifiedChangeScores(for: id, in: packageURL, identity: identity) {
            case .valid(let track, let source): scores[id] = track; sources.scores[id] = source
            case .rejected(let reason): rejected[id, default: [:]][.scores] = reason
            case .absent: break
            }
            // Left behind only if saving stopped partway; it is deleted at the next save.
            guard importedClips[id]?.referenceForgotten != true else { continue }
            if hasThumbnails(for: id, in: packageURL) { thumbnailed.insert(id) }
            references[id] = readReference(for: id, in: packageURL)
            switch readVerifiedOriginalScores(for: id, in: packageURL) {
            case .valid(let track, let source): original[id] = track; sources.originalScores[id] = source
            case .rejected(let reason): rejected[id, default: [:]][.originalScores] = reason
            case .absent: break
            }
        }
        // Reference movies of files since moved, changed or removed.
        MatroskaMedia.removeUnused(in: packageURL, keeping: Set(project.clips.compactMap { clip in
            clip.url.flatMap { MatroskaMedia.isMatroska($0) ? MatroskaMedia.movieName(for: $0) : nil }
        }))
        return ProjectLoadResult(project: project, missingMedia: missingMedia, offlineMedia: offlineMedia, changedMedia: changedMedia, changeScores: scores, beats: beats, references: references, assetsWithThumbnails: thumbnailed, analysisSources: sources, originalScores: original, rejectedAnalysis: rejected)
    }

    /// An asset whose file couldn't be opened, described from what the
    /// project saved about it; for files saved before that, from the
    /// original's reference data (unless the asset has since been
    /// replaced), and failing that from how its clips use it. Its length
    /// always covers its clips, so their trims stay valid.
    fileprivate static func offlineClip(
        for asset: ProjectFile.AssetEntry,
        at url: URL,
        in packageURL: URL,
        timelines: [ProjectFile.TimelineEntry]
    ) -> MediaClip {
        let replaced = !(asset.previousPaths ?? []).isEmpty || asset.alignmentOffset != nil
        let reference = asset.referenceForgotten == true || replaced
            ? nil : readReference(for: asset.id, in: packageURL)?.metadata
        let layers = timelines.flatMap(\.layers)
        let uses = layers.flatMap(\.clips).filter { $0.source.kind == .media && $0.source.id == asset.id }
        let longestUse = uses.map(\.trimEnd.time).max() ?? .zero
        let onVideoLayer = layers.contains { layer in
            layer.kind != LayerKind.sound.rawValue && layer.kind != LayerKind.music.rawValue
                && layer.clips.contains { $0.source.kind == .media && $0.source.id == asset.id }
        }
        let kind = asset.kind.flatMap(MediaKind.init(rawValue:))
            ?? reference.map { $0.isVideo ? MediaKind.video : .audio }
            ?? (onVideoLayer ? .video : .audio)
        let duration = asset.duration?.time ?? reference?.duration ?? longestUse
        return MediaClip(
            name: asset.name,
            kind: kind,
            url: url,
            duration: CMTimeMaximum(duration, longestUse),
            frameRate: asset.frameRate ?? reference?.frameRate ?? 0,
            colorSpace: asset.colorSpace.flatMap(ProjectColorSpace.init(rawValue:)) ?? .rec709,
            codecName: asset.codec ?? reference?.codecName ?? "Offline",
            hasAudio: asset.hasAudio ?? reference?.hasAudio ?? (kind == .audio || uses.contains { $0.streams == ClipStreams.audio.rawValue })
        )
    }
}
