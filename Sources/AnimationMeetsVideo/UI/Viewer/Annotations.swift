import AppKit
import Observation
import QuartzCore
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
        // The drag is SwiftUI's; the ink over it only draws.
        Color.clear
            .contentShape(Rectangle())
            .overlay {
                InkLayers(strokes: model.strokes, live: model.liveStroke)
                    .allowsHitTesting(false)
            }
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
            .accessibilityElement()
            .accessibilityLabel("Annotations")
            .accessibilityValue(model.strokes.isEmpty ? "None" : "\(model.strokes.count) strokes")
            .accessibilityAction(named: "Clear annotations") { model.clear() }
    }
}

/// The ink, as two shape layers: one for the finished strokes and one for
/// the stroke being drawn. Each new point extends the live layer's path,
/// so drawing doesn't redraw every stroke under it the way a Canvas would;
/// the finished layer changes only when a stroke ends or the ink is
/// cleared.
private struct InkLayers: NSViewRepresentable {
    let strokes: [AnnotationStroke]
    let live: AnnotationStroke?

    func makeNSView(context: Context) -> InkView { InkView() }

    func updateNSView(_ view: InkView, context: Context) {
        view.show(strokes: strokes, live: live)
    }

    final class InkView: NSView {
        private let finished = CAShapeLayer()
        private let drawing = CAShapeLayer()
        private var finishedPath = CGMutablePath()
        /// The finished strokes `finishedPath` holds, by id.
        private var finishedIDs: [UUID] = []
        private var drawingPath = CGMutablePath()
        private var drawingID: UUID?
        private var drawingCount = 0

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            for ink in [finished, drawing] {
                ink.strokeColor = NSColor.red.cgColor
                ink.fillColor = nil
                ink.lineWidth = 3
                ink.lineCap = .round
                ink.lineJoin = .round
                layer?.addSublayer(ink)
            }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("not used") }

        /// Top-left origin, as the gesture's points are.
        override var isFlipped: Bool { true }

        /// The SwiftUI gesture under this view takes the drags.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            finished.frame = bounds
            drawing.frame = bounds
            CATransaction.commit()
        }

        func show(strokes: [AnnotationStroke], live: AnnotationStroke?) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            showFinished(strokes)
            showDrawing(live)
            CATransaction.commit()
        }

        /// Strokes are only ever added at the end or all cleared, so the
        /// path is extended when it can be and rebuilt otherwise.
        private func showFinished(_ strokes: [AnnotationStroke]) {
            guard strokes.map(\.id) != finishedIDs else { return }
            let extends = strokes.count > finishedIDs.count && strokes.prefix(finishedIDs.count).map(\.id) == finishedIDs
            if !extends {
                finishedPath = CGMutablePath()
                finishedIDs = []
            }
            for stroke in strokes.dropFirst(finishedIDs.count) {
                Self.add(stroke.points, to: finishedPath)
                finishedIDs.append(stroke.id)
            }
            finished.path = finishedPath
        }

        private func showDrawing(_ live: AnnotationStroke?) {
            guard let live else {
                if drawingID != nil {
                    drawingID = nil
                    drawingCount = 0
                    drawingPath = CGMutablePath()
                    drawing.path = nil
                }
                return
            }
            if live.id != drawingID || live.points.count < drawingCount {
                drawingID = live.id
                drawingCount = 0
                drawingPath = CGMutablePath()
            }
            guard live.points.count > drawingCount else { return }
            for point in live.points.dropFirst(drawingCount) {
                if drawingPath.isEmpty {
                    drawingPath.move(to: point)
                } else {
                    drawingPath.addLine(to: point)
                }
            }
            drawingCount = live.points.count
            drawing.path = live.points.count > 1 ? drawingPath : nil
        }

        private static func add(_ points: [CGPoint], to path: CGMutablePath) {
            guard points.count > 1 else { return }
            path.move(to: points[0])
            for point in points.dropFirst() {
                path.addLine(to: point)
            }
        }
    }
}
