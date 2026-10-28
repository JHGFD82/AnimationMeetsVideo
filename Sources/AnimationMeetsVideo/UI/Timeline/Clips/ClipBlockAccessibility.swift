import CoreMedia
import SwiftUI

/// What VoiceOver reads of a clip on the timeline, and the edits it
/// offers in place of the drags.
extension ClipBlockView {
    // MARK: VoiceOver

    /// What the clip is: its name and kind.
    var accessibilityName: String {
        let kind = switch model.info {
        case .timeline: "nested timeline"
        case .adjustment: "adjustment clip"
        case .graphic(let title): title == nil ? "shape clip" : "text clip"
        case .media(let media) where media.kind == .audio || model.clip.streams == .audio: "audio clip"
        case .media(let media) where media.kind == .image: "still"
        case .media: "video clip"
        case nil: "missing clip"
        }
        return "\(model.info?.name ?? "Unknown"), \(kind)"
    }

    /// Where it is and what it carries, read after its name. Made each
    /// time the block is drawn, as a drag draws it at every step, so the
    /// timecodes, the costly part, are kept while they read the same.
    var accessibilityDescription: String {
        let times = timecodes.timecodes(of: model.clip, frameRate: model.frameRate)
        var parts = [
            "starts at \(times.start)",
            "\(times.duration) long",
        ]
        if let transition = model.clip.transitionIn { parts.append("\(transition.kind.name) at the start") }
        if let transition = model.clip.transitionOut { parts.append("\(transition.kind.name) at the end") }
        if !model.clip.enabled { parts.append("turned off") }
        if model.hasLinkedAudio { parts.append("with its own sound") }
        if model.playsSound, model.clip.soundMuted { parts.append("sound muted") }
        if let reach = model.reach { parts.append("reaches \(reach.summary)") }
        if let time = musicPointTime(of: model.clip) { parts.append("tied to the music at \(time.timecode(frameRate: model.frameRate))") }
        return parts.joined(separator: ", ")
    }

    /// Moves and trims a frame at a time, and the clip's menu, for VoiceOver.
    /// They go through the same placement rules as dragging.
    @ViewBuilder
    var accessibilityEditActions: some View {
        let frame = Timeline.frameDuration(for: model.frameRate)
        Button("Move one frame earlier") {
            handlers.onMove(CMTimeMaximum(.zero, CMTimeSubtract(model.clip.startOffset, frame)), nil)
        }
        Button("Move one frame later") { handlers.onMove(CMTimeAdd(model.clip.startOffset, frame), nil) }
        if let onOpenNested = handlers.onOpenNested { Button("Open timeline", action: onOpenNested) }
        if let piece = model.clip.footagePiece {
            Button("Show in clips browser") { NotificationCenter.default.post(name: .revealInBrowser, object: piece) }
        }
        if let onConformTimeline = handlers.onConformTimeline { Button("Conform timeline to clip", action: onConformTimeline) }
        Button(model.isInGroup ? "Remove from selection" : "Add to selection", action: handlers.onToggleInGroup)
        Button(model.clip.enabled ? "Turn off" : "Turn on") { handlers.onEditClip { $0.enabled.toggle() } }
        if model.playsSound {
            Button(model.clip.soundMuted ? "Unmute sound" : "Mute sound") { handlers.onEditClip { $0.soundMuted.toggle() } }
        }
        Button(model.isInGroup ? "Cut selection" : "Cut") { handlers.onClipboard(.cut) }
        Button(model.isInGroup ? "Copy selection" : "Copy") { handlers.onClipboard(.copy) }
        Button(model.isInGroup ? "Duplicate selection" : "Duplicate") { handlers.onClipboard(.duplicate) }
        Button(model.isInGroup ? "Put selection in new timeline" : "Put in new timeline") { handlers.onClipboard(.nest) }
        Button("Trim start one frame earlier") { handlers.onTrimStart(CMTimeSubtract(model.clip.trimStart, frame)) }
        Button("Trim start one frame later") { handlers.onTrimStart(CMTimeAdd(model.clip.trimStart, frame)) }
        Button("Trim end one frame earlier") { handlers.onTrimEnd(CMTimeSubtract(model.clip.trimEnd, frame)) }
        Button("Trim end one frame later") { handlers.onTrimEnd(CMTimeAdd(model.clip.trimEnd, frame)) }
        if let transition = model.clip.transitionIn, model.joinedLead == nil {
            Button("Remove \(transition.kind.name) at start") { handlers.onRemoveTransition(.leading) }
        }
        if let transition = model.clip.transitionOut {
            Button("Remove \(transition.kind.name) at end") { handlers.onRemoveTransition(.trailing) }
        }
        if model.hasLinkedAudio {
            Button("Detach audio", action: handlers.onDetachAudio)
        }
        if let onBeatMatch = handlers.onBeatMatch {
            Button("Beat match", action: onBeatMatch)
        }
        if let onRemoveBeats = handlers.onRemoveBeats {
            Button("Remove beats", action: onRemoveBeats)
        }
        if let onAttachToMusic = handlers.onAttachToMusic {
            Button(model.clip.followsMusic ? "Stop following music" : "Follow music") { handlers.onEditClip { $0.followsMusic.toggle() } }
            Button("Attach to music at playhead", action: onAttachToMusic)
        }
        if let onSetMusicPoint = handlers.onSetMusicPoint, let time = musicPointTime(of: model.clip) {
            let frame = Timeline.frameDuration(for: model.frameRate)
            Button("Music point one frame earlier") { onSetMusicPoint(clampedMusicPoint(CMTimeSubtract(time, frame))) }
            Button("Music point one frame later") { onSetMusicPoint(clampedMusicPoint(CMTimeAdd(time, frame))) }
        }
        if let onMotionDesign = handlers.onMotionDesign {
            Button(model.isInGroup ? "Open selection in motion designer" : "Open in motion designer", action: onMotionDesign)
        }
        if let reach = model.reach {
            Button("Reach all layers below") { handlers.onSetReach(nil) }
            ForEach(reach.options) { option in
                Button("Reach down to \(option.name)") { handlers.onSetReach(option.id) }
            }
        }
    }
}

/// A clip's start and length as timecode, for VoiceOver, kept while
/// they are the same. In a box, so keeping them redraws nothing.
@MainActor
final class ClipTimecodeCache {
    private struct Key: Equatable {
        var start: CMTime
        var duration: CMTime
        var frameRate: Double
    }

    private var key: Key?
    private var value = (start: "", duration: "")

    func timecodes(of clip: TimelineClip, frameRate: Double) -> (start: String, duration: String) {
        let key = Key(start: clip.startOffset, duration: clip.placedDuration, frameRate: frameRate)
        if key != self.key {
            self.key = key
            value = (clip.startOffset.timecode(frameRate: frameRate), clip.placedDuration.timecode(frameRate: frameRate))
        }
        return value
    }
}
