import SwiftUI

/// Why something just asked for wasn't done, in a few words: shown for a
/// moment over the editor window in front (`RefusalNoticeView`) and read
/// out by VoiceOver. It stands in for a beep, which says only that
/// something was refused and leaves the person to guess why.
///
/// Say what stood in the way and, where there is one, what to do instead:
/// "Select a clip on the timeline to add Glow to." Keep it to a sentence
/// or two; a question to answer belongs in an alert.
@MainActor
@Observable
final class RefusalNotice {
    static let shared = RefusalNotice()

    struct Note: Equatable {
        /// Tells one note from the next, even with the same words, for the
        /// view to show each arriving.
        let id: Int
        let message: String
    }

    /// The note showing; nil once it has gone.
    private(set) var note: Note?
    @ObservationIgnored private var count = 0
    @ObservationIgnored private var hiding: Task<Void, Never>?
    /// When `tell` was last called, for `tellUnlessJustTold`.
    @ObservationIgnored fileprivate var lastTold: Date?
    /// How long a note stays: long enough to read two short sentences.
    static let shownFor: Duration = .seconds(4)

    /// Shows `message`, and has VoiceOver read it. The same message again
    /// while it shows (a drag refused at every step, a key held down)
    /// only keeps it up longer, and isn't read out again.
    func tell(_ message: String) {
        lastTold = Date()
        if note?.message != message {
            count += 1
            note = Note(id: count, message: message)
            AccessibilityNotification.Announcement(message).post()
        }
        hiding?.cancel()
        hiding = Task { [weak self] in
            try? await Task.sleep(for: Self.shownFor)
            guard !Task.isCancelled else { return }
            self?.note = nil
        }
    }

    /// Takes the note away now, as a click on it does.
    func dismiss() {
        hiding?.cancel()
        hiding = nil
        note = nil
    }
}

/// The note a `RefusalNotice` holds, at the top of the editor, under its
/// header. Only the window in front shows it, since that is where what
/// was refused was asked for. A click takes it away; it never takes the
/// keyboard, so the keys that were refused still reach the editor.
struct RefusalNoticeView: View {
    let notice: RefusalNotice
    /// False to show it in a window that isn't in front, for a snapshot.
    var onlyInKeyWindow = true
    @Environment(\.controlActiveState) private var activeState

    var body: some View {
        ZStack {
            if activeState == .key || !onlyInKeyWindow, let note = notice.note {
                Label {
                    Text(note.message)
                        .font(Design.Typeface.body)
                        .foregroundStyle(Design.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                } icon: {
                    Image(systemName: Design.Symbol.refused)
                        .foregroundStyle(Design.statusWarning)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, Design.Space.group)
                .padding(.vertical, Design.Space.step)
                .frame(maxWidth: 420, alignment: .leading)
                .floatingSurface(radius: Design.Radius.panel)
                .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
                .contentShape(Rectangle())
                .onTapGesture { notice.dismiss() }
                .help("Click to dismiss")
                // Read out as it arrives (`RefusalNotice.tell`); here for
                // VoiceOver to find again while it shows.
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isStaticText)
                .accessibilityAction(named: "Dismiss") { notice.dismiss() }
                .id(note.id)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .editorAnimation(Design.Motion.fade, value: notice.note)
    }
}

extension RefusalNotice {
    /// Says `message` unless a note was told a moment ago: for the
    /// fallback of an edit that may already have been refused with a
    /// sharper reason, such as a clip open in the Motion Designer
    /// (`ClipLockRefusal`), which then stays.
    func tellUnlessJustTold(_ message: String) {
        if let lastTold, Date().timeIntervalSince(lastTold) < 0.25 { return }
        tell(message)
    }
}

/// The words of refusals that more than one place gives.
@MainActor
enum RefusalReason {
    /// Why `kind` can't go onto a clip, or that none is selected.
    static func addingEffect(_ kind: EffectKind, toClip clipID: UUID?, in timelineID: UUID, of project: EditingProject) -> String {
        guard let clipID, let clip = project.clipAndLayer(clipID, in: timelineID)?.clip else {
            return "Select a clip on the timeline to add \(kind.name) to."
        }
        let name = project.resolvedInfo(for: clip.source)?.name ?? "The selected clip"
        if kind.isAudio, !project.playsAudio(clip) {
            return "\u{201C}\(name)\u{201D} has no sound for \(kind.name) to work on."
        }
        if !kind.isAudio, !project.hasEffectStack(clip) {
            return "\u{201C}\(name)\u{201D} is sound only, and \(kind.name) works on pictures."
        }
        if !project.stack(of: clip, takes: kind) {
            return "\(kind.name) goes on a text or shape clip. Double-click it to make one at the playhead."
        }
        return "\(kind.name) couldn't be added to \u{201C}\(name)\u{201D}."
    }

    /// Why a timeline can't go into the one open.
    static func embedding(_ timelineID: UUID, into targetID: UUID, of project: EditingProject) -> String {
        guard let nested = project.timeline(id: timelineID) else { return "That timeline is gone." }
        if nested.duration <= .zero { return "\u{201C}\(nested.name)\u{201D} is empty, so there is nothing to embed." }
        return "\u{201C}\(nested.name)\u{201D} can't go into this timeline: it is this timeline, or has it inside, and a timeline can't contain itself."
    }

    /// A paste refused: a nested timeline into itself, or clips whose
    /// footage didn't come along.
    static let paste = "Those clips can't be pasted here. A timeline can't be pasted into itself or into a timeline it contains."

    /// A drag on the viewer refused because a Keyframing effect writes the
    /// control it would change, where there's no warning to offer baking.
    static let drivenControl = "A Keyframing effect writes this control's keyframes. Bake them to change it by hand."
}
