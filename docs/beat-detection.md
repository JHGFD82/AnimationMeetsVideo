# Beat detection

Status: **implemented**: detection, saving, and showing the beats of one
audio layer as markers on the timeline, with an optional click on each
beat during playback. It is unit tested; the timeline picker, markers and
clicks are compile-checked but have not been exercised on screen.
What is not built is listed under [Not implemented yet](#not-implemented-yet).

Only music is analyzed: an asset is analyzed for beats once a clip of it
sits on a **Music layer** (of any timeline). Audio files are placed on Sound
layers unless dropped on a Music one, and a video's sound only gets there
once it is detached and dragged from the Sound area into the Music area, so
dialogue and effects are never analyzed. The beats are shown
on the timeline for one audio layer at a time, chosen in the timeline's view
options.

## What is detected

`BeatDetector.detect(url:)` reads the file's first audio track and finds
its beats, following the tempo where it ramps or changes:

1. The audio is decoded in a stream to mono, 22,050 Hz floats, so a long
   file is never held in memory. `TimedSamples` places each buffer at its
   presentation time rather than joining them end to end: a gap is filled
   with silence, audio overlapping what came before is dropped, and a
   difference of up to two samples counts as rounding. A jump further
   ahead than the asset is long (at least a minute) is damage.
2. `OnsetAnalyzer` takes a short Fourier transform (1024 samples, hop of
   256) and measures, frame by frame, how much louder each frequency has
   become (spectral flux, log compressed). DC and Nyquist, which the real
   FFT packs together into its first slot, are left out. The result is an
   onset curve: about 86 values per second saying how much new sound
   starts there.
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
7. The chain lays a regular string of beats over any sound, so it is then
   checked for a real pulse (`BeatTracker.Confidence`), and rejected
   unless all of these hold:
   - **Periodicity contrast** of at least 0.25: for each stretch, how much
     more the onset curve correlates with itself one, two or four periods
     on (the best of the three; a bar repeats more exactly than a beat)
     than at a typical lag in the tempo range, the median over stretches
     that aren't silent. Speech and noise correlate about as much at any
     lag and score near 0; a pulse that repeats exactly scores about 1.
   - **Agreement** of at least 2, unless the periodicity contrast is 0.5
     or more: the onset strength at the beats over that at the same beats
     moved a quarter, half and three quarters of the way to the next.
     Noise, where the chain only finds local bumps, comes to about 1.5;
     so do steady sixteenth-note hi-hats, which is why a clearly periodic
     curve is let off.
   - **Support across intervals**: at least a quarter of the gaps between
     beats, and at least 4, have an onset of the curve's RMS or more
     within two frames of both ends.

   The thresholds come from whole files, as the app analyzes them (full
   mixes and the instrument, drum and vocal stems of several songs, a
   crowd track, a dither-only stem, a spoken recording, a feature film's
   dialogue), and from synthetic material (click tracks, drum patterns
   loud and quiet, white and wandering noise, speech-like syllables,
   isolated and random clicks). Speech, crowd, noise and dither scored a
   periodicity contrast of at most 0.15 and vocal stems up to 0.26, while
   every song and rhythmic stem scored at least 0.32, the lowest being a
   pop song whose busy vocal sits over a light rhythm section. So a vocal
   stem on its own may get beats; dialogue doesn't.
8. The tempo reported is that of the beats kept: 60 over the median gap
   between consecutive beats (the mean of the middle two for an even
   count). It matches the markers even where the chain took the period
   from the other side of a jump, ignores a few missed or doubled beats,
   and for a tempo that changes is the one held for the most beats.

Audio shorter than 4 seconds, with no usable onsets, or without a steady
pulse (noise, speech, a few isolated hits) gives an **empty result**. That is saved like any other result, so the file is not analyzed
again every time the project opens. An unreadable file is a failure and is
shown in the browser; it can be retried by reopening the project. So is
one whose decoded audio is damaged (a buffer that isn't the mono float
PCM asked for, has the wrong number of bytes for its samples, or can't
be copied) or whose read stops before the end: those are never saved as
an empty result. Cancelling (when the asset leaves the project or the
project closes) is checked before reading starts, before every buffer
(so also at the end of the audio), while a gap is filled, through the
tempo and beat passes, and before the result is returned; it always ends
in `CancellationError`, with the reader cancelled.

## Beats are stored per asset, in the asset's time

A `BeatTrack` holds beat times (in samples at 22,050 Hz, from the
presentation time of the first buffer that held any samples) and the tempo. It belongs to the asset, not
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
has a **Beat Markers** picker listing the Music layers whose clips have
beats, plus None.

The choice is just a layer ID held by the timeline view. The choices are
the layers for which `EditingProject.layerHasBeats(_:tracks:)` holds,
checked every time (`beatLayers(in:tracks:)` gives the same list). It
holds when the layer would get at least one marker: it looks clips up the
same way `beatMarkers` does (the asset, its audio, the replacement offset,
the half-open trim range) and asks the track whether any beat lies in the
range with a binary search, without building the markers. So when a layer
is deleted, its clips lose their beats, or its trims leave out every beat,
it **drops out of the picker and its markers disappear**, with no cleanup
step. The choice is view state and is not saved with the project.

Markers are drawn as orange ticks in the ruler with faint lines down through
the layers, under the playhead and ignoring the mouse. Detected beats are
drawn dimmer and dashed, since nobody has confirmed them; once the song is
beat matched its confirmed beats replace them (see
[beat-matching.md](beat-matching.md#on-the-timeline)). When zoomed out so
far that detected beats would be closer than 10 points, only every 2nd,
4th, 8th… beat is drawn, counted from the track's first beat (see
[timeline.md](timeline.md)).

With snapping on (N), clip edges, the blade and the playhead snap to the
shown layer's beats (see [timeline.md](timeline.md#snapping)).

## Hearing the beats

Below the picker, **Tick on beats** plays a short tone on each marker of
the chosen layer while the timeline plays, so the markers can be checked
by ear. It is off, and can't be turned on, while the picker is at None.
When on, a **Pitch** slider (200–2000 Hz, 1000 by default) sets the tone
and a **Volume** slider (80% by default) its level; letting go of either
slider, or the speaker button beside them, plays one tone as a preview.
The settings are remembered across launches in user defaults, not saved
with the project, and are shared with the beat match panel
(`ClickToneControls`); both places call the tone a tick. A beat marked as
a downbeat ticks an octave higher; detected beats have no measures, so
they all tick at the set pitch.

`BeatClickPlayer`, owned by `PlaybackModel` next to the shared `AVPlayer`,
does the playing. It does not fire tones from a time observer, which would
land wherever the main thread got to them. Instead it schedules them a
second ahead on an `AVAudioPlayerNode`, at host times converted from the
player item's timebase and moved earlier by the output device's latency
(AVPlayer delays its picture by the same amount). Every 0.25 s it adds the
next stretch. Play, pause, a seek, a rate change, a rebuilt player item or
new markers throw away everything scheduled and start again from now. The
tone is 50 ms of sine with a 2 ms fade in and a fast exponential decay, so
it sounds like a click with a pitch. Clicks play only during playback, not
while scrubbing, and are not part of the export.

## Saving

`Reference/<asset id>/beats.bin`, next to the change scores:

| Field | Type |
| --- | --- |
| magic `AMVB` | 4 bytes |
| version | UInt32 (2) |
| timescale | Int32 |
| beat count | UInt32 |
| tempo (from the median gap between beats) | Float32 bit pattern |
| beat times | Int64 each |

All integers are little endian. Version 1 files hold beats fitted to one
steady tempo; they are read as missing, so those beats are detected again
with the changing-tempo tracker. `AssetAnalysis` holds results in memory,
remembers which are unsaved, and `ProjectStore.save` writes only those.
Each saved beat file has a record in `provenance.json` (the file it was
found in, the analysis settings, an algorithm version, a digest of the beat
file), and beats are loaded only when it still applies, so a reopened
project never shows beats from an earlier file, and beats saved without a
record are found again rather than assumed current. Beats dropped because
the file changed are deleted at once when the project has a package, or at
the next save; if the file can't be deleted its record is marked
invalidated, and if that fails too the retirement stays pending and is
reported (see [scene-cuts.md](scene-cuts.md)). A
missing file means "not analyzed yet"; a damaged one is treated the same,
since beats can be recomputed. The file is recomputable, so a project
without it still opens.

## When it runs

`AssetAnalysis` queues one job per asset (reference data first, then scene
scores for video and reference pictures, then beats) on its serial
background queue. Beats are queued for assets whose `MediaClip.hasAudio` is
set (the importer fills it in from the file's audio tracks) and that have a
clip on a Music layer (`EditingProject.assetsOnMusicLayers`). Whether an
asset is on music is part of its analysis input, so moving its last music
clip away cancels beat detection under way; beats already found are kept,
for when it comes back. The browser
row names the stage running (reading the original, finding scenes, saving
pictures, finding beats) with that stage's progress, starting from zero for
each. Finding beats gives reading the audio the first 80% (by the buffers'
timestamps, clamped and never going back) and tracking the rest (it took
about a fifth of the time on a three-minute song); it reaches 100% only
with a result, never for a failed or cancelled run. Once done the row
shows the tempo: the median, or the range the beats
keep up for a few beats ("92–140 BPM") when it varies by more than 4%.

## Not implemented yet

- **Tempo changes faster than a few seconds.** The tempo is measured over
  8-second stretches, so rubato or a change that lasts only a bar or two
  is smoothed over. Only click tracks have been tested; tune the constants
  in `BeatTracker` against real music.
- **Editing markers** by hand, nudging, or adding missing beats.
- **Re-detect** from the browser, or a choice of tempo range.
- Markers for audio inside **nested timelines**; only clips placed directly
  on a layer are considered.
- Analyzing audio other than the file's first audio track.
