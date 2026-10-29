import CoreMedia
import Foundation

/// The motion designer's points on a clip, kept with the speed they were
/// written as, so the designer opens on them again (hits, eases and all)
/// instead of reading them back from keyframes (see
/// docs/motion-designer.md, "Opening on keyframed clips"). They stand only
/// while the clip's speed is still that speed: changing it anywhere else
/// leaves them behind.
struct MotionDesign: Equatable, Sendable {
    /// A point, without where it plays: the clip's speed places it.
    struct Point: Equatable, Sendable {
        var source: CMTime
        var kind: TimePoint.Kind
        var easeIn: KeyframeEase?
        var easeOut: KeyframeEase?
        var smooth = false
    }

    var points: [Point]
    /// The handles of the keyframes on the clip's first and last frames.
    var startEase: KeyframeEase?
    var endEase: KeyframeEase?
    /// The speed the points were written as.
    var speed: AnimatedValue<Double>

    init(points: [Point], startEase: KeyframeEase? = nil, endEase: KeyframeEase? = nil, speed: AnimatedValue<Double>) {
        self.points = points
        self.startEase = startEase
        self.endEase = endEase
        self.speed = speed
    }

    init(_ map: ClipTimeMap, speed: AnimatedValue<Double>) {
        points = map.points.map { Point(source: $0.source, kind: $0.kind, easeIn: $0.easeIn, easeOut: $0.easeOut, smooth: $0.smooth) }
        startEase = map.edgeEase(.start)
        endEase = map.edgeEase(.end)
        self.speed = speed
    }
}
