import SwiftUI

private struct ShowTapeScrubberKey: FocusedValueKey {
    typealias Value = TapeScrubberOpener
}

/// Opens the Tape Scrubber for the editor on screen. Always equal to
/// another: the editor makes a new one each redraw, opening the same
/// scrubber, and a value that differed every time would rebuild the menu
/// bar on every edit.
struct TapeScrubberOpener: Equatable {
    let open: () -> Void

    func callAsFunction() { open() }

    static func == (lhs: TapeScrubberOpener, rhs: TapeScrubberOpener) -> Bool { true }
}

extension FocusedValues {
    /// Opens the Tape Scrubber for the editor on screen, which publishes
    /// it with `focusedSceneValue`.
    var showTapeScrubber: TapeScrubberOpener? {
        get { self[ShowTapeScrubberKey.self] }
        set { self[ShowTapeScrubberKey.self] = newValue }
    }
}

/// The app's own items in the Window menu.
struct WindowCommands: Commands {
    @FocusedValue(\.showTapeScrubber) private var showTapeScrubber

    var body: some Commands {
        CommandGroup(after: .windowArrangement) {
            Button("Reset Panel Layout") {
                Preferences.resetLayout()
            }
            .help("Put every panel back to its first-launch size and place")

            Divider()

            Button("Tape Scrubber") { showTapeScrubber?() }
                .disabled(showTapeScrubber == nil)
                .help("Scrub the Main timeline's sound like tape, with a dial")
        }
    }
}
