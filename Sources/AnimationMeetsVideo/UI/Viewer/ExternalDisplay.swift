import AppKit
import Observation
import SwiftUI

/// Manages a borderless window pinned to an external `NSScreen`'s full frame.
/// It can mirror the primary editor's playhead/selection ("synced") or carry
/// its own independent timeline/selection while editing the same shared
/// project ("independent") — a second display can act as a reference view
/// while edits from either window land in the one project.
@MainActor
@Observable
final class ExternalDisplayController {
    private var windowController: NSWindowController?

    var isActive: Bool { windowController != nil }

    func start(
        on screen: NSScreen,
        project: Binding<EditingProject>,
        primaryTimelineID: Binding<UUID>,
        primarySelection: Binding<TimelineSelection?>,
        sharedPlayback: PlaybackModel,
        annotations: AnnotationModel,
        analysis: AssetAnalysis
    ) {
        stop()

        let window = KeyableBorderlessWindow(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        window.setFrame(screen.frame, display: true)
        window.level = .normal
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.hasShadow = false
        window.isOpaque = true
        window.backgroundColor = .black

        let content = ExternalViewerContent(
            project: project,
            primaryTimelineID: primaryTimelineID,
            primarySelection: primarySelection,
            sharedPlayback: sharedPlayback,
            annotations: annotations,
            analysis: analysis,
            onClose: { [weak self] in self?.stop() }
        )
        window.contentView = NSHostingView(rootView: content)
        window.makeKeyAndOrderFront(nil)

        windowController = NSWindowController(window: window)
    }

    func stop() {
        windowController?.window?.orderOut(nil)
        windowController = nil
    }
}

/// Borderless windows refuse key status by default, which would prevent the
/// annotation overlay (and the independent editor surface) from reliably
/// receiving mouse/keyboard events.
private final class KeyableBorderlessWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private struct ExternalViewerContent: View {
    @Binding var project: EditingProject
    @Binding var primaryTimelineID: UUID
    @Binding var primarySelection: TimelineSelection?
    let sharedPlayback: PlaybackModel
    let annotations: AnnotationModel
    let analysis: AssetAnalysis
    let onClose: () -> Void

    @State private var isSynced = true
    @State private var independentPlayback = PlaybackModel()
    @State private var independentTimelineID: UUID?
    @State private var independentSelection: TimelineSelection?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Toggle("Sync with primary", isOn: $isSynced)
                    .toggleStyle(.switch)
                Spacer()
                if isSynced {
                    Button("Clear markup") { annotations.clear() }
                        .buttonStyle(.bordered)
                }
                Button("Close") { onClose() }
                    .buttonStyle(.bordered)
            }
            .font(Design.Typeface.body)
            .foregroundStyle(Design.textPrimary)
            .padding(.horizontal, Design.Space.rail)
            .padding(.vertical, Design.Space.group)
            .rail(.raised)

            if isSynced {
                ZStack {
                    Color.black.ignoresSafeArea()
                    PlayerLayerView(player: sharedPlayback.player, still: sharedPlayback.cover)
                        .ignoresSafeArea()
                    AnnotationOverlay(model: annotations)
                        .ignoresSafeArea()
                }
            } else {
                TimelineEditorSurface(
                    project: $project,
                    timelineID: independentTimelineID ?? primaryTimelineID,
                    selectTimeline: { independentTimelineID = $0 },
                    selection: $independentSelection,
                    playback: independentPlayback,
                    analysis: analysis
                )
            }
        }
        // Synced, this window is a projection surface and stays pure
        // black; independent, it is a second editor, so it takes the same
        // fixed dark chrome as the main one.
        .background(isSynced ? Color.black : Design.Surface.base.color)
        .preferredColorScheme(.dark)
        .tint(Design.accent)
        .onAppear {
            if independentTimelineID == nil {
                independentTimelineID = primaryTimelineID
            }
        }
    }
}
