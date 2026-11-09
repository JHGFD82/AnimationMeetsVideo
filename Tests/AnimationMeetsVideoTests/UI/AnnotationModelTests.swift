import CoreGraphics
import Foundation
import Testing
@testable import AnimationMeetsVideo

/// The external display's markup: strokes are added, removed one at a
/// time and cleared as steps of its own undo (`AnnotationModel`).
@MainActor
struct AnnotationModelTests {
    /// A model whose undo groups only what each step does, as a key press
    /// would, without a run loop to close the groups.
    private func model() -> AnnotationModel {
        let model = AnnotationModel()
        model.undoManager.groupsByEvent = false
        return model
    }

    private func step(_ model: AnnotationModel, _ action: () -> Void) {
        model.undoManager.beginUndoGrouping()
        action()
        model.undoManager.endUndoGrouping()
    }

    private func draw(_ model: AnnotationModel, at y: CGFloat) {
        step(model) {
            model.beginStroke(at: CGPoint(x: 0, y: y))
            model.appendPoint(CGPoint(x: 10, y: y))
            model.endStroke()
        }
    }

    @Test func strokesAreUndoneAndRedoneOneAtATime() {
        let model = model()
        draw(model, at: 0)
        draw(model, at: 10)
        #expect(model.strokes.count == 2)
        model.undoManager.undo()
        #expect(model.strokes.count == 1)
        model.undoManager.redo()
        #expect(model.strokes.count == 2)
    }

    @Test func aDotIsNoStrokeAndNoStep() {
        let model = model()
        model.beginStroke(at: .zero)
        model.endStroke()
        #expect(model.strokes.isEmpty)
        #expect(!model.undoManager.canUndo)
    }

    @Test func theLastStrokeIsRemovedAndComesBackWithUndo() {
        let model = model()
        draw(model, at: 0)
        draw(model, at: 10)
        let kept = model.strokes[0].id
        step(model) { model.removeLastStroke() }
        #expect(model.strokes.map(\.id) == [kept])
        model.undoManager.undo()
        #expect(model.strokes.count == 2)
    }

    @Test func clearingIsUndone() {
        let model = model()
        draw(model, at: 0)
        step(model) { model.clear() }
        #expect(model.strokes.isEmpty)
        model.undoManager.undo()
        #expect(model.strokes.count == 1)
        // Clearing nothing is no step.
        step(model) { model.removeLastStroke() }
        #expect(model.strokes.isEmpty)
        model.clear()
        #expect(model.undoManager.undoActionName == "Remove Stroke")
    }
}
