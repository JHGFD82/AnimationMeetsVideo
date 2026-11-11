import CoreMedia

/// What a graph works out from its parameter's keyframes, kept between
/// redraws. Scrolling and zooming redraw the graph many times a second and
/// change none of it, and working it out reads every keyframe: reading a
/// parameter's keyframes as components builds and sorts them all afresh,
/// and fitting the values reads every segment.
///
/// The keyframes read from a project are kept for its `editCount`, which
/// is new with every edit, so they are read again only after one (always
/// for a project never stamped, whose count says nothing). The rest is
/// kept for the keyframes it came from: while those are the ones kept,
/// they share storage with them and so compare equal at once.
///
/// Not observed: it changes while a view's body is drawn, which it must
/// not invalidate. Used by one graph, on the main thread.
final class KeyframeGraphCache {
    private struct Read {
        var editCount: UInt64
        var key: ParameterKey
        var stored: AnimatedValue<ComponentValue>?
        var axis: ParameterTimeAxis?
    }

    private struct FitKey: Hashable {
        var offset: [Double]
        var components: [Int]
    }

    private var read: Read?
    /// The keyframes the rest was worked out for.
    private var value: AnimatedValue<ComponentValue>?
    private var segments: [KeyframeGraphLayout.Segment] = []
    private var fitTimes: (span: ClosedRange<Double>, frame: Double, fit: ClosedRange<Double>)?
    private var fitValues: [FitKey: ClosedRange<Double>] = [:]

    /// The parameter's keyframes in `project`, and its time axis.
    func source(of key: ParameterKey, in project: EditingProject) -> (stored: AnimatedValue<ComponentValue>?, axis: ParameterTimeAxis?) {
        let count = project.editCount
        if count != 0, let read, read.editCount == count, read.key == key {
            return (read.stored, read.axis)
        }
        let stored = project.components(of: key), axis = project.timeAxis(of: key)
        read = Read(editCount: count, key: key, stored: stored, axis: axis)
        return (stored, axis)
    }

    /// Lets go of what was kept for other keyframes than `value`.
    private func use(_ value: AnimatedValue<ComponentValue>) {
        guard self.value != value else { return }
        self.value = value
        segments = KeyframeGraphLayout.segments(of: value)
        fitTimes = nil
        fitValues = [:]
    }

    func segments(of value: AnimatedValue<ComponentValue>) -> [KeyframeGraphLayout.Segment] {
        use(value)
        return segments
    }

    /// `KeyframeGraphLayout.fitTimes`, kept.
    func fitTimes(_ value: AnimatedValue<ComponentValue>, span: ClosedRange<Double>, frame: Double) -> ClosedRange<Double> {
        use(value)
        if let fitTimes, fitTimes.span == span, fitTimes.frame == frame { return fitTimes.fit }
        let fit = KeyframeGraphLayout.fitTimes(value, span: span, frame: frame)
        fitTimes = (span, frame, fit)
        return fit
    }

    /// `KeyframeGraphLayout.fitValues`, kept.
    func fitValues(_ value: AnimatedValue<ComponentValue>, offset: [Double], components: [Int]) -> ClosedRange<Double> {
        use(value)
        let key = FitKey(offset: offset, components: components)
        if let fit = fitValues[key] { return fit }
        let fit = KeyframeGraphLayout.fitValues(value, offset: offset, components: components)
        fitValues[key] = fit
        return fit
    }
}
