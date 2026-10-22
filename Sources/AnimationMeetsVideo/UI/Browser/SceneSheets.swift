import CoreMedia
import SwiftUI

// Splitting and merging scenes, and the sensitivity of a stretch of them,
// are in the scene splitter (`SceneSplitter`); this is the sensitivity of
// a whole media file, from its menu.

struct SensitivityTarget: Identifiable {
    let id = UUID()
    var assetID: UUID
}

/// The cut sensitivity of a whole media file, replacing the project default
/// for it. Nothing changes until Apply, which also splits and joins the
/// timeline clips cut from its scenes.
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
        _draft = State(initialValue: current.mediaClip(id: target.assetID)?.sceneEdits.sensitivity ?? current.defaultSensitivity)
    }

    private func change(_ edits: inout SceneEdits) {
        edits.sensitivity = draft
    }

    private var currentScenes: [SceneRange] {
        project.scenes(ofAsset: target.assetID, track: track)
    }

    private var previewScenes: [SceneRange] {
        project.scenesPreviewing(ofAsset: target.assetID, track: track, applying: change)
    }

    /// Clips on a timeline whose animation runs across a cut this would add.
    private var animatedClips: Int {
        let cuts = SceneCutChange(from: currentScenes, to: previewScenes)
        return project.clipsAnimated(across: cuts.added, ofAsset: target.assetID).count
    }

    private var frameRate: Double { project.mediaClip(id: target.assetID)?.frameRate ?? 24 }

    var body: some View {
        let preview = previewScenes
        let animated = animatedClips
        SheetFrame(
            title: "Cut sensitivity for this media",
            subtitle: "Applies to every scene in this media that isn't covered by a more specific setting.",
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

            if animated > 0 {
                SheetCallout(
                    .warning,
                    animated == 1
                        ? "A clip on a timeline has keyframes across a new cut. It will be put into a timeline of its own, split there, with its animation applied to that embedded timeline."
                        : "\(animated) clips on a timeline have keyframes across new cuts. Each will be put into a timeline of its own, split there, with its animation applied to that embedded timeline."
                )
            }
        } actions: {
            if project.mediaClip(id: target.assetID)?.sceneEdits.sensitivity != nil {
                Button("Use project default") {
                    project.editScenesFollowingClips(ofAsset: target.assetID, track: track) { $0.sensitivity = nil }
                    dismiss()
                }
                Spacer()
            }
            Button("Cancel", role: .cancel) { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(animated > 0 ? "Embed and Apply" : "Apply") {
                project.editScenesFollowingClips(ofAsset: target.assetID, track: track, change)
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
    }
}
