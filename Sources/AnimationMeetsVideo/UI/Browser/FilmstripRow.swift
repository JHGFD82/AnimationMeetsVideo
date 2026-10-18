import AppKit
import CoreMedia
import SwiftUI

/// One row of a clip's filmstrip: its thumbnails (or, for sound, its
/// waveform), the selection, a picked range with its handles, a red line
/// under what timelines use, and on the first row the clip's duration in a
/// shaded box.
struct FilmstripRow: View {
    let entry: BrowserEntry
    let layout: FilmstripLayout
    let row: Int
    var isSelected = false
    /// A picked range, in seconds into the clip.
    var range: (start: Double, end: Double)?
    /// What the project's timelines use of the clip, in seconds into it.
    var used: [(start: Double, end: Double)] = []
    /// The duration, shown on the first row only.
    var durationText: String?
    /// For the first row of a video shown whole: the analysis whose scene
    /// detection shows across its top while the scenes are being found
    /// (`SceneDetectionBar`, which reads it, so progress redraws only that).
    var detection: AssetAnalysis?

    private var rowTop: CGFloat { CGFloat(row) * layout.rowPitch }
    private var cells: ArraySlice<FilmstripLayout.Cell> { layout.cells(inRow: row) }
    private var rowWidth: CGFloat { cells.last?.frame.maxX ?? 0 }

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(cells, id: \.start) { cell in
                cellView(cell)
                    .frame(width: cell.frame.width, height: cell.frame.height)
                    .clipped()
                    .offset(x: cell.frame.minX)
            }
            overlays
        }
        .frame(width: rowWidth, height: layout.cellSize.height, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous))
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous)
                    .strokeBorder(Design.accent, lineWidth: 2)
            } else {
                RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous)
                    .strokeBorder(Design.bevelEdge, lineWidth: 1)
            }
        }
        .overlay(alignment: .top) {
            if let detection {
                SceneDetectionBar(analysis: detection, clip: entry.clip)
            }
        }
        .overlay(alignment: .bottomLeading) {
            if let durationText {
                Text(durationText)
                    .font(Design.Typeface.numericMicro)
                    .foregroundStyle(Design.textOnColor)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: Design.Radius.chip, style: .continuous))
                    .padding(3)
            }
        }
    }

    @ViewBuilder
    private func cellView(_ cell: FilmstripLayout.Cell) -> some View {
        if entry.clip.kind.hasPictures {
            FilmstripThumbnail(
                url: entry.clip.url,
                time: entry.clip.fileTime(forSourceTime: CMTimeAdd(entry.start, CMTime(seconds: cell.start, preferredTimescale: 600))),
                height: layout.cellSize.height
            )
        } else {
            FilmstripWaveform(
                url: entry.clip.url,
                fileStart: entry.clip.fileTime(forSourceTime: entry.start).seconds + cell.start,
                duration: cell.duration,
                color: Design.ClipTone.of(.media(entry.clip), streams: .videoAndAudio).color
            )
        }
    }

    /// The range's shading and handles, in this row's part of it.
    @ViewBuilder
    private var overlays: some View {
        ForEach(Array(usedSpans.enumerated()), id: \.offset) { _, span in
            Rectangle()
                .fill(Design.statusDanger)
                .frame(width: span.width, height: 3)
                .offset(x: span.minX, y: span.height - 3)
        }
        if let range {
            ForEach(Array(layout.spans(from: range.start, to: range.end).enumerated()), id: \.offset) { _, span in
                if abs(span.minY - rowTop) < 0.5 {
                    Rectangle()
                        .fill(Design.accent.opacity(0.22))
                        .overlay(Rectangle().strokeBorder(Design.accent, lineWidth: 2))
                        .frame(width: max(span.width, 2), height: span.height)
                        .offset(x: span.minX)
                }
            }
            handle(at: range.start)
            handle(at: range.end)
        }
    }

    /// The used stretches' parts in this row.
    private var usedSpans: [CGRect] {
        used.flatMap { layout.spans(from: $0.start, to: $0.end) }.filter { abs($0.minY - rowTop) < 0.5 }
    }

    @ViewBuilder
    private func handle(at seconds: Double) -> some View {
        let position = layout.position(atSeconds: seconds)
        if position.row == row {
            Capsule()
                .fill(Design.accent)
                .frame(width: 4, height: layout.cellSize.height - 6)
                .offset(x: position.x - 2, y: 3)
        }
    }
}

/// The frame at `time` in a file, fitted into its cell.
///
/// The picture is kept with what it is of, and shown only while that is
/// still what the cell asks for: a cell reused for another clip or time
/// shows black until its own picture arrives, never the last one's.
struct FilmstripThumbnail: View {
    let url: URL?
    let time: CMTime
    let height: CGFloat
    @State private var loaded: (key: String, image: NSImage)?

    private var key: String { "\(url?.path ?? "")|\(time.value)/\(time.timescale)|\(height)" }

    var body: some View {
        ZStack {
            Rectangle().fill(.black)
            if let loaded, loaded.key == key {
                Image(nsImage: loaded.image)
                    .resizable()
                    .scaledToFit()
            }
        }
        .task(id: key) {
            let key = key
            guard let url, let image = await FrameThumbnails.image(url: url, time: time, height: height) else { return }
            loaded = (key, image)
        }
    }
}

/// A stretch of a file's sound, as bars on the clip's colour.
struct FilmstripWaveform: View {
    let url: URL?
    /// The stretch, in seconds of the file.
    let fileStart: Double
    let duration: Double
    let color: Color

    var body: some View {
        let waveform = url.flatMap { WaveformCache.shared.waveform(for: $0) }
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(color.opacity(0.55)))
            guard let waveform, !waveform.peaks.isEmpty, size.width > 0 else { return }
            let step: CGFloat = 2
            let reach = max(1, size.height / 2 - 3)
            var path = Path()
            var x: CGFloat = 0
            while x < size.width {
                let start = fileStart + duration * Double(x / size.width)
                let end = fileStart + duration * Double(min(x + step, size.width) / size.width)
                let half = max(0.5, CGFloat(waveform.peak(from: start, to: end)) * reach)
                path.addRect(CGRect(x: x, y: size.height / 2 - half, width: step - 0.6, height: half * 2))
                x += step
            }
            context.fill(path, with: .color(Design.textOnColor.opacity(0.75)))
        }
    }
}
