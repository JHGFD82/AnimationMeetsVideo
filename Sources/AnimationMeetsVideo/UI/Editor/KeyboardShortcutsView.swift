import SwiftUI

/// Help > Keyboard Shortcuts: every key the editor answers, in one place.
/// Most of the timeline's keys have no modifier, so they can't be real
/// menu shortcuts (see `TimelineCommands`) and are otherwise found only in
/// the Timeline menu's item names and the buttons' tooltips.
///
/// Keep in step with `TimelineView.handleKey`, the Clips list's
/// `handleKey` and the table in docs/accessibility.md.
struct KeyboardShortcutsView: View {
    static let windowID = "keyboard-shortcuts"

    struct Shortcut: Identifiable {
        let keys: String
        let does: String
        var id: String { keys + does }
    }

    struct Group: Identifiable {
        let title: String
        let shortcuts: [Shortcut]
        var id: String { title }
    }

    static let groups: [Group] = [
        Group(title: "Playback and the playhead", shortcuts: [
            Shortcut(keys: "Space", does: "Play or pause"),
            Shortcut(keys: "← →", does: "Step a frame; ten with ⇧"),
            Shortcut(keys: "↑ ↓", does: "Previous or next edit"),
            Shortcut(keys: "Home End", does: "Go to the start or the end"),
        ]),
        Group(title: "Editing clips", shortcuts: [
            Shortcut(keys: "⌘B", does: "Split the selected clips at the playhead"),
            Shortcut(keys: "⇧⌘B", does: "Split every clip at the playhead"),
            Shortcut(keys: ", .", does: "Nudge the selection a frame; ten with ⇧"),
            Shortcut(keys: "V", does: "Turn the selected clips off or on"),
            Shortcut(keys: "⌫", does: "Delete the selection"),
            Shortcut(keys: "⌘A", does: "Pick every clip of the timeline"),
            Shortcut(keys: "⌘X ⌘C ⌘V ⌘D", does: "Cut, copy, paste at the playhead, duplicate"),
            Shortcut(keys: "Esc", does: "Select nothing; cancel a clip move, trim or slip in progress"),
        ]),
        Group(title: "Tools and view", shortcuts: [
            Shortcut(keys: "A B Y", does: "Arrow, blade and slip tools"),
            Shortcut(keys: "N", does: "Snapping on or off"),
            Shortcut(keys: "= −", does: "Zoom in or out"),
            Shortcut(keys: "\\", does: "Fit the timeline to the window"),
            Shortcut(keys: "L", does: "Show or hide volume rows"),
            Shortcut(keys: "⇧E", does: "Show the selected clip's effects"),
        ]),
        Group(title: "Keyframes", shortcuts: [
            Shortcut(keys: "F9", does: "Easy ease the keyframes at the playhead"),
            Shortcut(keys: "⇧F9  ⇧⌘F9", does: "Ease in, ease out"),
            Shortcut(keys: "⌃⌥H", does: "Hold the keyframes at the playhead"),
        ]),
        Group(title: "Clips list", shortcuts: [
            Shortcut(keys: "↑ ↓", does: "Move the selection; ⇧ extends it"),
            Shortcut(keys: "⌥← ⌥→", does: "Skim a frame; ten with ⇧"),
            Shortcut(keys: "I O", does: "Set the start or end of the range"),
            Shortcut(keys: "Return", does: "Add the selection to the timeline"),
            Shortcut(keys: "⌘A", does: "Select every clip"),
            Shortcut(keys: "⌫", does: "Remove the selected media from the project"),
        ]),
        Group(title: "Project", shortcuts: [
            Shortcut(keys: "⌘N ⌘O", does: "New or open a project"),
            Shortcut(keys: "⌘S ⇧⌘S", does: "Save, save as"),
            Shortcut(keys: "⌘I", does: "Import media"),
            Shortcut(keys: "⌘E", does: "Export the timeline"),
            Shortcut(keys: "⌘J", does: "Project settings"),
            Shortcut(keys: "⌥⌘R", does: "Render now"),
        ]),
    ]

    var body: some View {
        ScrollView {
            LazyVGrid(
                columns: [GridItem(.flexible(), spacing: Design.Space.sheet, alignment: .topLeading),
                          GridItem(.flexible(), spacing: Design.Space.sheet, alignment: .topLeading)],
                alignment: .leading,
                spacing: Design.Space.sheet
            ) {
                ForEach(Self.groups) { group in
                    section(group)
                }
            }
            .padding(Design.Space.sheet)
        }
        .frame(minWidth: 640, idealWidth: 720, minHeight: 420, idealHeight: 620)
        .background(Design.Surface.floating.color)
        .preferredColorScheme(.dark)
    }

    /// A row's keys with their glyphs named in words, for VoiceOver, which
    /// reads "⇧⌘B" or "= −" badly or not at all: "Shift Command B",
    /// "Equals, Minus". The keys of a row are separated by commas.
    nonisolated static func spokenKeys(_ keys: String) -> String {
        let modifiers: [Character: String] = ["⌘": "Command", "⇧": "Shift", "⌥": "Option", "⌃": "Control"]
        let names = [
            "←": "Left Arrow", "→": "Right Arrow", "↑": "Up Arrow", "↓": "Down Arrow",
            "⌫": "Delete", "Esc": "Escape", ",": "Comma", ".": "Period",
            "=": "Equals", "−": "Minus", "\\": "Backslash",
        ]
        return keys.split(separator: " ").map { key in
            var words: [String] = []
            var rest = Substring(key)
            while let first = rest.first, let modifier = modifiers[first] {
                words.append(modifier)
                rest = rest.dropFirst()
            }
            if !rest.isEmpty { words.append(names[String(rest)] ?? String(rest)) }
            return words.joined(separator: " ")
        }
        .joined(separator: ", ")
    }

    private func section(_ group: Group) -> some View {
        VStack(alignment: .leading, spacing: Design.Space.close) {
            Text(group.title)
                .font(Design.Typeface.bodyEmphasis)
                .foregroundStyle(Design.textPrimary)
                .accessibilityAddTraits(.isHeader)
            ForEach(group.shortcuts) { shortcut in
                HStack(alignment: .firstTextBaseline, spacing: Design.Space.step) {
                    Text(shortcut.keys)
                        .font(Design.Typeface.numericSmall)
                        .foregroundStyle(Design.textPrimary)
                        .frame(width: 104, alignment: .trailing)
                    Text(shortcut.does)
                        .font(Design.Typeface.body)
                        .foregroundStyle(Design.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Self.spokenKeys(shortcut.keys) + ", " + shortcut.does.replacingOccurrences(of: "⇧", with: "Shift"))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
