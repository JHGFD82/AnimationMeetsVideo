import AppKit
import SwiftUI

/// Shown while no project is open. The editor always works inside a saved
/// package, so imported media and analysis results go straight to disk.
struct ProjectStartView: View {
    /// Projects opened lately that are still there, newest first.
    var recents: [URL] = []
    let onNew: () -> Void
    let onOpen: () -> Void
    var onOpenRecent: (URL) -> Void = { _ in }

    /// As many as fit without the sheet growing tall; the rest are in
    /// File > Open Recent.
    private static let recentsShown = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Design.Space.group) {
                TimelineMark()
                VStack(alignment: .leading, spacing: Design.Space.close) {
                    Text("Animation Meets Video")
                        .font(Design.Typeface.display)
                        .foregroundStyle(Design.textPrimary)
                    Text("A project is a folder on disk. Make one first and everything after it — the media you import, the scenes and beats found in it, the frames rendered in the background — is written there as it happens, not held in memory until you remember to save.")
                        .font(Design.Typeface.body)
                        .foregroundStyle(Design.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(Design.Space.sheet + 4)
            .frame(maxWidth: .infinity, alignment: .leading)

            if !recents.isEmpty {
                VStack(alignment: .leading, spacing: Design.Space.tight) {
                    Text("Recent")
                        .font(Design.Typeface.bodyEmphasis)
                        .foregroundStyle(Design.textSecondary)
                        .accessibilityAddTraits(.isHeader)
                        .padding(.horizontal, Design.Space.step)
                    ForEach(recents.prefix(Self.recentsShown), id: \.self) { url in
                        RecentProjectRow(url: url) { onOpenRecent(url) }
                    }
                }
                .padding(.horizontal, Design.Space.sheet + 4 - Design.Space.step)
                .padding(.bottom, Design.Space.sheet)
            }

            HStack(spacing: Design.Space.step) {
                Button("Quit") { NSApp.terminate(nil) }
                Spacer()
                Button("Open project…", action: onOpen)
                Button("New project…", action: onNew)
                    .buttonStyle(.borderedProminent)
                    .tint(Design.accentFill)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, Design.Space.sheet + 4)
            .padding(.vertical, Design.Space.group)
            .background(Design.Surface.raised.color)
            .overlay(alignment: .top) { Groove() }
        }
        .frame(width: Design.SheetWidth.wide - 60)
        .background(Design.Surface.floating.color)
        .preferredColorScheme(.dark)
        .interactiveDismissDisabled()
    }
}

/// A recent project on the start sheet: its name, and the folder it is in
/// to tell two of one name apart. Clicking it opens it.
private struct RecentProjectRow: View {
    let url: URL
    let open: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: Design.Space.step) {
                Image(systemName: "film.stack")
                    .foregroundStyle(Design.textSecondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(RecentProjects.name(of: url))
                        .font(Design.Typeface.bodyEmphasis)
                        .foregroundStyle(Design.textPrimary)
                    Text(RecentProjects.location(of: url))
                        .font(Design.Typeface.label)
                        .foregroundStyle(Design.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Design.Space.step)
            .padding(.vertical, Design.Space.tight + 1)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isHovered ? Design.Surface.raised.color : .clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(url.path)
        .accessibilityLabel("Open \(RecentProjects.name(of: url))")
        .accessibilityHint(RecentProjects.location(of: url))
    }
}

/// The app's mark: a few bars of its own timeline, in the three clip tones
/// over the same groove the editor uses. Drawn rather than illustrated,
/// because the timeline is what the app is.
private struct TimelineMark: View {
    private struct Bar {
        let tone: Design.ClipTone
        let width: CGFloat
    }

    private let bars: [Bar] = [
        Bar(tone: .video, width: 86),
        Bar(tone: .nested, width: 44),
        Bar(tone: .video, width: 62),
        Bar(tone: .audio, width: 150),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 2) {
                ForEach(Array(bars.prefix(3).enumerated()), id: \.offset) { _, item in
                    block(item, height: 14)
                }
            }
            Groove(subtle: true)
                .frame(width: 194)
            block(bars[3], height: 9)
        }
        .overlay(alignment: .topLeading) {
            // The playhead, parked where it would be on a real timeline.
            Rectangle()
                .fill(Design.playhead)
                .frame(width: 1.5, height: 27)
                .offset(x: 112)
        }
        .accessibilityHidden(true)
    }

    private func block(_ item: Bar, height: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .fill(Design.clipFill(item.tone.color, selected: false))
            .overlay {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .strokeBorder(Design.bevelEdge, lineWidth: 1)
            }
            .frame(width: item.width, height: height)
    }
}
