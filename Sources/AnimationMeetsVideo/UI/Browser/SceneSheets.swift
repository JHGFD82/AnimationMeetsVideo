import AppKit
import AVFoundation
import CoreMedia
import Observation
import SwiftUI

// MARK: - Preview

@MainActor
@Observable
final class ScenePreviewModel {
    let player = AVPlayer()
    let start: CMTime
    let end: CMTime
    /// Added to a time in the original to get a time in the file.
    let offset: CMTime
    private(set) var position: Double
    private(set) var isPlaying = false
    @ObservationIgnored private var observer: Any?

    init(url: URL, start: CMTime, end: CMTime, offset: CMTime = .zero) {
        self.start = start
        self.end = end
        self.offset = offset
        position = start.seconds
        let item = AVPlayerItem(asset: MediaFile.asset(at: url))
        item.forwardPlaybackEndTime = CMTimeAdd(end, offset)
        player.replaceCurrentItem(with: item)
        player.seek(to: CMTimeAdd(start, offset), toleranceBefore: .zero, toleranceAfter: .zero)
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                let original = CMTimeSubtract(time, self.offset)
                self.position = original.seconds
                if self.isPlaying, CMTimeCompare(original, self.end) >= 0 || self.player.rate == 0 {
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
        player.seek(to: CMTimeAdd(CMTime(seconds: clamped, preferredTimescale: 600), offset), toleranceBefore: .zero, toleranceAfter: .zero)
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
        let offset = project.wrappedValue.mediaClip(id: target.assetID)?.alignmentOffset ?? .zero
        _model = State(initialValue: ScenePreviewModel(url: target.url, start: target.scene.start, end: target.scene.end, offset: offset))
    }

    private var frameRate: Double { project.mediaClip(id: target.assetID)?.frameRate ?? 24 }

    private var splitTime: CMTime {
        let raw = CMTime(seconds: model.position, preferredTimescale: 600)
        let mapping = project.mediaClip(id: target.assetID)?.timeMapping ?? .identity
        return track?.nearestFrameTime(
            toOriginal: raw, mapping: mapping, within: CMTimeRange(start: target.scene.start, end: target.scene.end)
        ) ?? raw
    }

    private var canSplit: Bool {
        CMTimeCompare(splitTime, target.scene.start) > 0 && CMTimeCompare(splitTime, target.scene.end) < 0
    }

    var body: some View {
        SheetFrame(
            title: "Scene \(target.number)",
            subtitle: "Play through the scene and split it where it should start again.",
            width: 520
        ) {
            PlayerLayerView(player: model.player)
                .frame(width: 480, height: 270)
                .background(Design.Surface.well.color)
                .overlay {
                    Rectangle()
                        .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                }

            HStack(spacing: Design.Space.group) {
                Button {
                    model.togglePlayback()
                } label: {
                    Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                        .frame(width: 16)
                        .contentTransition(.symbolEffect(.replace))
                }
                .accessibilityLabel(model.isPlaying ? "Pause" : "Play")
                Slider(
                    value: Binding(get: { model.position }, set: { model.seek(to: $0) }),
                    in: target.scene.start.seconds...max(target.scene.end.seconds, target.scene.start.seconds + 0.001)
                )
                .accessibilityLabel("Position in the scene")
                .accessibilityValue(CMTime(seconds: model.position, preferredTimescale: 600).compactTimecode(frameRate: frameRate))
                Text(CMTime(seconds: model.position, preferredTimescale: 600).compactTimecode(frameRate: frameRate))
                    .font(Design.Typeface.numericSmall)
                    .foregroundStyle(Design.textPrimary)
                    // The slider reads it as its value.
                    .accessibilityHidden(true)
            }
        } actions: {
            Button("Split here") {
                let time = splitTime
                project.editScenes(ofAsset: target.assetID) { $0.addCut(at: time) }
                dismiss()
            }
            .disabled(!canSplit)
            .help("Start a new scene at the frame shown")
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        // Done is its only way out, so Escape closes it too.
        .onExitCommand { dismiss() }
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
        SheetFrame(
            title: span == nil ? "Cut sensitivity for this media" : "Cut sensitivity for the selected scenes",
            subtitle: span == nil
                ? "Applies to every scene in this media that isn't covered by a more specific setting."
                : "Applies only between the selected scenes' outer edges. Scenes outside, and boundaries you placed by hand, are left alone.",
            width: Design.SheetWidth.standard
        ) {
            SheetSection("Sensitivity") {
                HStack(spacing: Design.Space.step) {
                    Text("Fewer cuts")
                        .font(Design.Typeface.label)
                        .foregroundStyle(Design.textTertiary)
                        .accessibilityHidden(true)
                    Slider(value: $draft, in: 0...1)
                        .accessibilityLabel("Sensitivity")
                        .accessibilityValue("\(Int((draft * 100).rounded())) percent, \(preview.count) scene\(preview.count == 1 ? "" : "s")")
                        .accessibilityHint("Higher finds more cuts")
                    Text("More cuts")
                        .font(Design.Typeface.label)
                        .foregroundStyle(Design.textTertiary)
                        .accessibilityHidden(true)
                }
                HStack(spacing: Design.Space.tight) {
                    Text("\(currentScenes.count)")
                        .font(Design.Typeface.numeric)
                        .foregroundStyle(Design.textPrimary)
                    Text("scene\(currentScenes.count == 1 ? "" : "s") now,")
                        .font(Design.Typeface.body)
                        .foregroundStyle(Design.textSecondary)
                    Text("\(preview.count)")
                        .font(Design.Typeface.numeric)
                        .foregroundStyle(Design.accent)
                    Text("with this setting")
                        .font(Design.Typeface.body)
                        .foregroundStyle(Design.textSecondary)
                }
            }

            SheetSection("Scenes this would make") {
                List(Array(preview.enumerated()), id: \.element.id) { _, scene in
                    HStack {
                        Text(scene.start.compactTimecode(frameRate: frameRate))
                            .foregroundStyle(Design.textPrimary)
                        Spacer()
                        Text(scene.duration.formatted)
                            .foregroundStyle(Design.textTertiary)
                    }
                    .font(Design.Typeface.numericSmall)
                }
                .frame(height: 160)
                .scrollContentBackground(.hidden)
                .background(Design.Surface.sunken.color, in: RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous))
            }
        } actions: {
            if span == nil, project.mediaClip(id: target.assetID)?.sceneEdits.sensitivity != nil {
                Button("Use project default") {
                    project.editScenes(ofAsset: target.assetID) { $0.sensitivity = nil }
                    dismiss()
                }
                Spacer()
            }
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
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
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
    }
}
