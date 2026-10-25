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

    @ObservationIgnored private var url: URL?
    @ObservationIgnored private var request: Task<Void, Never>?
    @ObservationIgnored private var requested: (first: CMTime, last: CMTime, frames: TrimPreviewFrames)?

    /// Shows the frames of the file at `url` at the file times given.
    /// `labelFirst` and `labelLast` are the same frames in the clip's
    /// source time. Only the newest request is drawn.
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
        guard requested.map({ $0.first != first || $0.last != last || $0.frames != frames }) ?? true else { return }
        requested = (first, last, frames)
        request?.cancel()
        request = Task {
            let images = await Self.frames(of: url, at: first, and: last, frames: frames)
            guard !Task.isCancelled else { return }
            if let image = images.first { firstFrame = image }
            if let image = images.last { lastFrame = image }
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
        request?.cancel()
        request = nil
        requested = nil
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
