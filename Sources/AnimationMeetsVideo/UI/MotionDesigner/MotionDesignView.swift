import AppKit
import CoreMedia
import SwiftUI

/// The motion designer's panel: the transport above, the sidebar on the
/// left, and the lanes (footage, time graph, music) filling the rest. See
/// docs/motion-designer.md.
struct MotionDesignView: View {
    @Bindable var session: MotionDesignSession
    let onDone: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            transport
                .padding(.horizontal, Design.Space.rail)
                .padding(.vertical, Design.Space.close)
                .rail(.raised)
            HStack(spacing: 0) {
                MotionDesignSidebar(session: session, onDone: onDone, onCancel: onCancel)
                    .frame(width: 270)
                Groove(axis: .vertical)
                MotionDesignLanes(session: session)
            }
        }
        .background(Design.Surface.base.color)
        .preferredColorScheme(.dark)
        .tint(Design.accent)
        .background(KeyPressMonitor(handler: handleKey))
        .confirmationDialog(
            conflictTitle,
            isPresented: Binding(get: { session.pendingConflict != nil }, set: { if !$0 { session.pendingConflict = nil } }),
            titleVisibility: .visible,
            presenting: session.pendingConflict
        ) { pending in
            Button(conflictAction(pending.conflict)) {
                pending.retry()
                session.pendingConflict = nil
            }
            Button("Cancel", role: .cancel) { session.pendingConflict = nil }
        } message: { pending in
            Text(conflictMessage(pending.conflict))
        }
    }

    // MARK: Transport

    private var transport: some View {
        HStack(spacing: Design.Space.group) {
            HStack(spacing: Design.Space.step) {
                Button(action: session.togglePlayback) {
                    Image(systemName: session.isPlaying ? Design.Symbol.pause : Design.Symbol.play)
                        .frame(width: 18)
                }
                .help(session.isPlaying ? "Pause (Space)" : "Play the draft (Space)")
                .accessibilityLabel(session.isPlaying ? "Pause" : "Play")
                SwiftUI.TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !session.isPlaying)) { context in
                    let time = CMTime(seconds: max(0, session.playhead(at: context.date)), preferredTimescale: 600)
                        .timecode(frameRate: session.timeline.frameRate)
                    Text(time)
                        .font(Design.Typeface.timecode)
                        .foregroundStyle(Design.textPrimary)
                        .frame(width: 104, alignment: .leading)
                        .accessibilityLabel("Playhead")
                        .accessibilityValue(time)
                }
            }
            Groove(axis: .vertical).frame(height: 18)
            Toggle(isOn: $session.showsBeats) {
                Label("Beats", systemImage: Design.Symbol.tick)
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .disabled(session.beats.isEmpty)
            .help(session.beats.isEmpty ? "The song under these clips has no beats yet" : "Show the song's beats")
            .accessibilityValue(session.showsBeats ? "On" : "Off")
            Toggle(isOn: $session.snaps) {
                Label("Snap", systemImage: "arrow.right.to.line")
            }
            .toggleStyle(.button)
            .controlSize(.small)
            .help("Snap dragged points to beats, the playhead and clip edges")
            .accessibilityValue(session.snaps ? "On" : "Off")
            Spacer()
            HStack(spacing: 2) {
                Button(action: session.zoomOut) { Image(systemName: Design.Symbol.zoomOut) }
                    .help("Zoom out (⌘-)")
                    .accessibilityLabel("Zoom out")
                Button(action: session.zoomIn) { Image(systemName: Design.Symbol.zoomIn) }
                    .help("Zoom in (⌘=)")
                    .accessibilityLabel("Zoom in")
                Button(action: session.fit) { Image(systemName: Design.Symbol.zoomToFit) }
                    .help("Fit the clips (⌘0)")
                    .accessibilityLabel("Fit the clips")
            }
            .buttonStyle(.icon)
        }
        .frame(minHeight: 28)
    }

    // MARK: Conflicts

    private var conflictTitle: String {
        switch session.pendingConflict?.conflict {
        case .hitWouldMove: "Pacing this marker moves the hit after it"
        case .paceWouldEnd: "This hit ends the pace before it"
        default: ""
        }
    }

    private func conflictAction(_ conflict: ClipTimeMap.Conflict) -> String {
        if case .paceWouldEnd = conflict { return "Make Hit" }
        return "Set Pace"
    }

    private func conflictMessage(_ conflict: ClipTimeMap.Conflict) -> String {
        switch conflict {
        case .hitWouldMove: "The hit can't stay on its beat at this pace. It becomes a marker and moves with the pace."
        case .paceWouldEnd: "The pace marker before it becomes a marker, so this frame can stay on its beat."
        case .noRoom: ""
        }
    }

    // MARK: Keys

    /// Space plays, M adds a marker under the playhead, H makes the
    /// selected point a hit, P edits its pace, E eases it, Delete removes
    /// it, ← → move it (or the selected clip) a frame, ⇧ ten, Escape lets
    /// go, and ⌘= ⌘- ⌘0 zoom. Not while typing in a field.
    private func handleKey(_ event: NSEvent) -> Bool {
        if NSApp.keyWindow?.firstResponder is NSTextView { return false }
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command {
            switch event.charactersIgnoringModifiers {
            case "=", "+": session.zoomIn(); return true
            case "-": session.zoomOut(); return true
            case "0": session.fit(); return true
            default: return false
            }
        }
        guard flags.isDisjoint(with: [.command, .control, .option]) else { return false }
        let step = flags.contains(.shift) ? 10 : 1
        switch event.keyCode {
        case 123, 124:
            let frames = event.keyCode == 123 ? -step : step
            if session.selectedPoint != nil {
                session.nudgeSelected(byFrames: frames)
            } else if session.selectedPieceID != nil {
                session.nudgeSelectedPiece(byFrames: frames)
            } else {
                session.seek(to: session.playhead + Double(frames) * session.timeline.frameDuration.seconds)
            }
            return true
        case 51, 117:
            session.deleteSelected()
            return true
        case 53:
            if session.isDragging { session.cancelDrag() } else { session.select(point: nil); session.selectedPieceID = nil }
            return true
        default:
            break
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case " ": session.togglePlayback()
        case "m": session.addMarkerAtPlayhead()
        case "h": if let point = session.selectedPoint { session.setKind(.hit, ofPoint: point.id) }
        case "p": if session.selectedPoint != nil { session.focusesPace = true }
        case "e":
            if let point = session.selectedPoint {
                session.perform(point.eased ? "Sharpen" : "Ease") { $0.setEased(!point.eased, ofPoint: point.id) }
            }
        default: return false
        }
        return true
    }
}
