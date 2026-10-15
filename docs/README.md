# Design docs

Design notes for AnimationMeetsVideo. Each document says whether it
describes something that exists today or a planned design. Unless a
document says otherwise, treat it as **planned, not implemented**.
Currently: the package format, the scene-cut browser, media replacement,
beat detection, audio levels and the timeline view are
implemented (each document lists what remains).

| Document | Covers |
| --- | --- |
| [scene-cuts.md](scene-cuts.md) | Implemented (core). Detecting scene cuts in a media file and treating each scene as a virtual clip in the browser, without touching the file. |
| [beat-detection.md](beat-detection.md) | Implemented. Finding the beats of audio tracks, and showing one audio layer's beats as timeline markers chosen from the view options. |
| [layer-transforms.md](layer-transforms.md) | Replaced by effects. Keyframes, eases, the graph editor and arithmetic in numeric fields, which carry over; layers no longer have a transform. |
| [effects.md](effects.md) | Being built (see its Building it). Per-clip effect stacks applied in the order listed (Transform, Blending and Color to start), an anchor point on every visual clip, closed nested timelines, adjustment layers with a set reach, the effects panel, and strict project loading. Replaces layer transforms. |
| [audio.md](audio.md) | Implemented (core). Keyframed layer volume from mute to +6 dB in playback and export, and a meter of the whole mix beside the timeline. |
| [timeline.md](timeline.md) | Implemented. Zooming and scrolling the timeline, the ruler's tick grouping, the playhead, frame-locked moving and trimming of clips, linked and detached audio, and transitions. |
| [media-replacement.md](media-replacement.md) | Implemented (core). Replacing a file with a different version ("bait and switch"), the reference data that makes it safe, and how mismatches are handled. |
| [rendering.md](rendering.md) | Implemented. Drawing the viewer at reduced size (Auto, Full, Half, Quarter), rendering full-size frames in the background when idle, and reusing them in ProRes 422 exports. |
| [project-package.md](project-package.md) | The on-disk project format: a package folder with a JSON project file, assets, reference data, and a render cache. |

## Shared principles

- **Media files are never modified.** Everything the app learns about a
  file (scene cuts, thumbnails, signatures) is stored as metadata next to
  the project, never in or beside the original footage.
- **Storage is a first-class concern.** The app does not generate proxy or
  transcoded copies of footage. Anything it stores per asset is small, and
  disposable data is kept separate from data that cannot be regenerated.
- **The person is responsible for the footage.** The app detects and reports
  mismatches, auto-adjusts what is safe to adjust, and only blocks on
  things that would silently break sync.
- **Open and hand-editable.** Project data is plain text with stable IDs, so
  it can be read, diffed, and edited outside the app.
