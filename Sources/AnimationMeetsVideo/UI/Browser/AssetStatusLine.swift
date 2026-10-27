import SwiftUI

/// What is going on with an asset, under its name in the Clips tab: the
/// analysis's progress and stage, a missing or changed file, a failure, or
/// a song's tempo. It reads the analysis itself, so each step of progress
/// redraws only this line, not the whole list of clips around it.
struct AssetStatusLine: View {
    let analysis: AssetAnalysis
    let replacement: MediaReplacementController
    let clip: MediaClip
    /// Whether the clip's filmstrip shows scene detection across its top
    /// (`SceneDetectionBar`), so this line leaves it out.
    var stripShowsDetection = false

    var body: some View {
        let detectingOnStrip = stripShowsDetection && SceneDetectionBar.fraction(of: clip, in: analysis) != nil
        if !detectingOnStrip, let fraction = analysis.progress[clip.id] {
            HStack(spacing: Design.Space.close) {
                ProgressView(value: fraction)
                    .controlSize(.small)
                    .frame(width: 60)
                Text(analysis.stages[clip.id]?.label ?? "Waiting…")
                    .font(Design.Typeface.label)
                    .foregroundStyle(Design.textTertiary)
            }
        } else if let fraction = analysis.progress[clip.id] {
            // Shown across the strip, which VoiceOver skips; said here.
            Color.clear
                .frame(width: 0, height: 0)
                .accessibilityLabel("detecting scenes, \(Int(fraction * 100)) percent")
        } else if replacement.missingMedia.contains(clip.id) {
            Text("File missing")
                .font(Design.Typeface.label)
                .foregroundStyle(Design.statusWarning)
                .help("Its clips play as gaps until the file is back. Control-click to replace it.")
        } else if let failure = analysis.firstFailure(for: clip.id) {
            Text(failure.title)
                .font(Design.Typeface.label)
                .foregroundStyle(Design.statusWarning)
                .help(failure.detail)
                .accessibilityHint(failure.detail)
        } else if analysis.changedFiles[clip.id] != nil {
            Text("File changed outside the app")
                .font(Design.Typeface.label)
                .foregroundStyle(Design.statusWarning)
                .help("Scenes and beats aren't found until the change is checked. Control-click and choose \u{201C}File Changed — Check Sync…\u{201D}.")
                .accessibilityHint("Scenes and beats aren't found until the change is checked.")
        } else if let problem = analysis.persistenceProblem(for: clip.id) {
            Text(problem.title)
                .font(Design.Typeface.label)
                .foregroundStyle(Design.statusWarning)
                .help(problem.detail)
                .accessibilityHint(problem.detail)
        } else if let beats = analysis.beats[clip.id], !beats.isEmpty {
            Text(ClipsTabModel.tempoText(beats))
                .font(Design.Typeface.numericMicro)
                .foregroundStyle(Design.textTertiary)
        }
    }
}
