import SwiftUI

/// What the inspector draws each control as, in Illustrator's manner: the
/// icon of a number's field, and the icon buttons that pick a small choice
/// in place of a menu.
enum InspectorGlyphs {
    /// The icon of a number's field, or nil for one shown by name.
    static func field(_ kind: ControlKind) -> PanelGlyph? {
        switch kind {
        case .fontSize: .symbol("textformat.size")
        case .leading: .symbol("arrow.up.and.down.text.horizontal")
        case .tracking: .symbol("arrow.left.and.right.text.vertical")
        case .verticalScale: .symbol("arrow.up.and.down.square")
        case .horizontalScale: .symbol("arrow.left.and.right.square")
        case .baselineShift: .symbol("arrow.up.and.line.horizontal.and.arrow.down")
        case .characterRotation: .symbol("rotate.right")
        case .leftIndent: .symbol("arrow.right.to.line")
        case .rightIndent: .symbol("arrow.left.to.line")
        case .firstLineIndent: .symbol("text.line.first.and.arrowtriangle.forward")
        case .spaceBefore: .symbol("arrow.up.to.line")
        case .spaceAfter: .symbol("arrow.down.to.line")
        case .wrapWidth: .symbol("arrow.left.and.line.vertical.and.arrow.right")
        case .pathOffset: .symbol("point.topleft.down.to.point.bottomright.curvepath")
        case .kerning: .text("VA")
        case .stylisticSet: .text("ss")
        case .strokeWidth: .drawn(StrokeGlyphs.weight)
        default: nil
        }
    }

    /// The icon buttons for a choice, or nil for one that stays a menu.
    static func segments(_ kind: ControlKind) -> [PanelSegment<String>]? {
        switch kind {
        case .textAlign:
            TextAlign.allCases.map { PanelSegment(value: $0.rawValue, glyph: .symbol($0.systemImage), name: $0.name) }
        case .textCase:
            TextCase.allCases.map { PanelSegment(value: $0.rawValue, glyph: .text(caseGlyph($0)), name: $0.name) }
        case .ligatures:
            [
                PanelSegment(value: TextLigatures.none.rawValue, glyph: .text("f i"), name: "No Ligatures"),
                PanelSegment(value: TextLigatures.standard.rawValue, glyph: .text("fi"), name: "Standard Ligatures"),
                PanelSegment(value: TextLigatures.all.rawValue, glyph: .text("fi st"), name: "Standard and Discretionary Ligatures"),
            ]
        case .strokeEdge:
            StrokeEdge.allCases.map { edge in
                PanelSegment(value: edge.rawValue, glyph: .drawn { StrokeGlyphs.edge(edge, &$0, $1, $2) }, name: "Align Stroke to \(edge.name)")
            }
        case .strokeJoin:
            StrokeJoin.allCases.map { join in
                PanelSegment(value: join.rawValue, glyph: .drawn { StrokeGlyphs.join(join, &$0, $1, $2) }, name: "\(join.name) Join")
            }
        case .strokeCap:
            StrokeCap.allCases.map { cap in
                PanelSegment(value: cap.rawValue, glyph: .drawn { StrokeGlyphs.cap(cap, &$0, $1, $2) }, name: "\(cap.name) Cap")
            }
        default: nil
        }
    }

    /// The letters a case's button shows: "Aa", "AA", "Aᴀ", "ᴀᴀ".
    static func caseGlyph(_ textCase: TextCase) -> String {
        switch textCase {
        case .normal: "Aa"
        case .allCaps: "AA"
        case .smallCaps: "A\u{1D00}"
        case .allSmallCaps: "\u{1D00}\u{1D00}"
        }
    }

    /// The on-or-off OpenType features as Illustrator's OpenType panel
    /// shows them, a button each.
    static var openTypeToggles: [(kind: ControlKind, glyph: PanelGlyph)] {
        [
            (.contextualAlternates, .text("\u{212F}\u{2192}")),
            (.swash, .text("\u{1D49C}")),
            (.stylisticAlternates, .text("\u{0251}")),
            (.ordinals, .text("1\u{02E2}\u{1D57}")),
            (.fractions, .text("\u{00BD}")),
        ]
    }
}

/// Small drawings of a stroke, for what no SF Symbol shows: where it sits
/// on the outline, how it turns a corner and how it ends. Each draws in a
/// 16 × 14 box in the ink given.
enum StrokeGlyphs {
    /// A line of each of three weights, for Stroke Width.
    static func weight(_ context: inout GraphicsContext, _ size: CGSize, _ ink: Color) {
        for (index, width) in [1.0, 2.0, 3.5].enumerated() {
            let y = 2.5 + Double(index) * 4.5
            var line = Path()
            line.move(to: CGPoint(x: 1, y: y))
            line.addLine(to: CGPoint(x: size.width - 1, y: y))
            context.stroke(line, with: .color(ink), lineWidth: width)
        }
    }

    /// A square outline (dashed) with the stroke inside it, on it or
    /// outside it.
    static func edge(_ edge: StrokeEdge, _ context: inout GraphicsContext, _ size: CGSize, _ ink: Color) {
        let outline = CGRect(x: 4, y: 3, width: size.width - 8, height: size.height - 6)
        let band: CGFloat = 2.5
        let stroked: CGRect = switch edge {
        case .inside: outline.insetBy(dx: band / 2, dy: band / 2)
        case .center: outline
        case .outside: outline.insetBy(dx: -band / 2, dy: -band / 2)
        }
        context.stroke(Path(stroked), with: .color(ink.opacity(0.55)), lineWidth: band)
        context.stroke(Path(outline), with: .color(ink), style: StrokeStyle(lineWidth: 1, dash: [1.5, 1]))
    }

    /// A thick corner turned with the join.
    static func join(_ join: StrokeJoin, _ context: inout GraphicsContext, _ size: CGSize, _ ink: Color) {
        var corner = Path()
        corner.move(to: CGPoint(x: 3, y: size.height))
        corner.addLine(to: CGPoint(x: 3, y: 4))
        corner.addLine(to: CGPoint(x: size.width, y: 4))
        context.stroke(corner, with: .color(ink), style: StrokeStyle(lineWidth: 4, lineCap: .butt, lineJoin: join.cgJoin))
    }

    /// A thick line ending with the cap at a thin mark where its path ends.
    static func cap(_ cap: StrokeCap, _ context: inout GraphicsContext, _ size: CGSize, _ ink: Color) {
        let end = size.width - 5
        var line = Path()
        line.move(to: CGPoint(x: 0, y: size.height / 2))
        line.addLine(to: CGPoint(x: end, y: size.height / 2))
        context.stroke(line, with: .color(ink.opacity(0.5)), style: StrokeStyle(lineWidth: 6, lineCap: cap.cgCap))
        var mark = Path()
        mark.move(to: CGPoint(x: end, y: 1))
        mark.addLine(to: CGPoint(x: end, y: size.height - 1))
        context.stroke(mark, with: .color(ink), lineWidth: 1)
    }
}
