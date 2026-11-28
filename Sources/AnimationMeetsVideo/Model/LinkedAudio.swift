import CoreMedia
import Foundation

// MARK: - Streams

extension EditingProject {
    /// Whether the clip draws pictures: video it hasn't had its picture
    /// taken from, stills, nested timelines that aren't their detached
    /// sound, and shapes.
    func playsVideo(_ clip: TimelineClip) -> Bool {
        switch resolvedInfo(for: clip.source) {
        case .media(let media): media.kind.hasPictures && clip.streams != .audio
        case .timeline: clip.streams != .audio
        case .adjustment, .graphic: true
        case nil: false
        }
    }

    /// Whether the clip makes sound: audio files, videos with sound whose
    /// audio wasn't detached, and nested timelines whose audio wasn't.
    func playsAudio(_ clip: TimelineClip) -> Bool {
        switch resolvedInfo(for: clip.source) {
        case .media(let media): media.hasAudio && clip.streams != .video
        case .timeline: clip.streams != .video
        case .adjustment, .graphic, nil: false
        }
    }

    /// Whether the clip's sound is heard in the mix, as the composition
    /// places it (`CompositionFlattening`): it makes sound, is turned on,
    /// isn't muted, and isn't retimed to silence (Sound Mute, or played
    /// backwards). What listens to the mix from inside it, the Waveform
    /// and Audio Keys, hears only these.
    func soundIsHeard(_ clip: TimelineClip) -> Bool {
        playsAudio(clip) && clip.enabled && !clip.soundMuted
            && !(clip.isRetimed && (clip.time.sound == .mute || clip.isReversed))
    }

    /// True for a video clip still carrying its own sound, which the
    /// timeline can show expanded and detach.
    func hasLinkedAudio(_ clip: TimelineClip) -> Bool {
        guard case .media(let media) = resolvedInfo(for: clip.source) else { return false }
        return media.kind == .video && media.hasAudio && clip.streams == .videoAndAudio
    }

    /// Whether `detachAudio` can take the clip's sound apart from its
    /// picture: a video clip's linked sound, or a nested timeline's, when
    /// anything in it makes sound.
    func canDetachAudio(_ clip: TimelineClip) -> Bool {
        if hasLinkedAudio(clip) { return true }
        guard case .timeline(let nestedID) = clip.source, clip.streams == .videoAndAudio else { return false }
        var visited: Set<UUID> = []
        return timelineMakesSound(nestedID, visited: &visited)
    }

    /// Whether a clip in the timeline, or in one nested in it, makes sound.
    private func timelineMakesSound(_ timelineID: UUID, visited: inout Set<UUID>) -> Bool {
        guard visited.insert(timelineID).inserted, let timeline = timeline(id: timelineID) else { return false }
        for layer in timeline.layers {
            for clip in layer.clips where playsAudio(clip) {
                guard case .timeline(let nestedID) = clip.source else { return true }
                if timelineMakesSound(nestedID, visited: &visited) { return true }
            }
        }
        return false
    }

    func layerHasLinkedAudio(_ layer: TimelineLayer) -> Bool {
        layer.clips.contains { hasLinkedAudio($0) }
    }

    /// Separates the sound from video clips and nested timelines on a layer
    /// (`canDetachAudio`): the clips keep only
    /// their picture, and their sound goes onto a new layer just below with
    /// the same timing and trims, and the fades it had under the picture's
    /// transitions (`soundTransitions`), so it plays as before but can be
    /// moved, trimmed or deleted on its own. `clipIDs` limits it to those
    /// clips; nil detaches every linked clip on the layer. The new layer is
    /// a sound layer. Returns it, or nil when there was nothing to detach.
    @discardableResult
    mutating func detachAudio(of clipIDs: Set<UUID>? = nil, in timelineID: UUID, layer layerID: UUID) -> UUID? {
        guard let tIndex = timelines.firstIndex(id: timelineID),
              let lIndex = timelines[tIndex].layers.firstIndex(id: layerID)
        else {
            return nil
        }
        var audioClips: [TimelineClip] = []
        // The layer as it played, for the fades its sound had there.
        let playing = timelines[tIndex].layers[lIndex].clips
        let timeline = timelines[tIndex]
        let detaching = Set(playing.filter { (clipIDs?.contains($0.id) ?? true) && canDetachAudio($0) }.map(\.id))
        for cIndex in timelines[tIndex].layers[lIndex].clips.indices {
            let clip = timelines[tIndex].layers[lIndex].clips[cIndex]
            guard detaching.contains(clip.id) else { continue }
            timelines[tIndex].layers[lIndex].clips[cIndex].streams = .video
            timelines[tIndex].layers[lIndex].clips[cIndex].soundMuted = false
            // The picture keeps its effects and the sound takes its own.
            timelines[tIndex].layers[lIndex].clips[cIndex].audioEffects = []
            var audio = clip
            audio.id = UUID()
            audio.streams = .audio
            // Sound muted as it was placed plays once it is on a layer of
            // its own: taking it out is what the mute was waiting for.
            audio.soundMuted = false
            soundTransitions(of: clip, into: &audio, among: playing, detaching: detaching, in: timeline)
            audio.autoMatteEnabled = false
            audio.effects = []
            audio.anchorPoint = AnimatedValue(Vector2.zero)
            audioClips.append(audio)
        }
        guard !audioClips.isEmpty else { return nil }
        // The sound keeps the volume it played at: each clip's own, which
        // copying the clip carried over.
        let layer = TimelineLayer(customName: nil, kind: .sound, clips: audioClips)
        timelines[tIndex].layers.insert(layer, at: lIndex + 1)
        return layer.id
    }

    /// Gives the sound of `clip`, being detached into `audio`, the fades it
    /// had under picture transitions, as transitions of sound, so it plays
    /// as it did. They were dropped, and detached sound came in and went
    /// out at full level (F99).
    ///
    /// At a cut joined to a clip whose sound is detached too, the two
    /// copies join as the pictures did (`canJoin`), with the joint's timing
    /// and the shape the sounds crossfaded with. Elsewhere the sound fades
    /// over the span it faded over, and where it played past its end into a
    /// joint that stays, the copy is lengthened by that much. A picture
    /// transition's sound at an open end follows its curve at equal power;
    /// a transition of sound has no curve, so the copy fades at equal power
    /// over the same span, the same fade where the curve was linear.
    private func soundTransitions(
        of clip: TimelineClip, into audio: inout TimelineClip, among clips: [TimelineClip], detaching: Set<UUID>, in timeline: Timeline
    ) {
        audio.transitionIn = nil
        audio.transitionOut = nil
        let heard = audioFades(of: clip, among: clips)
        func kind(_ shape: AudioCrossfade) -> TransitionKind {
            switch shape {
            case .sCurve: .crossfade
            case .equalPower: .equalPowerCrossfade
            case .linear: .linearCrossfade
            }
        }
        func sound(_ transition: ClipTransition) -> ClipTransition {
            let shape = transition.kind.soundShape ?? transition.audioCrossfade ?? jointAudioCrossfade
            return ClipTransition(kind: kind(shape), duration: transition.duration, curve: .linear, lead: transition.lead, options: kind(shape).defaultOptions)
        }
        func fade(_ fade: AudioFade) -> ClipTransition {
            let length = timeline.frameAligned(CMTime(seconds: fade.end - fade.start, preferredTimescale: 240_000), .nearest)
            return ClipTransition(kind: kind(fade.crossfade ?? .equalPower), duration: length, curve: .linear)
        }

        let joinedBefore = predecessor(joining: clip, among: clips).map { detaching.contains($0.id) } ?? false
        let joinedAfter = successor(joining: clip, among: clips).map { detaching.contains($0.id) } ?? false
        if joinedBefore {
            audio.transitionIn = clip.transitionIn.map(sound)
        } else if let rising = heard.fades.first(where: \.rising) {
            audio.startOffset = CMTimeSubtract(audio.startOffset, heard.head)
            audio.trimStart = CMTimeSubtract(audio.trimStart, heard.head)
            audio.transitionIn = fade(rising)
        }
        if joinedAfter {
            audio.transitionOut = clip.transitionOut.map(sound)
        } else if let falling = heard.fades.first(where: { !$0.rising }) {
            audio.trimEnd = CMTimeAdd(audio.trimEnd, heard.tail)
            audio.transitionOut = fade(falling)
        }
    }
}
