import AVFoundation
import CoreMedia
import CryptoKit
import Foundation

// Splitting a resolved timeline into stretches, keying them for the render
// cache, and building the video composition that draws them.
extension CompositionExporter {
    /// Splits the timeline where any picture starts or ends, and each
    /// stretch draws the clips whose pictures cover all of it (top first).
    /// Stretches that need rendering are cut into pieces of at most
    /// `RenderSegment.maxFrames` frames.
    static func planRanges(
        tree: [DrawClip],
        overallDuration: CMTime,
        allowsPassthrough: Bool,
        frameSize: CGSize,
        frameRate: Double,
        colorSpace: ProjectColorSpace,
        canvasMargin: Double
    ) -> [PlannedRange] {
        var breakpoints: [CMTime] = [.zero]
        // Wherever a picture, a nested timeline or an adjustment starts or
        // ends, something about the drawing changes.
        func collect(_ clips: [DrawClip]) {
            for clip in clips {
                breakpoints.append(clip.range.start)
                breakpoints.append(clip.range.end)
                switch clip.content {
                case .group(let group):
                    collect(group.children)
                case .media(let media):
                    // Where its other tracks start and end, so each stretch
                    // has them throughout or not at all.
                    for copy in [media.nextFrame].compactMap({ $0 }) + media.echoes + media.trails {
                        breakpoints.append(copy.range.start)
                        breakpoints.append(copy.range.end)
                    }
                case .adjustment, .graphic:
                    break
                }
                for input in clip.inputs.values {
                    switch input {
                    case .track(let copy, _):
                        breakpoints.append(copy.range.start)
                        breakpoints.append(copy.range.end)
                    case .group(let group):
                        collect(group.children)
                    }
                }
            }
        }
        collect(tree)
        breakpoints = breakpoints.filter { $0 > .zero && $0 < overallDuration }
        breakpoints.append(.zero)
        breakpoints.sort()
        breakpoints.append(overallDuration)

        let frame = frameDuration(for: frameRate)
        let piece = CMTimeMultiply(frame, multiplier: Int32(RenderSegment.maxFrames))
        var plan: [PlannedRange] = []
        for index in 0..<(breakpoints.count - 1) {
            let whole = CMTimeRange(start: breakpoints[index], end: breakpoints[index + 1])
            guard whole.duration > .zero else { continue }
            let clips = DrawClip.assembled(tree.compactMap { $0.pruned(to: whole) })
                .withoutHidden(in: frameSize, over: whole, frame: frame)
            let leaves = clips.flatMap(\.leaves)
            let owners = Set(clips.map(\.owner))

            // One picture drawn the same way throughout plays from its file;
            // stacking it with others, or anything changing over time, is
            // rendered.
            let animated = clips.contains { clip in
                clip.animatedRanges.contains { range in
                    let overlap = range.intersection(whole)
                    return overlap.isValid && overlap.duration > .zero
                }
            }
            let changesPixels = clips.contains { clip in clip.everyClip.contains { $0.stack.resolve(atRoot: whole.start).changesPixels } }
            // Frames mixed from several, earlier copies, and motion blur
            // draw a clip more than once.
            let drawsTwice = clips.contains { clip in
                clip.everyClip.contains { clip in
                    if case .media(let media) = clip.content, media.nextFrame != nil || !media.echoes.isEmpty || !media.trails.isEmpty { return true }
                    return clip.stack.shutter.motionBlur != nil
                }
            }
            let needsRender = whole.duration >= frame && (leaves.count > 1 || animated || changesPixels || drawsTwice)

            // A single picture with nothing done to it and no fitting is the
            // stretch's frames as they are.
            var straight: CMPersistentTrackID?
            if allowsPassthrough, !needsRender, clips.count == 1, case .media(let media) = clips[0].content,
               media.still == nil, media.base == .identity, clips[0].stack.isNoOp(over: whole, frame: frame) {
                straight = media.trackID
            }
            guard needsRender else {
                plan.append(PlannedRange(
                    range: whole, clips: clips,
                    segment: RenderSegment(range: whole, key: "", needsRender: false, clipIDs: owners),
                    passthrough: straight
                ))
                continue
            }
            var start = whole.start
            while start < whole.end {
                let range = CMTimeRange(start: start, end: CMTimeMinimum(CMTimeAdd(start, piece), whole.end))
                let key = renderKey(
                    for: range, clips: clips, frame: frame,
                    frameSize: frameSize, frameRate: frameRate, colorSpace: colorSpace, canvasMargin: canvasMargin
                )
                plan.append(PlannedRange(
                    range: range, clips: clips,
                    segment: RenderSegment(range: range, key: key, needsRender: true, clipIDs: owners),
                    passthrough: nil
                ))
                start = range.end
            }
        }
        return plan
    }

    /// A hash of everything that decides a stretch's frames: each picture's
    /// file, its version on disk and the file time it starts at, and what
    /// is done to it on every frame, in the structure the clips are nested
    /// in. Where the stretch sits in the timeline is left out, so moving it
    /// keeps its render.
    static func renderKey(
        for range: CMTimeRange,
        clips: [DrawClip],
        frame: CMTime,
        frameSize: CGSize,
        frameRate: Double,
        colorSpace: ProjectColorSpace,
        canvasMargin: Double
    ) -> String {
        func number(_ value: Double) -> String { String(format: "%.5f", value) }
        func matrix(_ t: CGAffineTransform) -> String { [t.a, t.b, t.c, t.d, t.tx, t.ty].map(number).joined(separator: " ") }
        let frames = Int((range.duration.seconds / frame.seconds).rounded(.up))
        var text = "v\(RenderSegment.formatVersion) \(number(frameSize.width))x\(number(frameSize.height)) \(number(frameRate)) \(colorSpace.rawValue) \(number(canvasMargin)) \(frames)\n"

        func describe(_ clip: DrawClip) {
            switch clip.content {
            case .media(let media) where media.still != nil:
                // The same picture throughout, so no file time: moving it
                // keeps its render.
                let stamp = FileStamp(url: media.url)
                text += "I \(media.url.path) \(stamp?.byteCount ?? -1) \(number(stamp?.modified ?? 0)) \(matrix(media.base))"
                text += " trails:" + media.trails.map { "\(number($0.strength))@\(number($0.delay.seconds))" }.joined(separator: ",") + "\n"
            case .media(let media):
                let stamp = FileStamp(url: media.url)
                let fileStart = CMTimeAdd(media.sourceStart, CMTimeSubtract(range.start, media.segmentStart))
                text += "L \(media.url.path) \(stamp?.byteCount ?? -1) \(number(stamp?.modified ?? 0)) \(number(fileStart.seconds)) \(matrix(media.base))\n"
                // What is done to the footage's time, which the picture
                // depends on beyond the file time it starts at.
                text += "T \(number(media.frameDuration.seconds)) \(number(media.alignmentOffset.seconds)) next:\(media.nextFrame != nil) flow:\(media.opticalFlow)"
                text += " echo:" + media.echoes.map { "\(number($0.strength))@\(number($0.delay.seconds))" }.joined(separator: ",")
                text += " trails:" + media.trails.map { "\(number($0.strength))@\(number($0.delay.seconds))" }.joined(separator: ",") + "\n"
            case .group(let group):
                text += "G \(number(group.frameSize.width))x\(number(group.frameSize.height)) \(matrix(group.toOuter)) \(group.passThrough ? "pass" : "closed")\n"
            case .adjustment(let adjustment):
                text += "A \(adjustment.reachesAll ? "all" : "some")\n"
            case .graphic:
                text += "S\n"
            }
            if let blur = clip.stack.shutter.motionBlur {
                text += "B \(number(blur.angle)) \(blur.samples) \(number(clip.stack.frameDuration.seconds))\n"
            }
            for index in 0..<frames {
                let time = CMTimeAdd(range.start, CMTimeMultiply(frame, multiplier: Int32(index)))
                let resolved = clip.stack.resolve(atRoot: time)
                // Retimed, the file time each frame comes from isn't a
                // straight line from where the stretch starts.
                if clip.stack.retimed != nil {
                    text += "s \(number(clip.stack.sourceTime(atLocal: clip.stack.localTime(atRoot: time)).seconds)) "
                }
                for step in resolved.steps {
                    switch step {
                    case .place(let m, let opacity): text += "p \(matrix(m)) \(number(opacity))"
                    case .mark(let id): text += "m \(id.uuidString)"
                    case .matte(let effect, let mode, let amount): text += "k \(effect.uuidString) \(mode.rawValue) \(number(amount))"
                    case .blend(let mode, let amount, let against): text += "b \(mode.rawValue) \(number(amount)) \(against?.uuidString ?? "-")"
                    case .color(let ops):
                        text += "g \(clip.stack.colorSpace.rawValue) " + ops.map { op in
                            "\(op.kind.rawValue):" + (0..<4).map { number(Double(op.value[$0])) }.joined(separator: ",")
                        }.joined(separator: " ")
                    case .shape(let shape):
                        text += shape.keyText
                    case .outlineStroke(let style):
                        text += "o " + style.keyText
                    }
                    text += " "
                }
                if let transition = resolved.transition {
                    text += "t \(number(transition.opacity)) \(matrix(transition.transform))"
                    if let visible = transition.visibleRect {
                        text += " c" + [visible.minX, visible.minY, visible.width, visible.height].map(number).joined(separator: " ")
                    }
                    if let reveal = transition.lumaReveal {
                        text += " r\(number(reveal.progress)) \(reveal.keysIncoming)"
                    }
                }
                if let drawn = clip.stack.transitionFrame(atRoot: time) {
                    text += " x \(drawn.key)"
                    if drawn.kind == .matteWipe, case .clip(let id) = drawn.options.matte {
                        text += " \(MatteMaps.shared.stamp(for: id) ?? "noise")"
                    }
                }
                text += "\n"
            }
            switch clip.content {
            case .group(let group):
                text += "(\n"
                group.children.forEach(describe)
                text += ")\n"
            case .adjustment(let adjustment):
                text += "(\n"
                adjustment.reached.forEach(describe)
                text += ")\n"
            case .media, .graphic:
                break
            }
        }
        clips.forEach(describe)
        return SHA256.hash(data: Data(text.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Puts the cached render of each stretch that has one on a track of
    /// its own, and has the stretch show only that. Returns the keys used.
    ///
    /// A render can come out a little shorter than its stretch: the
    /// stretch's ends are clip edges, which at rates such as 29.97 fall
    /// between the exact frame times, and the render holds whole frames.
    /// One short by less than a frame is stretched to fit, rather than let
    /// go, which left the stretch compositing live although the timeline
    /// showed it rendered.
    static func substituteCachedRanges(
        _ plan: inout [PlannedRange],
        from cache: RenderCache,
        into composition: AVMutableComposition,
        frame: CMTime
    ) async throws -> Set<String> {
        var used: Set<String> = []
        var track: AVMutableCompositionTrack?
        for index in plan.indices where plan[index].segment.needsRender {
            let segment = plan[index].segment
            guard let file = cache.file(for: segment.key),
                  let info = try? await MediaTrackCache.shared.info(for: file),
                  let video = info.video,
                  info.videoRange.duration > .zero,
                  CMTimeAdd(info.videoRange.duration, frame) > segment.range.duration
            else {
                continue
            }
            if track == nil {
                track = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
            }
            guard let track else { break }
            let source = CMTimeRange(start: info.videoRange.start, duration: CMTimeMinimum(info.videoRange.duration, segment.range.duration))
            try track.insertTimeRange(source, of: video, at: segment.range.start)
            if source.duration < segment.range.duration {
                track.scaleTimeRange(CMTimeRange(start: segment.range.start, duration: source.duration), toDuration: segment.range.duration)
            }
            plan[index].clips = [DrawClip(
                content: .media(MediaDraw(
                    trackID: track.trackID, base: .identity, url: file,
                    sourceStart: source.start, segmentStart: segment.range.start
                )),
                stack: .none, range: segment.range, owner: UUID()
            )]
            cache.markUsed(segment.key)
            used.insert(segment.key)
        }
        return used
    }

    /// The per-stretch drawing instructions. Gaps are stretches with
    /// nothing to draw, which render black.
    static func buildVideoComposition(
        plan: [PlannedRange],
        hasPictures: Bool,
        renderSize: CGSize,
        frameRate: Double,
        colorSpace: ProjectColorSpace,
        forPreview: Bool,
        canvasMargin: Double,
        meter: RenderMeter?,
        options: DrawingOptions?
    ) -> AVMutableVideoComposition? {
        guard hasPictures else { return nil }

        let videoComposition = AVMutableVideoComposition()
        videoComposition.renderSize = renderSize
        videoComposition.frameDuration = frameDuration(for: frameRate)
        // The viewer draws SDR timelines in 8 bits, which decodes cheaper.
        videoComposition.customVideoCompositorClass = forPreview && colorSpace == .rec709
            ? SDRLayeredCompositor.self : LayeredCompositor.self
        videoComposition.instructions = plan.map { planned in
            LayeredInstruction(
                timeRange: planned.range, clips: planned.clips, passthrough: planned.passthrough ?? kCMPersistentTrackID_Invalid,
                renderSize: renderSize, colorSpace: colorSpace, canvasMargin: canvasMargin, meter: meter, options: options
            )
        }
        return videoComposition
    }

    static func frameDuration(for frameRate: Double) -> CMTime {
        Timeline.frameDuration(for: frameRate)
    }
}
