# Accessibility

Status: **implemented (core)**: VoiceOver across the timeline, inspector,
viewer and library; keyboard access to the playhead and clips; text
contrast to WCAG AA; reduced motion. What remains is listed at the end.

The editor is mostly custom drawing and drag gestures, which VoiceOver and
the keyboard can't reach on their own. This document says how each part is
made reachable, and the rules new UI should follow so it stays that way.

## Keyboard

The timeline's keys are handled by `TimelineView.handleKey` and listed in
the **Timeline** menu (`TimelineCommands`). Keys without a modifier are
written after the item's name rather than set as menu shortcuts, since a
menu shortcut would take the key from a text field; ⌘B is a real
shortcut. The keys are left alone while text is being typed, and the
arrow, Home and End keys also while a list or other control has the
keyboard (the library's list uses the arrows).

| Keys | Does |
| --- | --- |
| Space | Play or pause |
| ← / → | Step the playhead a frame; ten with Shift |
| ↑ / ↓ | Go to the previous or next edit (any clip's start or end, or the end of the timeline) |
| Home / End | Go to the start or the end |
| ⌘B | Split at the playhead: the selected clip if the playhead is in it, otherwise every clip the playhead is in |
| , / . | Nudge the selected clip a frame earlier or later; ten with Shift |
| Delete | Delete the selected section, layer, transition or clip |
| A / B / Y | Arrow, blade and slip tools |
| N | Snapping on or off |
| = / − / \\ | Zoom in, zoom out, fit the timeline to the window |
| P / S / R / T, L | Show position, scale, rotation, opacity, or volume rows |
| F9 | Easy ease the keyframes at the playhead; Shift for ease in, ⌘⇧ for ease out |

The Tape Scrubber (Window menu) runs the sound like tape while the Left
or Right Arrow key is held, at four times normal speed with Shift; its
dial is one element whose adjust action plays half a second either way.

Moving the playhead from the keyboard pauses playback, and scrolls the
playhead to the middle of the view when it lands out of view.

## VoiceOver

### Timeline

- **Layers.** Each layer's clip row is a group named as the timeline shows
  the layer, holding its clips.
- **Clips** read as their name and kind ("Interview, video clip"), then
  where they start and how long they are in the timeline's timecode, their
  transitions, and whether they carry their own sound. Pressing a clip
  selects it, so Delete, ⌘B and the nudge keys act on it. Its actions move
  it a frame earlier or later, trim either end by a frame, remove its
  transitions and detach its audio, by the same rules as dragging.
- **The ruler** is the playhead: its value is the playhead's timecode,
  and adjusting it (VO-Up and VO-Down) steps a frame.
- **Area titles** are headings ("Sound area, 2 layers").
- **Layer headers** are groups named "Layer 2, Music 1", holding their
  toggles. Pressing one selects the layer; its actions move it up or
  down, rename it and delete it.
- **Sections** read their name and span; pressing selects, and actions
  rename and delete.
- **Keyframes** read their time and ease; pressing moves the playhead to
  one, and actions apply an ease or delete it.
- **Joined transitions** read their kind, length and curve; pressing
  selects, and actions open the footage, set a curve or remove it.
- **Property values** in the rows and the inspector read as what they are
  ("Position X") and their value; pressing one opens it for typing
  (`NumericField`'s `accessibilityName`).

### Elsewhere

- The **viewer** reads as an image whose value is the playhead's timecode.
- The **audio meter** reads each channel's level in decibels, and its clip
  lamps as a button that clears them.
- **Library scenes** read as one line each (number, whether a hand-set
  boundary starts it, start and length), without their thumbnails.
- **Group titles** in the inspector and in sheets are headings.
- **Icon-only buttons** have labels, and toggles say whether they are on.
  The keyframe buttons shared by property rows (`KeyframeControls.swift`)
  have 18-point targets.

## Contrast

Text tones keep at least 4.5:1 contrast (WCAG AA for small text) on every
surface from `well` to `overlay` (`Design.textPrimary`, `textSecondary`,
`textTertiary`). `textTertiary` falls a little short on the `floating`
sheet surface, so sheets use `textSecondary` for their notes. Colour never
carries meaning alone: clip kinds also differ by icon and name, and
render states by position on the ruler strip.

## Reduced motion

With "Reduce motion" on, every animation the editor runs is skipped and
the change happens at once (`Design.Motion.respecting`,
`editorAnimation`), including the confirmation flash on edited clips and
the snap line's arrival.

## Rules for new UI

- A view drawn with shapes or a `Canvas`, or operated by a gesture, needs
  an accessibility element: a label saying what it is, a value saying its
  state, and the gesture's result as its default action or a named one.
- Context menu commands on such a view are also its accessibility
  actions, since VoiceOver can't reach a menu on an element it ignores.
- Icon-only buttons get an `accessibilityLabel`; toggles an
  `accessibilityValue` of on or off.
- Anything a drag can do needs a keyboard or menu path too, at least one
  step at a time.
- Use `Design` text tones, not new greys, so contrast holds: 4.5:1 for
  text, checked against what is really under it. Text on a clip's fill is
  `textOnColor` at 90% or more (`Design.clipFill` is shaded when
  selected so it holds); a filled button takes `.tint(Design.accentFill)`,
  since white on the accent itself is 3.2:1.
- Decoration drawn over a control (a bevel, rim, groove or selection bar)
  is `.decorative()`: no hit testing, so an edge's clicks and drags reach
  the control, and hidden from VoiceOver. `Groove` already is.
- In a sheet, a `SheetRow`'s label is only seen. Each control in the row
  names itself (its own label, hidden with `.labelsHidden()`, or an
  `accessibilityLabel`) and a `SheetNote` it depends on is also its
  `accessibilityHint`. A `SheetCallout` reads as its severity and message
  ("Warning: …"); the sheet's title is a header.
- Animate through `editorAnimation` or check `Design.Motion.isReduced`.

## Not implemented yet

- **Moving a clip to another layer** without a pointer. Layers can be
  reordered by their actions, but a clip can't change layers.
- **Applying transitions** from the panel without a pointer: tiles are
  dragged onto clips, with no action to apply one to the selected clip.
- **Transition curves** can only be shaped by dragging their points.
- **Keyframe graph editor** panels: VoiceOver reads the graph as one element (its parameter and keyframe count), the component chips and the zoom dials (adjustable, with a Fit action), but can't move keyframes or handles.
- **Sections and keyframes** can't be moved or resized from the keyboard,
  only selected, renamed, eased and deleted.
- **Times read as timecode**, which can be wordy ("00:00:05:12"); a choice
  of seconds may read better.
- **Announcements**: VoiceOver isn't told when an edit lands (a split, a
  nudge refused at a neighbor), so the result must be found by reading.
- **Annotations** on the external display are drawn with the pointer only;
  VoiceOver can clear them (a Clear annotations action) but not draw.
- **Dialogs and alerts** use standard controls and should work, but have
  not been checked with VoiceOver.
- Nothing here has been tested with VoiceOver on a real machine yet; the
  labels and actions were written from the code.
