import AppKit
import AVFoundation
import Observation
import SwiftUI

/// Shared player so the main viewer and a synced external window stay
/// perfectly in sync — both observe the same `AVPlayer` instance.
@Observable
final class PlaybackModel {
    let player = AVPlayer()
}

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
        Canvas { context, _ in
            for item in model.strokes {
                draw(item, in: context)
            }
            if let live = model.liveStroke {
                draw(live, in: context)
            }
        }
        .contentShape(Rectangle())
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
    }

    private func draw(_ item: AnnotationStroke, in context: GraphicsContext) {
        guard item.points.count > 1 else { return }
        var path = Path()
        path.move(to: item.points[0])
        for point in item.points.dropFirst() {
            path.addLine(to: point)
        }
        context.stroke(path, with: .color(.red), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
    }
}

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
        annotations: AnnotationModel
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
    let onClose: () -> Void

    @State private var isSynced = true
    @State private var independentPlayback = PlaybackModel()
    @State private var independentTimelineID: UUID?
    @State private var independentSelection: TimelineSelection?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Toggle("Sync with Primary", isOn: $isSynced)
                    .toggleStyle(.switch)
                Spacer()
                if isSynced {
                    Button("Clear Markup") { annotations.clear() }
                        .buttonStyle(.bordered)
                }
                Button("Close") { onClose() }
                    .buttonStyle(.bordered)
            }
            .padding()
            .foregroundStyle(.white)
            .background(.black)

            if isSynced {
                ZStack {
                    Color.black.ignoresSafeArea()
                    PlayerLayerView(player: sharedPlayback.player)
                        .ignoresSafeArea()
                    AnnotationOverlay(model: annotations)
                        .ignoresSafeArea()
                }
            } else {
                TimelineEditorSurface(
                    project: $project,
                    timelineID: Binding(
                        get: { independentTimelineID ?? primaryTimelineID },
                        set: { independentTimelineID = $0 }
                    ),
                    selection: $independentSelection,
                    playback: independentPlayback
                )
            }
        }
        .background(Color.black)
        .onAppear {
            if independentTimelineID == nil {
                independentTimelineID = primaryTimelineID
            }
        }
    }
}
