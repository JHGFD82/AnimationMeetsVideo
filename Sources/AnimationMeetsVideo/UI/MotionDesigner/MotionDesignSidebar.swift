import CoreMedia
import SwiftUI

/// The motion designer's sidebar: the frame under the playhead, what is
/// selected and its settings, what to do next, and Cancel and Done.
struct MotionDesignSidebar: View {
    @Bindable var session: MotionDesignSession
    let onDone: () -> Void
    let onCancel: () -> Void

    @State private var paceText = ""
    @FocusState private var paceFocused: Bool

    private enum Kind: Hashable { case hit, marker, pace }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Design.Space.group) {
                    MotionDesignMonitor(session: session)
                    if let point = session.selectedPoint {
                        pointControls(point)
                    } else if let id = session.selectedPieceID, let piece = session.run.pieces.first(id: id) {
                        pieceControls(piece)
                    } else {
                        guidance
                    }
                    if let message = session.message {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(Design.Typeface.label)
                            .foregroundStyle(Design.statusWarning)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(Design.Space.rail)
            }
            .controlSize(.small)
            Groove()
            HStack {
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Done", action: onDone)
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .tint(Design.accentFill)
                    .help("Keep the retiming and close (⌘Return)")
            }
            .padding(Design.Space.rail)
        }
        .background(Design.Surface.base.color)
        .onChange(of: session.selectedPoint?.pace, initial: true) { _, pace in
            paceText = pace.map { MotionDesignLanes.speedText($0) } ?? ""
        }
        .onChange(of: session.focusesPace) { _, focus in
            guard focus else { return }
            paceFocused = true
            session.focusesPace = false
        }
    }

    // MARK: Nothing selected

    private var guidance: some View {
        VStack(alignment: .leading, spacing: Design.Space.close) {
            heading("Retime to the music")
            Text("Grab the line to put a marker on that frame, and drag it along the music. Make a frame that must land on a beat a hit, and everything else retimes around it.")
            Text("A pace marker sets the speed after it. Ease a point to ramp the speed through it instead of stepping.")
            Text("M puts a marker under the playhead; ← → move the selected point a frame.")
                .foregroundStyle(Design.textTertiary)
        }
        .font(Design.Typeface.label)
        .foregroundStyle(Design.textSecondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: A point

    private func pointControls(_ point: TimePoint) -> some View {
        VStack(alignment: .leading, spacing: Design.Space.step) {
            heading(point.isHit ? "Hit" : point.pace != nil ? "Pace marker" : "Marker")
            reading("Plays at", session.timecode(point.time))
            reading("Frame", session.timecode(point.source))
            Picker("Kind", selection: Binding(get: { kind(of: point) }, set: { choose($0, for: point) })) {
                Text("Hit").tag(Kind.hit)
                Text("Marker").tag(Kind.marker)
                Text("Pace").tag(Kind.pace)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .accessibilityLabel("Kind of point")
            HStack(spacing: Design.Space.close) {
                Text("Pace")
                    .font(Design.Typeface.label)
                    .foregroundStyle(Design.textSecondary)
                TextField("None", text: $paceText)
                    .font(Design.Typeface.numericSmall)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 80)
                    .focused($paceFocused)
                    .onSubmit { submitPace(for: point) }
                    .accessibilityLabel("Pace, speed after this point in percent")
                    .help("The speed after this point, in percent (P)")
            }
            if let found = session.run.piece(holdingPoint: point.id) {
                footageNote(session.run.pieces[found.piece])
            }
            Toggle("Ease through this point", isOn: Binding(get: { point.eased }, set: { eased in
                session.perform(eased ? "Ease" : "Sharpen") { $0.setEased(eased, ofPoint: point.id) }
            }))
            .font(Design.Typeface.label)
            .help("Ramp the speed through this point instead of stepping (E)")
            if let ease = point.ease {
                rampSlider("Ramp in", value: ease.before, point: point, before: true)
                rampSlider("Ramp out", value: ease.after, point: point, before: false)
            }
            HStack(spacing: Design.Space.close) {
                Button { session.nudgeSelected(byFrames: -1) } label: { Image(systemName: "chevron.left") }
                    .help("A frame earlier (←)")
                    .accessibilityLabel("Move a frame earlier")
                Button { session.nudgeSelected(byFrames: 1) } label: { Image(systemName: "chevron.right") }
                    .help("A frame later (→)")
                    .accessibilityLabel("Move a frame later")
                Spacer()
                Button("Remove", role: .destructive) { session.deleteSelected() }
                    .help("Remove this point (Delete)")
            }
        }
    }

    /// How far one of a point's ramps reaches into its stretch, as the
    /// handle on the graph sets it. A drag of the slider is one undo step.
    private func rampSlider(_ label: String, value: Double, point: TimePoint, before: Bool) -> some View {
        let percent = "\(Int((value * 100).rounded()))%"
        return HStack(spacing: Design.Space.close) {
            Text(label)
                .font(Design.Typeface.label)
                .foregroundStyle(Design.textSecondary)
                .frame(width: 58, alignment: .leading)
            Slider(
                value: Binding(get: { value }, set: { reach in
                    guard let ease = point.ease else { return }
                    session.perform("Shape Ease") {
                        $0.setEase(TimeEase(before: before ? reach : ease.before, after: before ? ease.after : reach), ofPoint: point.id)
                    }
                }),
                in: TimeEase.reach
            ) { editing in
                if editing { session.beginDragIfNeeded() } else { session.endDrag("Shape Ease") }
            }
            .accessibilityLabel(label)
            .accessibilityValue("\(percent) of the stretch")
            Text(percent)
                .font(Design.Typeface.numericSmall)
                .foregroundStyle(Design.textPrimary)
                .frame(width: 34, alignment: .trailing)
                .accessibilityHidden(true)
        }
        .help(before
              ? "How far into the stretch before this point the speed ramps"
              : "How far into the stretch after this point the speed ramps")
    }

    private func kind(of point: TimePoint) -> Kind {
        point.isHit ? .hit : point.pace != nil ? .pace : .marker
    }

    private func choose(_ kind: Kind, for point: TimePoint) {
        switch kind {
        case .hit: session.setKind(.hit, ofPoint: point.id)
        case .marker: session.setKind(.marker, ofPoint: point.id)
        case .pace:
            // Paced at the speed it already has after it.
            guard let found = session.run.piece(holdingPoint: point.id) else { return }
            let speed = session.run.pieces[found.piece].map.speed(after: found.point)
            session.setKind(.pace(speed), ofPoint: point.id)
            session.focusesPace = true
        }
    }

    private func submitPace(for point: TimePoint) {
        let digits = paceText.filter { "0123456789.".contains($0) }
        guard let speed = Double(digits), speed > 0 else {
            paceText = point.pace.map { MotionDesignLanes.speedText($0) } ?? ""
            return
        }
        session.setKind(.pace(speed), ofPoint: point.id)
    }

    // MARK: A clip

    private func pieceControls(_ piece: MotionRun.Piece) -> some View {
        let drafted = session.drafted(piece)
        return VStack(alignment: .leading, spacing: Design.Space.step) {
            heading(session.project.resolvedInfo(for: piece.clip.source)?.name ?? "Clip")
            reading("Starts", session.timecode(drafted.startOffset))
            reading("Ends", session.timecode(drafted.endOffset))
            trimRow("Start", piece: piece, edge: .start)
            trimRow("End", piece: piece, edge: .end)
            footageNote(piece)
            if session.run.canMove(piece.id) {
                HStack(spacing: Design.Space.close) {
                    Button { session.nudgeSelectedPiece(byFrames: -1) } label: { Image(systemName: "chevron.left") }
                        .help("Move the clip a frame earlier (←)")
                        .accessibilityLabel("Move the clip a frame earlier")
                    Button { session.nudgeSelectedPiece(byFrames: 1) } label: { Image(systemName: "chevron.right") }
                        .help("Move the clip a frame later (→)")
                        .accessibilityLabel("Move the clip a frame later")
                }
                Text("Drag the clip in the strip to move it; it stops at the clips beside it.")
                    .font(Design.Typeface.label)
                    .foregroundStyle(Design.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("A hit holds this clip to its beat. Make its hits markers to move it.")
                    .font(Design.Typeface.label)
                    .foregroundStyle(Design.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// A frame either way for one edge of a clip, as dragging it does.
    private func trimRow(_ label: String, piece: MotionRun.Piece, edge: MotionRun.Edge) -> some View {
        HStack(spacing: Design.Space.close) {
            Text("Trim \(label.lowercased())")
                .font(Design.Typeface.label)
                .foregroundStyle(Design.textSecondary)
            Spacer()
            Button { session.trimSelectedPiece(edge, byFrames: -1) } label: { Image(systemName: "chevron.left") }
                .help("\(label) a frame earlier")
                .accessibilityLabel("\(label) a frame earlier")
            Button { session.trimSelectedPiece(edge, byFrames: 1) } label: { Image(systemName: "chevron.right") }
                .help("\(label) a frame later")
                .accessibilityLabel("\(label) a frame later")
        }
    }

    /// Says when a clip has used all the footage its scene has on a side.
    @ViewBuilder
    private func footageNote(_ piece: MotionRun.Piece) -> some View {
        let start = piece.isAtFootageEdge(.start), end = piece.isAtFootageEdge(.end)
        if start || end {
            let side = start && end ? "either side" : start ? "before its start" : "after its end"
            Text("No more of its scene \(side). Merge scenes in the browser to give it more footage.")
                .font(Design.Typeface.label)
                .foregroundStyle(Design.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: Pieces

    private func heading(_ title: String) -> some View {
        Text(title)
            .font(Design.Typeface.groupTitle)
            .foregroundStyle(Design.textPrimary)
            .accessibilityAddTraits(.isHeader)
    }

    private func reading(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(Design.Typeface.label)
                .foregroundStyle(Design.textSecondary)
            Spacer()
            Text(value)
                .font(Design.Typeface.numericSmall)
                .foregroundStyle(Design.textPrimary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The monitor: the editor's own player, which plays the project with the
/// run written in, as the viewer would, and its paused frame over it.
private struct MotionDesignMonitor: View {
    let session: MotionDesignSession

    var body: some View {
        ViewerLayerView(display: session.playback.display)
            .aspectRatio(aspect, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .background(Design.Surface.well.color)
            .clipShape(RoundedRectangle(cornerRadius: Design.Radius.control))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Monitor")
            .accessibilityAddTraits(.isImage)
    }

    /// The timeline's frame shape.
    private var aspect: CGFloat {
        let size = session.timeline.frameSize
        return size.height > 0 ? size.width / size.height : 16 / 9
    }
}
