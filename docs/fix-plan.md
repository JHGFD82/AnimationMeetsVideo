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

Do 1, then 4, 2 (which needs the Mac to diagnose), and 6 (whose list
needs confirming).
