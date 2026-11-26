import CoreMedia
import Foundation

// Copying keyframes (see docs/parameter-rows.md, "Copying keyframes"):
// keyframes picked in the effects panel's lanes, copied with their times
// apart, their values and their eases, and pasted at the playhead onto
// the same controls of another clip, or onto one picked control.

/// Keyframes copied from controls, each control's apart, their times as
/// seconds from the earliest of them all, in the timeline's time.
struct CopiedKeyframes: Equatable, Codable, Sendable {
    struct Keyframe: Equatable, Codable, Sendable {
        var offset: Double
        var values: [Double]
        var easeIn: [Double]?
        var easeOut: [Double]?
        var hold: Bool?
    }

    struct Lane: Equatable, Codable, Sendable {
        /// The control they came from, as the timeline's rows match it.
        var key: ParameterRowKey
        var keyframes: [Keyframe]
    }

    var lanes: [Lane]

    var count: Int { lanes.reduce(0) { $0 + $1.keyframes.count } }

    /// As text for the pasteboard, which pastes into a text editor too.
    var json: String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(self)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Read back from the pasteboard's text; nil for text that isn't.
    init?(json: String) {
        guard let data = json.data(using: .utf8), let read = try? JSONDecoder().decode(CopiedKeyframes.self, from: data), read.count > 0
        else { return nil }
        self = read
    }

    init(lanes: [Lane]) {
        self.lanes = lanes
    }
}

extension EditingProject {
    /// The keyframes at `times` (source times) of each control of `clipID`
    /// in `picked`, by effect and control ID; nil with none, or none that
    /// can be a row.
    func copiedKeyframes(_ picked: [UUID: [UUID: [CMTime]]], ofClip clipID: UUID, in timelineID: UUID) -> CopiedKeyframes? {
        guard let clip = clipAndLayer(clipID, in: timelineID)?.clip else { return nil }
        var found: [(key: ParameterRowKey, keyframes: [(time: Double, frame: AnimationMeetsVideo.Keyframe<ComponentValue>)])] = []
        for (effectID, controls) in picked {
            for (controlID, times) in controls {
                guard let key = clip.parameterKey(effect: effectID, control: controlID),
                      let control = clip.parameter(key)?.control
                else { continue }
                let wanted = Set(times)
                let keyframes = control.number.keyframes.filter { wanted.contains($0.time) }.map {
                    (time: clip.timelineTime(forSourceTime: $0.time).seconds, frame: $0)
                }
                if !keyframes.isEmpty { found.append((key, keyframes)) }
            }
        }
        guard let earliest = found.flatMap({ $0.keyframes.map(\.time) }).min() else { return nil }
        func ease(_ ease: KeyframeEase?) -> [Double]? { ease.map { [$0.influence, $0.speed] } }
        let lanes = found.map { lane in
            CopiedKeyframes.Lane(key: lane.key, keyframes: lane.keyframes.sorted { $0.time < $1.time }.map { time, frame in
                CopiedKeyframes.Keyframe(
                    offset: time - earliest, values: frame.value.values, easeIn: ease(frame.easeIn), easeOut: ease(frame.easeOut),
                    hold: frame.hold ? true : nil
                )
            })
        }
        return CopiedKeyframes(lanes: lanes.sorted { ($0.key.effectKind, $0.key.ordinal, $0.key.control) < ($1.key.effectKind, $1.key.ordinal, $1.key.control) })
    }

    /// Pastes `copied` on `clipID` with its earliest keyframe at timeline
    /// `time`, each lane onto the same control of the clip (matched as the
    /// timeline's rows match them), or, with `onto` and one lane copied,
    /// onto that control when it has as many numbers. Pasted keyframes
    /// replace any at the same times. Returns how many were pasted.
    @discardableResult
    mutating func pasteKeyframes(
        _ copied: CopiedKeyframes, onClip clipID: UUID, in timelineID: UUID, at time: CMTime,
        onto: (effectID: UUID, controlID: UUID)? = nil
    ) -> Int {
        guard let clip = clipAndLayer(clipID, in: timelineID)?.clip else { return 0 }
        var pasted = 0
        for lane in copied.lanes {
            let target: (effectID: UUID, controlID: UUID)?
            if let onto, copied.lanes.count == 1 {
                target = onto
            } else {
                target = clip.parameter(lane.key).map { ($0.effect.id, $0.control.id) }
            }
            guard let target, let control = clip.effect(id: target.effectID)?.controls.first(where: { $0.id == target.controlID }),
                  control.isDrivable, let width = lane.keyframes.first?.values.count, control.number.value.values.count == width
            else { continue }
            func ease(_ numbers: [Double]?) -> KeyframeEase? {
                numbers.flatMap { $0.count == 2 ? KeyframeEase(influence: $0[0], speed: $0[1]) : nil }
            }
            let made = lane.keyframes.filter { $0.values.count == width }.map { frame in
                let at = CMTimeAdd(time, CMTime(seconds: frame.offset, preferredTimescale: ParameterTimeAxis.timescale))
                return AnimationMeetsVideo.Keyframe(
                    time: clip.sourceTime(atTimelineTime: at), value: ComponentValue(values: frame.values),
                    easeIn: ease(frame.easeIn), easeOut: ease(frame.easeOut), hold: frame.hold ?? false
                )
            }
            guard !made.isEmpty else { continue }
            let times = Set(made.map(\.time))
            editEffect(target.effectID, ofClip: clipID, in: timelineID) { effect in
                guard let c = effect.controlIndex(target.controlID) else { return }
                let number = effect.controls[c].number
                let kept = number.keyframes.filter { !times.contains($0.time) }
                effect.controls[c].number = AnimatedValue(number.value, keyframes: (kept + made).sorted { $0.time < $1.time })
            }
            pasted += made.count
        }
        return pasted
    }
}
