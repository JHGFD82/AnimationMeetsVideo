# Fix plan

Status: **planned, not implemented**. Fixes asked for after a first
look at the parameter rows, gradients, Strobe Keys and Waveform work,
each with what causes it (where that is known from the code) and how to
fix it. Written from reading the code at 1955176, without building or
running the app, so the line numbers are from then and every cause
marked as found still needs confirming on a Mac. Take each fix out of
here as it lands, moving what it settles into the document it belongs
to; delete this file when it is empty.

Paths are under `Sources/AnimationMeetsVideo/` unless they start with
`docs/` or `Tests/`.

---

## 1. Stroke offset, and the Stroke effect matching every shape-stroke option

**What's there now.** Shapes and the Stroke effect already list the same
controls (`stroke, strokeWidth, strokeEdge, strokeJoin, strokeCap, dash`), and
both draw through `ShapeStroke.area(around:)`. They still differ in three ways:

- In the inspector, a shape only shows Width/Edge/Join/Cap/Dash while Stroke
  is on (`PaintInspectorGroup`). The Stroke effect always shows all of them
  (`ShapeInspectorGroup`, the `effect.kind == .stroke` branch).
- **The gradient handles don't line up with the drawn gradient.**
  `GradientHandles.locate` (`Model/ViewerHandles/GradientHandles.swift:85`)
  always lays a Stroke effect's gradient over the *frame*. The compositor lays
  it over the outline's bounds unless the paint says Frame
  (`LayeredCompositor.swift:956`, `placed(item: outline.boundingBoxOfPath, …)`).
- A new Stroke effect starts at width 0, so it draws nothing until a width is
  set. `Effect.shapeValues` has no case for `.stroke`.

**Plan**

1. `Model/Effects/BuiltInEffects.swift`
   - Add `static let strokeOffset = ControlKind(builtIn: "strokeOffset")`.
   - Add `ControlDefinition(.strokeOffset, "Offset", .rectangle, defaults: [0], unit: " px", range: -10_000...10_000)`.
   - Add one shared list, so the two can't drift apart again:
     `static let strokeShapeControls: [ControlKind] = [.strokeWidth, .strokeEdge, .strokeOffset, .strokeJoin, .strokeCap, .dash]`.
     Then `paintControls = [.fill, .stroke] + strokeShapeControls`, and the
     Stroke effect's `controls: [.stroke] + EffectKind.strokeShapeControls`.
2. `Rendering/Compositor/ShapeGeometry.swift`, `ShapeStroke`
   - Add `var offset: Double`, read in both inits as `values(.strokeOffset)?.first ?? 0`.
   - In `area(around:)`, move the outline before dashing and before Edge,
     the same way `PathMaskStep.area` grows a mask:
     `band = outline.copy(strokingWithWidth: abs(offset) * 2, lineCap: .round, lineJoin: join.cgJoin, miterLimit: 10)`,
     then `shifted = offset > 0 ? outline.union(band) : outline.subtracting(band)`.
     Use `shifted` everywhere `outline` is used below, including the
     `.intersection` and `.subtracting` for Inside and Outside.
   - Only offset closed outlines. An open free path has no inside, and the
     boolean ops would close it. Add a small `CGPath.isClosed` check
     (`applyWithBlock`, looking for `.closeSubpath`), or pass `isFillable` in
     from `ShapeStep`.
   - Add `\(n(offset))` to `keyText`, or renders won't refresh when it changes.
   - Text picks it up for free through `ShapeStroke(geometryOf:)`.
3. UI
   - `UI/Inspector/PaintInspectorGroup.swift`: use `kinds: EffectKind.strokeShapeControls`.
   - `UI/Inspector/ShapeInspectorGroup.swift`: for `.stroke`, show `[.stroke]`
     with gradients first, then `strokeShapeControls` only while Stroke is on,
     the same as a shape. The simplest way is to render the Stroke effect
     through `PaintInspectorGroup` minus Fill: add a `kinds` parameter, or
     `showsFill: false`.
4. Matching fixes
   - `GradientHandles.locate`: for `.stroke`, use the union of the outlines of
     the shapes above it as `item`, the same as the compositor does. Keep
     `frame` only when `style.space == .frame`. To get those outlines, walk
     `StackFolding.steps` for the stack up to the Stroke effect and union the
     `.shape` edges (`ShapeStep.edge`).
   - `Effect.shapeValues`: give `(.stroke, .strokeWidth)` a visible default,
     for example `[4]`, so a new Stroke effect draws something.
5. Old projects: their effects have no `strokeOffset` and draw as before
   (offset 0). "Add Control" can put it back (`missingControlKinds`). Saving
   needs no change.
6. Docs and tests: add Offset to `docs/graphic-layers.md`, "Strokes", and
   update `docs/gradients.md` for the handle fix. In `ShapeTests`, add an
   outward offset that grows the stroke's bounds by 2×offset, a negative one
   that shrinks them, and an open path that ignores it. In
   `GradientHandlesTests`, add a Stroke effect's handles on its outline's bounds.

> Check first: "stroke offset" is read here as moving the stroke off the
> outline by some pixels. If a **dash offset** is meant (dash phase, for marching ants),
> that is a one-liner in the same function: `copy(dashingWithPhase: offset, …)`
> in place of phase 0. It could be offered alongside as "Dash Offset".

---

## 2. Gradients don't show in the built app

The cause wasn't found from the code alone. The whole path is wired:
inspector menu → `setPaint` → `ShapeStep.fillGradient` / `ShapeStroke.gradient`
→ `ShapeRendering.draw` → `GradientRendering.draw`, and save/load keeps
`paint`. The docs say it was "not yet tried in the running app", and CI only
runs when started by hand, so the gradient tests may never have run on a Mac.

**Plan, in order**

1. Run `swift test --filter "Gradient"` on the Mac (`GradientDrawingTests`,
   `GradientPaintTests`, `PaintGradientTests`, `TextGradientTests`).
   - **Tests fail**: the bug is in `GradientRendering.draw` or
     `ShapeRendering.draw`. Check these in order:
     - `context.clip()` followed by drawing in the frame's pixels under
       `paint.transform`.
     - The float bitmap context: `premultipliedLast | floatComponents | byteOrder32Little`
       against `CGGradient` in sRGB.
     - The `covering:` rect.
     - The 256-stop `CGGradient`.
     A quick check: in `ShapeRendering.draw`, temporarily fill solid red after
     `clip()`. If red shows, the clip is right and the gradient call is at fault.
   - **Tests pass**: the bug is between the model and the compositor in the
     running app. Go on to step 2.
2. Put a breakpoint (or log) in `LayeredCompositor` `case .shape` (line ~932)
   and check that `shape.paints[0].gradient != nil` for a gradient-filled
   rectangle.
   - **Nil there**: check the edit actually reached the project. Set a
     breakpoint in `PaintKindMenu` → `onEdit { $0.setPaint(…) }`. Then check
     `EffectControl.paint` survives `project.editEffect`, and anything that
     rebuilds controls (`Effect.fitToPackage`, keyframing's base, the Python
     bridge's `ProjectBridge+Changes`).
   - **Set there but the frame doesn't change**: the player wasn't rebuilt, or
     a cached frame is being shown. Compare the `CompositionKey` before and
     after, and check `ShapeStep.keyText` (it has the gradient) is what the
     frame cache keys on.
3. Whatever the cause, add a test that draws a gradient rectangle through the
   whole compositor (`LayeredCompositor`, not just `ShapeRendering`). Then add
   the same for export, with `CompositionExporter` on a 2-frame timeline.

---

## 4. Keyframe Designer unaffected by retiming, with a toggle

**Cause.** Keyframing methods sample on *timeline* frames
(`KeyframeSampling`, `Model/Effects/Keyframing.swift:842`) but store keys in
*source* time. The graph's x axis is source seconds
(`KeyframeGraphLayout.x(_:)` / `seconds(atX:)`), so on a retimed clip,
evenly spaced pulses spread out unevenly. `GraphTimeRow` already maps the
timeline's ticks into source x, which is why its ticks look warped.

**Plan**

1. Add a time basis to `ParameterTimeAxis` (`Model/KeyframeEase.swift:257`):
   `enum GraphTime { case timeline, source }` and `var basis: GraphTime`.
   Add `displaySeconds(key:)` and `keySeconds(display:)`: through
   `clip.timelineTime(forSourceTime:)` / `sourceTime(atTimelineTime:)` for
   `.timeline`, identity for `.source` or with no clip. Also give `span` in
   display seconds.
2. `KeyframeGraphLayout`: keep a `ParameterTimeAxis`, or just the two
   closures, and send `x(_:)` / `seconds(atX:)` through it. Callers keep
   passing key seconds, so the hit-testing, drag and snap code in
   `KeyframeGraphView` stays as it is.
   - **Curves**: if segments are drawn as Béziers from the handles, a
     non-linear time warp bends them wrong. Sample each segment, every few
     points, through `value(at:)`, and draw a polyline when the clip is
     retimed. Keep the Bézier path when it isn't, since then the warp is linear.
   - Ease handles: draw them at their warped positions. Leave dragging them
     in key time, and convert the drag delta through the axis.
   - Viewport, fit and zoom (`fitTimes`, `padded`, `timeZooms`) work in
     display seconds.
3. `GraphTimeRow`: in `.timeline` its ticks become linear. Drop the
   `keyTime(atTimeline:)` mapping from `x(_:)` while in timeline basis.
4. Toggle: a two-way control in the Keyframe Designer's header (and the
   graph HUD, which shares `KeyframeGraphView`): **Timeline Time** (the
   default, unaffected by retiming) and **Clip Time** ("as stored", the
   real spacing in the media). Only show it when `clip.isRetimed`. Keep it
   in `Preferences` (`keyframeGraphTimeBasis`) so it sticks, or in
   `KeyframeGraphHUDs` per panel. Give it a VoiceOver label and value per
   `docs/accessibility.md`.
5. Docs and tests: add the toggle to `docs/keyframing-effects.md`
   ("The Keyframe Designer"). In a new `ParameterTimeAxisTests`, check that a
   2× clip's keys at source 0, 2 and 4 s show at 0, 1 and 2 s in timeline
   basis and round-trip. Add a `UISnapshots` case for a retimed clip with a
   Strobe Keys target in both bases.

---

## 5. Timeline doesn't jump when parameter rows appear or disappear

**Cause.** `labelColumnWidth` (`UI/Timeline/TimelineAreas.swift:149`) jumps
150 → 300 when a selected clip's parameter rows show (they depend on the
selection), and back again. That moves the track area's left edge by 150 pt.
In fitted zoom it also changes `fitPixelsPerSecond`, so the scale shifts too.

**Plan**

1. Keep the scale: in `TimelineTrackSurface`'s
   `.onChange(of: geometry.size.width - labelColumnWidth)`
   (`TimelineTrackSurface.swift:186`), if the change came from the label
   column and the timeline is fitted, set `zoomedPixelsPerSecond` to the
   current scale first. That stops the scale moving.
2. Keep the time under each point: on a column change of Δ (new − old),
   set `scrollX += Δ`. The time at the old left edge then stays at the same
   screen x.
3. A lead-in for the narrowing case. When the column shrinks and
   `scrollX - Δ` would go below 0, the space before 0:00 stays empty:
   - Add `var leadIn: CGFloat = 0` to `TimelineViewportModel`. Make
     `TimelineViewport` accept `requestedScrollX` down to `-leadIn` (today it
     clamps to `0...maxScroll`). `x(atSeconds:)` and `seconds(atX:)` already
     handle a negative `scrollX`.
   - Set `leadIn = max(leadIn, -(scrollX - Δ))` when the column narrows.
   - Shrink it only when the timeline is scrolled: in the scroll, scrollbar, pan and zoom
     setters (`TimelineZoom.swift` 72–120 and `TimelineScrollbar`), after
     applying, `leadIn = max(0, -scrollX)`. Scrolling right past 0 sets it
     to 0 and collapses the space. Fit (`reset()`), `show(_:)` and
     zoom-to-fit clear it.
   - Draw nothing before 0: check the ruler, sections lane, loop bar and
     clip lanes start drawing at x(0) rather than assuming 0 is the left
     edge. Clamp hit-tests below 0 to 0 (scrub, lasso start, drops).
   - The scrollbar thumb: treat the range as `-leadIn...maxScrollX`.
4. Alternative, if this is too much: keep the column at 300 whenever the
   timeline has any parameter rows at all, not just shown ones. That's a
   one-line change in `labelColumnWidth` and the timeline never moves. But
   it doesn't give the empty space before 0:00 that was asked for.
5. Tests: `TimelineViewport` accepts a negative scroll within the lead-in
   and clamps past it. A unit test on the model: narrowing from scrollX 0
   gives leadIn 150 and scrollX −150, and scrolling +200 then leaves
   leadIn 0.

---

## 6. Waveform: graph-type toggle and the missing features

**What's there.** Mode (Wave / Spectrum), Draw (Lines / Dots / Bars), Shape
(Line / Radial) and Stereo are all choice controls. In the inspector they're
plain menus, mixed in among about 25 settings, with `waveformShows` hiding
the ones that don't apply. None of it has been tried in the running app.

**Plan.** Confirm the list in step 2 before building, since it guesses at
"many features missing".

1. **A graph-type control at the top of the Waveform's inspector group**
   (`ShapeInspectorGroup` / a new `UI/Inspector/WaveformGraphPicker.swift`):
   - A segmented control of icons for the kind of graph, mapping to existing
     controls: **Wave** (`waveMode = wave, waveDraw = lines`), **Bars**
     (`spectrum + bars`), **Dots**, **Filled** (`lines + waveFillsToBaseline`),
     **Ring** (`waveShape = radial`), **Scope** (`waveStereo = xy`), and
     the new types below.
   - Under it, the existing Mode / Shape / Draw as icon buttons (add glyphs
     in `InspectorGlyphs`), not menus.
   - The same picker in the effects panel's Waveform header, and Tab /
     arrow-key access per `docs/accessibility.md`.
2. **Features to build** (from "Not yet" in `docs/waveform-effect.md`, plus
   graph types it lacks):
   - New graph types (`WaveformDraw` cases and `WaveformDrawing`):
     **Area / Mountain** (a filled envelope with no line), **Spectrogram**
     (scrolling heat-map history, using `Analysis/Spectrogram.swift`),
     **Level meter / VU** (one bar or a pair per channel, with peak hold),
     **Particles / Rays** for the radial shape.
   - **Attack** beside Release, in Spectrum and Wave.
   - **Smoothing in Wave** (temporal, frame to frame).
   - **Bars shaded along their length** for By Level (a gradient per bar).
   - **Peak hold** markers (bars and meter).
   - **Log / linear frequency scale** and a **dB floor** setting (today it
     is fixed at −80 dB).
   - **Hearing the EQ** and **nested timelines' sound**
     (`EditingProject.waveformSounds`), and **volume edits without a
     rebuild**: read the volume from the live project at draw time, or
     include volumes in `CompositionKey`.
   - **Count from a bar width** (bars of N px, the count derived from length).
   - **A preview in the picker**: tiny thumbnails from `LookRecipes.waveformStyles`.
3. Each new choice case needs: the `WaveformDraw` / `WaveformMode` enum
   case, its `waveformShows` rules, its drawing in `WaveformDrawing.paints`,
   `WaveformSetup.keyText`, a preset in `LookRecipes` (bump the version so
   the presets reinstall), the docs, and a `WaveformTests` case.
4. Test it through the compositor from a sound file. That's the doc's
   open "Not yet" test, and it would catch a Waveform that draws nothing in
   the app.

---

## Suggested order

Do 5, then 1, 4, 2 (which needs the Mac to diagnose), and 6 (whose list
needs confirming).
