import AVFoundation
import CoreMedia
import Observation
import SwiftUI

/// The first and last frames of a clip while its edge is being rippled,
/// shown side by side over the viewer so the person sees exactly which
/// part of the footage the clip will play.
@MainActor
@Observable
final class TrimPreviewModel {
    private(set) var isActive = false
    private(set) var firstFrame: CGImage?
    private(set) var lastFrame: CGImage?
    /// The frames' times in the clip's source, for their labels.
    private(set) var firstTime: CMTime = .zero
    private(set) var lastTime: CMTime = .zero

    @ObservationIgnored private var url: URL?
    @ObservationIgnored private var request: Task<Void, Never>?
    @ObservationIgnored private var requested: (first: CMTime, last: CMTime)?

    /// Shows the frames of the file at `url` at the file times given.
    /// `labelFirst` and `labelLast` are the same frames in the clip's
    /// source time. Only the newest request is drawn.
    func show(url: URL, first: CMTime, last: CMTime, labelFirst: CMTime, labelLast: CMTime) {
        isActive = true
        firstTime = labelFirst
        lastTime = labelLast
        if url != self.url {
            self.url = url
            firstFrame = nil
            lastFrame = nil
            requested = nil
        }
        guard requested.map({ $0.first != first || $0.last != last }) ?? true else { return }
        requested = (first, last)
        request?.cancel()
        request = Task {
            let frames = await Self.frames(of: url, at: first, and: last)
            guard !Task.isCancelled else { return }
            if let image = frames.first { firstFrame = image }
            if let image = frames.last { lastFrame = image }
        }
    }

    private nonisolated static func frames(of url: URL, at first: CMTime, and last: CMTime) async -> (first: CGImage?, last: CGImage?) {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        generator.maximumSize = CGSize(width: 960, height: 540)
        let firstImage = try? await generator.image(at: first).image
        guard !Task.isCancelled else { return (nil, nil) }
        let lastImage = try? await generator.image(at: last).image
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

/// The two frames of a `TrimPreviewModel`, side by side.
struct TrimPreviewOverlay: View {
    let model: TrimPreviewModel
    let frameRate: Double
    let aspectRatio: CGFloat

    var body: some View {
        HStack(spacing: 12) {
            frame(model.firstFrame, label: "First frame", time: model.firstTime)
            frame(model.lastFrame, label: "Last frame", time: model.lastTime)
        }
        .padding(16)
        .background(Color.black.opacity(0.85))
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
                Spacer()
                Text(time.timecode(frameRate: frameRate))
                    .monospacedDigit()
            }
            .font(.caption)
            .foregroundStyle(.white.opacity(0.85))
        }
    }
}
