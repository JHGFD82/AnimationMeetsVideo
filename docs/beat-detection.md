# Beat detection

Status: **implemented**: detection, saving, and showing the beats of one
audio layer as markers on the timeline. It is unit tested; the timeline
picker and markers are compile-checked but have not been exercised on screen.
What is not built is listed under [Not implemented yet](#not-implemented-yet).

Any media file that has an audio track (an audio file, or a video with
sound) is analyzed for beats when it enters the project. The beats are shown
on the timeline for one audio layer at a time, chosen in the timeline's view
options.

## What is detected

`BeatDetector.detect(url:)` reads the file's first audio track and finds a
steady beat:

1. The audio is decoded in a stream to mono, 22,050 Hz floats, so a long
   file is never held in memory.
2. `OnsetAnalyzer` takes a short Fourier transform (1024 samples, hop of
   256) and measures, frame by frame, how much louder each frequency has
   become (spectral flux, log compressed). The result is an onset curve:
   about 86 values per second saying how much new sound starts there.
3. `BeatTracker` estimates one tempo from the curve's autocorrelation,
   weighted toward 120 BPM (which settles tempo versus double or half
   tempo), within 60 to 200 BPM. It then picks beats with dynamic
   programming: each beat should land on a strong onset and about one tempo
   period after the previous one. Weak beats at the very start and end are
   trimmed.

Audio shorter than 4 seconds, or with no usable onsets, gives an **empty
result**. That is saved like any other result, so the file is not analyzed
again every time the project opens. An unreadable file is a failure and is
shown in the browser; it can be retried by reopening the project.

## Beats are stored per asset, in the asset's time

A `BeatTrack` holds beat times (in samples at 22,050 Hz, adjusted by the
audio's first presentation time) and the tempo. It belongs to the asset, not
to a clip or layer, so moving or trimming a clip, or using the same file
twice, needs no re-detection.

Where beats fall on the timeline is **derived**, never stored:
`EditingProject.beatMarkers(in:tracks:)` takes each clip on a layer, keeps
the beats inside its trim range, and moves them by the clip's start offset.

## Choosing which layer's beats to show

More than one layer can have audio with beats, but showing all of them would
be unreadable. The view options popover (the sliders button on the timeline)
has a **Beat Markers** picker listing the layers whose clips have beats, plus
None.

The choice is just a layer ID held by the timeline view. The choices come
from `EditingProject.beatLayers(in:tracks:)` every time, so when a layer is
deleted (or its clips lose their beats) it **drops out of the picker and its
markers disappear**, with no cleanup step. The choice is view state and is
not saved with the project.

Markers are drawn as orange ticks in the ruler with faint lines down through
the layers, under the playhead and ignoring the mouse.

## Saving

`Reference/<asset id>/beats.bin`, next to the change scores:

| Field | Type |
| --- | --- |
| magic `AMVB` | 4 bytes |
| version | UInt32 (1) |
| timescale | Int32 |
| beat count | UInt32 |
| tempo | Float32 bit pattern |
| beat times | Int64 each |

All integers are little endian. `AssetAnalysis` holds results in memory,
remembers which are unsaved, and `ProjectStore.save` writes only those. A
missing file means "not analyzed yet"; a damaged one is treated the same,
since beats can be recomputed. The file is recomputable, so a project
without it still opens.

## When it runs

`AssetAnalysis` queues one job per asset (reference data first, then scene
scores for video and reference pictures, then beats) on its serial
background queue. Beats are queued for assets whose `MediaClip.hasAudio` is
set, which the importer fills in from the file's audio tracks. The browser
row shows progress and, once done, the tempo.

## Not implemented yet

- **Changing tempo.** One steady tempo is assumed. Music that speeds up,
  slows down, or has tempo changes drifts off the markers after the change.
- **Editing markers** by hand, nudging, or adding missing beats.
- **Snapping** clips or the playhead to markers.
- **Re-detect** from the browser, or a choice of tempo range.
- Markers for audio inside **nested timelines**; only clips placed directly
  on a layer are considered.
- Analyzing audio other than the file's first audio track.
