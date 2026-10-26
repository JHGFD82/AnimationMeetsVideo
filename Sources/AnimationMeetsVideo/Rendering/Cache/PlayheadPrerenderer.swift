import AVFoundation
import CoreMedia
import Foundation

/// While the viewer is paused, draws the frames around the playhead as
/// playing would draw them, keeping each clip's finished picture in the
/// viewer's `ClipPictureCache` (`Keeping.all`), so that pressing play
/// there takes the pictures instead of drawing them, and a stretch too
/// heavy to draw live plays smoothly for as far as was drawn. The classic
/// answer of an editor to "this section is too heavy", without waiting
/// for a background render of the whole stretch.
///
/// It starts half a second after the player settles, draws `aheadSeconds`
/// from the playhead and then `behindSeconds` before it, and stops before
/// its pictures would push its own first ones out of the cache. Any seek,
/// play, edit or change of size cancels it (`cancel`), and it waits while
/// the Mac is hot or in Low Power Mode. Stretches with nothing worth
/// keeping (plain pictures, renders) are skipped.
@MainActor
final class PlayheadPrerenderer {
    /// How long the player must stay paused before drawing starts.
    var settleSeconds = 0.5
    var aheadSeconds = 2.0
    var behindSeconds = 0.5
    /// The share of the cache's budget one pass fills before it stops.
    nonisolated static let budgetShare = 0.75

    private var task: Task<Void, Never>?
    /// The frames the last pass drew, for tests.
    private(set) var drawnTimes: [CMTime] = []

    /// Starts drawing around `time` from `videoComposition` (the player's, at
    /// the size it draws), after any pass under way is cancelled.
    func start(composition: AVComposition, videoComposition: AVVideoComposition, around time: CMTime) {
        cancel()
        let instructions = videoComposition.instructions.compactMap { $0 as? LayeredInstruction }
        guard let pictures = instructions.first?.options?.pictures,
              let times = Self.frames(around: time, of: videoComposition, ahead: aheadSeconds, behind: behindSeconds),
              let copy = videoComposition.mutableCopy() as? AVMutableVideoComposition
        else { return }
        // Only the stretches with something to keep, drawn keeping it all.
        let worth = times.filter { time in instructions.contains { $0.timeRange.containsTime(time) && $0.hasPicturesWorthKeeping } }
        guard !worth.isEmpty else { return }
        copy.instructions = copy.instructions.map { instruction in
            (instruction as? LayeredInstruction).map { $0.drawing($0.clips, keeping: .all) } ?? instruction
        }
        let settle = settleSeconds
        let handed = HandedOver(value: (composition, copy as AVVideoComposition))
        task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(settle))
            guard !Task.isCancelled, Self.machineIsFree else { return }
            let drawn = await Self.draw(worth, of: handed, into: pictures)
            if !Task.isCancelled { self?.drawnTimes = drawn }
        }
    }

    /// Draws `times` of the composition (`handed`, the timeline and the
    /// drawing that keeps everything) in order, one at a time so a cancel stops it within a
    /// frame, until this pass has kept its share of the cache's budget.
    /// Returns the times drawn.
    nonisolated private static func draw(
        _ times: [CMTime], of handed: HandedOver<(AVComposition, AVVideoComposition)>, into pictures: ClipPictureCache
    ) async -> [CMTime] {
        let (composition, videoComposition) = handed.value
        let generator = AVAssetImageGenerator(asset: composition)
        generator.videoComposition = videoComposition
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let limit = Int(Double(pictures.budget) * budgetShare)
        let startBytes = pictures.counts.keptBytes
        var drawn: [CMTime] = []
        for time in times {
            guard !Task.isCancelled, pictures.counts.keptBytes - startBytes < limit else { break }
            guard (try? await generator.image(at: time)) != nil else { break }
            drawn.append(time)
        }
        return drawn
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    /// Waits for the pass under way, for tests.
    func finish() async {
        await task?.value
    }

    /// The frame times from `time` to `ahead` seconds on, then back to
    /// `behind` seconds before it, nearest first, within the timeline.
    static func frames(around time: CMTime, of videoComposition: AVVideoComposition, ahead: Double, behind: Double) -> [CMTime]? {
        let frame = videoComposition.frameDuration
        guard frame.seconds > 0 else { return nil }
        let end = videoComposition.instructions.map(\.timeRange.end).max() ?? .zero
        // The frame the playhead is in.
        let index = Int64((time.seconds / frame.seconds + 1e-6).rounded(.down))
        let forward = Int64((ahead / frame.seconds).rounded()), backward = Int64((behind / frame.seconds).rounded())
        func at(_ n: Int64) -> CMTime { CMTimeMultiply(frame, multiplier: Int32(n)) }
        let later = (0...forward).map { at(index + $0) }.filter { $0 < end }
        let earlier = (0...backward).dropFirst().map { at(index - $0) }.filter { $0 >= .zero }
        return later + earlier
    }

    private static var machineIsFree: Bool {
        let thermal = ProcessInfo.processInfo.thermalState
        return thermal != .serious && thermal != .critical && !ProcessInfo.processInfo.isLowPowerModeEnabled
    }
}

extension LayeredInstruction {
    /// Whether any clip it draws may be kept (`ClipPictureCache`): one with
    /// effects or a transition, or mixing in frames of its footage. A
    /// plain picture, as a render plays, has nothing to keep.
    var hasPicturesWorthKeeping: Bool {
        func worth(_ clip: DrawClip) -> Bool {
            switch clip.content {
            case .group(let group):
                return group.children.contains(where: worth) || clip.stack.effects.contains(where: \.enabled)
            case .adjustment(let adjustment):
                return adjustment.reached.contains(where: worth)
            case .media(let media) where media.nextFrame != nil || !media.echoes.isEmpty:
                return true
            case .media, .graphic:
                return clip.stack.effects.contains(where: \.enabled) || clip.stack.hasTransitions
            }
        }
        return clips.contains(where: worth)
    }
}
