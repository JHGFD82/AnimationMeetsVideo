import CoreMedia
import Foundation

extension ProjectStore {
    /// Writes the package and returns the project with any copied media
    /// pointing at its new location. `copying` lists the media IDs to copy
    /// into `Media/`; on APFS a same-volume copy is a clone and costs no
    /// extra space. `changeScores` are written to `Reference/`; pass only the
    /// ones that aren't saved yet, and so are `references` and `thumbnails`.
    /// The reference data of assets marked `referenceForgotten` is deleted
    /// rather than written. For Save As, `previousPackageURL` is where the
    /// project was saved before: what it holds in `Reference/` is copied
    /// first, since only unsaved results are passed in. `discardedBeats`
    /// are assets whose saved beats came from a file they no longer use.
    ///
    /// Runs through the `PackageCoordinator`, after everything already queued
    /// on the package (and, for Save As, on the previous one).
    @discardableResult
    static func save(
        _ project: EditingProject,
        to packageURL: URL,
        copying: Set<UUID> = [],
        changeScores: [UUID: ChangeScoreTrack] = [:],
        references: [UUID: AssetReference] = [:],
        thumbnails: [UUID: ReferenceThumbnails] = [:],
        beats: [UUID: BeatTrack] = [:],
        originalScores: [UUID: ChangeScoreTrack] = [:],
        sources: AnalysisSources = AnalysisSources(),
        discardingBeats discardedBeats: Set<UUID> = [],
        invalidatingScores invalidatedScores: Set<UUID> = [],
        previousPackageURL: URL? = nil
    ) async throws -> EditingProject {
        try await PackageCoordinator.shared.run(on: [packageURL] + (previousPackageURL.map { [$0] } ?? [])) {
            try performSave(
                project, to: packageURL, copying: copying, changeScores: changeScores,
                references: references, thumbnails: thumbnails, beats: beats, originalScores: originalScores, sources: sources,
                discardingBeats: discardedBeats, invalidatingScores: invalidatedScores,
                previousPackageURL: previousPackageURL
            )
        }
    }

    private static func performSave(
        _ project: EditingProject,
        to packageURL: URL,
        copying: Set<UUID>,
        changeScores: [UUID: ChangeScoreTrack],
        references: [UUID: AssetReference],
        thumbnails: [UUID: ReferenceThumbnails],
        beats: [UUID: BeatTrack],
        originalScores: [UUID: ChangeScoreTrack],
        sources: AnalysisSources,
        discardingBeats discardedBeats: Set<UUID>,
        invalidatingScores invalidatedScores: Set<UUID>,
        previousPackageURL: URL?
    ) throws -> EditingProject {
        try preparePackage(at: packageURL)
        if let previousPackageURL {
            try copyReferenceData(
                for: project.clips.filter { !$0.referenceForgotten }.map(\.id),
                from: previousPackageURL, to: packageURL
            )
        }

        var project = project
        for index in project.clips.indices {
            let clip = project.clips[index]
            guard copying.contains(clip.id), let source = clip.url, !isInside(source, package: packageURL) else { continue }
            let destination = try copyIntoPackage(source, packageURL: packageURL)
            project.clips[index].url = destination
            project.clips[index].acceptedStamp = FileStamp(url: destination)
        }

        // Retired results go first, and a retirement that can't be made
        // durable fails the save, so an outdated result can't return.
        for assetID in invalidatedScores where changeScores[assetID] == nil {
            try invalidate(.scores, for: assetID, in: packageURL)
        }
        for assetID in discardedBeats where beats[assetID] == nil {
            try invalidate(.beats, for: assetID, in: packageURL)
        }
        for (assetID, track) in changeScores where project.mediaClip(id: assetID) != nil {
            try writeChangeScores(track, for: assetID, in: packageURL, source: sources.scores[assetID])
        }
        for (assetID, track) in beats where project.mediaClip(id: assetID) != nil {
            try writeBeats(track, for: assetID, in: packageURL, source: sources.beats[assetID])
        }
        // A forgotten original's data is deleted only now, so that undoing
        // Forget Original before saving loses nothing.
        let forgotten = Set(project.clips.filter(\.referenceForgotten).map(\.id))
        for assetID in forgotten {
            try forgetReference(for: assetID, in: packageURL)
        }
        for (assetID, reference) in references where project.mediaClip(id: assetID) != nil && !forgotten.contains(assetID) {
            try writeReference(reference, for: assetID, in: packageURL)
        }
        for (assetID, pictures) in thumbnails where project.mediaClip(id: assetID) != nil && !forgotten.contains(assetID) {
            try writeThumbnails(pictures, for: assetID, in: packageURL)
        }
        for (assetID, track) in originalScores where project.mediaClip(id: assetID) != nil && !forgotten.contains(assetID) {
            try writeOriginalScores(track, for: assetID, in: packageURL, source: sources.originalScores[assetID])
        }

        try encode(project, packageURL: packageURL)
            .write(to: packageURL.appending(path: projectFileName), options: .atomic)
        // Matroska files imported before the project had a package, or
        // copied into it just now, get their reference movies here. A
        // movie is only an index, so one that can't be made fails no save:
        // it's tried again on opening.
        for clip in project.clips {
            guard let url = clip.url, MatroskaMedia.isMatroska(url) else { continue }
            _ = try? MatroskaMedia.prepare(url, in: MatroskaMedia.folder(in: packageURL))
        }
        return project
    }

    static func encode(_ project: EditingProject, packageURL: URL) throws -> Data {
        try JSONFile.encode(makeFile(from: project, packageURL: packageURL))
    }

    private static func makeFile(from project: EditingProject, packageURL: URL) -> ProjectFile {
        let urlClips = project.clips.filter { $0.url != nil }
        let mediaIDs = Set(urlClips.map(\.id))
        let timelineIDs = Set(project.timelines.map(\.id))

        func relativePath(for url: URL) -> String {
            if isInside(url, package: packageURL) {
                let packagePath = packageURL.standardizedFileURL.resolvingSymlinksInPath().path
                let path = url.standardizedFileURL.resolvingSymlinksInPath().path
                return String(path.dropFirst(packagePath.count + 1))
            }
            return url.path
        }

        func sourceEntry(for source: ClipSource) -> ProjectFile.SourceEntry? {
            switch source {
            case .media(let id): mediaIDs.contains(id) ? ProjectFile.SourceEntry(kind: .media, id: id) : nil
            case .timeline(let id): timelineIDs.contains(id) ? ProjectFile.SourceEntry(kind: .timeline, id: id) : nil
            case .adjustment: ProjectFile.SourceEntry(kind: .adjustment, id: nil)
            case .graphic: ProjectFile.SourceEntry(kind: .graphic, id: nil)
            }
        }

        let timelines = project.timelines.map { timeline in
            ProjectFile.TimelineEntry(
                id: timeline.id,
                name: timeline.name,
                width: timeline.frameSize.width,
                height: timeline.frameSize.height,
                frameRate: timeline.frameRate,
                colorSpace: timeline.colorSpace.rawValue,
                layers: timeline.layers.map { layer in
                    ProjectFile.LayerEntry(
                        id: layer.id,
                        customName: layer.customName,
                        kind: layer.kind.rawValue,
                        clips: layer.clips.compactMap { clip in
                            guard let source = sourceEntry(for: clip.source) else { return nil }
                            return ProjectFile.ClipEntry(
                                id: clip.id,
                                source: source,
                                startOffset: ProjectFile.TimeEntry(clip.startOffset),
                                trimStart: ProjectFile.TimeEntry(clip.trimStart),
                                trimEnd: ProjectFile.TimeEntry(clip.trimEnd),
                                autoMatteEnabled: clip.autoMatteEnabled,
                                streams: clip.streams == .videoAndAudio ? nil : clip.streams.rawValue,
                                transitionIn: clip.transitionIn.map(ProjectFile.TransitionEntry.init),
                                transitionOut: clip.transitionOut.map(ProjectFile.TransitionEntry.init),
                                anchorPoint: clip.anchorPoint == AnimatedValue(Vector2.zero)
                                    ? nil : ProjectFile.PropertyEntry(clip.anchorPoint) { [$0.x, $0.y] },
                                effects: clip.effects.isEmpty ? nil : clip.effects.map(ProjectFile.EffectEntry.init),
                                audioEffects: clip.audioEffects.isEmpty ? nil : clip.audioEffects.map(ProjectFile.EffectEntry.init),
                                volume: clip.volume == AnimatedValue(0.0) ? nil : ProjectFile.PropertyEntry(clip.volume) { $0 },
                                pan: clip.pan == AnimatedValue(0.0) ? nil : ProjectFile.PropertyEntry(clip.pan) { $0 },
                                passThrough: clip.passThrough ? true : nil,
                                time: ProjectFile.ClipTimeEntry(clip.time),
                                shutter: ProjectFile.ShutterEntry(clip.shutter),
                                reach: clip.source == .adjustment ? clip.reach : nil,
                                enabled: clip.enabled ? nil : false,
                                soundMuted: clip.soundMuted ? true : nil,
                                music: layer.kind == .music ? nil : clip.music.map(ProjectFile.MusicEntry.init),
                                followsMusic: clip.followsMusic ? nil : false
                            )
                        },
                        volume: layer.kind.isAudio && layer.volume != AnimatedValue(0.0)
                            ? ProjectFile.PropertyEntry(layer.volume) { $0 } : nil,
                        pan: layer.kind.isAudio && layer.pan != AnimatedValue(0.0)
                            ? ProjectFile.PropertyEntry(layer.pan) { $0 } : nil,
                        audioEffects: layer.kind.isAudio && !layer.audioEffects.isEmpty
                            ? layer.audioEffects.map(ProjectFile.EffectEntry.init) : nil,
                        adjustment: layer.isAdjustment ? true : nil
                    )
                },
                sections: timeline.sections.isEmpty ? nil : timeline.sections.map { section in
                    ProjectFile.SectionEntry(
                        id: section.id, name: section.name,
                        start: ProjectFile.TimeEntry(section.start), end: ProjectFile.TimeEntry(section.end)
                    )
                },
                previewBackground: timeline.previewBackground
            )
        }

        return ProjectFile(
            formatVersion: ProjectFile.currentVersion,
            id: project.id,
            name: project.name,
            rootTimelineID: project.rootTimelineID,
            defaultSensitivity: project.defaultSensitivity == EditingProject.balancedSensitivity ? nil : project.defaultSensitivity,
            copiesMediaOnImport: project.copiesMediaOnImport ? nil : false,
            canvasMargin: project.canvasMargin == EditingProject.defaultCanvasMargin ? nil : project.canvasMargin,
            jointAudioCrossfade: project.jointAudioCrossfade == .sCurve ? nil : project.jointAudioCrossfade.rawValue,
            assets: urlClips.map { clip in
                ProjectFile.AssetEntry(
                    id: clip.id,
                    name: clip.name,
                    path: relativePath(for: clip.url!),
                    sceneEdits: clip.sceneEdits == SceneEdits() ? nil : ProjectFile.SceneEditsEntry(clip.sceneEdits),
                    beatMap: clip.beatMap.isEmpty ? nil : ProjectFile.BeatMapEntry(clip.beatMap),
                    alignmentOffset: clip.alignmentOffset == .zero ? nil : ProjectFile.TimeEntry(clip.alignmentOffset),
                    originalDuration: clip.originalDuration.map(ProjectFile.TimeEntry.init),
                    previousPaths: clip.previousPaths.isEmpty ? nil : clip.previousPaths,
                    fileStamp: clip.acceptedStamp,
                    referenceForgotten: clip.referenceForgotten ? true : nil,
                    skipsSceneDetection: clip.skipsSceneDetection ? true : nil,
                    kind: clip.kind.rawValue,
                    duration: ProjectFile.TimeEntry(clip.duration),
                    frameRate: clip.frameRate,
                    codec: clip.codecName,
                    colorSpace: clip.colorSpace.rawValue,
                    hasAudio: clip.hasAudio
                )
            },
            timelines: timelines
        )
    }
}
