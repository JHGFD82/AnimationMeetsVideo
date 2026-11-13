# Bar colors and Clear Layer

Status: **planned, not implemented**. Nothing here is built. This
document is written for whoever builds it: what the person sees, where
each piece goes in the code as it stands today, and the order to build
it in. Choices the request didn't settle are listed under
[Decisions made here](#decisions-made-here).

Two additions to right-click menus:

- A **Color** menu on every bar on the timeline: clips, sections and
  the loop region ([loop-region.md](loop-region.md)). 64 preset colors,
  the Mac's color picker for any other, and Default to go back.
- On a layer's header: the same **Color** menu, which recolors every
  clip on the layer, and **Clear Layer**, which deletes every clip on
  it and keeps the layer.

There are no rules about which colors go together. A clip can take the
loop's color, a section a clip's, every bar the same one: that is the
person's choice, and nothing warns or adjusts. The app only keeps the
text on a bar readable ([Ink](#ink)).

## What can be colored

| Bar | Right-click | Default when it has no color | Is an edit |
| --- | --- | --- | --- |
| Clip | The clip (`ClipBlockView.clipMenu`) | Its tone by kind (`Design.ClipTone`) | Yes: undo, saved in `project.json` |
| Section | Its chip (`SectionLane`) | `Design.section` | Yes |
| Loop region | Its chip (`LoopBar`) | `Design.loop` | No: view state, as the region is |
| Layer | Its header (`LayerHeaderRow`) | (sets its clips; a layer has no color) | Yes |

Not colored: Beat Match's sections, whose tone says their kind
(`BeatSectionTone`); the area title bars; browser filmstrips, which are
media and not clips on a timeline.

## The Color menu

A submenu named **Color**, the same everywhere:

```
Color ▸  Default                 ✓ while the bar has no color of its own
         ─────────
         ● ● ● ● ● ● ● ●         8 rows of 8 swatches
         …
         ─────────
         Other…                  opens the Mac's color picker
```

- **A swatch** gives the bar that color. The swatch of the bar's
  current color is shown picked.
- **Default** takes the bar's color away, so it goes back to its tone.
- **Other…** opens the system color panel (`NSColorPanel`) showing the
  bar's current color. Every change in the panel recolors the bar at
  once. The panel stays open, as it does in any Mac app, and goes on
  recoloring the same bar until another **Other…** is chosen or the
  bar is gone.
- On a clip picked with others (a lasso, ⌘A), every item recolors
  **all the picked clips**, as the menu's other items act on them all.
  This needs nothing new: `handlers.onEditClip` is already handed out
  to each picked clip (see the comment on `ClipBlockView.clipMenu`).
- A clip open in the Motion Designer is locked and has
  `lockedClipMenu` instead, which gets no Color menu.

### Building the menu

The swatches are a grid inside a menu, which SwiftUI draws from
`Picker`s in the palette style: one `Picker` per row, each with eight
tinted symbols.

```swift
/// UI/Components/BarColorMenu.swift
struct BarColorMenu: View {
    /// The bar's own color; nil for its default.
    let current: BarColor?
    let onSet: (BarColor?) -> Void
    let onPickOther: () -> Void

    var body: some View {
        Menu("Color") {
            Toggle("Default", isOn: …)          // on while current == nil
            Divider()
            ForEach(BarColor.presetRows.indices, id: \.self) { row in
                Picker("Row \(row + 1)", selection: …) {
                    ForEach(BarColor.presetRows[row]) { preset in
                        Label(preset.name, systemImage: "circle.fill")
                            .tint(Design.color(preset.color))
                            .tag(Optional(preset.color))
                    }
                }
                .pickerStyle(.palette)
                .paletteSelectionEffect(.symbolVariant(.inset))   // or .custom
            }
            Divider()
            Button("Other…", action: onPickOther)
        }
    }
}
```

**Not tried.** This was written without a Mac to run it on. Palette
pickers in menus are a macOS 14 API and the package targets macOS 15,
but whether eight stacked palette pickers draw as a tidy 8 × 8 grid of
tinted swatches inside a *context* menu must be looked at on screen;
menus are AppKit windows, so the snapshot tests can't show it. If it
doesn't hold up, the fallback is an `NSMenuItem` whose `view` is the
grid (an `NSHostingView` of 64 swatch buttons), which means building
that submenu in AppKit. Keep `BarColorMenu`'s inputs the same either
way so its four call sites don't change.

### The color picker

`UI/Components/BarColorPanel.swift`, one for the app:

```swift
@MainActor
final class BarColorPanel: NSObject {
    static let shared = BarColorPanel()
    /// Shows the system panel on `current` and sends every change to
    /// `onChange` until `show` is called again or `end()` is.
    func show(current: BarColor, onChange: @escaping (BarColor) -> Void)
    func end()
}
```

- It sets itself as `NSColorPanel.shared`'s target and action, with
  `showsAlpha = false` and `isContinuous = true`, and brings the panel
  forward.
- A picked `NSColor` is converted to sRGB and rounded to 8 bits a
  channel (`BarColor(_ color: NSColor)`), since that is what is saved.
- `onChange` must hold **IDs, not views**: the menu that opened the
  panel is gone by the time a color arrives. For clips it is
  `{ color in host.dispatch(.editProject { $0.setColor(color, ofClips: ids, in: timelineID) }) }`
  built in `TimelineView` (`host.dispatch` reads the project as it is
  then). IDs that no longer exist change nothing.
- Dragging in the panel sends many changes a second. Each is an edit;
  `ProjectHistory` already merges edits in quick succession with the
  same identity into one undo step (`coalescingInterval`), so a drag
  is one step as long as the change is named as below.
- `end()` when the editor's window closes or shows another project, so
  a panel left open can't recolor a project that isn't on screen.

## The 64 presets

Eight hues at seven lightnesses, light to dark, and a row of grays.
Made at even steps of lightness (OKLCH), so a row reads as one family
and a column as one hue. Read across, then down; the menu draws them in
this order.

| Red | Orange | Yellow | Green | Teal | Blue | Purple | Pink |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `#FED2CD` | `#FED4B9` | `#EADEB2` | `#C6E9C6` | `#B0EBEA` | `#C9E0FE` | `#E3D6FE` | `#FECEE4` |
| `#FFABA3` | `#F7B385` | `#D8C477` | `#9BD69C` | `#6CD9D8` | `#9DC7FE` | `#CEB6FC` | `#F6A9CD` |
| `#F28881` | `#E99355` | `#C5A93B` | `#73C076` | `#03C3C3` | `#70ADFB` | `#B897F0` | `#E887B6` |
| `#DF6862` | `#D67523` | `#AC9008` | `#4EA954` | `#05A7A7` | `#4C94EC` | `#A17ADF` | `#D4679F` |
| `#C34F4B` | `#B85F05` | `#907904` | `#33903C` | `#068C8C` | `#337BD0` | `#8962C5` | `#B94F87` |
| `#9A3936` | `#8F4802` | `#6F5C01` | `#207029` | `#086B6C` | `#215DA5` | `#6A499B` | `#913968` |
| `#6E2826` | `#673200` | `#4F4100` | `#17501D` | `#024D4D` | `#174276` | `#4B346F` | `#68284A` |

The last row, Gray 1 to Gray 8:

| | | | | | | | |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `#EEEEEE` | `#D1D1D1` | `#B4B4B4` | `#989898` | `#7D7D7D` | `#636363` | `#4A4A4A` | `#333333` |

Each has a name for VoiceOver and the swatch's tooltip: the column's
hue and the row's number, "Red 1" (lightest) to "Red 7" (darkest), and
"Gray 1" to "Gray 8". All 64 are different, and a test keeps them so.
None is one of the default tones on purpose: Default is how a bar gets
its tone back.

## Layers

`LayerHeaderRow`'s context menu becomes:

```
Move Layer Up
Move Layer Down
(linked audio and channels items, as now)
─────────
Color ▸                    recolors every clip on the layer
─────────
Clear Layer                deletes every clip on the layer
Delete Layer
```

**Color** sets the color of every clip the layer has *now*. The layer
keeps no color of its own: a clip added, pasted or moved onto it later
comes with whatever color it has (none, for new media). In the menu,
Default is checked when none of the layer's clips has a color, and a
swatch is picked when they all share that one; mixed, nothing is
marked. **Other…** recolors the clips the layer had when it was chosen.
The Color menu is disabled on a layer with no clips.

**Clear Layer** removes every clip from the layer and leaves the layer
where it is, with its name, kind, height, volume, pan, sound effects
and adjustment flag.

- One undo step. No confirmation, as Delete Layer asks for none.
- `role: .destructive`, above Delete Layer.
- Disabled on a layer with no clips, and on one with a clip locked by
  the Motion Designer (`ProjectState.lockedClipIDs`), for the reason
  Delete is held back there (`TimelineKeyboard.menuSelection`,
  `deletesLocked`).
- A clip of the layer that was selected is no longer selected
  afterwards. The layer's own selection stays.
- Everything else follows from the clips being deleted, exactly as if
  each had been deleted by hand: their transitions go with them, clips
  elsewhere that followed a cleared song lose it as they do when a song
  is deleted, and the timeline gets shorter if the layer held its last
  clip.
- Nothing has a key for it: Delete with a layer selected still deletes
  the layer.

## Model

New file `Sources/AnimationMeetsVideo/Model/BarColor.swift`. Foundation
only; `Model/` has no SwiftUI.

```swift
/// A color a person gave a bar, as it is saved: sRGB, 8 bits a channel.
struct BarColor: Hashable, Sendable {
    var red: UInt8
    var green: UInt8
    var blue: UInt8

    /// "#3DB8D0"; nil unless it is `#` and six hex digits.
    init?(hex: String)
    var hex: String

    struct Preset: Identifiable { let name: String; let color: BarColor; var id: BarColor { color } }
    /// Eight rows of eight, as the menu draws them.
    static let presetRows: [[Preset]]
    /// Relative luminance (WCAG), for picking the ink.
    var luminance: Double
}
```

Fields, each nil for the default:

- `TimelineClip.color: BarColor?` (`Model/TimelineClip.swift`).
- `TimelineSection.color: BarColor?` (`Model/TimelineSections.swift`).
- `LoopRegion.color: BarColor?` ([loop-region.md](loop-region.md)).

Edits, on `EditingProject`:

- `setColor(_ color: BarColor?, ofClips ids: Set<UUID>, in timelineID: UUID)`
  beside `deleteClips` and `toggleEnabled(ofClips:in:)` in
  `Model/ClipGroups.swift`. The layer's Color menu calls it with the
  layer's clip IDs.
- `setColor(_:ofSection:in:)` in `TimelineSections.swift`, through
  `updateSection`.
- `clearLayer(_ layerID: UUID, in timelineID: UUID)`: the layer's clips
  through `deleteClips(_:in:)`, so it can never drift from what
  deleting them does.

What keeps a clip's color, because it copies the clip: splitting (both
halves), copy and paste, Duplicate, an Option-drag copy of a layer
(`duplicateLayer`), detached audio (the sound clip keeps the color of
the clip it came from), and a section's Option-drag copy
(`resolvedSectionCopy` builds a new `TimelineSection`; add the color
there). A clip made by Put in New Timeline is new and has none.

## Drawing

One place decides a clip's tone, so the timeline and the Motion
Designer can't disagree. In `UI/Design/` (an extension beside
`Design.ClipTone.of`):

```swift
extension Design {
    static func color(_ color: BarColor) -> Color
    /// A clip's own color, else its tone by kind; Music layers' default
    /// is the music tone.
    static func tone(of clip: TimelineClip, info: ResolvedClipInfo?, on kind: LayerKind) -> Color
}
```

Use it at the three places that work out a clip's tone today:

- `LayerClipRow.blockModel(for:)`, which sets `ClipBlockModel.typeColor`.
  Everything in `ClipBlockView` already draws from `typeColor` (the
  fill, the outline, the lifted ghost, the dashed copy), so the block
  follows without further change. `typeColor` is part of the model the
  block compares, so a recolor redraws it; `ClipBlockEqualityTests`
  should say so.
- `MotionDesignLanes` (the `tone` of each piece's box) and
  `RetimedFilmstrip` (the same).

A clip turned off is still greyed (`tone.greyed()`), whatever its color.

`SectionLane.sectionView` and `copyPreview` use
`section.color.map(Design.color) ?? Design.section` wherever they use
`Design.section` now. `LoopBar` does the same with `Design.loop`.

Bars keep one material: a custom color goes through `Design.clipFill`
like a default tone, translucent over the track. A very dark color on
the dark track is hard to see; that is allowed.

### Ink

Names and badges on a bar are drawn in `Design.textOnColor` today,
which was checked against the seven default tones only
(`Design.clipFill`'s comment). On a pale custom color white text can't
be read, so the ink is chosen per bar:

- `Design.ink(on fill: Color, over surface: Color) -> Color`: white or
  black, whichever has the higher contrast with the fill **as drawn
  where the label sits**: the fill's top stop (the tone at 62%, or the
  selected fill) laid over the surface under it (`Surface.sunken` for
  the tracks; the lane's black 22% over `Surface.raised` for the rail).
- For any color at all, the better of white and black reaches at least
  4.58:1, so names hold the 4.5:1 that
  [accessibility.md](accessibility.md) asks for. (The 64 presets, taken
  solid, are 4.62:1 or better.)
- A bar with **no** color of its own keeps `textOnColor` exactly as
  now, so nothing about today's timeline changes.
- Where to apply it: `ClipLabelRow` (the name and the badges, which
  stay at 90% strength of the ink), the section chip's name and its
  rename field, the loop chip's glyph and length. The waveform, volume
  line and thumbnails on a clip aren't text and stay as they are;
  check them by eye in the snapshot.

## Saving

`project.json`, in `Project/ProjectFile.swift`:

- `ClipEntry` and `SectionEntry` gain `var color: String?`: `"#RRGGBB"`,
  uppercase, left out when the bar has no color, so files without
  colors are byte for byte what they were.
- Loading is strict: add `.optional("color", …)` to the clip's and the
  section's `JSONShape`. `JSONShape` has no case for a color; add
  `case color` (a string that is `#` and six hex digits), so a bad
  value is refused with a message that names it and where it is
  ("`#12` isn't a color: use # and six hex digits"), like every other
  field.
- `formatVersion` stays 2. An older build refuses a project that has a
  `color` key, naming the key, as it does any key it doesn't know;
  that is how every optional field added since version 2 behaves.
- A layer has nothing to save: its menu only edits its clips.

The loop region's color is in `view-state.json` with the region
([loop-region.md](loop-region.md#saving)).

## Undo names

`ProjectChange` names an edit by comparing the project before and
after; no call site says what it did. Teach it these:

| Change found | Name | Identity |
| --- | --- | --- |
| One clip's `color` differs | "Change Color of Scene 4 of interview.mov" | `clip-color` and the clip's ID |
| Several clips' colors differ, nothing else | "Change Color of 5 Clips" | `clip-color` and their IDs |
| A section's `color` differs | "Change Color of Section “Chorus”" | `section-color` and its ID |
| Every clip of one layer is gone, two or more, and the layer remains | "Clear Layer “Video 2”" | `clear-layer` and the layer's ID |

The identity doesn't include the color, so the color panel's stream of
changes to the same bars merges into one step. A layer cleared of its
only clip reads as that clip's deletion, which it is.

## Accessibility

- Each swatch's label is its preset's name; the picked one is selected.
- A context menu's commands must also be accessibility actions on the
  view ([accessibility.md](accessibility.md), "Rules for new UI"), and
  64 actions would bury the rest. So clips, sections and the loop
  region get two: **Choose color…** (opens the color panel, which
  VoiceOver can use and which has its own swatches) and **Use default
  color**. A layer's header gets **Choose color for its clips…**,
  **Use default color for its clips** and **Clear layer**.
- A bar's color is not read out: it is decoration the person chose,
  and the bar's label already says what it is.
- Color never carries meaning the app relies on, so nothing here needs
  a second cue.

## Tests

- `Model/BarColorTests`: hex in and out, bad strings refused; 64
  presets, all different, eight by eight; the ink rule gives at least
  4.5:1 for every preset over the track and the rail surfaces, plain
  and selected, and for a sweep of grays (the worst case).
- `Model/` tests for `setColor(_:ofClips:in:)`, `setColor(_:ofSection:in:)`
  and `clearLayer`: the layer and its settings stay, other layers are
  untouched, an empty layer is a no-op; a split and a paste keep the
  color.
- `Project/ProjectStoreTests`: a clip's and a section's color survive
  a save and load; a project without colors saves without the key; a
  malformed color is refused with its message.
- `Project/ProjectHistoryTests` (or wherever `ProjectChange` is
  tested): the four names above, and two quick recolors of one clip
  merging into one step.
- `UI/UISnapshots`: a `coloredBars` case: clips in a light, a middle
  and a dark preset, selected and not, one turned off, a colored
  section, and the loop region colored the same as a section (to see
  that it is allowed and still legible).
- `UI/TimelineMenuStateTests` or a new test for the layer menu's
  state: Clear Layer disabled when empty or locked; the layer's Color
  menu marking Default, one swatch, or nothing.

## Decisions made here

The request didn't settle these. Each is cheap to change before the
build starts.

1. **"Bars" means clips, sections and the loop region.** The request
   says "regions" for both loop regions and what a layer holds, so all
   three get the menu. Dropping sections or the loop is a deletion
   from this document, nothing more.
2. **A layer has no color of its own.** "Recolor all regions of that
   layer" is done to the clips there at that moment; later clips
   aren't recolored.
3. **Default** is added to the menu, since otherwise a color could
   never be taken off again.
4. **The palette** is the one above; any 64 different colors would do.
5. **Text turns black on light colors.** "No rules for conflicting
   color" is about what the person may pick, not about letting names
   become unreadable.
6. **Clear Layer asks nothing**, like Delete Layer, and is undone with
   ⌘Z.
7. **The loop region's color isn't undoable**, since nothing about the
   loop is an edit.

## Building it

1. `BarColor` with its presets and `BarColorTests`.
2. The fields, the three edits, saving and strict loading, with their
   tests.
3. `ProjectChange`'s names.
4. `Design.color`, `Design.tone(of:info:on:)`, `Design.ink`, and the
   drawing sites; the snapshot case.
5. `BarColorMenu` and `BarColorPanel`; the clip's, the section's and
   the layer's menus. **Look at the swatch grid on screen** before
   going on (see "Not tried").
6. Clear Layer in the layer's menu, with its state.
7. The loop region's Color menu, once
   [loop-region.md](loop-region.md) has a `LoopBar`.
8. Accessibility actions, checked with the `accessibility-reviewer`
   agent.
9. Docs, once built: this document's status; the README's row;
   [timeline.md](timeline.md) ("Layers" for the header's menu,
   "Sections" for the color and the saved key, "Clip badges and menus"
   for the clip's, and its "Not implemented yet");
   [accessibility.md](accessibility.md) ("Contrast", for the ink, and
   the VoiceOver lists); [project-package.md](project-package.md)
   where it lists what `project.json` holds; and the comments on
   `Design` and `Design.clipFill`, which say clips are colored only by
   what they are.

This can't be built or run on Linux; it needs full Xcode on a Mac. CI
runs only when started by hand.
