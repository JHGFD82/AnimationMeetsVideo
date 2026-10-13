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

`BeatDetector.detect(url:)` reads the file's first audio track and finds
its beats, following the tempo where it ramps or changes:

1. The audio is decoded in a stream to mono, 22,050 Hz floats, so a long
   file is never held in memory.
2. `OnsetAnalyzer` takes a short Fourier transform (1024 samples, hop of
   256) and measures, frame by frame, how much louder each frequency has
   become (spectral flux, log compressed). The result is an onset curve:
   about 86 values per second saying how much new sound starts there.
3. `BeatTracker` measures the tempo locally: for each 8-second stretch,
   one second apart, it scores every period from 60 to 200 BPM by the
   curve's autocorrelation, weighted toward 120 BPM (which settles tempo
   versus double or half tempo). The curve is blurred slightly for this
   step only, so a period that falls between two whole frames isn't
   undercounted.
4. A Viterbi pass picks one tempo per stretch. Changing tempo between
   neighbouring stretches costs 40 per squared octave, capped at 2.5 (a
   stretch's best score is 1). A ramp's small steps are cheap to follow,
   while a sudden change, or a flip to double or half tempo, is taken only
   once a few seconds of music are better explained by it.
5. The period is interpolated between the stretches' centers. Across a
   jump of more than about 7% it isn't interpolated: for a second and a
   half either side of the jump, the next step may use either tempo, so
   the onsets decide where the change falls.
6. Beats are picked with dynamic programming (after Ellis, "Beat Tracking
   by Dynamic Programming"): each beat should land on a strong onset and
   about one local period after the previous one. Weak beats at the very
   start and end are trimmed.

Audio shorter than 4 seconds, or with no usable onsets, gives an **empty
result**. That is saved like any other result, so the file is not analyzed
again every time the project opens. An unreadable file is a failure and is
shown in the browser; it can be retried by reopening the project.

## Beats are stored per asset, in the asset's time

A `BeatTrack` holds beat times (in samples at 22,050 Hz, adjusted by the
audio's first presentation time) and the tempo. It belongs to the asset, not
to a clip or layer, so moving or trimming a clip, or using the same file
twice, needs no re-detection.

Beats are found in the asset's current file, so for a replaced asset they
are in that file's time, while trims stay in the original's time.
`AssetAnalysis` remembers which file (path and accepted file stamp) each
result came from. When the asset points at another file, including through
undo, or its accepted file changes, or it loses its sound, the beats are
dropped at once and found again from the new file. Beats read from the
package are taken to belong to the file the asset has when the project
opens.

Where beats fall on the timeline is **derived**, never stored:
`EditingProject.beatMarkers(in:tracks:)` takes each clip on a layer, maps its
trim range into file time with the asset's alignment offset, keeps the beats
inside it, and moves them to where the clip sits. The timeline view keeps
the result and works it out again only when the chosen layer, its beats or
its assets' offsets change, not on every playback tick or scroll.

## Choosing which layer's beats to show

More than one layer can have audio with beats, but showing all of them would
be unreadable. The view options popover (the sliders button on the timeline)
has a **Beat Markers** picker listing the layers whose clips have beats, plus
None.

The choice is just a layer ID held by the timeline view. The choices are
the layers for which `EditingProject.layerHasBeats(_:tracks:)` holds,
checked every time (`beatLayers(in:tracks:)` gives the same list), so when a layer is
deleted (or its clips lose their beats) it **drops out of the picker and its
markers disappear**, with no cleanup step. The choice is view state and is
not saved with the project.

Markers are drawn as orange ticks in the ruler with faint lines down through
the layers, under the playhead and ignoring the mouse. When zoomed out so
far that they would be closer than 10 points, only every 2nd, 4th, 8th…
beat is drawn, counted from the track's first beat (see
[timeline.md](timeline.md)).

## Saving

`Reference/<asset id>/beats.bin`, next to the change scores:

| Field | Type |
| --- | --- |
| magic `AMVB` | 4 bytes |
| version | UInt32 (2) |
| timescale | Int32 |
| beat count | UInt32 |
| tempo (median over the beats) | Float32 bit pattern |
| beat times | Int64 each |

All integers are little endian. Version 1 files hold beats fitted to one
steady tempo; they are read as missing, so those beats are detected again
with the changing-tempo tracker. `AssetAnalysis` holds results in memory,
remembers which are unsaved, and `ProjectStore.save` writes only those.
Saved beats that were dropped because the file changed are deleted at the
next save, so a reopened project never shows beats from an earlier file. A
missing file means "not analyzed yet"; a damaged one is treated the same,
since beats can be recomputed. The file is recomputable, so a project
without it still opens.

## When it runs

`AssetAnalysis` queues one job per asset (reference data first, then scene
scores for video and reference pictures, then beats) on its serial
background queue. Beats are queued for assets whose `MediaClip.hasAudio` is
set, which the importer fills in from the file's audio tracks. The browser
row names the stage running (reading the original, finding scenes, saving
pictures, finding beats) with that stage's progress, starting from zero for
each, and once done shows the tempo: the median, or the range the beats
keep up for a few beats ("92–140 BPM") when it varies by more than 4%.

## Not implemented yet

- **Tempo changes faster than a few seconds.** The tempo is measured over
  8-second stretches, so rubato or a change that lasts only a bar or two
  is smoothed over. Only click tracks have been tested; tune the constants
  in `BeatTracker` against real music.
- **Editing markers** by hand, nudging, or adding missing beats.
- **Snapping** clips or the playhead to markers.
- **Re-detect** from the browser, or a choice of tempo range.
- Markers for audio inside **nested timelines**; only clips placed directly
  on a layer are considered.
- Analyzing audio other than the file's first audio track.
