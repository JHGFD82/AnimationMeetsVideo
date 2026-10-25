import AVFoundation
import CoreMedia
import Observation
import SwiftUI

/// Which of a clip's frames the trim preview shows: both ends while its
/// footage is slipped, or the end being trimmed.
enum TrimPreviewFrames: Equatable {
    case both, first, last

    var showsFirst: Bool { self != .last }
    var showsLast: Bool { self != .first }
}

/// The first and last frames of a clip while its footage is being slipped,
/// shown side by side over the viewer so the person sees exactly which
/// part of the footage the clip will play; while an edge is trimmed, the
/// frame at that edge alone.
@MainActor
@Observable
final class TrimPreviewModel {
    private(set) var isActive = false
    private(set) var frames = TrimPreviewFrames.both
    private(set) var firstFrame: CGImage?
    private(set) var lastFrame: CGImage?
    /// The frames' times in the clip's source, for their labels.
    private(set) var firstTime: CMTime = .zero
    private(set) var lastTime: CMTime = .zero

    private struct Request: Equatable {
        var url: URL
        var first: CMTime
        var last: CMTime
        var frames: TrimPreviewFrames
    }

    @ObservationIgnored private var url: URL?
    @ObservationIgnored private var request: Task<Void, Never>?
    /// What the frames shown, or being read, are of.
    @ObservationIgnored private var requested: Request?
    /// The newest request, waiting for the one being read to finish.
    @ObservationIgnored private var waiting: Request?
    /// Counts reads, so one let go by `clear` doesn't start the next.
    @ObservationIgnored private var generation = 0

    /// Shows the frames of the file at `url` at the file times given.
    /// `labelFirst` and `labelLast` are the same frames in the clip's
    /// source time.
    ///
    /// A drag asks for a new frame at every step, faster than frames can be
    /// read. One read runs at a time and isn't cut short, and when it
    /// finishes the newest step's frame is read next, so the picture keeps
    /// following the pointer. Cancelling each read for the next showed
    /// nothing new until the drag paused.
    func show(url: URL, first: CMTime, last: CMTime, labelFirst: CMTime, labelLast: CMTime, frames: TrimPreviewFrames = .both) {
        isActive = true
        self.frames = frames
        firstTime = labelFirst
        lastTime = labelLast
        if url != self.url {
            self.url = url
            firstFrame = nil
            lastFrame = nil
            requested = nil
        }
        let wanted = Request(url: url, first: first, last: last, frames: frames)
        guard wanted != requested else {
            waiting = nil
            return
        }
        waiting = wanted
        readNext()
    }

    /// Reads the waiting request's frames, unless a read is under way, which
    /// reads it once done.
    private func readNext() {
        guard request == nil, let next = waiting else { return }
        waiting = nil
        requested = next
        let generation = generation
        request = Task {
            let images = await Self.frames(of: next.url, at: next.first, and: next.last, frames: next.frames)
            guard generation == self.generation else { return }
            request = nil
            if let image = images.first { firstFrame = image }
            if let image = images.last { lastFrame = image }
            readNext()
        }
    }

    private nonisolated static func frames(
        of url: URL, at first: CMTime, and last: CMTime, frames: TrimPreviewFrames
    ) async -> (first: CGImage?, last: CGImage?) {
        let generator = AVAssetImageGenerator(asset: MediaFile.asset(at: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: 960, height: 540)
        let firstImage = frames.showsFirst ? try? await generator.image(at: first).image : nil
        guard !Task.isCancelled else { return (nil, nil) }
        let lastImage = frames.showsLast ? try? await generator.image(at: last).image : nil
        return (firstImage, lastImage)
    }

    func clear() {
        generation += 1
        request?.cancel()
        request = nil
        requested = nil
        waiting = nil
        isActive = false
        firstFrame = nil
        lastFrame = nil
        url = nil
    }
}

/// The frames of a `TrimPreviewModel`, side by side.
struct TrimPreviewOverlay: View {
    let model: TrimPreviewModel
    let frameRate: Double
    let aspectRatio: CGFloat

    var body: some View {
        HStack(spacing: 12) {
            if model.frames.showsFirst { frame(model.firstFrame, label: "First frame", time: model.firstTime) }
            if model.frames.showsLast { frame(model.lastFrame, label: "Last frame", time: model.lastTime) }
        }
        .padding(Design.Space.rail)
        .background(Design.Surface.well.color.opacity(0.94), in: RoundedRectangle(cornerRadius: Design.Radius.panel, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Design.Radius.panel, style: .continuous)
                .strokeBorder(Design.bevelEdge, lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.5), radius: 16, y: 6)
    }

    private func frame(_ image: CGImage?, label: String, time: CMTime) -> some View {
        VStack(spacing: 6) {
            ZStack {
                Color.black
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                }
            }
            .aspectRatio(aspectRatio, contentMode: .fit)
            HStack {
                Text(label)
                    .font(Design.Typeface.label)
                    .foregroundStyle(Design.textSecondary)
                Spacer()
                Text(time.timecode(frameRate: frameRate))
                    .font(Design.Typeface.numericSmall)
                    .foregroundStyle(Design.textPrimary)
            }
        }
    }
}
