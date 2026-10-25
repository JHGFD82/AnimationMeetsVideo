import CoreMedia
import SwiftUI

/// What VoiceOver reads of a clip on the timeline, and the edits it
/// offers in place of the drags.
extension ClipBlockView {
    // MARK: VoiceOver

    /// What the clip is: its name and kind.
    var accessibilityName: String {
        let kind = switch info {
        case .timeline: "nested timeline"
        case .adjustment: "adjustment clip"
        case .graphic: "shape clip"
        case .media(let media) where media.kind == .audio || clip.streams == .audio: "audio clip"
        case .media(let media) where media.kind == .image: "still"
        case .media: "video clip"
        case nil: "missing clip"
        }
        return "\(info?.name ?? "Unknown"), \(kind)"
    }

    /// Where it is and what it carries, read after its name.
    var accessibilityDescription: String {
        var parts = [
            "starts at \(clip.startOffset.timecode(frameRate: frameRate))",
            "\(clip.placedDuration.timecode(frameRate: frameRate)) long",
        ]
        if let transition = clip.transitionIn { parts.append("\(transition.kind.name) at the start") }
        if let transition = clip.transitionOut { parts.append("\(transition.kind.name) at the end") }
        if !clip.enabled { parts.append("turned off") }
        if hasLinkedAudio { parts.append("with its own sound") }
        if playsSound, clip.soundMuted { parts.append("sound muted") }
        if let reach { parts.append("reaches \(reach.summary)") }
        if let time = musicPointTime(of: clip) { parts.append("tied to the music at \(time.timecode(frameRate: frameRate))") }
        return parts.joined(separator: ", ")
    }

    /// Moves and trims a frame at a time, and the clip's menu, for VoiceOver.
    /// They go through the same placement rules as dragging.
    @ViewBuilder
    var accessibilityEditActions: some View {
        let frame = Timeline.frameDuration(for: frameRate)
        Button("Move one frame earlier") {
            onMove(CMTimeMaximum(.zero, CMTimeSubtract(clip.startOffset, frame)), nil)
        }
        Button("Move one frame later") { onMove(CMTimeAdd(clip.startOffset, frame), nil) }
        if let onOpenNested { Button("Open timeline", action: onOpenNested) }
        if let piece = clip.footagePiece {
            Button("Show in clips browser") { NotificationCenter.default.post(name: .revealInBrowser, object: piece) }
        }
        Button(isInGroup ? "Remove from selection" : "Add to selection", action: onToggleInGroup)
        Button(clip.enabled ? "Turn off" : "Turn on") { onEditClip { $0.enabled.toggle() } }
        if playsSound {
            Button(clip.soundMuted ? "Unmute sound" : "Mute sound") { onEditClip { $0.soundMuted.toggle() } }
        }
        Button(isInGroup ? "Cut selection" : "Cut") { onClipboard(.cut) }
        Button(isInGroup ? "Copy selection" : "Copy") { onClipboard(.copy) }
        Button(isInGroup ? "Duplicate selection" : "Duplicate") { onClipboard(.duplicate) }
        Button(isInGroup ? "Put selection in new timeline" : "Put in new timeline") { onClipboard(.nest) }
        Button("Trim start one frame earlier") { onTrimStart(CMTimeSubtract(clip.trimStart, frame)) }
        Button("Trim start one frame later") { onTrimStart(CMTimeAdd(clip.trimStart, frame)) }
        Button("Trim end one frame earlier") { onTrimEnd(CMTimeSubtract(clip.trimEnd, frame)) }
        Button("Trim end one frame later") { onTrimEnd(CMTimeAdd(clip.trimEnd, frame)) }
        if let transition = clip.transitionIn, joinedLead == nil {
            Button("Remove \(transition.kind.name) at start") { onRemoveTransition(.leading) }
        }
        if let transition = clip.transitionOut {
            Button("Remove \(transition.kind.name) at end") { onRemoveTransition(.trailing) }
        }
        if hasLinkedAudio {
            Button("Detach audio", action: onDetachAudio)
        }
        if let onBeatMatch {
            Button("Beat match", action: onBeatMatch)
        }
        if let onRemoveBeats {
            Button("Remove beats", action: onRemoveBeats)
        }
        if let onAttachToMusic {
            Button(clip.followsMusic ? "Stop following music" : "Follow music") { onEditClip { $0.followsMusic.toggle() } }
            Button("Attach to music at playhead", action: onAttachToMusic)
        }
        if let onSetMusicPoint, let time = musicPointTime(of: clip) {
            let frame = Timeline.frameDuration(for: frameRate)
            Button("Music point one frame earlier") { onSetMusicPoint(clampedMusicPoint(CMTimeSubtract(time, frame))) }
            Button("Music point one frame later") { onSetMusicPoint(clampedMusicPoint(CMTimeAdd(time, frame))) }
        }
        if let onMotionDesign {
            Button(isInGroup ? "Open selection in motion designer" : "Open in motion designer", action: onMotionDesign)
        }
        if let reach {
            Button("Reach all layers below") { reach.onChoose(nil) }
            ForEach(reach.options, id: \.id) { option in
                Button("Reach down to \(option.name)") { reach.onChoose(option.id) }
            }
        }
    }
}
