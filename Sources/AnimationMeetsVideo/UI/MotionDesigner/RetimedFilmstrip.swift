import CoreMedia
import SwiftUI

/// The run's footage, each frame shown where it plays: frames are taken at
/// even steps of the footage and placed by the draft, so a stretch played
/// slowly spreads them apart, with the lane showing between, and one played
/// fast crowds them into slivers. At 100% they just touch. Dragging a clip
/// moves it, either edge snapping, unless a locked marker holds it: then it
/// follows the pointer a few points and springs back, saying why. Dragging
/// its edge trims it, as far as its scene's footage goes, which a bracket
/// marks once reached.
struct RetimedFilmstrip: View {
    let session: MotionDesignSession
    let width: CGFloat
    let height: CGFloat

    /// How far a clip held by a locked marker follows the pointer before it springs
    /// back.
    static let tugReach: CGFloat = 6
    /// A held clip pulled with the pointer, and how far.
    @State private var tug: (id: UUID, offset: CGFloat)?
    /// Whether the held clip being pulled has sprung back already, so the
    /// rest of that drag leaves it be.
    @State private var tugSprang = false
    /// The press a move or trim follows (`follows`).
    @State private var press = DragPress()

    /// The tiles' height, inside the lane's padding.
    private var tileHeight: CGFloat { height - 10 }
    private var tileWidth: CGFloat { (tileHeight * 16 / 9).rounded() }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(session.run.pieces) { piece in
                pieceStrip(piece)
            }
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .clipped()
        .background(Design.Surface.sunken.color)
        // A sheet over the panel takes a move's or trim's release.
        .onDraftPanelSheet { if session.isDragging { session.cancelDrag() } }
    }

    @ViewBuilder
    private func pieceStrip(_ piece: MotionRun.Piece) -> some View {
        let drafted = session.drafted(piece)
        let x0 = session.x(of: drafted.startOffset.seconds), x1 = session.x(of: drafted.endOffset.seconds)
        let info = session.project.resolvedInfo(for: piece.clip.source)
        let tone = Design.ClipTone.of(info, streams: piece.clip.streams).color
        let isSelected = session.selectedPieceID == piece.id && session.selectedPointID == nil
        if x1 > 0, x0 < width {
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: Design.Radius.chip)
                    .fill(tone.opacity(0.22))
                if case .media(let media) = info, let url = media.url {
                    ForEach(tiles(of: drafted, x0: x0), id: \.index) { tile in
                        FilmstripTile(url: url, time: media.fileTime(forSourceTime: tile.source), height: tileHeight)
                            .frame(width: tile.width, height: tileHeight, alignment: .leading)
                            .clipped()
                            .offset(x: tile.x - x0, y: 5)
                    }
                }
                Text(info?.name ?? "Clip")
                    .font(Design.Typeface.tag)
                    .foregroundStyle(Design.textOnColor)
                    .lineLimit(1)
                    .padding(.horizontal, Design.Space.tight)
                    .background(tone.opacity(0.85), in: RoundedRectangle(cornerRadius: Design.Radius.chip))
                    .padding(Design.Space.tight)
                    // Clear of a scene bracket at the start.
                    .padding(.leading, piece.isAtFootageEdge(.start) ? Design.Space.close : 0)
                RoundedRectangle(cornerRadius: Design.Radius.chip)
                    .strokeBorder(isSelected ? Design.accent : tone, lineWidth: isSelected ? 2 : 1)
                    .allowsHitTesting(false)
                footageBracket(piece, edge: .start)
                footageBracket(piece, edge: .end)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .frame(width: max(1, x1 - x0), height: height)
            .clipped()
            .overlay(alignment: .leading) { edgeHandle(piece, edge: .start) }
            .overlay(alignment: .trailing) { edgeHandle(piece, edge: .end) }
            // The shape before the offset, so the clip is grabbed where it
            // is drawn: after it, the shape stayed at the strip's start.
            .contentShape(Rectangle())
            .gesture(moveGesture(piece))
            .onTapGesture {
                session.selectedPieceID = piece.id
                session.select(point: nil)
            }
            .offset(x: x0 + (tug?.id == piece.id ? tug?.offset ?? 0 : 0))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(info?.name ?? "Clip"), clip")
            .accessibilityValue("From \(session.timecode(drafted.startOffset)) to \(session.timecode(drafted.endOffset))")
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
            .accessibilityAction { session.select(point: nil); session.selectedPieceID = piece.id }
            .accessibilityActions {
                Button("Move a frame earlier") { session.selectedPieceID = piece.id; session.nudgeSelectedPiece(byFrames: -1) }
                Button("Move a frame later") { session.selectedPieceID = piece.id; session.nudgeSelectedPiece(byFrames: 1) }
                Button("Start a frame earlier") { session.selectedPieceID = piece.id; session.trimSelectedPiece(.start, byFrames: -1) }
                Button("Start a frame later") { session.selectedPieceID = piece.id; session.trimSelectedPiece(.start, byFrames: 1) }
                Button("End a frame earlier") { session.selectedPieceID = piece.id; session.trimSelectedPiece(.end, byFrames: -1) }
                Button("End a frame later") { session.selectedPieceID = piece.id; session.trimSelectedPiece(.end, byFrames: 1) }
            }
        }
    }

    private struct Tile {
        var index: Int
        var source: CMTime
        var x: CGFloat
        var width: CGFloat
    }

    /// The frames on screen: one every tile's width of footage at 100%,
    /// each as wide as the room before the next, up to a whole tile.
    private func tiles(of clip: TimelineClip, x0: CGFloat) -> [Tile] {
        let step = Double(tileWidth) * session.secondsPerPoint
        guard step > 0 else { return [] }
        // The grid belongs to the file, so a changing trim doesn't change
        // every thumbnail. Include the partial tile at either edge.
        let first = Int((clip.trimStart.seconds / step).rounded(.down))
        let last = Int((clip.trimEnd.seconds / step).rounded(.up))
        var result: [Tile] = []
        var previous: (index: Int, source: CMTime, x: CGFloat)?
        // Footage times on a tenth-second grid, so a frame drawn once is
        // found again as the zoom changes.
        for index in first...last {
            let seconds = Double(index) * step
            let source = CMTime(seconds: (seconds * 10).rounded(.down) / 10, preferredTimescale: 600)
            let x = session.x(of: clip.timelineTime(forSourceTime: CMTime(seconds: seconds, preferredTimescale: 600)).seconds)
            if let previous, previous.x < width, x > 0 {
                result.append(Tile(index: previous.index, source: previous.source, x: previous.x, width: min(tileWidth, max(1, x - previous.x))))
            }
            previous = (index, source, x)
        }
        return result
    }

    /// A bracket at an edge whose trim has reached the end of its scene's
    /// footage: there is no more to reveal that way.
    @ViewBuilder
    private func footageBracket(_ piece: MotionRun.Piece, edge: MotionRun.Edge) -> some View {
        if piece.isAtFootageEdge(edge) {
            Path { path in
                let w: CGFloat = 5
                let outer: CGFloat = edge == .start ? 0 : w
                let inner: CGFloat = edge == .start ? w : 0
                path.move(to: CGPoint(x: inner, y: 3))
                path.addLine(to: CGPoint(x: outer, y: 3))
                path.addLine(to: CGPoint(x: outer, y: height - 3))
                path.addLine(to: CGPoint(x: inner, y: height - 3))
            }
            .stroke(Design.textPrimary, lineWidth: 2)
            .frame(width: 5, height: height)
            .padding(.horizontal, 1)
            .help(edge == .start ? "The start of this clip's scene" : "The end of this clip's scene")
            .allowsHitTesting(false)
        }
    }

    /// The strip at a clip's edge that trims it, revealing or hiding
    /// footage; it snaps like a point.
    private func edgeHandle(_ piece: MotionRun.Piece, edge: MotionRun.Edge) -> some View {
        Color.clear
            .frame(width: 7, height: height)
            .contentShape(Rectangle())
            .onHover { inside in (inside ? NSCursor.resizeLeftRight : NSCursor.arrow).set() }
            .highPriorityGesture(DragGesture(minimumDistance: 1)
                .onChanged { drag in
                    guard follows(drag) else { return }
                    session.selectedPieceID = piece.id
                    session.select(point: nil)
                    let from = (edge == .start ? piece.span.start : piece.span.end).seconds
                    let target = from + Double(press.translation(drag).width) * session.secondsPerPoint
                    let snapped = session.snapped(target, tolerance: 8 * session.secondsPerPoint, excluding: piece.id)
                    session.dragTrim(piece.id, edge: edge, to: snapped ?? target)
                }
                .onEnded { _ in
                    session.endDrag("Trim Clip")
                    press.end()
                })
            .accessibilityHidden(true)
    }

    private func moveGesture(_ piece: MotionRun.Piece) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { drag in
                guard follows(drag) else { return }
                if session.selectedPieceID != piece.id || session.selectedPointID != nil {
                    session.selectedPieceID = piece.id
                    session.select(point: nil)
                }
                let pull = press.translation(drag).width
                guard session.run.canMove(piece.id) else {
                    // Held by a locked marker: it gives a little, then springs back.
                    guard !tugSprang else { return }
                    if abs(pull) <= Self.tugReach { tug = (piece.id, pull) } else { springBack(piece.id) }
                    return
                }
                let delta = Double(pull) * session.secondsPerPoint
                session.dragPiece(
                    piece.id, by: CMTime(seconds: delta, preferredTimescale: ClipTimeMap.timescale),
                    snapTolerance: 8 * session.secondsPerPoint
                )
            }
            .onEnded { _ in
                if !session.run.canMove(piece.id), !tugSprang { springBack(piece.id) }
                tugSprang = false
                session.endDrag("Move Clip")
                press.end()
            }
    }

    /// Whether a move or trim follows this change of its drag: the drag
    /// begins once, at the first change of its press, and once Escape has
    /// cancelled it (or a sheet over the panel let go of it), the rest of
    /// that press is ignored rather than beginning it again from where the
    /// draft went back to.
    private func follows(_ drag: DragGesture.Value) -> Bool {        if press.begins(drag) {
            // A press whose release went unheard leaves nothing behind.
            session.cancelDrag()
            tugSprang = false
            session.beginDrag()
        }
        return session.isDragging
    }

    /// Lets a held clip go back to its place with a small bounce, and says
    /// why it can't move.
    private func springBack(_ id: UUID) {
        tugSprang = true
        withAnimation(Design.Motion.respecting(Design.Motion.springBack)) { tug = (id, 0) }
        session.explainHeldPiece()
    }
}

/// One frame of the strip, from the shared thumbnail cache.
private struct FilmstripTile: View {
    let url: URL
    let time: CMTime
    let height: CGFloat
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let shown = image ?? FrameThumbnails.nearestCached(url: url, time: time, height: height) {
                Image(nsImage: shown)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Design.Surface.raised.color
            }
        }
        .task(id: time) { image = await FrameThumbnails.image(url: url, time: time, height: height) }
        .accessibilityHidden(true)
    }
}
