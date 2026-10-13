import AppKit
import AVFoundation
import CoreMedia
import Observation
import SwiftUI

// MARK: - Selection and dragging

struct SceneKey: Hashable {
    var assetID: UUID
    var sceneID: String
}

/// Scenes being dragged from the browser to the timeline. It travels as plain
/// text so it works without a registered content type (this app runs
/// unbundled), and only scenes from one asset are carried at a time.
struct SceneDragPayload: Transferable {
    struct Entry: Codable, Equatable {
        var startValue: Int64
        var startScale: Int32
        var endValue: Int64
        var endScale: Int32
    }

    private struct Wire: Codable {
        var assetID: UUID
        var entries: [Entry]
    }

    private static let prefix = "amv-scenes:"

    var assetID: UUID
    var entries: [Entry]

    init(assetID: UUID, scenes: [SceneRange]) {
        self.assetID = assetID
        entries = scenes.map {
            Entry(startValue: $0.start.value, startScale: $0.start.timescale, endValue: $0.end.value, endScale: $0.end.timescale)
        }
    }

    init?(text: String) {
        guard text.hasPrefix(Self.prefix),
              let wire = try? JSONDecoder().decode(Wire.self, from: Data(text.dropFirst(Self.prefix.count).utf8)),
              !wire.entries.isEmpty,
              wire.entries.allSatisfy({ $0.startScale > 0 && $0.endScale > 0 })
        else { return nil }
        assetID = wire.assetID
        entries = wire.entries
    }

    var text: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = (try? encoder.encode(Wire(assetID: assetID, entries: entries))) ?? Data()
        return Self.prefix + String(decoding: data, as: UTF8.self)
    }

    var scenes: [SceneRange] {
        entries.map {
            SceneRange(
                start: CMTime(value: $0.startValue, timescale: $0.startScale),
                end: CMTime(value: $0.endValue, timescale: $0.endScale),
                origin: .auto
            )
        }
    }

    static var transferRepresentation: some TransferRepresentation {
        ProxyRepresentation(exporting: { $0.text }, importing: { text in
            guard let payload = SceneDragPayload(text: text) else { throw CocoaError(.coderInvalidValue) }
            return payload
        })
    }
}

// MARK: - Thumbnails

@MainActor
enum SceneThumbnailStore {
    private static let cache = NSCache<NSString, NSImage>()

    static func image(url: URL, time: CMTime) async -> NSImage? {
        let key = "\(url.path)|\(time.value)/\(time.timescale)" as NSString
        if let cached = cache.object(forKey: key) { return cached }
        guard let cgImage = await render(url: url, time: time) else { return nil }
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
        cache.setObject(image, forKey: key)
        return image
    }

    private nonisolated static func render(url: URL, time: CMTime) async -> CGImage? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 160, height: 90)
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        return try? await generator.image(at: time).image
    }
}

struct SceneThumbnail: View {
    let url: URL?
    let time: CMTime
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Rectangle().fill(.quaternary)
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            }
        }
        .frame(width: 64, height: 36)
        .clipShape(RoundedRectangle(cornerRadius: 3))
        .task(id: "\(time.value)/\(time.timescale)") {
            guard let url else { return }
            image = await SceneThumbnailStore.image(url: url, time: time)
        }
    }
}

struct SceneRowView: View {
    let clip: MediaClip
    let scene: SceneRange
    let number: Int

    var body: some View {
        HStack(spacing: 8) {
            SceneThumbnail(url: clip.url, time: scene.start)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text("Scene \(number)")
                    if scene.origin == .manual {
                        Image(systemName: "hand.point.up.left")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .help("Boundary set by hand")
                    }
                }
                Text("\(scene.start.compactTimecode(frameRate: clip.frameRate)) · \(scene.duration.formatted)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Preview

@MainActor
@Observable
final class ScenePreviewModel {
    let player = AVPlayer()
    let start: CMTime
    let end: CMTime
    private(set) var position: Double
    private(set) var isPlaying = false
    @ObservationIgnored private var observer: Any?

    init(url: URL, start: CMTime, end: CMTime) {
        self.start = start
        self.end = end
        position = start.seconds
        let item = AVPlayerItem(url: url)
        item.forwardPlaybackEndTime = end
        player.replaceCurrentItem(with: item)
        player.seek(to: start, toleranceBefore: .zero, toleranceAfter: .zero)
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.position = time.seconds
                if self.isPlaying, CMTimeCompare(time, self.end) >= 0 || self.player.rate == 0 {
                    self.isPlaying = false
                }
            }
        }
    }

    func togglePlayback() {
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            if position >= end.seconds - 0.05 { seek(to: start.seconds) }
            player.play()
            isPlaying = true
        }
    }

    func seek(to seconds: Double) {
        let clamped = min(max(seconds, start.seconds), end.seconds)
        position = clamped
        player.seek(to: CMTime(seconds: clamped, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func stop() {
        player.pause()
        isPlaying = false
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
    }
}

struct ScenePreviewTarget: Identifiable {
    let id = UUID()
    var assetID: UUID
    var url: URL
    var scene: SceneRange
    var number: Int
}

struct ScenePreviewSheet: View {
    @Binding var project: EditingProject
    let target: ScenePreviewTarget
    let track: ChangeScoreTrack?
    @Environment(\.dismiss) private var dismiss
    @State private var model: ScenePreviewModel

    init(project: Binding<EditingProject>, target: ScenePreviewTarget, track: ChangeScoreTrack?) {
        _project = project
        self.target = target
        self.track = track
        _model = State(initialValue: ScenePreviewModel(url: target.url, start: target.scene.start, end: target.scene.end))
    }

    private var frameRate: Double { project.mediaClip(id: target.assetID)?.frameRate ?? 24 }

    private var splitTime: CMTime {
        let raw = CMTime(seconds: model.position, preferredTimescale: 600)
        return track?.nearestFrameTime(to: raw) ?? raw
    }

    private var canSplit: Bool {
        CMTimeCompare(splitTime, target.scene.start) > 0 && CMTimeCompare(splitTime, target.scene.end) < 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Scene \(target.number)").font(.headline)

            PlayerLayerView(player: model.player)
                .frame(width: 480, height: 270)
                .background(.black)

            HStack(spacing: 10) {
                Button {
                    model.togglePlayback()
                } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill").frame(width: 16)
                }
                Slider(
                    value: Binding(get: { model.position }, set: { model.seek(to: $0) }),
                    in: target.scene.start.seconds...max(target.scene.end.seconds, target.scene.start.seconds + 0.001)
                )
                Text(CMTime(seconds: model.position, preferredTimescale: 600).compactTimecode(frameRate: frameRate))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Split Here") {
                    let time = splitTime
                    project.editScenes(ofAsset: target.assetID) { $0.addCut(at: time) }
                    dismiss()
                }
                .disabled(!canSplit)
                .help("Start a new scene at the frame shown")
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .onDisappear { model.stop() }
    }
}

// MARK: - Sensitivity

struct SensitivityTarget: Identifiable {
    enum Scope {
        /// The span of the selected scenes only.
        case span(start: CMTime, end: CMTime)
        /// The whole asset, replacing the project default for it.
        case asset
    }

    let id = UUID()
    var assetID: UUID
    var scope: Scope
}

struct SensitivitySheet: View {
    @Binding var project: EditingProject
    let target: SensitivityTarget
    let track: ChangeScoreTrack?
    @Environment(\.dismiss) private var dismiss
    @State private var draft: Double

    init(project: Binding<EditingProject>, target: SensitivityTarget, track: ChangeScoreTrack?) {
        _project = project
        self.target = target
        self.track = track
        let current = project.wrappedValue
        let edits = current.mediaClip(id: target.assetID)?.sceneEdits ?? SceneEdits()
        let initial: Double
        switch target.scope {
        case .span(let start, let end):
            let middle = CMTimeMultiplyByRatio(CMTimeAdd(start, end), multiplier: 1, divisor: 2)
            initial = SceneDetector.sensitivity(at: middle, defaultSensitivity: current.defaultSensitivity, edits: edits)
        case .asset:
            initial = edits.sensitivity ?? current.defaultSensitivity
        }
        _draft = State(initialValue: initial)
    }

    private var span: (start: CMTime, end: CMTime)? {
        if case .span(let start, let end) = target.scope { return (start, end) }
        return nil
    }

    private var currentScenes: [SceneRange] {
        project.scenesPreviewing(ofAsset: target.assetID, track: track, applying: { _ in }, within: span)
    }

    private var previewScenes: [SceneRange] {
        let value = draft
        let scope = target.scope
        return project.scenesPreviewing(ofAsset: target.assetID, track: track, applying: { edits in
            switch scope {
            case .span(let start, let end): edits.applySensitivity(value, from: start, to: end)
            case .asset: edits.sensitivity = value
            }
        }, within: span)
    }

    private var frameRate: Double { project.mediaClip(id: target.assetID)?.frameRate ?? 24 }

    var body: some View {
        let preview = previewScenes
        VStack(alignment: .leading, spacing: 12) {
            Text(span == nil ? "Cut Sensitivity for This Media" : "Cut Sensitivity for Selected Scenes")
                .font(.headline)
            Text(span == nil
                 ? "Applies to every scene in this media that isn't covered by a more specific setting."
                 : "Applies only between the selected scenes' outer edges. Scenes outside, and boundaries you placed by hand, are left alone.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Text("Fewer cuts").font(.caption).foregroundStyle(.secondary)
                Slider(value: $draft, in: 0...1)
                Text("More cuts").font(.caption).foregroundStyle(.secondary)
            }

            Text("\(currentScenes.count) scene\(currentScenes.count == 1 ? "" : "s") now, \(preview.count) with this setting")
                .font(.callout.monospacedDigit())

            List(Array(preview.enumerated()), id: \.element.id) { _, scene in
                HStack {
                    Text(scene.start.compactTimecode(frameRate: frameRate)).monospacedDigit()
                    Spacer()
                    Text(scene.duration.formatted).foregroundStyle(.secondary).monospacedDigit()
                }
                .font(.caption)
            }
            .frame(height: 160)

            HStack {
                if span == nil, project.mediaClip(id: target.assetID)?.sceneEdits.sensitivity != nil {
                    Button("Use Project Default") {
                        project.editScenes(ofAsset: target.assetID) { $0.sensitivity = nil }
                        dismiss()
                    }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Apply") {
                    let value = draft
                    let scope = target.scope
                    project.editScenes(ofAsset: target.assetID) { edits in
                        switch scope {
                        case .span(let start, let end): edits.applySensitivity(value, from: start, to: end)
                        case .asset: edits.sensitivity = value
                        }
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}
