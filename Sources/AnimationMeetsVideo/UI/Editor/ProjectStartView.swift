import AppKit
import SwiftUI

/// Shown while no project is open. The editor always works inside a saved
/// package, so imported media and analysis results go straight to disk.
struct ProjectStartView: View {
    let onNew: () -> Void
    let onOpen: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Design.Space.group) {
                TimelineMark()
                VStack(alignment: .leading, spacing: Design.Space.close) {
                    Text("Animation Meets Video")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(Design.textPrimary)
                    Text("A project is a folder on disk. Make one first and everything after it — the media you import, the scenes and beats found in it, the frames rendered in the background — is written there as it happens, not held in memory until you remember to save.")
                        .font(Design.Typeface.body)
                        .foregroundStyle(Design.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(Design.Space.sheet + 4)
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: Design.Space.step) {
                Button("Quit") { NSApp.terminate(nil) }
                Spacer()
                Button("Open project…", action: onOpen)
                Button("New project…", action: onNew)
                    .buttonStyle(.borderedProminent)
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
