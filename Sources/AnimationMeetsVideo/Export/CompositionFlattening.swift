import AVFoundation
import CoreMedia
import Foundation

// Resolving a timeline, nested timelines included, into the clips it
// draws and the media placed for them.
extension CompositionExporter {
    /// Resolves a timeline into the clips drawn in it, top layer first,
    /// with a nested timeline's clips inside its own, and collects the
    /// media that makes up the composition's tracks in `hosts`. `window` is
    /// the visible range in this timeline's own time, `offset` maps this
    /// timeline's time to root time, and `outerVolume` holds the volumes of
    /// the clips and layers this timeline is nested in (innermost first).
    static func flatten(
        project: EditingProject,
        timelineID: UUID,
        visiting: Set<UUID>,
        window: CMTimeRange,
        offset: CMTime,
        outerVolume: [MixStage],
        rootClipID: UUID?,
        silent: Bool = false,
        hosts: inout [TrackHost]
    ) async throws -> [BuildNode] {
        guard !visiting.contains(timelineID) else {
            throw CompositionError.cyclicTimeline
        }
        guard let timeline = project.timeline(id: timelineID) else { return [] }
        var visiting = visiting
        visiting.insert(timelineID)

        let center = CGPoint(x: timeline.frameSize.width / 2, y: timeline.frameSize.height / 2)
        var result: [BuildNode] = []
        for layer in timeline.layers {
            // Sound and Music layers act as a fader and pan over their
            // clips' own; video layers have neither of their own.
            let layerVolume = layer.kind.isAudio ? [MixStage(id: layer.id, shift: offset)] : []
            let volume = layerVolume + outerVolume
            let clips = layer.clips.sorted(by: { $0.startOffset < $1.startOffset })
            let own = TrackHost(volume: volume)
            // The incoming clip's frames before a joined cut, on a track of
            // their own above the layer's, so they can overlap the outgoing
            // clip that is still playing there.
            let overlay = TrackHost()
            // Frames shown under a transition at a cut, on a track of their
            // own below the layer's so the two can overlap.
            let underlay = TrackHost()
            // The sound of clips with a volume or pan of their own, each on
            // a track of its own to be played through them.
            var clipSound: [TrackHost] = []
            // The footage again, for frame blending, echo and trails.
            var copyHosts: [TrackHost] = []
            var nestedHosts: [TrackHost] = []
            var overlayNodes: [BuildNode] = [], ownNodes: [BuildNode] = [], underlayNodes: [BuildNode] = []

            for clip in clips {
                func stack(of clip: TimelineClip, edges: EdgeTransitions? = nil) -> ClipStack {
                    ClipStack(clip: clip, center: center, shift: offset, edges: edges, colorSpace: timeline.colorSpace, frameDuration: timeline.frameDuration)
                }
                // The clip's volume counts in its source time, which a
                // retimed clip plays through at its speed (at the speed it
                // starts at, when that is changing).
                let rate = abs(clip.speed(atSource: clip.trimStart)) / 100
                let clipVolume = MixStage(
                    id: clip.id,
                    shift: CMTimeAdd(offset, CMTimeSubtract(clip.startOffset, CMTimeMultiplyByFloat64(clip.trimStart, multiplier: 1 / rate))),
                    rate: rate
                )
                // Fades under its transitions and its neighbors', with the
                // sound past its ends that a crossfade at a cut plays.
                let audioFades = project.playsAudio(clip) ? project.audioFades(of: clip, among: clips) : ([], .zero, .zero)
                let fadeStages = audioFades.fades.map { MixStage(id: clip.id, shift: offset, fade: $0.shifted(by: offset)) }
                let lead = project.joinedLead(of: clip, among: clips) ?? .zero
                var clipStack = stack(of: clip)
                if project.playsVideo(clip) {
                    clipStack.edges = EdgeTransitions(clip: clip, frameSize: timeline.frameSize, lead: lead)
                }
                let placed = CMTimeRange(start: CMTimeSubtract(clip.startOffset, lead), end: clip.endOffset)
                let visible = placed.intersection(window)
                guard visible.isValid, visible.duration > .zero else { continue }
                let owner = rootClipID ?? clip.id

                // The pictures its effects take come from the browser, not
                // the timeline: footage on tracks of its own, or a nested
                // timeline drawn as one picture.
                var inputs: [UUID: BuildInput] = [:]
                for effect in clip.effects where effect.enabled && effect.kind.takesInput {
                    guard let input = effect.input else { continue }
                    switch input.source {
                    case .asset(let assetID):
                        if let (placement, base) = try await inputPlacement(
                            assetID, input: input, clip: clip, visible: visible,
                            project: project, frameSize: timeline.frameSize, offset: offset
                        ) {
                            copyHosts.append(TrackHost(placements: [placement]))
                            inputs[effect.id] = .track(placement, base: base)
                        }
                    case .timeline(let nestedID):
                        guard let nested = project.timeline(id: nestedID) else { continue }
                        guard !visiting.contains(nestedID) else { throw CompositionError.cyclicTimeline }
                        var inner: [TrackHost] = []
                        let children = try await flatten(
                            project: project, timelineID: nestedID, visiting: visiting,
                            window: CMTimeRange(
                                start: CMTimeAdd(input.offset, CMTimeSubtract(visible.start, clip.startOffset)), duration: visible.duration
                            ),
                            offset: CMTimeAdd(offset, CMTimeSubtract(clip.startOffset, input.offset)),
                            outerVolume: [], rootClipID: owner, silent: true, hosts: &inner
                        )
                        nestedHosts += inner
                        if !children.isEmpty {
                            inputs[effect.id] = .group(
                                frameSize: nested.frameSize, toOuter: fitTransform(from: nested.frameSize, to: timeline.frameSize), children: children
                            )
                        }
                    }
                }

                /// `source`'s pictures from `sourceStart` placed at
                /// `placedStart` for `duration`, drawn through `stack`:
                /// footage on a track of `host`, or a still's picture.
                func spare(
                    _ source: TimelineClip, from sourceStart: CMTime, at placedStart: CMTime, for duration: CMTime,
                    stack: ClipStack, host: TrackHost
                ) async throws -> BuildNode? {
                    if let still = try await stillDraw(of: source, project: project, in: timeline) {
                        let shown = CMTimeRange(start: placedStart, duration: duration).intersection(window)
                        guard shown.isValid, shown.duration > .zero else { return nil }
                        return BuildNode(
                            content: .still(still.picture, url: still.url, base: still.base, trails: []), stack: stack,
                            range: CMTimeRange(start: CMTimeAdd(shown.start, offset), duration: shown.duration),
                            owner: owner, layerID: layer.id
                        )
                    }
                    guard let (placement, base) = try await mediaPlacement(
                        of: source, from: sourceStart, at: placedStart, for: duration,
                        project: project, frameSize: timeline.frameSize, window: window, offset: offset,
                        includesVideo: true, includesAudio: false
                    ) else { return nil }
                    host.placements.append(placement)
                    return BuildNode(content: .media(placement, base: base, extras: PlacementExtras()), stack: stack, range: .invalid, owner: owner, layerID: layer.id)
                }

                switch clip.source {
                case .media(let mediaID):
                    let still = try await stillDraw(of: clip, project: project, in: timeline)
                    let main: (Placement, CGAffineTransform)?
                    if still != nil {
                        main = nil
                    } else if clip.isRetimed {
                        main = try await retimedPlacement(
                            of: clip, project: project, frameSize: timeline.frameSize, frameDuration: timeline.frameDuration,
                            window: window, offset: offset,
                            includesVideo: clip.streams != .audio, includesAudio: clip.streams != .video
                        )
                    } else {
                        main = try await mediaPlacement(
                            of: clip, from: clip.trimStart, at: clip.startOffset, for: clip.trimmedDuration,
                            project: project, frameSize: timeline.frameSize, window: window, offset: offset,
                            includesVideo: clip.streams != .audio, includesAudio: clip.streams != .video
                        )
                    }
                    if let (placement, base) = main {
                        if silent { placement.includesAudio = false }
                        // A retimed clip's sound is silent, or played at its
                        // new speed with or without its pitch changing.
                        if clip.isRetimed, clip.time.sound == .mute || clip.isReversed { placement.includesAudio = false }
                        if placement.includesAudio, clip.hasOwnMix || clip.isRetimed || !fadeStages.isEmpty {
                            let sound = placement.copy()
                            sound.includesVideo = false
                            var sounds = [sound]
                            // The sound before its in point and after its out
                            // point that a crossfade at a joined cut plays.
                            // Only unretimed clips are joined.
                            if !clip.isRetimed {
                                if audioFades.head > .zero, let (head, _) = try await mediaPlacement(
                                    of: clip, from: CMTimeSubtract(clip.trimStart, audioFades.head),
                                    at: CMTimeSubtract(clip.startOffset, audioFades.head), for: audioFades.head,
                                    project: project, frameSize: timeline.frameSize, window: window, offset: offset,
                                    includesVideo: false, includesAudio: true
                                ) {
                                    sounds.insert(head, at: 0)
                                }
                                if audioFades.tail > .zero, let (tail, _) = try await mediaPlacement(
                                    of: clip, from: clip.trimEnd, at: clip.endOffset, for: audioFades.tail,
                                    project: project, frameSize: timeline.frameSize, window: window, offset: offset,
                                    includesVideo: false, includesAudio: true
                                ) {
                                    sounds.append(tail)
                                }
                            }
                            let pitch: AVAudioTimePitchAlgorithm? = clip.isRetimed ? (clip.time.sound == .changePitch ? .varispeed : .spectral) : nil
                            clipSound.append(TrackHost(placements: sounds, volume: [clipVolume] + fadeStages + volume, pitch: pitch))
                            placement.includesAudio = false
                        }
                        own.placements.append(placement)
                        if placement.includesVideo {
                            let media = project.mediaClip(id: mediaID)
                            var extras = PlacementExtras(
                                frameDuration: Timeline.frameDuration(for: media.map { $0.frameRate > 0 ? $0.frameRate : timeline.frameRate } ?? timeline.frameRate),
                                alignmentOffset: media?.alignmentOffset ?? .zero
                            )
                            func copy(_ delay: CMTime, inFileBy fileShift: CMTime = .zero) -> Placement {
                                let copy = placement.shifted(by: delay, inFileBy: fileShift)
                                copy.includesAudio = false
                                copyHosts.append(TrackHost(placements: [copy]))
                                return copy
                            }
                            // Blend mixes the frame the footage is at with the
                            // one after it.
                            if clip.time.frameBlending != .off {
                                extras.next = copy(.zero, inFileBy: extras.frameDuration)
                                extras.opticalFlow = clip.time.frameBlending == .opticalFlow
                            }
                            // Echo and trails are the footage again, later in
                            // time, so each moment has an earlier one to show.
                            if let echo = clip.time.echo?.clamped {
                                extras.echoes = (1...echo.count).map { k in
                                    (copy(CMTimeMultiply(echo.delay, multiplier: Int32(k))), pow(echo.decay, Double(k)))
                                }
                            }
                            if let trails = clip.shutter.trails?.clamped {
                                extras.trails = (1...trails.count).map { k in
                                    (copy(CMTimeMultiply(trails.delay, multiplier: Int32(k))), pow(trails.decay, Double(k)))
                                }
                            }
                            ownNodes.append(BuildNode(
                                content: .media(placement, base: base, extras: extras), stack: clipStack, range: .invalid,
                                owner: owner, layerID: layer.id, inputs: inputs
                            ))
                        }
                    }
                    if let still, project.playsVideo(clip) {
                        let shown = CMTimeRange(start: clip.startOffset, end: clip.endOffset).intersection(window)
                        if shown.isValid, shown.duration > .zero {
                            // Its trails are its own picture at earlier
                            // moments; a still has no other frames to blend
                            // or echo.
                            let trails = (clip.shutter.trails?.clamped).map { trails in
                                (1...trails.count).map { k in (delay: CMTimeMultiply(trails.delay, multiplier: Int32(k)), strength: pow(trails.decay, Double(k))) }
                            } ?? []
                            ownNodes.append(BuildNode(
                                content: .still(still.picture, url: still.url, base: still.base, trails: trails), stack: clipStack,
                                range: CMTimeRange(start: CMTimeAdd(shown.start, offset), duration: shown.duration),
                                owner: owner, layerID: layer.id, inputs: inputs
                            ))
                        }
                    }
                    // Where this clip meets its neighbor at a cut, the
                    // neighbor's frames beyond its trim play underneath the
                    // transition, so a dissolve blends the two clips rather
                    // than passing through what is below the layer. A way in
                    // that joins the clip before may also start before the
                    // cut, playing this clip's frames before its in point.
                    // Without spare frames there is nothing to show, and the
                    // transition plays over the layers below.
                    let durations = clipStack.edges == nil ? (leading: CMTime.zero, trailing: CMTime.zero) : clip.effectiveTransitionDurations(lead: lead)
                    if lead > .zero, let node = try await spare(
                        clip, from: CMTimeSubtract(clip.trimStart, lead), at: CMTimeSubtract(clip.startOffset, lead), for: lead,
                        stack: clipStack, host: overlay
                    ) {
                        overlayNodes.append(node)
                    }
                    if durations.leading > .zero, let previous = project.predecessor(joining: clip, among: clips),
                       let node = try await spare(
                           previous, from: previous.trimEnd, at: clip.startOffset, for: durations.leading,
                           stack: stack(of: previous), host: underlay
                       ) {
                        underlayNodes.append(node)
                    }
                    if durations.trailing > .zero, let next = project.successor(joining: clip, among: clips),
                       let node = try await spare(
                           next, from: CMTimeSubtract(next.trimStart, durations.trailing),
                           at: CMTimeSubtract(clip.endOffset, durations.trailing), for: durations.trailing,
                           stack: stack(of: next), host: underlay
                       ) {
                        underlayNodes.append(node)
                    }
                case .timeline(let nestedID):
                    guard let nested = project.timeline(id: nestedID) else { continue }
                    // Nested time = this timeline's time - clip.startOffset + clip.trimStart.
                    let shift = CMTimeSubtract(clip.startOffset, clip.trimStart)
                    let nestedWindow = CMTimeRange(start: CMTimeSubtract(visible.start, shift), duration: visible.duration)
                    var inner: [TrackHost] = []
                    let children = try await flatten(
                        project: project,
                        timelineID: nestedID,
                        visiting: visiting,
                        window: nestedWindow,
                        offset: CMTimeAdd(offset, shift),
                        outerVolume: [clipVolume] + fadeStages + volume,
                        rootClipID: owner,
                        silent: silent,
                        hosts: &inner
                    )
                    nestedHosts += inner
                    guard !children.isEmpty else { continue }
                    ownNodes.append(BuildNode(
                        content: .group(
                            frameSize: nested.frameSize, toOuter: fitTransform(from: nested.frameSize, to: timeline.frameSize),
                            passThrough: clip.passThrough, children: children
                        ),
                        stack: clipStack,
                        range: CMTimeRange(start: CMTimeAdd(visible.start, offset), duration: visible.duration),
                        owner: owner,
                        layerID: layer.id,
                        inputs: inputs
                    ))
                case .graphic:
                    // Transparency, which its stack draws shapes on.
                    ownNodes.append(BuildNode(
                        content: .graphic, stack: clipStack,
                        range: CMTimeRange(start: CMTimeAdd(visible.start, offset), duration: visible.duration),
                        owner: owner, layerID: layer.id, inputs: inputs
                    ))
                case .adjustment:
                    // No picture: its stack is applied to the layers it
                    // reaches while it plays.
                    let reached = project.reach(of: clip, on: layer, in: timeline)
                    ownNodes.append(BuildNode(
                        content: .adjustment(reachedLayerIDs: Set(reached.layers.map(\.id)), reachesAll: reached.all),
                        stack: clipStack,
                        range: CMTimeRange(start: CMTimeAdd(visible.start, offset), duration: visible.duration),
                        owner: owner,
                        layerID: layer.id,
                        inputs: inputs
                    ))
                }
            }

            result += overlayNodes + ownNodes + underlayNodes
            hosts += [overlay, own, underlay].filter { !$0.placements.isEmpty }
            hosts += clipSound
            hosts += copyHosts
            hosts += nestedHosts
        }
        return result
    }

    /// A media clip's frames from `sourceStart` (in its asset's original
    /// time) placed at `placedStart` in the timeline for `duration`, cut to
    /// the window, with the transform that orients and fits them into the
    /// timeline's frame. Nil when it falls outside the window, the clip
    /// isn't media, or its file is missing. Frames past either end of the
    /// file are dropped when the tracks are built.
    static func mediaPlacement(
        of clip: TimelineClip,
        from sourceStart: CMTime,
        at placedStart: CMTime,
        for duration: CMTime,
        project: EditingProject,
        frameSize: CGSize,
        window: CMTimeRange,
        offset: CMTime,
        includesVideo: Bool,
        includesAudio: Bool
    ) async throws -> (Placement, CGAffineTransform)? {
        guard case .media(let mediaID) = clip.source,
              let media = project.mediaClip(id: mediaID), media.kind != .image, let url = media.url
        else {
            return nil
        }
        let visible = CMTimeRange(start: placedStart, duration: duration).intersection(window)
        guard visible.isValid, visible.duration > .zero else { return nil }
        let intoClip = CMTimeSubtract(visible.start, placedStart)
        let info: MediaTrackInfo
        do {
            info = try await MediaTrackCache.shared.info(for: url)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // A file that is there but unreadable is a real failure; one
            // that is gone is offline media (see `skipsMissingMedia`).
            guard !FileManager.default.fileExists(atPath: url.path) else { throw error }
            if skipsMissingMedia { return nil }
            throw CompositionError.missingMedia(media.name)
        }
        let wanted = CMTimeRange(start: media.fileTime(forSourceTime: CMTimeAdd(sourceStart, intoClip)), duration: visible.duration)
        let base = info.orientedTransform
            .concatenating(fitTransform(from: info.orientedSize, to: frameSize))
        let placement = Placement(
            info: info,
            file: wanted,
            at: CMTimeAdd(visible.start, offset),
            includesVideo: includesVideo,
            includesAudio: includesAudio
        )
        return (placement, base)
    }

    /// A retimed media clip's footage, cut to the window: one piece playing
    /// the file at the clip's speed, or for a speed that changes, a piece
    /// for every few frames each at the speed it has there.
    static func retimedPlacement(
        of clip: TimelineClip,
        project: EditingProject,
        frameSize: CGSize,
        frameDuration: CMTime,
        window: CMTimeRange,
        offset: CMTime,
        includesVideo: Bool,
        includesAudio: Bool
    ) async throws -> (Placement, CGAffineTransform)? {
        guard case .media(let mediaID) = clip.source,
              let media = project.mediaClip(id: mediaID), media.kind != .image, let url = media.url
        else {
            return nil
        }
        let visible = CMTimeRange(start: clip.startOffset, end: clip.endOffset).intersection(window)
        guard visible.isValid, visible.duration > .zero else { return nil }
        let info = try await MediaTrackCache.shared.info(for: url)

        func piece(from a: CMTime, to b: CMTime) -> Placement.Piece {
            let first = clip.sourceTime(atTimelineTime: a), last = clip.sourceTime(atTimelineTime: b)
            // Backwards, a piece is a frame's worth of footage starting at
            // where the piece starts, so it shows that moment.
            return Placement.Piece(
                file: CMTimeRange(start: media.fileTime(forSourceTime: first), duration: CMTimeSubtract(max(first, last), min(first, last))),
                at: CMTimeAdd(a, offset), duration: CMTimeSubtract(b, a)
            )
        }
        var pieces: [Placement.Piece] = []
        if clip.isReversed || clip.time.speed.isAnimated {
            // A composition can't play footage backwards, so backwards
            // footage is a piece for every frame, each placed after the
            // one that follows it in the file.
            let step = clip.isReversed ? frameDuration : CMTimeMultiply(frameDuration, multiplier: 4)
            var cursor = visible.start
            while cursor < visible.end {
                let end = CMTimeMinimum(CMTimeAdd(cursor, step), visible.end)
                pieces.append(piece(from: cursor, to: end))
                cursor = end
            }
        } else {
            pieces = [piece(from: visible.start, to: visible.end)]
        }
        let base = info.orientedTransform.concatenating(fitTransform(from: info.orientedSize, to: frameSize))
        return (Placement(info: info, pieces: pieces, includesVideo: includesVideo, includesAudio: includesAudio), base)
    }

    /// A still clip's picture for `timeline`, decoded, with the transform that
    /// fits it into the timeline's frame. Nil when the clip isn't a still,
    /// or its file is missing while building for the viewer (see
    /// `skipsMissingMedia`).
    static func stillDraw(
        of clip: TimelineClip, project: EditingProject, in timeline: Timeline
    ) async throws -> (picture: StillPicture, url: URL, base: CGAffineTransform)? {
        guard case .media(let mediaID) = clip.source, let media = project.mediaClip(id: mediaID), media.kind == .image else {
            return nil
        }
        guard let url = media.url, FileManager.default.fileExists(atPath: url.path) else {
            if skipsMissingMedia { return nil }
            throw CompositionError.missingMedia(media.name)
        }
        guard let picture = await StillImages.shared.picture(at: url, frameSize: timeline.frameSize, colorSpace: timeline.colorSpace) else {
            throw MediaImportError.unreadableImage
        }
        return (picture, url, fitTransform(from: picture.size, to: timeline.frameSize))
    }

    /// Scales `source` to fit inside `target` (aspect-preserving) and centers it.
    static func fitTransform(from source: CGSize, to target: CGSize) -> CGAffineTransform {
        guard source.width > 0, source.height > 0, target.width > 0, target.height > 0 else { return .identity }
        let scale = min(target.width / source.width, target.height / source.height)
        return CGAffineTransform(scaleX: scale, y: scale).concatenating(CGAffineTransform(
            translationX: (target.width - source.width * scale) / 2,
            y: (target.height - source.height * scale) / 2
        ))
    }

    /// The footage an effect takes, for the stretch of the timeline `visible`
    /// where its clip is: it starts with the clip, `input.offset` into itself,
    /// and plays at its own speed. At its end it holds its last frame, or
    /// plays again from its start when it loops. Nil when the asset has no
    /// file or no pictures.
    static func inputPlacement(
        _ assetID: UUID,
        input: EffectInput,
        clip: TimelineClip,
        visible: CMTimeRange,
        project: EditingProject,
        frameSize: CGSize,
        offset: CMTime
    ) async throws -> (Placement, CGAffineTransform)? {
        guard let media = project.mediaClip(id: assetID), media.kind == .video, let url = media.url else { return nil }
        let info = try await MediaTrackCache.shared.info(for: url)
        guard info.video != nil, media.duration > .zero else { return nil }

        let frame = Timeline.frameDuration(for: media.frameRate > 0 ? media.frameRate : 24)
        let length = media.duration
        var position = CMTimeAdd(input.offset, CMTimeSubtract(visible.start, clip.startOffset))
        var left = visible.duration
        var at = CMTimeAdd(visible.start, offset)
        var pieces: [Placement.Piece] = []
        if input.loops {
            position = CMTime(seconds: position.seconds.truncatingRemainder(dividingBy: length.seconds), preferredTimescale: 240_000)
        }
        while left > .zero, pieces.count < 4000 {
            if position < length {
                let span = CMTimeMinimum(left, CMTimeSubtract(length, position))
                pieces.append(Placement.Piece(
                    file: CMTimeRange(start: media.fileTime(forSourceTime: position), duration: span), at: at, duration: span
                ))
                left = CMTimeSubtract(left, span)
                at = CMTimeAdd(at, span)
                position = CMTimeAdd(position, span)
            } else if !input.loops {
                // Past the end: its last frame, held for what remains.
                let last = CMTimeMaximum(.zero, CMTimeSubtract(length, frame))
                pieces.append(Placement.Piece(
                    file: CMTimeRange(start: media.fileTime(forSourceTime: last), duration: frame), at: at, duration: left
                ))
                left = .zero
            } else {
                position = .zero
            }
        }
        guard !pieces.isEmpty else { return nil }
        let base = info.orientedTransform.concatenating(fitTransform(from: info.orientedSize, to: frameSize))
        return (Placement(info: info, pieces: pieces, includesVideo: true, includesAudio: false), base)
    }
}
