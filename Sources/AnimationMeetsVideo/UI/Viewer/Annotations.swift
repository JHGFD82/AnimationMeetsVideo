import Observation
import SwiftUI

struct AnnotationStroke: Identifiable {
    let id = UUID()
    var points: [CGPoint]
}

/// Lightweight freehand markup for the external viewer. Deliberately simple
/// ink, not the full vector engine planned for a later milestone.
@Observable
final class AnnotationModel {
    var strokes: [AnnotationStroke] = []
    private(set) var liveStroke: AnnotationStroke?

    func beginStroke(at point: CGPoint) {
        liveStroke = AnnotationStroke(points: [point])
    }

    func appendPoint(_ point: CGPoint) {
        liveStroke?.points.append(point)
    }

    func endStroke() {
        if let liveStroke, liveStroke.points.count > 1 {
            strokes.append(liveStroke)
        }
        liveStroke = nil
    }

    func clear() {
        strokes.removeAll()
        liveStroke = nil
    }
}

struct AnnotationOverlay: View {
    let model: AnnotationModel

    var body: some View {
        Canvas { context, _ in
            for item in model.strokes {
                draw(item, in: context)
            }
            if let live = model.liveStroke {
                draw(live, in: context)
            }
        }
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if model.liveStroke == nil {
                        model.beginStroke(at: value.location)
                    } else {
                        model.appendPoint(value.location)
                    }
                }
                .onEnded { _ in
                    model.endStroke()
                }
        )
    }

    private func draw(_ item: AnnotationStroke, in context: GraphicsContext) {
        guard item.points.count > 1 else { return }
        var path = Path()
        path.move(to: item.points[0])
        for point in item.points.dropFirst() {
            path.addLine(to: point)
        }
        context.stroke(path, with: .color(.red), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
    }
}
