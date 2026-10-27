import CoreGraphics
import CoreMedia
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// A frame at 29.97 fps, on the 30000 timescale.
private let ntscFrame = CMTime(value: 1001, timescale: 30000)

private func ntscFrames(_ count: Int64) -> CMTime {
    CMTime(value: count * 1001, timescale: 30000)
}

@Suite struct TransitionFrameKeyTests {
    private func expectMatchesFormatter(_ value: Double) {
        #expect(TransitionFrame.fiveDecimals(value) == String(format: "%.5f", value), "\(value)")
    }

    @Test func fiveDecimalsMatchesTheFormatterAtTheEdges() {
        let values: [Double] = [
            0, -0.0, 1, -1, 0.5, -0.5,
            0.000005, -0.000005, 0.000004, -0.000004, 0.0000049999, 0.0000050001,
            0.999995, -0.999995, 0.9999949999, 0.9999950001, 1.000005, 0.000015, 0.000025,
            1e-9, -1e-9, 1e-300, -1e-300, 0.1, 0.2, 0.3, 2.0 / 3, -2.0 / 3,
            1.2345649999, 1.234565, 9999.999995, 12345.678905, 1e5, -1e5, 1e12, -1e12,
            .greatestFiniteMagnitude, .infinity, -.infinity, .nan,
        ]
        values.forEach(expectMatchesFormatter)
    }

    /// The values most likely to be rounded the wrong way without the
    /// formatter: a half of the last decimal and a hair either side, for
    /// every last decimal from 0 to 1, both signs.
    @Test func fiveDecimalsMatchesTheFormatterAtEveryHalf() {
        for n in 0...100_000 {
            let half = (Double(n) + 0.5) / 100_000
            for value in [half, half.nextUp, half.nextDown] {
                expectMatchesFormatter(value)
                expectMatchesFormatter(-value)
            }
        }
    }

    /// The formatter is the slow way; it should only be needed close to a
    /// half. The values are spread evenly over -2...2 by the golden ratio,
    /// unlike a stride's, which (0.0000137 being 1.37 last decimals) puts
    /// every hundredth value on a half.
    @Test func fiveDecimalsRarelyNeedsTheFormatter() {
        let golden = (5.0.squareRoot() - 1) / 2
        let values = (0..<300_000).map { -2 + 4 * (Double($0) * golden).truncatingRemainder(dividingBy: 1) }
        values.forEach(expectMatchesFormatter)
        let fast = values.filter { TransitionFrame.fiveDecimalsWithoutFormatter($0) != nil }.count
        #expect(Double(fast) >= 0.99 * Double(values.count), "\(fast) of \(values.count)")
    }

    @Test func fiveDecimalsMatchesTheFormatterOverASweep() {
        // An awkward step lands everywhere between the decimals.
        for value in stride(from: -2.0, through: 2.0, by: 0.0000137) { expectMatchesFormatter(value) }
        // Halves of the last decimal, where rounding is closest to tipping.
        for step in -20_000...220_000 { expectMatchesFormatter(Double(step) * 0.000005) }
        // Whole last decimals, and a hair either side of them.
        for step in -1_000...101_000 {
            let value = Double(step) / 100_000
            expectMatchesFormatter(value)
            expectMatchesFormatter(value.nextUp)
            expectMatchesFormatter(value.nextDown)
        }
    }

    @Test func theKeyKeepsItsFormat() {
        var options = TransitionOptions()
        options.direction = .left
        options.color = TransitionColor(red: 0.25, green: 0.5, blue: 1)
        options.center = CGPoint(x: 0.125, y: 0.75)
        options.count = 12
        options.amount = 0.3
        let frame = TransitionFrame(kind: .blinds, options: options, progress: 0.123456, entering: false)
        #expect(frame.key == "blinds 0.12346 false left 0.2500,0.5000,1.0000 0.1250,0.7500 circle 12 random 0.3000 noise")
    }

    private static func options(_ change: (inout TransitionOptions) -> Void) -> TransitionOptions {
        var options = TransitionOptions()
        change(&options)
        return options
    }

    private static let matteID = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!

    /// Keys name cached renders on disk; these were printed by the key as
    /// it was before it was cached in parts (e2661da), so a change to any
    /// part of one leaves those files behind.
    private static let goldenKeys: [(frame: TransitionFrame, key: String)] = [
        (
            TransitionFrame(kind: .matteWipe, options: options { $0.matte = .clip(matteID) }, progress: 0.25, entering: true),
            "matteWipe 0.25000 true right 0.0000,0.0000,0.0000 0.5000,0.5000 circle 8 random 0.5000 6F9619FF-8B86-D011-B42D-00C04FC964FF"
        ),
        (
            TransitionFrame(kind: .matteWipe, options: options { $0.matte = .noise; $0.amount = 0.8 }, progress: 0.73125, entering: false),
            "matteWipe 0.73125 false right 0.0000,0.0000,0.0000 0.5000,0.5000 circle 8 random 0.8000 noise"
        ),
        (
            TransitionFrame(
                kind: .dipToColor, options: options { $0.color = TransitionColor(red: 0.12345, green: 0.5, blue: 0.987654) },
                progress: 1.0 / 3, entering: true
            ),
            "dipToColor 0.33333 true right 0.1235,0.5000,0.9877 0.5000,0.5000 circle 8 random 0.5000 noise"
        ),
        (
            TransitionFrame(
                kind: .crossZoom, options: options { $0.center = CGPoint(x: 0.2, y: 0.85); $0.amount = 0.65 },
                progress: 0.999995, entering: false
            ),
            "crossZoom 0.99999 false right 0.0000,0.0000,0.0000 0.2000,0.8500 circle 8 random 0.6500 noise"
        ),
        (
            TransitionFrame(kind: .blinds, options: options { $0.direction = .down; $0.count = 12 }, progress: 0, entering: true),
            "blinds 0.00000 true down 0.0000,0.0000,0.0000 0.5000,0.5000 circle 12 random 0.5000 noise"
        ),
        (
            TransitionFrame(kind: .iris, options: options { $0.shape = .diamond; $0.center = CGPoint(x: 0.3, y: 0.4) }, progress: 1, entering: true),
            "iris 1.00000 true right 0.0000,0.0000,0.0000 0.3000,0.4000 diamond 8 random 0.5000 noise"
        ),
        (
            TransitionFrame(kind: .grid, options: options { $0.order = .diagonal; $0.count = 5 }, progress: 0.5, entering: false),
            "grid 0.50000 false right 0.0000,0.0000,0.0000 0.5000,0.5000 circle 5 diagonal 0.5000 noise"
        ),
        (
            TransitionFrame(kind: .pageCurl, options: options { $0.direction = .up }, progress: -0.0000001, entering: true),
            "pageCurl -0.00000 true up 0.0000,0.0000,0.0000 0.5000,0.5000 circle 8 random 0.5000 noise"
        ),
        (
            TransitionFrame(
                kind: .ripple, options: options { $0.center = CGPoint(x: 0.0001, y: 0.99995); $0.amount = 0.33333 },
                progress: 1.0000049, entering: false
            ),
            "ripple 1.00000 false right 0.0000,0.0000,0.0000 0.0001,1.0000 circle 8 random 0.3333 noise"
        ),
        (
            TransitionFrame(kind: .morph, options: TransitionKind.morph.defaultOptions, progress: 0.000005, entering: true),
            "morph 0.00001 true right 0.0000,0.0000,0.0000 0.5000,0.5000 circle 8 random 1.0000 noise"
        ),
    ]

    @Test func keysMatchThoseOfCachedRenders() {
        for (frame, key) in Self.goldenKeys {
            #expect(frame.key == key)
        }
    }

    /// A frame a clip's transitions make carries the options key worked
    /// out when they were placed; it must read as one made afresh.
    @Test func aPlacedTransitionsKeyMatchesAFreshOne() throws {
        let options = Self.options { $0.matte = .clip(Self.matteID); $0.amount = 0.8 }
        var clip = TimelineClip(source: .media(UUID()), startOffset: .zero, trimStart: .zero, trimEnd: CMTime(value: 4, timescale: 1))
        clip.transitionIn = ClipTransition(kind: .matteWipe, duration: CMTime(value: 1, timescale: 1), options: options)
        let edges = try #require(EdgeTransitions(clip: clip, frameSize: CGSize(width: 100, height: 50)))
        let placed = try #require(edges.transitionFrame(at: CMTime(value: 1, timescale: 4)))
        let fresh = TransitionFrame(kind: .matteWipe, options: options, progress: placed.progress, entering: true)
        #expect(placed.key == fresh.key)
        #expect(placed.key == "matteWipe 0.25000 true right 0.0000,0.0000,0.0000 0.5000,0.5000 circle 8 random 0.8000 6F9619FF-8B86-D011-B42D-00C04FC964FF")
    }
}

@Suite struct EdgeTransitionsTimingTests {
    private let frameSize = CGSize(width: 100, height: 50)

    /// Where the clips start, in frames. Whether a transition's end lands
    /// exactly in seconds depends on where it is, so there are many.
    private static let starts: [Int64] = Array(stride(from: 15, to: 108_000, by: 997))

    /// How long the transitions are: a second, which isn't a whole number
    /// of frames, and lengths whose inverse isn't exact in seconds.
    private static let durations = [CMTime(value: 30000, timescale: 30000), ntscFrames(29), ntscFrames(10)]

    private static let leads = [CMTime.zero, ntscFrames(5)]

    /// A five second clip at 29.97 fps from frame `start`, with a
    /// transition of `kind` at each end.
    private func edges(
        _ kind: TransitionKind, curve: TransitionCurve = .linear, duration: CMTime, lead: CMTime, start: Int64
    ) throws -> EdgeTransitions {
        var clip = TimelineClip(source: .media(UUID()), startOffset: ntscFrames(start), trimStart: .zero, trimEnd: ntscFrames(150))
        clip.transitionIn = ClipTransition(kind: kind, duration: duration, curve: curve, lead: lead)
        clip.transitionOut = ClipTransition(kind: kind, duration: duration, curve: curve)
        return try #require(EdgeTransitions(clip: clip, frameSize: frameSize, lead: lead))
    }

    /// The fraction of the way in passed at `time`, as it was worked out
    /// before the times were kept in seconds; nil outside it.
    private func previousLeading(_ edges: EdgeTransitions, at time: CMTime) throws -> Double? {
        let leading = try #require(edges.leading)
        let elapsed = CMTimeSubtract(time, edges.leadingStart).seconds / leading.duration.seconds
        return elapsed < 1 ? elapsed : nil
    }

    private func previousTrailing(_ edges: EdgeTransitions, at time: CMTime) throws -> Double? {
        let trailing = try #require(edges.trailing)
        let elapsed = 1 - CMTimeSubtract(edges.end, time).seconds / trailing.duration.seconds
        return elapsed > 0 ? elapsed : nil
    }

    /// The times either side of each end of each transition, with whether
    /// a transition plays there.
    private func samples(_ edges: EdgeTransitions) throws -> [(time: CMTime, active: Bool)] {
        let leading = try #require(edges.leading), trailing = try #require(edges.trailing)
        let leadingEnd = CMTimeAdd(edges.leadingStart, leading.duration)
        return [
            (edges.leadingStart, true),
            (CMTimeSubtract(leadingEnd, ntscFrame), true),
            (leadingEnd, false),
            (CMTimeSubtract(edges.end, trailing.duration), false),
            (CMTimeSubtract(edges.end, ntscFrame), true),
            (edges.end, true),
        ]
    }

    @Test(arguments: durations, leads)
    func aDissolvePlaysOnTheSameFramesAsBefore(duration: CMTime, lead: CMTime) throws {
        for start in Self.starts {
            try expectDissolveAsBefore(edges(.crossDissolve, duration: duration, lead: lead, start: start))
        }
    }

    @Test(arguments: durations, leads)
    func aTwoPictureTransitionPlaysOnTheSameFramesAndKeysAsBefore(duration: CMTime, lead: CMTime) throws {
        let curve = TransitionCurve(preset: .easyEase)
        for start in Self.starts {
            try expectTwoPicturesAsBefore(edges(.push, curve: curve, duration: duration, lead: lead, start: start), curve: curve)
        }
    }

    private func expectDissolveAsBefore(_ edges: EdgeTransitions) throws {
        for (time, active) in try samples(edges) {
            let leading = try previousLeading(edges, at: time), trailing = try previousTrailing(edges, at: time)
            #expect((leading != nil || trailing != nil) == active, "\(time.seconds)")
            var opacity = 1.0
            if let leading { opacity *= TransitionCurve.linear.value(at: leading).clamped(between: 0, and: 1) }
            if let trailing { opacity *= (1 - TransitionCurve.linear.value(at: trailing)).clamped(between: 0, and: 1) }
            let effect = edges.effect(at: time)
            #expect(abs(effect.opacity - opacity) < 1e-9, "\(time.seconds)")
            #expect((effect.opacity < 1) == active, "\(time.seconds)")
        }
    }

    private func expectTwoPicturesAsBefore(_ edges: EdgeTransitions, curve: TransitionCurve) throws {
        for (time, active) in try samples(edges) {
            let frame = edges.transitionFrame(at: time)
            #expect((frame != nil) == active, "\(time.seconds)")
            let previous: Double? = if let leading = try previousLeading(edges, at: time) {
                curve.value(at: max(leading, 0))
            } else if let trailing = try previousTrailing(edges, at: time) {
                curve.value(at: min(trailing, 1))
            } else {
                nil
            }
            guard let frame, let previous else {
                #expect(frame == nil && previous == nil, "\(time.seconds)")
                continue
            }
            #expect(abs(frame.progress - previous) < 1e-9, "\(time.seconds)")
            // The progress names the cached render, so it must read the same.
            #expect(TransitionFrame.fiveDecimals(frame.progress) == String(format: "%.5f", previous), "\(time.seconds)")
        }
    }
}

@Suite struct MixedEdgeTransitionsTests {
    private let frameSize = CGSize(width: 100, height: 50)

    private func seconds(_ value: Double) -> CMTime {
        CMTime(seconds: value, preferredTimescale: 600)
    }

    /// A four second clip at ten seconds with a one second transition at
    /// each end.
    private func edges(leading: TransitionKind, trailing: TransitionKind) throws -> EdgeTransitions {
        var clip = TimelineClip(source: .media(UUID()), startOffset: seconds(10), trimStart: .zero, trimEnd: seconds(4))
        clip.transitionIn = ClipTransition(kind: leading, duration: seconds(1))
        clip.transitionOut = ClipTransition(kind: trailing, duration: seconds(1))
        return try #require(EdgeTransitions(clip: clip, frameSize: frameSize))
    }

    @Test func aWipeOutStillCropsWhileACubeComesIn() throws {
        let edges = try edges(leading: .cube, trailing: .wipe)
        let whole = CGRect(origin: .zero, size: frameSize)

        let comingIn = edges.effect(at: seconds(10.5))
        #expect(comingIn.visibleRect == whole)
        #expect(comingIn.opacity == 1 && comingIn.transform == .identity)
        #expect(edges.transitionFrame(at: seconds(10.5))?.kind == .cube)

        #expect(edges.effect(at: seconds(12)).visibleRect == whole)
        #expect(edges.transitionFrame(at: seconds(12)) == nil)

        #expect(edges.effect(at: seconds(13.5)).visibleRect == CGRect(x: 50, y: 0, width: 50, height: 50))
        #expect(edges.transitionFrame(at: seconds(13.5)) == nil)
    }

    @Test func aFilmDissolveStillKeysBeforeAPushOut() throws {
        let edges = try edges(leading: .filmDissolve, trailing: .push)

        let comingIn = edges.effect(at: seconds(10.5))
        #expect(comingIn.lumaReveal == LumaReveal(progress: 0.5, keysIncoming: true))
        #expect(edges.transitionFrame(at: seconds(10.5)) == nil)

        #expect(edges.effect(at: seconds(12)).lumaReveal == nil)

        #expect(edges.effect(at: seconds(13.5)).lumaReveal == nil)
        let goingOut = try #require(edges.transitionFrame(at: seconds(13.5)))
        #expect(goingOut.kind == .push && !goingOut.entering)
        #expect(abs(goingOut.progress - 0.5) < 1e-9)
    }
}
