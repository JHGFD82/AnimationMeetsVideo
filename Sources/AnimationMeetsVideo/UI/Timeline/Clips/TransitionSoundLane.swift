import CoreMedia
import SwiftUI

/// The sound of a transition joining two clips, opened under its footage
/// lane when the transition is expanded: the outgoing clip's sound falling
/// and the incoming clip's rising across the transition, drawn in the
/// shape they crossfade with. The timing is the transition's, set in the
/// footage lane above; only the shape is chosen here (its menu, or the
/// picker beside the lane's name). Sound detached from its picture takes
/// no transitions, so a joint only has this lane while the sound is
/// attached.
struct TransitionSoundLane: View {
    let joint: TransitionJoint
    /// The project's shape, which the transition follows when it has none.
    let projectCrossfade: AudioCrossfade
    let pixelsPerSecond: CGFloat
    let width: CGFloat
    let onSetCrossfade: (AudioCrossfade?) -> Void

    static let height: CGFloat = 44

    private var shape: AudioCrossfade { joint.transition.audioCrossfade ?? projectCrossfade }

    var body: some View {
        let startX = joint.start.seconds * pixelsPerSecond
        let spanWidth = max(4, joint.transition.duration.seconds * pixelsPerSecond)
        let cutX = joint.lead.seconds * pixelsPerSecond
        let inset: CGFloat = 6
        let curveHeight = Self.height - inset * 2
        let tone = Design.ClipTone.audio.color

        ZStack(alignment: .topLeading) {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(tone.opacity(0.14))
                CrossfadeCurve(shape: shape, rising: false)
                    .stroke(tone.opacity(0.7), lineWidth: 1.5)
                    .frame(width: spanWidth, height: curveHeight)
                    .offset(y: inset)
                CrossfadeCurve(shape: shape, rising: true)
                    .stroke(Design.textOnColor.opacity(0.85), lineWidth: 1.5)
                    .frame(width: spanWidth, height: curveHeight)
                    .offset(y: inset)
                Rectangle()
                    .fill(Design.textOnColor.opacity(0.5))
                    .frame(width: 1, height: Self.height)
                    .offset(x: cutX)
            }
            .frame(width: spanWidth, height: Self.height, alignment: .topLeading)
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(tone, lineWidth: 1))
            .contentShape(Rectangle())
            .contextMenu { menu }
            .help("\(shape.name) crossfade of the two clips' sound. Its timing follows the transition; detach the sound to fade it by hand.")
            .offset(x: startX)
        }
        .frame(width: width, height: Self.height, alignment: .topLeading)
        .background(Design.Surface.well.color.opacity(0.5))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sound crossfade")
        .accessibilityValue(joint.transition.audioCrossfade == nil ? "\(shape.name), the project's" : shape.name)
        .accessibilityActions {
            Button("Use the project's shape") { onSetCrossfade(nil) }
            ForEach(AudioCrossfade.allCases) { option in
                Button("Use \(option.name)") { onSetCrossfade(option) }
            }
        }
    }

    @ViewBuilder
    private var menu: some View {
        Self.choices(selected: joint.transition.audioCrossfade, project: projectCrossfade, onSet: onSetCrossfade)
    }

    /// The shapes to choose from, the current one checked: the project's,
    /// then each shape. Shared by the lane's menu and its header's picker.
    @ViewBuilder
    static func choices(selected: AudioCrossfade?, project: AudioCrossfade, onSet: @escaping (AudioCrossfade?) -> Void) -> some View {
        Button { onSet(nil) } label: {
            let title = "Project (\(project.name))"
            if selected == nil { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
        Divider()
        ForEach(AudioCrossfade.allCases) { option in
            Button { onSet(option) } label: {
                if selected == option { Label(option.name, systemImage: "checkmark") } else { Text(option.name) }
            }
        }
    }
}

/// One side of a crossfade across its frame: the gain from bottom (silent)
/// to top (full), left to right.
private struct CrossfadeCurve: Shape {
    let shape: AudioCrossfade
    let rising: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let steps = 32
        for step in 0...steps {
            let progress = Double(step) / Double(steps)
            let gain = CGFloat(shape.gain(at: rising ? progress : 1 - progress))
            let point = CGPoint(x: rect.minX + rect.width * progress, y: rect.maxY - rect.height * gain)
            if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        return path
    }
}
