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

## 6. Waveform: graph-type toggle and the missing features

**What's there.** Mode (Wave / Spectrum), Draw (Lines / Dots / Bars), Shape
(Line / Radial) and Stereo are all choice controls. In the inspector they're
plain menus, mixed in among about 25 settings, with `waveformShows` hiding
the ones that don't apply. None of it has been tried in the running app.

**Plan.** Confirm the list in step 2 before building, since it guesses at
"many features missing".

1. **A graph-type control at the top of the Waveform's inspector group**
   (built: Graph with Wave, Filled, Dots, Bars, Ring and Scope, and Mode,
   Shape and Draw as icon buttons; see docs/waveform-effect.md. Left:
   the same picker in the effects panel's Waveform header, and the new
   types of step 2.)
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
