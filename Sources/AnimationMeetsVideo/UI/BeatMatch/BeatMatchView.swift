import AppKit
import Carbon.HIToolbox
import SwiftUI

/// The beat match panel: the song's transport along the top (with the tick
/// once there are beats to tick on), and the step the person is on and
/// the selected section or beat to the left of the waveform. See
/// docs/beat-matching.md.
///
/// Keys: Space plays, M drops a beat or anchor at the playhead (while
/// playing, taps in a row count on through the measure), or while drawing
/// sections marks the stretch up to the playhead, ← → nudge
/// the selected beat (1 ms; ⌥ one sample; ⇧ 10 ms) or, with none selected,
/// move the playhead a second, ↑ ↓ select the previous and next beat,
/// Delete removes the selected beat or section, L loops around the
/// selected beat, while drawing F fills the gap at the playhead and [ and ]
/// move the selected section's edges to it, Return fills the selected
/// section, ⌘Return confirms (continues, while drawing), ⌘Z and ⇧⌘Z undo
/// and redo, ⌘= and ⌘- zoom and ⌘0 fits. A key does only what its
/// control would do just then, and otherwise goes on to the window.
///
/// Each part is a view of its own that reads only the session's
/// properties it shows, so a change to one, such as the song's volume as
/// its slider drags or a fill starting, redraws that part alone.
struct BeatMatchView: View {
    let session: BeatMatchSession
    let onConfirm: () -> Void
    let onCancel: () -> Void

    @AppStorage(ClickToneSettings.frequencyKey) private var frequency = ClickToneSettings.defaultFrequency
    @AppStorage(ClickToneSettings.volumeKey) private var volume = ClickToneSettings.defaultVolume

    var body: some View {
        VStack(spacing: 0) {
            BeatMatchTransport(session: session, frequency: $frequency, volume: $volume)
                .padding(.horizontal, Design.Space.rail)
                .padding(.vertical, Design.Space.close)
                .rail(.raised)
            HStack(spacing: 0) {
                BeatMatchSidebar(session: session, onConfirm: onConfirm, onCancel: onCancel)
                    .frame(width: 280)
                Groove(axis: .vertical)
                WaveformArea(session: session)
                    .toolEdge(.beatMatcher)
            }
        }
        .background(Design.Surface.base.color)
        .preferredColorScheme(.dark)
        .tint(Design.accent)
        .background(KeyPressMonitor { [session] event in BeatMatchKeys.handle(event, in: session) })
        .modifier(EditMenu(session: session))
        .onChange(of: frequency, initial: true) { _, hertz in session.clicks.frequency = hertz }
        .onChange(of: volume, initial: true) { _, level in session.clicks.volume = Float(level) }
    }

    /// What dropping a beat says about tapping.
    static let tapHelp = "Drops a beat where the song is. Tap M, or any note on a MIDI pad or keyboard, along with the song to place beats in a row; MIDI taps land where they were played."
}

/// The waveform, or how reading the song is going, or why it failed.
private struct WaveformArea: View {
    let session: BeatMatchSession

    var body: some View {
        if let error = session.loadError {
            ContentUnavailableView {
                Label("Couldn't Read the Song", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Try Again", action: session.reload)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if session.audio == nil {
            VStack(spacing: Design.Space.step) {
                ProgressView(value: session.loadProgress)
                    .frame(width: 220)
                Text("Reading the song…")
                    .font(Design.Typeface.label)
                    .foregroundStyle(Design.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            BeatMatchWaveform(session: session)
        }
    }
}

/// What the Edit menu does while Beat Match is open (see
/// `EditCommands`): Copy and Paste carry a filled section's tempo,
/// measure and steadiness to another; Delete deletes the selected beat,
/// or the selected section while drawing them. Cut and Duplicate have
/// nothing to act on here (the timeline offers none while it is open).
/// A modifier of its own, so only what the commands depend on makes a
/// new set of them.
private struct EditMenu: ViewModifier {
    let session: BeatMatchSession

    func body(content: Content) -> some View {
        content.focusedSceneValue(\.beatMatchEditActions, actions)
    }

    private var actions: EditMenuActions {
        let canCopy = session.selectedDetails != nil
        let canPaste = session.canPasteDetails
        let canDelete = BeatMatchKeys.canDelete(in: session)
        return EditMenuActions(
            cut: nil,
            copy: canCopy ? { [session] in session.copyDetails() } : nil,
            paste: canPaste ? { [session] in session.pasteDetails() } : nil,
            duplicate: nil,
            delete: canDelete ? { [session] in BeatMatchKeys.delete(in: session) } : nil,
            state: [canCopy, canPaste, canDelete,
                    session.selectedBeat.map { AnyHashable($0.seconds) }, session.selectedSectionID] as [AnyHashable?]
        )
    }
}

/// The panel's keys, listed on `BeatMatchView`. Each acts only when the
/// control it stands for would, and otherwise gives the key back to the
/// window. `KeyPressMonitor` already leaves keys to a text field being
/// edited and to other windows, such as the tick's popover.
@MainActor
private enum BeatMatchKeys {
    static func handle(_ event: NSEvent, in session: BeatMatchSession) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command) {
            switch event.charactersIgnoringModifiers {
            case "=", "+": session.zoomIn()
            case "-": session.zoomOut()
            case "0": session.fit()
            // Taken even with nothing to undo, so the editor's own undo
            // never reaches the project behind the panel.
            case "z":
                if flags.contains(.shift) { session.redo() } else { session.undo() }
            case "c":
                guard session.selectedDetails != nil else { return false }
                session.copyDetails()
            case "v":
                guard session.canPasteDetails else { return false }
                session.pasteDetails()
            default: return false
            }
            return true
        }
        switch Int(event.keyCode) {
        case kVK_Space:
            session.togglePlayback()
        case kVK_LeftArrow, kVK_RightArrow:
            // A slider or stepper with the focus takes its own arrows.
            if event.window?.firstResponder is NSSlider || event.window?.firstResponder is NSStepper { return false }
            let direction: Double = Int(event.keyCode) == kVK_LeftArrow ? -1 : 1
            if session.selectedBeat != nil {
                let step = flags.contains(.option) ? session.sampleDuration : flags.contains(.shift) ? 0.01 : 0.001
                session.nudgeSelected(by: direction * step)
            } else {
                session.seek(to: session.livePlayhead + direction)
            }
        case kVK_UpArrow:
            session.selectBeat(step: -1)
        case kVK_DownArrow:
            session.selectBeat(step: 1)
        case kVK_Delete, kVK_ForwardDelete:
            guard canDelete(in: session) else { return false }
            delete(in: session)
        case kVK_Return, kVK_ANSI_KeypadEnter:
            guard session.canFillSelected else { return false }
            session.fillSelected()
        default:
            return handleCharacter(event.charactersIgnoringModifiers?.lowercased(), in: session)
        }
        return true
    }

    private static func handleCharacter(_ character: String?, in session: BeatMatchSession) -> Bool {
        let drawing = session.step == .drawSections
        switch character {
        case "m":
            switch session.step {
            case .chooseMode:
                return false
            case .drawSections:
                session.drawSectionToPlayhead()
            case .mark:
                guard let kind = session.selectedSection?.kind, kind != .none else {
                    session.explain("Select a consistent or ramp section first, then press M to drop a beat in it.")
                    return true
                }
                session.addBeatAtPlayhead()
            }
        case "l":
            guard session.selectedBeat != nil else { return false }
            session.isLooping.toggle()
        case "f":
            guard drawing else { return false }
            session.fillGap(at: session.livePlayhead)
        case "[", "]":
            guard drawing, session.selectedSection != nil else { return false }
            session.moveSelectedEdgeToPlayhead(character == "[" ? .start : .end)
        default:
            return false
        }
        return true
    }

    /// Whether Delete has anything to delete: the selected beat, or the
    /// selected section while drawing them.
    static func canDelete(in session: BeatMatchSession) -> Bool {
        session.selectedBeat != nil || (session.step == .drawSections && session.selectedSection != nil)
    }

    static func delete(in session: BeatMatchSession) {
        if session.selectedBeat != nil { session.deleteSelectedBeat() } else { session.deleteSelectedSection() }
    }
}
