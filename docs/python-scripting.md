# Python scripting

Status: **planned, not implemented**. Nothing here is built. This
document is written for whoever builds it: it says what the person sees,
then how it works, then where each piece goes in the code as it stands
today, then the order to build it in. Choices made while writing it that
the request didn't settle are listed under
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
  keyframed; **Seed**; **Keyframes** (Smooth or Stepped); and
  **Tolerance**.
- **Applies To** has Component, Range, Listen To and Beats From, as the
  other methods have between them. Combine isn't offered: the code says
  how its result meets `value`.

### A script

A script is a `.py` file in
`~/Library/Application Support/AnimationMeetsVideo/Scripts/`, beside the
Effects and Presets folders. Each is listed in the **Scripts** menu
under the first line of its docstring, or its file name.

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
- The menu also has **Run Script File…**, **Show Scripts Folder**,
  **Python Console** and **Review Expressions…**. A file added to or
  changed in the folder is picked up without relaunching.

### The console

**Python Console** is a floating panel: output above, one input line
below, with history on the up and down arrows. `amv` is already
imported. Each line entered is a run of its own, so each is an undo step
when it changed something. Names set on one line are there on the next.
What scripts print, and their tracebacks, go here too.

### Allowing code

Python that came from somewhere else doesn't run until the person has
seen and allowed it (see [Safety](#safety)).

- Code typed into the designer's editor, the console or a script the
  person runs is allowed by that act.
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
3.11 or later, so their packages can be imported), **Show Scripts
Folder**, and **Forget Allowed Code**.

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

What is given up is an expression evaluated between frames: it is
sampled once per timeline frame, like every method, and straight lines
join the samples.

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
| `clip`, `layer`, `timeline` | The same objects scripts get, to read only |
| `audio(low, high)` | How loud those frequencies are here, 0 to 1 between `floor=-48` and `ceiling=0` dB; what Listen To hears, by Audio Keys' arithmetic (`AudioKeysMath`) |
| `beats` | From the layer under Beats From: `.index` (beats so far), `.since` and `.until` (seconds), `.phase` (0 to 1 between beats), `.downbeat` |
| `noise(x)`, `wiggle(frequency, amount)` | Wiggler's noise (`KeyframeGenerators`) |
| `linear`, `ease`, `clamp` | Mapping one range onto another |
| `sin`, `cos`, `sqrt`, `pi`, `tau`, … | Everything in `math` |
| `random()` | Seeded from Seed, the effect and the sample: the same every run |

Vectors add, subtract, multiply and divide with numbers and with each
other, by component. The result is a number, or as many numbers as the
target has; with one component chosen, `value` and the result are
numbers. A single number for a vector target sets every component. A
result that isn't a finite number is an error.

Any module can be imported. Nothing is hidden from inside Python: the
limits are the helper's (see [Safety](#safety)), since limits made in
the language don't hold.

### A run

1. The app sends the code, the sample times (`KeyframeSampling`: one per
   timeline frame of the range, as every method), the base's value at
   each, the inputs' values at each, and the seed.
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
reads, the expression follows when the drag ends, like everything but
the viewer and the dragged row. Following each step is step 9 of
[Building it](#building-it).

### What it reads, and going out of date

A method's `readPrint` is a fingerprint of what it read. For an
expression that is: its code, its inputs and seed, the clip's place,
trim and speed, the frame rate, its range, and **each of its reads**:

| Read | Out of date when |
| --- | --- |
| A control of a clip | Its value or keyframes change |
| A clip's or layer's own properties | Its place, trim, speed or name changes |
| The timeline | Its size, frame rate or sections change |
| `audio` | What it hears changes, as for Audio Keys (`addHeard`) |
| `beats` | The layer's beats change, as for Beat Keys |

The reads are saved with the effect, so telling whether an expression
is current is arithmetic in Swift (`keyframingReadPrint`). **Opening a
project never starts Python** unless something an expression read has
changed since it was saved.

- **Its own timeline only.** An expression can read its clip, the other
  clips and layers of its timeline, and the timeline. That keeps
  `refreshKeyframing(after:)` looking only in the timelines an edit
  changed.
- **Reading its own target** gives the base, which is `value`.
- **Reading a control another method drives** gives the keyframes that
  method made. When they are made again, this expression is out of date
  and follows, so chains settle in order.
- **A loop** (one expression reads a control whose expression reads it
  back, directly or through others) writes nothing. Each one's note
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
| `amv.project` | `name`, `assets`, `timelines`, `document()` (the project as `project.json` has it, as a dictionary) | `add_timeline()` (`addTimeline`) |
| `amv.timeline` (the one shown), any timeline | `name`, `frame_size`, `frame_rate`, `frame`, `duration`, `layers`, `sections` | `name` (`renameTimeline`), `place(asset)` (`placeAsset`) |
| Layer | `name`, `kind`, `clips`, `beats` | `name` (`renameLayer`), `move()` (`moveLayer`), `delete()` (`deleteLayer`) |
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
a file, call a service. That is the point of them, and it is why they
only run when the person runs them.

## Safety

Python in a project is code from wherever the project came from. Three
rules, in order of weight:

1. **Nothing runs that wasn't allowed here.** The app keeps the SHA-256
   of each piece of code the person allowed on this Mac
   (`CodeApproval`, in
   `~/Library/Application Support/AnimationMeetsVideo/AllowedCode.json`,
   never in a project, which could then vouch for itself). An expression
   is run only if its code's hash is there. Applying code typed in the
   editor adds it. Changing one character outside the app makes it
   unallowed again. Scripts aren't hashed: running one is the person's
   act, as opening a file is.
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
  `smooth`, `stepped`) and `tolerance`.
- `Effect.expression: String?`, the code; nil for every other kind.
- `KeyframingSetup.reads: [KeyframingRead]`, what the last run read.
  `KeyframingRead` is an enum: `.control(clip:effect:control:)`,
  `.volume(clip:)`, `.clip(UUID)`, `.layer(UUID)`, `.timeline`,
  `.heard(AudioKeysSource)`, `.beats(layer:)`.

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
      { "control": "…", "effect": "…", "clip": "…" },
      { "beats": "…" }
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

The code is in the project file, not in files beside it, so undo, copy
and paste, presets, autosave and backups carry it with no new work.

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
| `CodeApproval.swift` | The allowed hashes |
| `ScriptLibrary.swift` | The Scripts folder's list, watched as the Effects folder is (`EffectFolderWatcher`, made to watch files as well as packages) |

- `Model/Effects/Expression.swift`: `KeyframingRead`, the fingerprint of
  each read, `expressionCycles`.
- `Resources/Python/amv_host/`: the helper, in Python (`__main__.py`,
  `protocol.py`, `expressions.py`, and `amv/`, the module scripts
  import). `Package.swift` copies it as it copies `Resources/Effects`.

Changed:

- `Model/Effects/Keyframing.swift`: `regenerateKeyframes` takes an
  expression's samples from `ExpressionResults` where it takes `heard`
  for Audio Keys; `keyframingReadPrint` adds the code and the reads;
  `keyframingNote` gains "Running…", the error, not allowed, no Python
  and the loop.
- `Model/Effects/BuiltInEffects.swift`, `KeyframeDesign.swift`: the
  kind, its controls, its chip.
- `Project/ProjectFile.swift`: `expression`, `reads`, their shapes.
- `Project/ProjectHistory.swift`: naming the next step.
- `UI/Editor/EditorView.swift`: sending waiting expressions to the
  runner; a result landing joins `analysisArrived`.
- `App/Preferences.swift`: `pythonInterpreter`, `showsScriptConsole`.
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

## Tests

Mirroring the source folders. Most need no Python: `ScriptHelper` is
faked.

- `Model/Effects/ExpressionTests`: samples to keyframes, Smooth and
  Stepped; a fitting result is written and a stale one isn't; each kind
  of read puts it out of date and nothing else does; a loop of two and
  of three writes nothing and is named; reading its own target is the
  base; Bake keeps the keyframes and drops the code.
- `Project/ProjectFileExpressionTests`: an expression saves and loads
  byte for byte; `expression` on another kind is refused with its path.
- `Scripting/ProjectBridgeTests`: each row of the `amv` table against
  the model; a refused change raises and leaves the working copy as it
  was; a run that raises writes nothing; a run is one undo step with the
  script's name.
- `Scripting/CodeApprovalTests`: allowed by typing; not after a change
  outside; never read from a project.
- `Scripting/PythonHelperTests`, with a real interpreter
  (`AMV_PYTHON=<python3> swift test --filter Scripting`; skipped when
  the variable isn't set): the names in scope against hand-worked
  values; an error's line; the time limit and Stop; a helper killed
  mid-run; output over the cap; the same seed giving the same samples.
  The helper's own Python has `unittest`s, run from here.
- `Scripting/ConfinementTests`, on a Mac with the app bundle: the
  network, a file write, a subprocess and a read in the home folder are
  each refused in the expressions' helper.
- `UI/UISnapshots`: `expressionEditor` (clean, edited, with an error,
  not allowed) and `scriptConsole`.

## Decisions made here

The request didn't settle these. Each is cheap to change before the
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
5. **Code runs only once allowed on this Mac, by its hash**, and typing
   it allows it. Blender asks once per file; a hash also covers a file
   changed afterwards.
6. **Expressions are confined and scripts aren't.**
7. **The code is saved in `project.json`**, not as `.py` files in the
   package.
8. **An expression reads its own timeline only.**
9. **The last line is the value.**
10. **Four fixed inputs, A to D**, rather than inputs the code declares,
    since a kind's controls come from the registry.
11. **A script is all or nothing and one undo step.**
12. **Scripts live in Application Support**, not in projects: a project
    never brings a script that runs.
13. **The module is `amv`**, after the project's extension.

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
- Code shared between expressions (a project's own module).
- A dialog for a script's settings.
- A debugger, completion and syntax coloring in the editor.
- Expressions on text (a Text effect's words) and choices; numbers
  only, as every method.
- Limiting a script's memory.

## Building it

In order, each step usable on its own:

1. **Runtime and helper.** `PythonRuntime`, `PythonHelper`, the frames,
   `amv_host` answering a ping; the time limit and Stop;
   `fetch-python.sh` and the bundle; the Settings tab showing the
   version. Usable as: Settings says which Python the app has.
2. **Reading, and the console.** `ProjectBridge`'s reads, the `amv`
   module's objects, `ScriptConsole`. Usable as: look around a project
   in Python.
3. **Scripts that edit.** The working copy, the changes in the table,
   refusals, the one named undo step, `ScriptLibrary`, the Scripts menu
   and the run sheet.
4. **The expression model**, with no Python: the kind, `expression`,
   `reads`, saving, `ExpressionResults`, `regenerateKeyframes` and the
   fingerprints, loops. Tested with results put in the store by hand.
5. **Allowing code.** `CodeApproval`, the badge's and designer's states,
   Review Expressions.
6. **The confined helper**: the profile, on a Mac, and its tests.
7. **Running expressions.** `ExpressionRunner`, the helper's evaluator
   and tables, the names in scope, errors, `ExpressionEditor` and the
   chip. Not before steps 5 and 6: from the first build that runs an
   expression, it runs only allowed code, confined.
8. **Listen To and Beats From** for expressions: `audio` and `beats`.
9. **Following a held drag**: running against `ProjectState.held`, for
   the inputs' sliders in the designer first.
10. Accessibility, checked with the `accessibility-reviewer` agent.
11. Docs, once built: this document's status; the README's row and the
    milestones; [keyframing-effects.md](keyframing-effects.md) (the
    kinds table, "The idea", "Not yet");
    [project-package.md](project-package.md) and
    [effects.md](effects.md#saving) (the new keys);
    [accessibility.md](accessibility.md); `KeyboardShortcutsView`; and
    AGENTS.md (the `Scripting/` folder, `AMV_PYTHON`, and what
    `build-app.sh` now fetches).

This can't be built or run on Linux; it needs full Xcode on a Mac. CI
runs only when started by hand, and its runner needs `AMV_PYTHON` set
for the suites that use a real interpreter. The sandbox profile, the
size the bundled Python adds to the app and signing it for notarization
can only be settled on a Mac.
