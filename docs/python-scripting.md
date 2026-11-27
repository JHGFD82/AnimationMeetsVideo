# Python scripting

Status: **built**, but for NumPy (step 12 of [Building it](#building-it)),
which step 10's measurement doesn't call for. Steps 1 to 8 have been
built and tried on a Mac; steps 9 to 11 (Between Frames, re-running only
the changed samples, following a held drag), the accessibility review
(13) and these docs (14) were written since. They build and their tests
pass, with a real interpreter too (the code review's baseline), but
haven't been tried by hand.
No Python release is pinned in the repository: `scripts/fetch-python.sh
--pin`, run on the Mac that builds the app, writes the pin to
`scripts/python-pin`, which git ignores.

The document was written as the plan, before the build: it says what
the person sees, then how it works, then where each piece goes in the
code, then the order to build it in. Where the build differs, a note
**As built** says how; choices made while writing it are under
[Decisions made here](#decisions-made-here).

Two ways to work on a project in Python, on one framework:

- **Expressions**: a few lines of Python that work out a control's value
  over time, as expressions do in After Effects. Here an expression is a
  Keyframing method ([keyframing-effects.md](keyframing-effects.md)): it
  writes real keyframes.
- **Scripts**: Python that reads and edits the project, as `bpy` does in
  Blender, run from a **Scripts** menu or typed into a console. A run is
  one undo step.

Both use the same three pieces: a Python **helper process**, a
**protocol** between it and the app, and the **`amv` module**, whose
objects are the project's own model, served by the app.

## What the person sees

### An expression

The Keyframe Designer gets a ninth method chip, **Expression**. Picking
it for a control shows a code editor where the other methods show their
settings, and the control's graph beside it as ever.

```python
value + 30 * sin(t * tau * 2)        # a wobble on what is there
```

```python
100 if beats.index % 2 == 0 else 40  # Opacity: dim on every other beat
```

```python
# Position: swing sideways, and fall through each beat.
swing = a * sin(t * tau * b)         # A and B are the inputs below the code
drop = 200 * beats.phase ** 2
[value[0] + swing, value[1] + drop]
```

```python
# Follow another control of the clip half a second late.
clip.effect("Transform")["position"].at(time - 0.5)
```

```python
# Scale with the logo, which is in another timeline.
logo = project.timeline("Titles").layer("Logo").clip_at(time)
logo.effect("Transform")["scale"].value
```

- The code is ordinary Python. **The value of its last line is the
  result**, as in a notebook; lines before it can set names.
- **Command-Return**, or the **Apply** button, runs it. Until
  then the editor holds a draft, marked as edited; Escape puts the
  applied code back.
- The keyframes land a moment later (a three-minute clip is a few
  thousand calls, some tens of milliseconds) and the graph redraws. They
  are generated keyframes like any method's: drawn in the generated
  color, refused hand edits, kept by **Bake Keyframes**.
- **A mistake** shows under the editor with its line, and the moment it
  happened when it isn't in every sample: "Line 2: NameError: name 'tim'
  is not defined". The control keeps the keyframes it had, and its
  [badge](keyframing-effects.md#the-badge) turns to the warning.
- Under the code: four **inputs**, A to D, ordinary numeric controls
  that the code reads as `a`, `b`, `c` and `d` and that can be
  keyframed; **Seed**; **Keyframes** (Smooth or Stepped);
  **Between Frames** (Auto, Off, 2, 4 or 8 moments a frame; see
  [Between frames](#between-frames)); and **Tolerance**.
- **Applies To** has Component, Range, Listen To and Beats From, as the
  other methods have between them. Combine isn't offered: the code says
  how its result meets `value`.

### A script

A script is a `.py` file in the project's own package, in `Scripts/`
beside `project.json` and `Media/`, so it is kept, copied and sent
with the project it works on. There is no folder of scripts for
every project. Each is listed in the **Scripts** menu under the first
line of its docstring, or its file name.

```
MyProject.amv/
  project.json
  Media/
  Scripts/
    stagger.py
    blur-in.py
    shots.csv         anything a script reads can sit beside it
```

```python
"""Stagger Selected Clips"""
import amv

for n, clip in enumerate(amv.selection):
    clip.start += n * 2 * amv.timeline.frame
```

```python
"""Blur In"""
import amv

for clip in amv.selection:
    blur = clip.effects.add("gaussianBlur")
    start = clip.trim_start
    blur["blurRadius"].keyframes = [(start, 40), (start + 1, 0)]
```

- Choosing one runs it on the project in the front window. Everything it
  changed is **one undo step**, "Run “Stagger Selected Clips”".
- **All or nothing**: a script that raises changes nothing. Its
  traceback opens in the console.
- While it runs, a sheet over the window names it, counts the seconds
  and has **Stop**. The window takes no other input meanwhile
  (`WindowInputBlock`).
- The menu also has **New Script…**, which makes a file in the
  project's `Scripts/` and opens it in the Mac's editor for `.py` files;
  **Show Scripts Folder**; **Run Script File…**, for a script kept
  anywhere else, with the last few run that way listed under it;
  **Python Console**; and **Review Expressions…**. A file added to or
  changed in the folder is picked up without reopening the project.
- A script runs with its folder as the working directory, so
  `open("shots.csv")` reads the file beside it.

### The console

**Python Console** is a floating panel: output above, one input line
below, with history on the up and down arrows. `amv` is already
imported. Each line entered is a run of its own, so each is an undo step
when it changed something. Names set on one line are there on the next.
What scripts print, and their tracebacks, go here too.

### Allowing code

Python that came from somewhere else doesn't run until the person has
seen and allowed it (see [Safety](#safety)).

- Code typed into the designer's editor or the console is allowed by
  that act, and so are the scripts of a project made on this Mac.
- **A script in a project that came from somewhere else** asks the first
  time it is chosen: "“Stagger Selected Clips” came with this project.
  A script can read and change files on this Mac." with **Run**,
  **Always Run This Project's Scripts**, **Show Script** and Cancel. Run
  allows that file as it is; changed, it asks again.
- An expression that arrived another way (a project from someone else, a
  preset, `project.json` edited outside the app) plays exactly as saved,
  since its keyframes are in the project. It just isn't run again: its
  badge shows the warning, and the designer shows its code, read-only,
  with **Allow** and **Allow All in This Project (12)**.
- **Review Expressions…** lists every expression of the project (clip,
  control, state, code) in one window, to read and allow them together,
  and to find them.

### Settings

A **Scripting** tab in Settings: which Python runs (**Built In**, with
its version, or **Choose…** for an interpreter of the person's own,
3.11 or later, so their packages can be imported) and **Forget Allowed
Code**, which also forgets which projects' scripts were allowed.

## The idea: expressions write keyframes

[keyframing-effects.md](keyframing-effects.md) says the app has no
expressions and gives the reason: a method that writes ordinary
keyframes needs no new path for drawing, playback or export. An
expression is the same bargain with Python as the generator, and here
the bargain pays for more:

- **Python is never in the render path.** The compositor draws several
  frames at once on its own threads and draws ahead of the playhead; the
  sound taps read volume and EQ curves on the audio thread. Neither can
  wait for an interpreter, and a sound target couldn't be live at all.
- **Render keys and the render cache stay true.** They are made from a
  clip's keyframes. A value worked out while drawing would have to be
  worked out again just to name the frame.
- **A project plays the same everywhere**: on a Mac with no Python, in
  an app that doesn't know expressions, and before its code is allowed.
  This is what makes the [safety](#safety) rule cheap: not running code
  costs nothing but freshness.
- **Everything that works on keyframes works**: the graph, eases after
  baking, copying, presets, the Motion Designer's retiming.

What an expression evaluated while drawing would give for free is its
value at any moment, not only on frames. Here the code is called at
chosen moments and straight lines join them, so the moments have to be
chosen well: once per timeline frame, as every method, and more where
something reads between frames (see [Between frames](#between-frames)).

## How it runs

```
 AnimationMeetsVideo (Swift)                 helper (Python)
 ┌──────────────────────────────┐   pipes   ┌──────────────────────┐
 │ ExpressionRunner ScriptRunner│  frames   │ amv_host             │
 │            │                 │ ────────► │   runs the code      │
 │      ProjectBridge           │ ◄──────── │   amv: proxies that  │
 │  reads a snapshot of         │   calls   │   hold IDs and ask   │
 │  EditingProject, applies     │           │   the app            │
 │  changes to a working copy   │           └──────────────────────┘
 └──────────────────────────────┘
```

### A helper process, not an embedded interpreter

The app starts Python as a child process and talks to it over pipes
(`PythonHelper`), rather than linking CPython into the app.

- **It can be stopped.** A loop that never ends, or a call stuck in C,
  is ended by ending the process. Inside the app there is no safe way to
  stop a thread.
- **A crash is the helper's.** An extension module that crashes takes
  the run with it, not the editor.
- **It can be confined** by the system, per process (see
  [Safety](#safety)).
- **The app links nothing.** No C API, no bridging library, and any
  Python 3.11 or later can stand in, which is how a person's own
  interpreter works and how tests run in development.

The cost is that every question the code asks about the project crosses
a pipe (tens of microseconds). The protocol is shaped around that: an
expression gets whole tables, not single values, and scripts read and
write lists in one call.

The helper is started the first time something needs it, never at
launch, and kept until the app quits. There are two: one for
expressions, confined, and one for scripts and the console, with the
person's rights. Each runs one thing at a time.

### Which Python

- **Built in.** `scripts/build-app.sh` puts a relocatable CPython (a
  pinned 3.14 release of
  [python-build-standalone](https://github.com/astral-sh/python-build-standalone),
  `aarch64-apple-darwin`, `install_only_stripped`) in
  `Contents/Resources/Python/`, as Blender keeps its own. Everyone on
  one version of the app has one Python, so an expression gives the same
  keyframes on every Mac.
  **As built**, the pin is kept on the Mac that builds the app, in
  `scripts/python-pin`, which `scripts/fetch-python.sh --pin` writes and
  git ignores, so two builds can carry different Pythons, and an
  expression's keyframes are the same only between apps built with the
  same pin. Without a pin the app is built without a Python, and asks
  for one in Settings > Scripting.
- **Chosen.** Settings can point at another interpreter. The helper's
  own code uses only the standard library, so anything 3.11 or later
  runs it. The built-in one has no third-party packages; this is the way
  to NumPy.
- **In development**, with no bundle (`swift test`), the interpreter is
  the one named by `AMV_PYTHON`. Without it, nothing that needs Python
  runs and the suites that need it are skipped.

macOS itself is no help: `/usr/bin/python3` is a stub that offers to
install the developer tools.

With no interpreter found, expressions keep their keyframes with the
note "Python isn't available. Choose one in Settings > Scripting.", and
the Scripts menu's items are off with the same reason.

### The protocol

Frames over the helper's standard input and output: a four-byte length,
a JSON header, and after it, for tables, raw little-endian `float64`s.
The helper points its own `stdout` and `stderr` at messages when it
starts, so `print` and stray writes from C never land in a frame.

| From | Message | For |
| --- | --- | --- |
| app | `expression` | Run this code over these samples |
| app | `script`, `line` | Run this file's text; run one console line |
| helper | `call` | A read or a change, answered by the app with `reply` |
| helper | `output` | Text printed, with its stream |
| helper | `result`, `error` | The samples, or nothing for a script; or the exception with its line and traceback |

**Stop** and the time limit send `SIGINT`, which Python raises as
`KeyboardInterrupt`, and after a second end the process. The next run
starts a new one.

### The bridge

`ProjectBridge` answers the helper's calls from a **snapshot**: the
`EditingProject` as it was when the run began. It is a value, so the
run sees one consistent project however long it takes, off the main
actor. Objects in Python are proxies holding an ID and nothing else, so
they never go stale by holding data; one whose thing is gone raises
`amv.Gone` when used.

Swift stays the only place a curve is evaluated, a clip's time is
mapped or a sound's level is worked out. The helper is handed the
answers; nothing is written twice in two languages.

## Expressions in detail

### A Keyframing kind

`expression` is a kind in `EffectCategory.keyframing`, so all of
[keyframing-effects.md](keyframing-effects.md) holds for it: hidden in
the stack, a badge on the driven control, a target, a component or all,
a range, the base it starts from, the two fingerprints, Regenerate and
Keep Edits, Bake, hand edits refused, copied along with its control.
What differs:

- Its code is the effect's `expression`, as a Text effect's words are
  its `text`.
- **Combine** is fixed to Replace and not shown.
- Its signal doesn't come from Swift arithmetic but from a result that
  arrives, as Audio Keys' sound does (below).

### Names in scope

| Name | What it is |
| --- | --- |
| `time` | The timeline's time at this sample, in seconds |
| `t` | Seconds since the expression's range began, as played |
| `frame` | The timeline's frame number at this sample |
| `source_time` | The clip's source time, where its keyframes sit; apart from `time` when the clip is moved or retimed |
| `fps`, `duration` | The timeline's frame rate; the range's length as played |
| `value` | The control here before the expression: a number, or a vector for Position, Scale or a color |
| `prev` | The result at the sample before, `None` at the first |
| `state` | A dictionary kept across the samples of one run, for anything that accumulates |
| `a`, `b`, `c`, `d` | The four inputs, at this sample |
| `clip`, `layer`, `timeline` | This clip, its layer and its timeline: the same objects scripts get, to read only |
| `project` | Everything else: `project.timeline("Titles")`, and from there its layers, their clips, effects and controls |
| `audio(low, high)` | How loud those frequencies are here, 0 to 1 between `floor=-48` and `ceiling=0` dB; what Listen To hears, by Audio Keys' arithmetic (`AudioKeysMath`) |
| `beats` | From the layer under Beats From: `.index` (beats so far), `.since` and `.until` (seconds), `.phase` (0 to 1 between beats), `.downbeat` |
| `noise(x)`, `wiggle(frequency, amount)` | Wiggler's noise (`KeyframeGenerators`) |
| `linear`, `ease`, `clamp` | Mapping one range onto another |
| `sin`, `cos`, `sqrt`, `pi`, `tau`, … | Everything in `math` |
| `random()` | Seeded from Seed, the effect and the sample: the same every run |

**As built**: `audio(low, high, floor=-48, ceiling=0)`; `noise(x,
dimension=0)` and `wiggle(frequency, amount, octaves=1, dimension=0)`
are Wiggler's noise for the expression's Seed, worked out by the app,
`wiggle` from the start of the expression's range, as Wiggler starts,
and `dimension` another stream, as Wiggler moves each component on its
own. `beats.since` and `beats.until` are None where there is no beat
before or after; `beats.phase` is 0 there; `beats.times` lists them
all. `prev` is a number, or a Vector for several. Everything in `math`
is in scope, `pow` included, which takes the place of the built-in one.

Vectors add, subtract, multiply and divide with numbers and with each
other, by component. The result is a number, or as many numbers as the
target has; with one component chosen, `value` and the result are
numbers. A single number for a vector target sets every component. A
result that isn't a finite number is an error.

A control in another timeline is read on that timeline's own clock:
`.value` is its value as many seconds from that timeline's start as
`time` is from this one's, as After Effects reads another composition,
and `.at(seconds)` is any other moment. Where one of the two timelines
is nested in the other, the clip that nests it maps between them
(`nest.source_time(time)`).

Any module can be imported. Nothing is hidden from inside Python: the
limits are the helper's (see [Safety](#safety)), since limits made in
the language don't hold.

### A run

1. The app sends the code, the sample times (`KeyframeSampling`: one per
   timeline frame of the range, as every method, and the moments
   [between frames](#between-frames) where those are on), the base's
   value at each, the inputs' values at each, and the seed.
2. The helper compiles the code once into a function and calls it per
   sample, in order.
3. The first time the code touches something of the project, the helper
   asks for it and gets it **for every sample at once**: a control read
   with `.value` comes as a table of its value at each sample; `audio`
   as the 48 bands at each sample (`heardBands`); `beats` as the beat
   times. A control read at another moment (`.at(time - 0.5)`) comes as
   its value at each frame of its clip, read in a straight line between
   frames.
4. The bridge notes each thing asked for: the run's **reads**.
5. The helper returns the samples. The app clamps them to the control's
   range and thins them by Tolerance like any method's
   (`KeyframeGenerators.reduced`), or, with Keyframes set to Stepped,
   keeps a held keyframe at each side of every jump
   (`KeyframeGenerators.steps`), so a value that switches on a beat
   stays flat between.

### Between frames

Motion Blur draws a clip at several moments inside one frame and
averages them: `samples` moments across the shutter, which is open for
`angle / 360` of the frame around the frame's own time
(`LayeredCompositor`). Each reads the clip's controls at its moment.
Keyframes on frames alone would give those moments a straight line from
one frame's value to the next, whatever the code would have said.

The code can say, so it is asked. With **Between Frames** on Auto and
Motion Blur on for the expression's clip, the expression is also called
at the shutter's own moments,
`time + shutter × ((i + 0.5) / n − 0.5)` for `i` from 0 to `n − 1`,
where `n` is the clip's sample count, up to 8. Those samples become
keyframes like the rest, so the blur is averaged from values the code
gave.

- **Thinning still applies.** A move that is straight within the frame
  keeps none of the extra keyframes; one that curves keeps them.
- **Past 8 samples**, the shutter's other moments read the lines
  between the eight.
- **The clip's shutter joins the fingerprint**, so turning Motion Blur
  on, or changing its angle or samples, makes the keyframes again.
- **2, 4 or 8** are for readers Auto can't see: the blur is on a clip
  that nests this timeline, on Trails, or the timeline is nested in one
  with a higher frame rate. Those spread the moments evenly over the
  whole frame.
- **It costs calls**: `n` times as many.

### Arriving

Making keyframes stays where it is, synchronous and pure, in
`EditingProject.regenerateKeyframes`. For an expression it looks for a
finished result in `ExpressionResults`, a store for the session like
`SpectrogramStore`:

- **A result that fits** (made from the code, settings, base and reads
  as they are now, told by its fingerprint) is written as keyframes.
- **None that fits**: the control keeps its keyframes and its note says
  "Running…", exactly as Audio Keys does with "Reading the sound…"
  while a spectrogram is made. The editor sees the effect waiting and asks
  `ExpressionRunner` to run it on the project as it is.
- **When the result lands**, the editor does what it does when analysis
  arrives (`EditorView.analysisArrived`): the keyframes are made in the
  project and in the undo baseline. Applying the code was the undo step;
  the result arriving isn't one.

A newer request for the same effect replaces one still waiting. A run
over the **time limit** (5 seconds) is stopped, with the note "Took
longer than 5 seconds, so it was stopped."

During a held drag (`ProjectState.hold`) of something an expression
reads, such as one of its inputs in the Keyframe Designer, the
expression runs against the drag as it goes (`held`), and what lands is
written into the drag, as what follows from it rather than an edit, so
the viewer follows each step; only the samples the step changed are run
again. The project is untouched until the drag ends, when its last
step is committed and the edit that commits it finds the result
already made. A view of its own watches the drag, so the rest of the
editor doesn't run again at each step.

### Doing less work

A run is one message each way, however many samples it has. The 5,400
calls of a three-minute clip at 30 fps happen inside Python, one after
another, with the tables already there. That is estimated at tens of
milliseconds for the clip and hasn't been measured; Between Frames
multiplies it by up to 8. What keeps runs few and short:

- **The helper stays running** and keeps each expression's compiled
  code by its hash, so a run starts with no launch and no compile.
- **Results are kept by fingerprint** for the session
  (`ExpressionResults`), several for each effect. Undo, redo and a value
  set back to what it was find the result made before, and nothing
  runs.
- **Only the samples that changed are run again.** The helper keeps
  each expression's last tables and results. The app sends a table's
  rows only where they differ from the last it sent, and the helper
  calls the code for those samples alone. Moving one keyframe of an
  input then costs the samples around it, not the clip. Two cases run
  more: code that used `prev` or `state` runs from the first changed
  sample to the end, since each sample follows from the one before, and
  code that read a control at another moment (`.at`) runs whole when
  that control changed.
- **As built**, two things differ from the above. The app sends every
  row each run, and the helper compares them with the rows it kept, so
  a helper started afresh can never use rows it doesn't have; sending
  is cheap, and the calls are what cost. And code that uses `state`
  runs whole, rather than from the first changed sample, which would
  need `state` kept as it was at every sample. The helper uses its last
  run only when the app says nothing that run read has changed since,
  and when the code, the tables' shape and a key of what else the
  samples depend on (what `audio()` hears and `beats` follows, the
  component, where the clip is, the frame rate) are the same; a partial
  run's reads join the whole run's. `prev` is the sample before as a
  number or a Vector, the same in a whole run and a partial one.
- **Measured** on the helper alone (Python 3.13 on Linux, with the app's
  answers stood in for), for `value + [a * sin(t * tau * b), 0]` on a
  Position: a three-minute clip at 30 fps (5,400 samples) runs whole in
  about 0.14 s, and in 16 ms after one input keyframe moves; with 8
  moments between frames (48,600 samples), 0.8 s and 0.19 s. Well inside
  the 5 second limit, so NumPy (below) isn't called for yet. To measure
  again on a Mac, in the real app, with projects' own expressions.
- **A whole clip in one call**, only if measuring says the rest isn't
  enough. With NumPy in the built-in Python, `t`, `value` and the tables
  are arrays, and the code is called once, its arithmetic running over
  every sample together: `value + 30 * sin(t * tau * 2)` works as
  written. Code that decides per sample (`if`), or uses `prev` or
  `state`, can't run that way and is called per sample as before. The
  helper finds out by trying, and checks the arrays against a few plain
  calls before using them. It costs NumPy in the bundle and two ways
  for one expression to run, so it is the last step and may never be
  needed.

### What it reads, and going out of date

A method's `readPrint` is a fingerprint of what it read. For an
expression that is: its code, its inputs and seed, the clip's place,
trim and speed, the frame rate, its range, the clip's shutter where
Between Frames follows it, and **each of its reads**:

| Read | Out of date when |
| --- | --- |
| A control of a clip, in any timeline | Its value or keyframes change |
| A clip's or layer's own properties | Its place, trim, speed or name changes |
| A timeline | Its size, frame rate or sections change, or which layers it has and what they are called |
| `audio` | What it hears changes, as for Audio Keys (`addHeard`) |
| `beats` | The layer's beats change, as for Beat Keys |

The reads are saved with the effect, so telling whether an expression
is current is arithmetic in Swift (`keyframingReadPrint`). **Opening a
project never starts Python** unless something an expression read has
changed since it was saved.

- **Anything in the project.** An expression can read every timeline:
  its layers, their clips, their effects and controls, its beats and
  its sound. Each read is saved with its timeline, and
  `EditingProject.expressionReaders` gives, for a timeline, the
  expressions elsewhere that read it. After an edit,
  `refreshKeyframing(after:)` looks in the timelines the edit changed,
  as now, and at their readers.
- **By name.** `layer("Logo")` is a read of the layer found and of
  which layers its timeline has and their names. Renaming it, or adding
  the layer a lookup failed to find, runs the expression again. Of two
  layers with one name, the upper is found.
- **Reading its own target** gives the base, which is `value`.
- **Reading a control another method drives** gives the keyframes that
  method made. When they are made again, this expression is out of date
  and follows, so chains settle in order.
- **A loop** (one expression reads a control whose expression reads it
  back, directly or through others, in whichever timelines) writes
  nothing. Each one's note
  names the next: "It reads Scale, whose expression reads it back."
  `EditingProject.expressionCycles` finds them from the saved reads
  before anything is run.

Code that isn't the same every run (the clock, unseeded randomness)
would give new keyframes each time something it read changed. Nothing
prevents it; `random()` is seeded so the ordinary case is repeatable.

## Scripts in detail

### The `amv` module

Names follow `project.json`'s keys, in Python's snake case. Effects and
controls are looked up by the `kind` they are saved under
(`"gaussianBlur"`, `"blurRadius"`) or by name. Times are
`fractions.Fraction` seconds, exact as in the file; a float is taken and
rounded to a frame of the timeline.

| Object | Reads | Changes, and the `EditingProject` call behind each |
| --- | --- | --- |
| `amv.project` | `name`, `assets`, `timelines`, `timeline(name)`, `document()` (the project as `project.json` has it, as a dictionary) | `add_timeline()` (`addTimeline`) |
| `amv.timeline` (the one shown), any timeline | `name`, `frame_size`, `frame_rate`, `frame`, `duration`, `layers`, `layer(name)`, `sections` | `name` (`renameTimeline`), `place(asset)` (`placeAsset`) |
| Layer | `name`, `kind`, `clips`, `clip_at(time)`, `beats` | `name` (`renameLayer`), `move()` (`moveLayer`), `delete()` (`deleteLayer`) |
| Clip | `start`, `end`, `trim_start`, `trim_end`, `source`, `effects`, `sound_effects`, `volume`, `source_time(time)`, `timeline_time(time)` | `start` (`moveClip`), `trim_start`, `trim_end` (`trimClipStart`, `trimClipEnd`), `split(at)` (`split`), `delete()` (`deleteClip`) |
| Effect | `kind`, `name`, `enabled`, its controls by `[…]` | `effects.add(kind)` (`addEffect`), `remove()` (`removeEffect`), `move()` (`moveEffect`), `name`, `enabled` (`editEffect`) |
| Control | `value`, `keyframes`, `at(time)`, `driven_by` | `value`, `keyframes` (`editEffect`), `drive(method, …)` (`setKeyframing`), `bake()` (`bakeKeyframing`) |
| Asset | `name`, `path`, `duration`, `scenes` | `name` (`renameMedia`) |
| `amv.selection`, `amv.playhead` | The selected clips; the playhead's time | Not yet |

Every change goes through the function the editor's own controls call,
so a script can't leave the project in a state the app couldn't have
made. A change with no function behind it isn't offered yet; the table
grows by adding a row to the bridge.

A whole list is read or written in one call: `control.keyframes` gives
every keyframe, and assigning a list replaces them. A keyframe's time
is in its clip's source time, as it is saved; `clip.source_time(time)`
gives it for a moment of the timeline.

### One run, one undo step

1. The bridge takes the snapshot and a **working copy** of it.
2. Each change is applied to the working copy at once, and reads that
   follow see it.
3. A change the app would refuse by hand is refused there, at its line,
   with `amv.Refused`: a clip the Motion Designer has open
   (`ProjectState.allows`), or the keyframes of a control a method
   drives (`EditingProject.drivenKeyframesEdit`). Picking a method and
   baking pass, as they do by hand.
4. If the script ends without raising, the working copy is written to
   `ProjectState.value` once. `ProjectHistory` records one step, named
   for the script rather than by `ProjectChange`, which names an edit by
   comparing and would call this one "Edit …".
5. What follows from any edit follows: methods whose reads changed make
   their keyframes again in the same step, and expressions' results
   arrive after.

A script that raises, is stopped, or whose helper dies writes nothing.

Scripts run with the person's rights: they can read a spreadsheet, write
a file, call a service. That is the point of them. It is why one runs
only when the person chooses it, and asks first when it came with a
project from somewhere else.

### Where scripts live

In the project's package, in `Scripts/`: the person's work, like
`project.json`, never deleted by the app.

- `ScriptLibrary` lists the folder's `.py` files and watches it with
  FSEvents while the project is open, as the Effects folder is watched.
- **New Script…** writes its file through `PackageCoordinator`, as
  every write to a package goes. Scripts are otherwise written by the
  person's own editor.
- **Save As** copies `Scripts/` into the new package, as it copies
  `Media/` and `Reference/`.
- A backup (`.amvbackup`) copies `Scripts/` too, as it copies `Media/`.
  Autosaves in `Backups/` hold only the edit.

## Safety

Python in a project is code from wherever the project came from. Three
rules, in order of weight:

1. **Nothing runs that wasn't allowed here.** `CodeApproval` keeps what
   was allowed on this Mac in
   `~/Library/Application Support/AnimationMeetsVideo/AllowedCode.json`,
   never in a project, which could then vouch for itself: the SHA-256
   of each piece of code, and the projects whose scripts may run.
   - An **expression** runs only if its code's hash is there. Applying
     code typed in the editor adds it; changing one character outside
     the app makes it unallowed again.
   - A **script in a project** runs when chosen if the project was made
     on this Mac, or its scripts were allowed, or that file's hash was.
     Otherwise it asks first. Since a script runs with its folder first
     on the import path, the hash allowed is of its text with the name
     and hash of every other file in its folder
     (`CodeApproval.approvalCode`): a helper module changed or added
     beside it asks again. Modules a script imports from its folder are
     forgotten when it ends, so the next script imports its own.
   - A project is known by its ID and where its package was when it was
     allowed, so a copy arriving from elsewhere under the same ID asks
     again.
   - A file picked with **Run Script File…** runs: picking it is the
     person's act, as opening a file is.
2. **Expressions are confined.** Their helper runs under a sandbox
   profile: no network, no writing files, no starting processes, and no
   reading the home folder beyond the interpreter and the helper's own
   code. An expression is arithmetic; it needs none of them. The helper
   is started through `sandbox-exec`, which Apple marks deprecated and
   which still works and has no replacement for this; if it goes, the
   helper becomes a signed tool with App Sandbox entitlements. The
   profile is written and tried on a Mac in step 6, with a test for each
   thing it must refuse.
3. **Runs are bounded**: the time limit, Stop, and a cap on printed
   output (1 MB a run; the rest is dropped with a note).

What this doesn't do: confine scripts, limit memory, or vet what an
allowed expression computes. Allowing code means trusting it, the way
installing an effect package does
([effect-packages.md](effect-packages.md#safety)).

## Model and saving

- `EffectKind.expression`, in BuiltInEffects.swift, with the controls
  `inputA` to `inputD`, `seed` (Wiggler's), `expressionKeys` (a choice:
  `smooth`, `stepped`), `betweenFrames` (a choice: `auto`, `off`, `2`,
  `4`, `8`) and `tolerance`.
- `Effect.expression: String?`, the code; nil for every other kind.
- `KeyframingSetup.reads: [KeyframingRead]`, what the last run read.
  `KeyframingRead` is a timeline's ID and what was read in it:
  `.control(clip:effect:control:)`, `.volume(clip:)`, `.clip(UUID)`,
  `.layer(UUID)`, `.settings`, `.layerNames`,
  `.heard(AudioKeysSource)` or `.beats(layer:)`.

In `project.json`, an expression effect is a Keyframing effect with two
additions:

```json
{
  "id": "…",
  "kind": "expression",
  "expression": "swing = a * sin(t * tau * b)\n[value[0] + swing, value[1]]",
  "keyframing": {
    "effect": "…", "control": "…",
    "beatLayer": "…",
    "reads": [
      { "timeline": "…", "control": "…", "effect": "…", "clip": "…" },
      { "timeline": "…", "layerNames": true },
      { "timeline": "…", "beats": "…" }
    ],
    "readPrint": "9f3c…", "writtenPrint": "41aa…"
  },
  "controls": [{ "id": "…", "kind": "inputA", "value": 40 }]
}
```

`expression` is written for this kind only and `reads` only when there
are some; `ProjectFile.shape` takes them nowhere else, as loading is
strict. The format version stays 2: a project without expressions is
unchanged, and one with them is refused by an earlier app as any kind it
doesn't know is ("Unknown effect kind "expression" at …").

An expression's code is in the project file, not in a file beside it,
so undo, copy and paste, presets, autosave and backups carry it with no
new work. Scripts are files, in the package's `Scripts/` (see
[Where scripts live](#where-scripts-live)); `project.json` doesn't list
them.

## Where it goes in the code

New, outside `UI/`, in a new folder,
`Sources/AnimationMeetsVideo/Scripting/`:

| File | Holds |
| --- | --- |
| `PythonRuntime.swift` | Finding the interpreter: built in, chosen, or `AMV_PYTHON`; its version |
| `PythonHelper.swift` | The process, its pipes and frames, the time limit, Stop, starting again. Behind a `ScriptHelper` protocol, so tests can stand a fake in |
| `ScriptMessages.swift` | The protocol's messages |
| `ProjectBridge.swift` | An actor: the snapshot, the working copy, each `call`'s answer, the reads |
| `ExpressionRunner.swift` | The waiting expressions, newest wins; `ExpressionResults` |
| `ScriptRunner.swift` | A script's or a console line's run and its one write |
| `CodeApproval.swift` | The allowed hashes and projects |
| `ScriptLibrary.swift` | A project's `Scripts/` folder: its list, watched as the Effects folder is (`EffectFolderWatcher`, made to watch files as well as packages) |

- `Model/Effects/Expression.swift`: `KeyframingRead`, the fingerprint of
  each read, `expressionReaders`, `expressionCycles`, and the moments
  between frames for a clip's shutter.
- `Resources/Python/amv_host/`: the helper, in Python (`__main__.py`,
  `protocol.py`, `expressions.py`, and `amv/`, the module scripts
  import). `Package.swift` copies it as it copies `Resources/Effects`.

Changed:

- `Model/Effects/Keyframing.swift`: `regenerateKeyframes` takes an
  expression's samples from `ExpressionResults` where it takes `heard`
  for Audio Keys; `keyframingReadPrint` adds the code, the reads and
  the shutter; `refreshKeyframing(after:)` also looks at the readers of
  the timelines an edit changed; `KeyframeSampling` takes moments
  between frames; `keyframingNote` gains "Running…", the error, not
  allowed, no Python and the loop.
- `Model/Effects/BuiltInEffects.swift`, `KeyframeDesign.swift`: the
  kind, its controls, its chip.
- `Project/ProjectFile.swift`: `expression`, `reads`, their shapes.
- `Project/ProjectHistory.swift`: naming the next step.
- `UI/Editor/EditorView.swift`: sending waiting expressions to the
  runner; a result landing joins `analysisArrived`.
- `Project/ProjectStore+Save.swift`, `ProjectStore+Backups.swift`:
  Save As and backups copy `Scripts/`; New Script's write, through
  `PackageCoordinator`.
- `App/Preferences.swift`: `pythonInterpreter`, `showsScriptConsole`,
  `recentScriptFiles`.
- `scripts/build-app.sh`, with a new `scripts/fetch-python.sh`: the
  pinned archive by version and SHA-256, kept in `build/` between
  builds, trimmed of what the helper can't use (`idlelib`, `tkinter`,
  `ensurepip`, `test`), copied into the bundle and signed, each binary
  inside it before the app.

New UI, one main view per file:

- `UI/Keyframes/ExpressionEditor.swift`: the code, its draft, Apply, the
  error line; in `KeyframeDesigner`'s settings column.
- `UI/Scripting/ScriptConsole.swift`, `ScriptRunSheet.swift`,
  `ExpressionReview.swift`.
- `UI/Editor/ScriptCommands.swift`: the Scripts menu, beside
  `FileCommands` and the rest.
- `UI/Settings/SettingsView.swift`: the Scripting tab.

## Accessibility

By the rules in [accessibility.md](accessibility.md):

- The code editor and the console are system text views, so VoiceOver,
  full keyboard access and Dictation work in them as in any editor. Tab
  indents in the code editor; Control-Tab leaves it.
- An error is announced when it appears, and is the editor's
  accessibility value's last line, not only a red mark.
- The method's badge says its state in words, as today: "Keyframes made
  by Expression", "Expression not allowed yet", "Expression has an
  error".
- Nothing here is done by dragging. Every command is in the Scripts
  menu or a labeled button; Stop answers to Escape and Command-Period.
- Code is set in `Design.Typeface.numeric`, the monospaced face numbers
  use, in `Design`'s text tones.
- As built: the console's output is a read-only system text view on the
  well surface, where the error tone reads at 5.2:1 (3.1:1 on the
  panel's own surface), and a problem the app reports reads "Error:";
  text a script prints to stderr is in the primary tone like stdout,
  since it is often a warning and red alone mustn't say "error";
  what each line gave is announced. Its input line stays enabled while
  a line runs, so Escape reaches it. The run sheet's Stop answers to
  Escape and Command-Period. Review Expressions' rows keep their Allow
  buttons, named for their expression. The keys are in Help > Keyboard
  Shortcuts and [accessibility.md](accessibility.md#keyboard).

## Tests

Mirroring the source folders. Most need no Python: `ScriptHelper` is
faked.

- `Model/Effects/ExpressionTests`: samples to keyframes, Smooth and
  Stepped; a fitting result is written and a stale one isn't; each kind
  of read puts it out of date and nothing else does; an edit in
  another timeline reaches an expression that read it, and no other; a
  loop of two and of three, within and across timelines, writes nothing
  and is named; reading its own target is the base; Bake keeps the
  keyframes and drops the code.
- `Model/Effects/BetweenFramesTests`: the moments are the compositor's
  for a clip's angle and samples; a move straight within the frame keeps
  no extra keyframes and a curved one does; a changed shutter puts the
  expression out of date.
- `Project/ProjectFileExpressionTests`: an expression saves and loads
  byte for byte; `expression` on another kind is refused with its path.
- `Scripting/ProjectBridgeTests`: each row of the `amv` table against
  the model; a refused change raises and leaves the working copy as it
  was; a run that raises writes nothing; a run is one undo step with the
  script's name.
- `Scripting/CodeApprovalTests`: allowed by typing; not after a change
  outside; never read from a project; a project made here runs its
  scripts, and a copy of it elsewhere asks.
- `Scripting/ScriptLibraryTests`: a package's `Scripts/` is listed by
  docstring; a file added or changed is picked up; Save As and a backup
  carry the folder.
- `Scripting/PythonHelperTests`, with a real interpreter
  (`AMV_PYTHON=<python3> swift test --filter "PythonHelper|Confinement"`; skipped when
  the variable isn't set): the names in scope against hand-worked
  values; an error's line; the time limit and Stop; a helper killed
  mid-run; output over the cap; the same seed giving the same samples;
  a run of the changed samples alone, with and without `prev`, giving
  what a whole run gives.
  The helper's own Python has `unittest`s, run from here.
- `Scripting/ConfinementTests`, on a Mac with the app bundle: the
  network, a file write, a subprocess and a read in the home folder are
  each refused in the expressions' helper.
- `UI/UISnapshots`: `expressionEditor` (clean, edited, with an error,
  not allowed) and `scriptConsole`.

## Decisions made here

Asked for, and so not open:

- **Expressions read every timeline of the project**, not only their
  own.
- **Scripts live in the project's package**, beside its files, and
  there is no folder of scripts in Application Support.
- **Motion blur reads values the code gave**, not lines between frames.

The request didn't settle the rest. Each is cheap to change before the
build starts; the first two shape everything after them.

1. **Expressions write keyframes** and aren't evaluated while drawing,
   for the reasons under
   [The idea](#the-idea-expressions-write-keyframes). After Effects and
   Blender's drivers evaluate live; this app already chose otherwise
   for its methods.
2. **Python runs in a helper process**, not inside the app. Blender
   embeds it and can be hung or crashed by a script.
3. **Python, not JavaScript.** JavaScriptCore is already on every Mac
   and would need no bundle; Python is what was asked for and what
   people who script video and animation tools write.
4. **A Python ships in the app**, pinned, and another can be chosen.
5. **Code runs only once allowed on this Mac**: an expression by its
   hash, typing it being allowing it; a project's scripts by the
   project, known by its ID and its place. Blender asks once per file;
   a hash also covers a file changed afterwards.
6. **Expressions are confined and scripts aren't.**
7. **An expression's code is saved in `project.json`**, not as a `.py`
   file in the package. "Beside the files" is read as being about
   scripts; an expression belongs to one control of one clip, and
   inline it is undone, copied and saved in presets with it.
8. **Another timeline is read on its own clock**, at the same seconds
   from its start, as After Effects does.
9. **The last line is the value.**
10. **Four fixed inputs, A to D**, rather than inputs the code declares,
    since a kind's controls come from the registry.
11. **A script is all or nothing and one undo step.**
12. **A project made on this Mac runs its scripts without asking**, and
    one from elsewhere asks once.
13. **The module is `amv`**, after the project's extension.
14. **At most 8 moments between frames**, at the shutter's own places.
    A clip set to 64 samples reads lines between the eight.
15. **Runs are cut down by keeping results and re-running changed
    samples**; NumPy and whole-clip calls wait for a measurement.

## Not yet

- Python that runs on its own: handlers for a frame change, a save or an
  open, and add-ons that add commands, panels or methods to the app, as
  Blender's do. Everything here runs because the person ran it or
  allowed it.
- Changing the selection and the playhead from a script; importing
  media (`MediaImporter` is asynchronous and copies files); exporting.
- Writing the whole document back (`amv.project.apply(document)`),
  checked as a file read from disk is. `document()` only reads.
- Running a script without a window (from a terminal, on a project
  path).
- Code shared between expressions: importing a module from the
  project's `Scripts/`, whose text would have to be allowed with the
  expression's.
- Between Frames for the other methods, which sample on frames only.
- A dialog for a script's settings.
- A debugger, completion and syntax coloring in the editor.
- Expressions on text (a Text effect's words) and choices; numbers
  only, as every method.
- Limiting a script's memory.

## Building it

In order, each step usable on its own:

1. **Runtime and helper** (done). `PythonRuntime`, `PythonHelper`, the frames,
   `amv_host` answering a ping; the time limit and Stop;
   `fetch-python.sh` and the bundle; the Settings tab showing the
   version. Usable as: Settings says which Python the app has.
2. **Reading, and the console** (done). `ProjectBridge`'s reads, the `amv`
   module's objects, `ScriptConsole`. Usable as: look around a project
   in Python.
3. **Scripts that edit** (done). The working copy, the changes in the table,
   refusals, the one named undo step; `ScriptLibrary` and the package's
   `Scripts/`, with Save As and backups; allowing a project's scripts
   (`CodeApproval`); the Scripts menu and the run sheet.
4. **The expression model** (done), with no Python: the kind, `expression`,
   `reads` across timelines and their readers, saving,
   `ExpressionResults`, `regenerateKeyframes` and the fingerprints,
   loops. Tested with results put in the store by hand.
5. **Allowing expressions** (done). Hashes in `CodeApproval`, the badge's and
   designer's states, Review Expressions.
6. **The confined helper** (done; tried on a Mac, which found that the
   helper must start in a folder its sandbox can read): the profile, on a Mac, and its tests.
7. **Running expressions** (done). `ExpressionRunner`, the helper's evaluator
   and tables, the names in scope, errors, `ExpressionEditor` and the
   chip. Not before steps 5 and 6: from the first build that runs an
   expression, it runs only allowed code, confined.
8. **Listen To and Beats From** (done, with `noise()` and `wiggle()`) for expressions: `audio` and `beats`.
9. **Between frames** (done): the shutter's moments, the setting, the
   fingerprint.
10. **Doing less work** (done; measured under "Doing less work"): re-running the changed samples alone. Then
    measure a run on real projects, with Between Frames on.
11. **Following a held drag** (done, for every held drag): running against `ProjectState.held`, for
    the inputs' sliders in the designer first.
12. **Whole-clip calls with NumPy** (not done: not called for), only if step 10's measurement
    shows runs that are still slow.
13. Accessibility (done), checked with the `accessibility-reviewer` agent.
14. Docs (done), once built: this document's status; the README's row and the
    milestones; [keyframing-effects.md](keyframing-effects.md) (the
    kinds table, "The idea", "Not yet");
    [project-package.md](project-package.md) (`Scripts/` in the layout,
    in Retention and in what Save As and backups copy) and
    [effects.md](effects.md#saving) (the new keys);
    [accessibility.md](accessibility.md); `KeyboardShortcutsView`; and
    AGENTS.md (the `Scripting/` folder, `AMV_PYTHON`, and what
    `build-app.sh` now fetches).

This can't be built or run on Linux; it needs full Xcode on a Mac. CI
runs only when started by hand, and its runner needs `AMV_PYTHON` set
for the suites that use a real interpreter. The sandbox profile, the
size the bundled Python adds to the app and signing it for notarization
can only be settled on a Mac.
