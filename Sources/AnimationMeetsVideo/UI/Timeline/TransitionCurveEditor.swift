import AppKit
import SwiftUI

/// Maps a transition curve onto a transition's area of a clip: time runs
/// left to right, and up is how much of the clip shows, so a way out's
/// curve is drawn falling, the same shape as its wedge.
struct TransitionCurveFrame {
    let size: CGSize
    let edge: TransitionEdge
    /// Room above and below the curve so points at the ends can be grabbed.
    var inset: CGFloat = 6

    private var plotHeight: CGFloat { max(1, size.height - 2 * inset) }
    private var sign: CGFloat { edge == .leading ? 1 : -1 }

    func screen(_ point: CGPoint) -> CGPoint {
        let shown = edge == .leading ? point.y : 1 - point.y
        return CGPoint(x: point.x * size.width, y: inset + (1 - shown) * plotHeight)
    }

    func curve(_ location: CGPoint) -> CGPoint {
        let shown = 1 - (location.y - inset) / plotHeight
        return CGPoint(x: location.x / max(1, size.width), y: edge == .leading ? shown : 1 - shown)
    }

    func screen(_ handle: CGVector) -> CGVector {
        CGVector(dx: handle.dx * size.width, dy: -sign * handle.dy * plotHeight)
    }

    func curve(_ offset: CGVector) -> CGVector {
        CGVector(dx: offset.dx / max(1, size.width), dy: -sign * offset.dy / plotHeight)
    }

    /// The curve as a path, drawn exactly with its bezier segments.
    func path(of curve: TransitionCurve) -> Path {
        var path = Path()
        for index in 0..<curve.segmentCount {
            let (p0, p1, p2, p3) = curve.controlPoints(ofSegment: index)
            if index == 0 { path.move(to: screen(p0)) }
            path.addCurve(to: screen(p3), control1: screen(p1), control2: screen(p2))
        }
        return path
    }
}

/// Bezier points and handles over a selected transition. Clicking the line
/// adds a point; dragging moves points and handles; Option-clicking a
/// point makes it a sharp corner (or smooth again), and Option-clicking
/// the line straightens that segment. A drag is committed when it ends.
struct TransitionCurveEditor: View {
    let curve: TransitionCurve
    let edge: TransitionEdge
    let size: CGSize
    let onChange: (TransitionCurve) -> Void

    @State private var draft: TransitionCurve?

    private let space = "transitionCurve"
    private var shown: TransitionCurve { draft ?? curve }
    private var frame: TransitionCurveFrame { TransitionCurveFrame(size: size, edge: edge) }

    var body: some View {
        let curve = shown
        let frame = frame
        let line = frame.path(of: curve)
        ZStack(alignment: .topLeading) {
            line.stroke(Color.accentColor, lineWidth: 1.5)
                .allowsHitTesting(false)

            // A wide invisible stroke takes clicks on the line.
            line.stroke(Color.clear, lineWidth: 1)
                .contentShape(line.strokedPath(StrokeStyle(lineWidth: 10)))
                .gesture(SpatialTapGesture(coordinateSpace: .named(space)).onEnded { value in
                    clickLine(at: value.location)
                })
                .help("Click to add a point; Option-click to straighten")

            ForEach(Array(curve.points.enumerated()), id: \.offset) { index, point in
                if let handle = point.inHandle {
                    handleView(index: index, side: .incoming, point: point, offset: handle)
                }
                if let handle = point.outHandle {
                    handleView(index: index, side: .outgoing, point: point, offset: handle)
                }
            }
            ForEach(Array(curve.points.enumerated()), id: \.offset) { index, point in
                pointView(index: index, point: point)
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
        .coordinateSpace(name: space)
    }

    private var optionIsDown: Bool {
        NSEvent.modifierFlags.contains(.option)
    }

    private func clickLine(at location: CGPoint) {
        var edited = curve
        let time = Double(frame.curve(location).x)
        if optionIsDown {
            edited.straightenSegment(edited.segment(containingTime: time))
        } else {
            edited.insertPoint(atTime: time)
        }
        if edited != curve { onChange(edited) }
    }

    private func pointView(index: Int, point: TransitionCurve.Point) -> some View {
        let center = frame.screen(point.location)
        let isEnd = index == 0 || index == curve.points.count - 1
        return Rectangle()
            .fill(Color.accentColor)
            .overlay(Rectangle().strokeBorder(Color.white, lineWidth: 1))
            .frame(width: 8, height: 8)
            .rotationEffect(.degrees(45))
            .frame(width: 16, height: 16)
            .contentShape(Rectangle())
            .position(center)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named(space))
                    .onChanged { value in
                        guard !isEnd, hypot(value.translation.width, value.translation.height) >= 2 else { return }
                        var edited = draft ?? curve
                        edited.movePoint(index, to: frame.curve(value.location))
                        draft = edited
                    }
                    .onEnded { value in
                        if hypot(value.translation.width, value.translation.height) < 2 {
                            if optionIsDown {
                                var edited = curve
                                edited.toggleCorner(index)
                                onChange(edited)
                            }
                        } else if let draft {
                            onChange(draft)
                        }
                        draft = nil
                    }
            )
            .contextMenu {
                if !isEnd {
                    Button("Delete Point") {
                        var edited = curve
                        edited.removePoint(index)
                        onChange(edited)
                    }
                }
                Button(point.inHandle == nil && point.outHandle == nil ? "Make Smooth" : "Make Corner") {
                    var edited = curve
                    edited.toggleCorner(index)
                    onChange(edited)
                }
            }
            .help(isEnd ? "Option-click to ease or straighten" : "Drag to move; Option-click for a corner")
    }

    private func handleView(index: Int, side: TransitionCurve.HandleSide, point: TransitionCurve.Point, offset: CGVector) -> some View {
        let anchor = frame.screen(point.location)
        let reach = frame.screen(offset)
        let tip = CGPoint(x: anchor.x + reach.dx, y: anchor.y + reach.dy)
        return ZStack(alignment: .topLeading) {
            Path { path in
                path.move(to: anchor)
                path.addLine(to: tip)
            }
            .stroke(Color.accentColor.opacity(0.8), lineWidth: 1)
            .allowsHitTesting(false)

            Circle()
                .fill(Color.white)
                .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 1.5))
                .frame(width: 8, height: 8)
                .frame(width: 14, height: 14)
                .contentShape(Circle())
                .position(tip)
                .gesture(
                    DragGesture(minimumDistance: 1, coordinateSpace: .named(space))
                        .onChanged { value in
                            var edited = draft ?? curve
                            let pulled = CGVector(dx: value.location.x - anchor.x, dy: value.location.y - anchor.y)
                            edited.setHandle(side, of: index, to: frame.curve(pulled))
                            draft = edited
                        }
                        .onEnded { _ in
                            if let draft { onChange(draft) }
                            draft = nil
                        }
                )
        }
    }
}
