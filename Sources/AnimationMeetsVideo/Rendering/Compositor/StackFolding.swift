import CoreGraphics
import CoreMedia
import Foundation

/// Where a clip's picture is and how opaque, after the Position, Scale,
/// Rotation and Opacity steps of its stack.
struct FoldedPlacement: Equatable {
    /// Maps the fitted picture to where it is drawn, in the frame's
    /// coordinates (pixels, origin top left, y down).
    var matrix = CGAffineTransform.identity
    var opacity = 1.0
    /// Where the anchor point is in the frame.
    var anchor: CGPoint

    /// Applies one Transform control. Steps work on the picture as it is on
    /// screen: Position moves along the screen's axes, and Scale and
    /// Rotation turn about the anchor, wherever it is.
    mutating func apply(_ control: EffectControl, movesAnchor: Bool, at time: CMTime) {
        guard control.enabled, !control.isNoOp else { return }
        let values = control.values(at: time)
        switch control.kind {
        case .position:
            guard values.count == 2 else { return }
            matrix = matrix.concatenating(CGAffineTransform(translationX: values[0], y: values[1]))
            if movesAnchor { anchor = CGPoint(x: anchor.x + values[0], y: anchor.y + values[1]) }
        case .scale:
            guard values.count == 2 else { return }
            matrix = aboutAnchor(CGAffineTransform(scaleX: values[0] / 100, y: values[1] / 100))
        case .rotation:
            guard let degrees = values.first else { return }
            matrix = aboutAnchor(CGAffineTransform(rotationAngle: degrees * .pi / 180))
        case .opacity:
            guard let percent = values.first else { return }
            opacity *= min(max(percent / 100, 0), 1)
        default:
            break
        }
    }

    /// `matrix` followed by `change`, applied about the anchor.
    private func aboutAnchor(_ change: CGAffineTransform) -> CGAffineTransform {
        matrix
            .concatenating(CGAffineTransform(translationX: -anchor.x, y: -anchor.y))
            .concatenating(change)
            .concatenating(CGAffineTransform(translationX: anchor.x, y: anchor.y))
    }
}

/// One step of a clip's stack as the compositor draws it at a moment.
/// Consecutive Position, Scale, Rotation and Opacity steps are folded into
/// one `place`, so the picture is sampled once however many there are; a
/// step that reads another picture ends the run.
enum ResolvedStep: Equatable, Sendable {
    /// Moves the picture by `matrix` (in the frame's pixels, origin top
    /// left) and multiplies its alpha by `opacity`.
    case place(matrix: CGAffineTransform, opacity: Double)
    /// Keeps the picture as it is here, for a Blending step lower in the
    /// stack to blend against: it is how the picture was just before the
    /// effect with this ID.
    case mark(UUID)
    /// Blends the picture with the backdrop, or with the picture kept at
    /// the mark `against`. `amount` is 0...1.
    case blend(mode: BlendMode, amount: Double, against: UUID?)
    /// Grades the picture's color, a run of Color steps in the order listed.
    case color([ColorOp])
    /// Cuts the picture with the input of the effect with this ID. `amount`
    /// is 0...1.
    case matte(effect: UUID, mode: MatteMode, amount: Double)
    /// Draws a shape over the picture.
    case shape(ShapeStep)
    /// Strokes the outline of the shapes above, their strokes included.
    case outlineStroke(ShapeStroke)
}

enum StackFolding {
    /// The placement the stack's Transform effects give the fitted picture
    /// at source time `time`, as if nothing but them were in it.
    /// `center` is the center of the picture, where the anchor point's
    /// offset is measured from.
    static func fold(effects: [Effect], anchorPoint: AnimatedValue<Vector2>, at time: CMTime, center: CGPoint) -> FoldedPlacement {
        let offset = anchorPoint.value(at: time)
        var placement = FoldedPlacement(anchor: CGPoint(x: center.x + offset.x, y: center.y + offset.y))
        for effect in effects where effect.enabled && effect.kind == .transform {
            for control in effect.controls {
                placement.apply(control, movesAnchor: effect.movesAnchor, at: time)
            }
        }
        return placement
    }

    /// The steps to draw for the stack at source time `time`: nothing while
    /// every control is at its default.
    static func steps(effects: [Effect], anchorPoint: AnimatedValue<Vector2>, at time: CMTime, center: CGPoint) -> [ResolvedStep] {
        let offset = anchorPoint.value(at: time)
        var placement = FoldedPlacement(anchor: CGPoint(x: center.x + offset.x, y: center.y + offset.y))
        var colors: [ColorOp] = []
        var steps: [ResolvedStep] = []
        // What has built up becomes steps; the anchor keeps its place in the
        // frame, so what follows turns about it as before. Moving a picture
        // and grading its color don't depend on each other, so a run of both
        // is one move and one grade whatever order they were listed in.
        func flush() {
            if placement.matrix != .identity || placement.opacity != 1 {
                steps.append(.place(matrix: placement.matrix, opacity: placement.opacity))
                placement.matrix = .identity
                placement.opacity = 1
            }
            if !colors.isEmpty {
                steps.append(.color(colors))
                colors = []
            }
        }
        let targets = Set(effects.compactMap { $0.kind == .blending && $0.enabled ? $0.against : nil })

        for effect in effects {
            if targets.contains(effect.id) {
                flush()
                steps.append(.mark(effect.id))
            }
            guard effect.enabled else { continue }
            switch effect.kind {
            case .transform:
                for control in effect.controls {
                    placement.apply(control, movesAnchor: effect.movesAnchor, at: time)
                }
            case .color:
                for control in effect.controls where control.enabled && !control.isNoOp {
                    if let op = ColorOp(control, at: time) { colors.append(op) }
                }
            case .matte:
                // Without a picture to cut with there is nothing to do.
                guard effect.input != nil, let take = effect.control(.matteMode), take.enabled else { continue }
                var amount = 1.0
                if let control = effect.control(.amount), control.enabled, let percent = control.values(at: time).first {
                    amount = min(max(percent / 100, 0), 1)
                }
                guard amount > 0 else { continue }
                flush()
                steps.append(.matte(effect: effect.id, mode: take.matteMode, amount: amount))
            case .rectangle, .ellipse, .polygon, .star:
                // Drawn over what the steps above made of the picture, so
                // they come first.
                guard let shape = ShapeStep(effect, at: time, center: center) else { continue }
                flush()
                steps.append(.shape(shape))
            case .stroke:
                guard let style = ShapeStroke(effect, at: time) else { continue }
                flush()
                steps.append(.outlineStroke(style))
            case .blending:
                guard let mode = effect.control(.mode), mode.enabled, mode.blendMode != .normal else { continue }
                var amount = 1.0
                if let control = effect.control(.amount), control.enabled, let percent = control.values(at: time).first {
                    amount = min(max(percent / 100, 0), 1)
                }
                guard amount > 0 else { continue }
                flush()
                steps.append(.blend(mode: mode.blendMode, amount: amount, against: effect.against))
            case .equalizer, .compressor, .limiter, .voiceIsolation:
                // Sound effects live in a clip's `audioEffects`, played by
                // its audio track's tap.
                continue
            case .beatKeys, .wiggler, .oscillator, .smoother, .looper, .timeStep, .overshoot:
                // Keyframing effects draw nothing: the keyframes they wrote
                // are on the controls below.
                continue
            }
        }
        flush()
        return steps
    }
}
