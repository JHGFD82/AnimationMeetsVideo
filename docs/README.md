# Design docs

Design notes for AnimationMeetsVideo. Each document says whether it
describes something that exists today or a planned design. Unless a
document says otherwise, treat it as **planned, not implemented**.
Currently: the package format, the scene-cut browser, media replacement,
beat detection, audio levels, the timeline view, effects, transitions,
Matroska import, effect packages and accessibility are implemented (each document lists what remains).

| Document | Covers |
| --- | --- |
| [scene-cuts.md](scene-cuts.md) | Implemented (core). Detecting scene cuts in a media file and treating each scene as a virtual clip in the browser, without touching the file; splitting and merging them in the scene splitter, with timeline clips split, joined or embedded to follow. |
| [beat-detection.md](beat-detection.md) | Implemented. Finding the beats of audio tracks, and showing one audio layer's beats as timeline markers chosen from the view options. |
| [beat-matching.md](beat-matching.md) | Built, not yet tried on screen. Confirming a song's beats by hand in the beat match panel: anchors, sections of one tempo or a ramp, measures, and the beat map saved with the project. |
| [motion-designer.md](motion-designer.md) | Built, not yet tried on screen. Retiming clips to the music in a panel: hits that pin a frame to a beat, markers dragged along a time graph, pace markers, eases, written out as speed keyframes, with clips trimmed and their edges held within their scenes; clips attached to the music, and hold keyframes. |
| [layer-transforms.md](layer-transforms.md) | Replaced by effects. Keyframes, eases, the graph editor and arithmetic in numeric fields, which carry over; layers no longer have a transform. |
| [effects.md](effects.md) | Built (see its Building it). Per-clip effect stacks applied in the order listed (Transform, Blending, Color and Matte), an anchor point on every visual clip, closed nested timelines, adjustment layers whose clips each set their reach, the effects panel, and strict project loading. Time and Shutter, inputs, speed ramps and Optical Flow, copy and presets with paste changes. Replaces layer transforms. |
| [equalizer.md](equalizer.md) | Implemented. The EQ sound effect's eight parametric bands, its own biquad filters in playback and export, the graph over a live spectrum, and loading EQs saved before bands; why Logic Pro's Channel EQ can't be borrowed. |
| [keyframing-effects.md](keyframing-effects.md) | Built. A Keyframing category of effects that write real keyframes onto controls below them: Audio Keys (from a sound's frequency bands), Beat Keys, Wiggler, Oscillator, Smoother, Looper, Time Step and Overshoot. |
| [psychedelic-effects.md](psychedelic-effects.md) | Built. 25 Noise, Color and Distortion effect kinds that combine into psychedelic looks over footage or generated pictures, recipes, and the cheapest built-in macOS way (Core Image filters, Metal kernels, Vision) to draw each. |
| [effect-packages.md](effect-packages.md) | Built. Looks as effect packages (`.amveffect` folders of JSON and a Metal kernel), written and installed without building the app: the 76 that ship, every look (Displace reading its input and Against, Feedback and Slit-Scan earlier moments, Flow Smear the motion ahead), and the person's, read at launch; how to write one, and making, copying and opening one from the app; problems shown in the effects library; missing effects in projects; what stays in Swift. |
| [effects-correction.md](effects-correction.md) | Built. The twelve Color Correction effects, packages with color kernels: Levels, Highs & Lows, Hue/Saturation, Vibrance, Hue Range, Gray Point, Black & White, Colorize, Sepia, Invert, Threshold and Broadcast Safe; the tones they work on in SDR and HDR, and what is left. |
| [effects-light.md](effects-light.md) | Built. The Light category's effect packages (Glow, Bloom, Halation, Light Rays, Lens Flare, Light Leak, Spotlight, Vignette), how they add light in linear light for SDR and HDR, and how the glows use repeated passes to read the picture twice. |
| [effects-keying.md](effects-keying.md) | Built. The Keying & Masks effects, as packages: Chroma, Luma and Difference Keys, Despill, Matte Choker, Box, Ellipse, Corner and Gradient Masks, and Alpha Tools; how each keys or masks, and a green screen stack. |
| [effects-blur.md](effects-blur.md) | Built. The nine Blur & Sharpen effects (Gaussian, Directional, Zoom, Spin, Lens, Tilt-Shift, Surface Blur, Sharpen, Unsharp Mask) as effect packages: their controls, Repeat or Transparent edges, and the two-pass kernels. |
| [effects-stylize.md](effects-stylize.md) | Built. The twelve Stylize effect packages (Pixelate, Halftone, Crystallize, Oil Paint, Cel Shade, Find Edges, Emboss, Scan Lines, VHS, Old Film, Film Damage, Strobe): what each draws, its controls, why they are kernels rather than Core Image's filters, and which change every frame or can flash. |
| [audio.md](audio.md) | Implemented (core). Keyframed volume and pan on clips and layers, sound effects (EQ, Compressor, Limiter) on clips, fades under transitions, a level and loudness meter of the whole mix, and exports mastered to a loudness target. |
| [transitions.md](transitions.md) | Implemented. The 25 transition kinds of pictures in five categories and the three of sound, their settings, how each is drawn, and what counts as a kind. |
| [timeline.md](timeline.md) | Implemented. Zooming and scrolling the timeline, the ruler's tick grouping, the playhead, frame-locked moving and trimming of clips, linked and detached audio, and transitions. |
| [scene-detection-review.md](scene-detection-review.md) | Review notes. Measured behavior of scene detection and splitting on real decoded fixtures, the defects found, and the tests that pin them. |
| [media-replacement.md](media-replacement.md) | Implemented (core). Replacing a file with a different version ("bait and switch"), the reference data that makes it safe, and how mismatches are handled. |
| [rendering.md](rendering.md) | Implemented. Drawing the viewer at reduced size (Auto, Full, Half, Quarter), rendering full-size frames in the background when idle, and reusing them in ProRes 422 exports. |
| [accessibility.md](accessibility.md) | Implemented (core). Keyboard access to the playhead and clips, VoiceOver across the timeline, inspector, viewer and browser, text contrast and reduced motion, the rules new UI follows, and what remains. |
| [browser.md](browser.md) | Being built. The browser left of the viewer: Clips, Timelines and Generators (text and shapes) tabs, filmstrips, skimming in the viewer, whole-clip and range drags, used-media underlines, and preset previews over generated footage. |
| [graphic-layers.md](graphic-layers.md) | Stills, shapes and strokes (stroke a stroke, inside or outside an edge) built, and text layers (Illustrator's character, paragraph and OpenType settings, styled runs, kerning by hand and optical kerning, hyphenation, variable axes, animators and text on a path), with shapes' and text's settings, fill and stroke in the inspector; gradients, free paths and path operations planned. Still images imported from files, and shapes and text made in the app and drawn as vectors: their model, how the compositor draws them without a track, keeping them sharp, and saving. |
| [matroska.md](matroska.md) | Implemented. Importing MKV files through reference movies in the package's cache that point at their frames in place, so H.264 and HEVC in Matroska play and edit without a copy; the timing and AAC priming details that keep sound in sync. |
| [loose-ends.md](loose-ends.md) | Temporary. What is left over from the UX pass (PR #24): checks to make before merging, what to try in the app, and small gaps left on purpose. Delete when empty. |
| [project-package.md](project-package.md) | The on-disk project format: a package folder with a JSON project file, assets, reference data, and a render cache. |

## Shared principles

- **Media files are never modified.** Everything the app learns about a
  file (scene cuts, thumbnails, signatures) is stored as metadata next to
  the project, never in or beside the original footage.
- **Footage is played from its own file, in its own codec.** H.264, HEVC
  and ProRes video (QuickTime or MPEG-4 files), and sound files (WAV,
  AIFF, AAC, FLAC and the rest Core Audio reads), are decoded straight from
  the file in the viewer, the browser, analysis and export alike. The app
  never makes proxies, optimized copies or transcodes of footage, ProRes or
  otherwise, and never re-encodes a file to make it editable.
- **Matroska is read in place.** AVFoundation can't open MKV files, so for
  each one the app makes a reference movie: a QuickTime movie of a few
  megabytes holding only the index of the MKV's frames, whose samples point
  at those frames inside the MKV, in `Cache/References/` in the package
  (see [matroska.md](matroska.md)). Its H.264 or HEVC video and its AAC,
  FLAC or PCM sound are then decoded from the MKV itself.
- **What the app does write is small or disposable.** Per asset it keeps
  reference data (`Reference/`: audio envelopes, change scores, beats,
  thumbnails), which can't be regenerated once a file is replaced. Its
  caches can always be made again: rendered segments of the timeline where
  effects are too costly to draw live (`Cache/Renders/`, ProRes, of the
  timeline and not of the footage; see [rendering.md](rendering.md)),
  Matroska reference movies (`Cache/References/`), and a stereo copy of a
  mono sound file so it can be panned (in the user's Caches folder; see
  [audio.md](audio.md)), the one copy of a file's media the app makes on
  its own (copying files into `Media/` is the person's choice).
- **The person is responsible for the footage.** The app detects and reports
  mismatches, auto-adjusts what is safe to adjust, and only blocks on
  things that would silently break sync.
- **Open and hand-editable.** Project data is plain text with stable IDs, so
  it can be read, diffed, and edited outside the app.
