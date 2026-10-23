# Effect packages

Status: **built** (see [Building it](#building-it)); inputs, and the
looks still in Swift, are under [Not yet](#not-yet). `EffectKind` and `ControlKind`
are names looked up in an `EffectRegistry` of the effects written in
Swift (BuiltInEffects.swift), the 21 looks that ship as packages
(Resources/Effects) and the person's packages, which
`EffectPackageStore` reads from the Effects folder at launch. A
package's look is listed, saved and drawn like any other
(`PackageLookRenderer`), and one whose package is missing is kept.
This plan moved the looks of
[psychedelic-effects.md](psychedelic-effects.md) out of Swift into
**effect packages**: folders the app reads at launch, which can be
written, shared and installed without building the app. Effects that need
more than a Core Image kernel stay in Swift (see
[What stays in Swift](#what-stays-in-swift)).

## Why it is possible

A look is already data plus Metal source. Its kernel is Metal text that
`LookKernels` compiles at run time with
`CIKernel.kernels(withMetalString:)`, and Core Image's built-in filters
are named by string (`CIBloom`). What is Swift today is the glue: the
effect's name, icon and controls, and the line in `LookRenderer.apply`
that turns control values into kernel arguments (degrees to radians, a
speed times the clip's seconds, a choice to 0, 1 or 2). A package
describes that glue as data.

## A package

A package is a folder whose name ends in `.amveffect`, as a project is a
folder ending in `.amv`. Like a project it is plain text, so it can be
read, diffed and edited by hand:

```
Posterize.amveffect/
  effect.json     what the effect is, its controls, its arguments
  kernel.metal    one Core Image kernel
```

### effect.json

```json
{
  "formatVersion": 1,
  "id": "posterize",
  "version": 1,
  "name": "Posterize",
  "category": "recolor",
  "symbol": "square.stack.3d.down.forward",
  "kernel": { "file": "kernel.metal", "function": "amvPosterize", "type": "color" },
  "controls": [
    { "id": "levels", "name": "Levels", "type": "number",
      "default": 6, "range": [2, 64], "whole": true }
  ],
  "amount": true,
  "arguments": ["levels"]
}
```

| Key | Meaning |
| --- | --- |
| `formatVersion` | The package format, 1. The app refuses a version it doesn't read, as it does a preset's. |
| `id` | The kind saved in projects and presets. Built-in packages keep the names saved today (`posterize`), so no project changes. Any other package's `id` must contain a dot, reverse-DNS style (`com.example.glow`), so it can never clash with a built-in kind, now or later. |
| `version` | The package's own version, a whole number raised whenever its controls or drawing change. Part of the render key. |
| `name`, `symbol` | Shown in the effects library and the stack. `symbol` is an SF Symbol name; an unknown one shows a generic icon. |
| `category` | `recolor`, `noise` or `distortion`. New categories are under [Not yet](#not-yet). |
| `kernel` | The Metal file, the function in it, and its type: `color`, `warp` or `general`, the rungs of [Efficiency](psychedelic-effects.md#efficiency). |
| `controls` | The controls a new effect of this kind lists, in order. |
| `amount` | Whether the standard Amount control (0–100%, default 100%) comes last. A look with it is a no-op at 0%, as today. A `{ "type": "amount" }` entry in `controls` puts it there instead (Grain lists it first). |
| `arguments` | What the kernel receives after the fixed ones, in order (see [Arguments](#arguments)). |
| `generates` | `true` for a generator, which replaces the picture and fills the frame where nothing was. |
| `changesEveryFrame` | `true` when it draws a new picture every frame (Grain, Static, Block Glitch), so the renderer never reuses a frame of it. |
| `dependsOnPixelSize` | `true` when the picture depends on the size it is drawn at (Neon Edges, Dither), as `EffectKind.dependsOnPixelSize`. |
| `flashes` | `true` for an effect that can flash several times a second, or a condition saying when, such as `"abs(hueSpeed) > 3"`, checked with each control at its largest value across its keyframes; the panel shows the warning of [Safety](psychedelic-effects.md#safety-flashing). |
| `reach` | Warp and general kernels: how far, in output pixels, it reads from each pixel, an [expression](#arguments). Core Image renders only the pixels needed from it. Left out, the whole canvas. |
| `input` | General kernels: `"clamped"` (edges repeat, for kernels that read beside a pixel) or `"clear"` (transparent past the edges, the default). |
| `after` | Built-in Core Image filters applied to the kernel's result, in order (see [Built-in filters](#built-in-filters)). |

Strict loading applies: an unknown key, a wrong type or a missing
required field refuses the package, with the problem and its place in the
file, worded as for projects.

### Controls

Each control has an `id`, a `name` and a `type`. The `id` is letters and
digits, starting with a letter, unique within the package, and none of
the names expressions use (`seconds`, `rad`, `amount`, …). It is what an
expression calls the control, and what a project saves as the control's
`kind`.

| Type | Holds | Keys |
| --- | --- | --- |
| `number` | One number | `default`, `range`, `unit`, `step`, `whole` |
| `vector` | 2 to 4 numbers | `components` (their names, e.g. `["X", "Y"]`), `default`, `range`, `unit`, `step` |
| `point` | A position from the middle of the frame, in the timeline's pixels | `default` (`[0, 0]`) |
| `color` | Red, green and blue, 0–1, and alpha (1 if left out) | `default` |
| `choice` | One of a list | `options` (`[{ "id": "bayer4", "name": "Bayer 4×4" }, …]`), `default` |

`unit` is one of `%`, `°`, `px`, `s`, `×`, `/s`, `turns/s` or none, and
decides how a value is shown and dragged, as `ControlKind.unit` does now.
`step` is the drag step: by default 1, a hundredth for speeds and `×`, a
tenth for `s`. A number with `"rate": true` is a speed:
the effect changes on its own while it isn't 0, as Hue Cycle's Speed does,
which `Effect.changesOnItsOwn` decides today.

Every control can be keyframed, turned off, reset and deleted like a
built-in one. A control turned off or deleted gives the kernel its
default.

### Arguments

A kernel's first arguments are fixed by its type:

- `color`: the pixel (`coreimage::sample_t`), then the timeline's color
  space (`float`, the index `toTones` takes).
- `general`: the picture (`coreimage::sampler`), then the color space.
- `warp`: none; it returns where to sample.

Then come the package's `arguments`, then Amount if the effect has it.
Each argument is an **expression**: `+ - * /` with the usual precedence,
parentheses and unary minus, as in a numeric field, and comparisons
(`< <= > >= == !=`, giving 1 or 0) for `when`. Dividing by zero gives 0.
It may use these names:

- each control's `id`: its value now; a vector or point is a `float2`,
  `float3` or `float4` by its count, a color a `float4`. A choice is read
  only through `index`
- `seconds`: the clip's source time; `frame`: its frame number, for seeds
- `scale`: output pixels per timeline pixel, for sizes given in the
  timeline's pixels
- `frameWidth`, `frameHeight`, `canvasWidth`, `canvasHeight`: in output
  pixels; `frameCenter`, the frame's middle as a position
- `center(p)`: point control `p` as a position in output pixels
- `index(c)`: the position of choice `c`'s option in its list, from 0
- `rad(x)`, `fract(x)`, `floor(x)`, `min`, `max`, `abs`, `pi`

Posterize's `"levels"` is the simplest case. Kaleidoscope's angle, which
combines two controls and the time, is
`"-(rad(angle) + spinSpeed * seconds * 2 * pi)"`. Expressions are checked
when the package loads: an unknown name or function, a wrong count of
arguments, or arithmetic on a vector refuses it. A vector, point or color
can only be an argument's whole value, never part of a sum.

They are only arithmetic, never code: no loops, no reading files, no
calls but those listed. Anything more belongs in the kernel.

### The kernel

`kernel.metal` holds the function named in `kernel.function`, marked
`extern "C" [[stitchable]]`, and any helpers it needs. The app compiles
it with a **prelude** of its own in front, the shared functions in
`LookKernels.source` today, among them `toLinear`, `fromLinear`,
`toTones`, `fromTones`, `straight`, `mixed`, `luma`, `hsv`,
`hueRotated`, `rand`, `hash3`, `noise3` and `bayer`. The prelude is part of
the format: its functions keep their names and behavior within a
`formatVersion`, and new ones may be added.

Each package's kernel is compiled from its own source, as each look's is
now, because Core Image within one `CIContext` mistook kernels compiled
from one source for each other. A kernel that compiles as another type
than `kernel.type` says (a warp declared as a color kernel) is refused
with that mistake.

Where each type draws, as the built-in looks of that type do:

- **color**: over the picture, one pixel at a time. A generator draws
  over the frame where there was nothing.
- **general** with `"input": "clamped"`: over the picture, reading
  beside it as if its edges went on (Neon Edges, Block Glitch).
- **general** with `"input": "clear"` (the default): over the whole
  canvas, reading transparent past the picture's edges (Chromatic
  Aberration).
- **warp**: over the whole canvas, sampling the picture where the kernel
  says, transparent past its edges.

`reach` bounds what a general or warp kernel reads from each pixel; left
out, Core Image may read the whole canvas. A number argument is a
`float`; a vector, point or color a `float2`, `float3` or `float4` by its
count.

### Built-in filters

`after` lists Core Image filters by name with their parameters as
expressions, for the work a built-in filter does better than a kernel.
Neon Edges ends with:

```json
"after": [
  { "filter": "CIBloom", "when": "glow > 0",
    "parameters": { "inputRadius": "edgeWidth * scale * 4", "inputIntensity": "glow / 100" } }
]
```

A filter name Core Image doesn't know refuses the package when it loads.

## Where packages come from

- **Built in**: in the app's resources, from
  `Sources/AnimationMeetsVideo/Resources/Effects/`, which SwiftPM copies
  into its resource bundle as they are and `scripts/build-app.sh` puts in
  the app's Contents/Resources. They are read the first time the
  registry is, in tests too, and their effects take their places in the
  library from `BuiltInEffects.libraryOrder`.
- **The person's**:
  `~/Library/Application Support/AnimationMeetsVideo/Effects/`, beside
  the Presets folder. Installing one means copying it there; the app
  reads the folder at launch.

The person's packages load after the built-in ones. One whose `id` is
already taken is refused, so a built-in effect can't be replaced by
mistake. Each package that can't be used is listed at the end of the
effects library, under "Can't Be Used", with why and Show in Finder, as
preset problems are in the Presets tab.

Kernels are compiled in the background just after launch, not at first
use, so a mistake shows up in the library at once
(`EffectPackageStatus`). One that doesn't compile stays listed, its
chip marked with a warning, and is listed under "Can't Be Used" too; it
can be added, but leaves the picture as it is, and its note in the
effects panel says why. The message is the Metal compiler's first error
at its place in the package's file ("kernel.metal:4:12: use of
undeclared identifier 'turnn'"): Core Image's own error is only a
code, and counts lines from a header of its own, whose length the app
finds once by compiling an error on a kernel's first line.

## Missing effects

A project can use a package that isn't installed where it is opened. The
rule in [Loading is strict](effects.md#loading-is-strict) would refuse
the whole project, losing the person's work over one effect. Instead, an
effect in a picture's stack (or a preset) whose `kind` contains a dot
and isn't installed loads as a **missing effect**:

- Only its `id`, `name` and `enabled` are checked. The rest is kept as
  it was read, keys this app doesn't know included, and written back the
  same, so installing the package later brings it back as it was.
- It draws nothing: the picture passes through.
- The stack shows it under the name it was given, or else the last part
  of its ID ("Glow" for `com.example.glow`), dimmed, with a note: "Not
  installed (com.example.glow), so it draws nothing. Installing its
  effect package brings it back as it was." The note shows while it is
  off too.
- It can be turned off, moved, copied, duplicated, deleted and saved in
  a preset, but not renamed, reset or edited. A copy gets new IDs, its
  saved controls' too. Its keyframes stay at the times it was saved
  with, as nothing in it can be read: pasting it at another moment, or
  into a preset, doesn't move them.

A saved effect with a control its installed package doesn't list was
saved by a newer version of the package, and loads as missing in the
same way, its note saying it needs a newer version. A control the
package lists that the saved effect lacks was deleted, as for built-in
effects.

A `kind` without a dot that the app doesn't know is still refused, as
today: it is a typo or a built-in kind of a newer app. So is a package's
kind in a sound's stack, since package effects are all pictures'.

Inside the app a missing effect is an `Effect` of the hidden kind
`missing`, which `EffectKind.all` leaves out, holding a `MissingEffect`:
the kind it was saved as, why it is missing, and the saved JSON.

## Render keys and caches

A look step's render key gains the package's `id`, `version` and a hash
of its kernel source, so editing a kernel and relaunching never shows a
frame cached from the old one, in the viewer or in `Cache/Renders/`.

## Safety

A package is data and a GPU kernel. Expressions are arithmetic only, and
a Core Image kernel can't reach files, the network or memory outside its
images. The risk is speed: a slow kernel slows the viewer and exports,
and Core Image has no time limit to stop one. The app doesn't sandbox
packages beyond this; installing one means trusting it the way a person
trusts a plug-in.

## What stays in Swift

These need the model, the renderer or other frameworks, not just a
kernel:

- Transform, Blending, Color and Matte: the stack's foundations, folded
  and pushed into nested timelines by `StackFolding`.
- The shapes and Stroke: vector drawing, sized to the frame.
- The sound effects: biquad filters and Audio Units.
- The Keyframing effects: they write keyframes, not pictures.
- Feedback, Slit-Scan and Flow Smear: they draw the picture at other
  moments, and Flow Smear uses Vision's optical flow.
- Displace: it reads an input or an earlier step's picture
  ([Against](effects.md#against)). Packages taking inputs are under
  [Not yet](#not-yet).

The other 21 looks are built-in packages: the eight Color looks, the
seven Noise looks, Liquid, Twirl, Wave, Kaleidoscope, Mirror Tile and
Chromatic Aberration. Each was generated from the Swift it replaced
and checked against it: its controls one by one, its pictures against
the reference frames, and the recipes using it.

## Inside the app

- `EffectKind` and `ControlKind` are structs wrapping a string. The
  built-in kinds have static members (`EffectKind.transform`), so most
  code reads as it did when they were enums.
- The `EffectRegistry` maps each kind to an `EffectDefinition` or a
  `ControlDefinition`: name, symbol, category, controls, ranges, units,
  defaults and flags. The built-in definitions are tables in
  BuiltInEffects.swift; `EffectPackageStore.installAtLaunch` adds each
  package's, read from `effect.json`, before a project is opened. Tests
  give theirs through `EffectRegistry.override`, a task-local, so they
  don't change what other tests see.
- A package's controls are scoped to it: its `levels` is
  `com.example.glow/levels` in the registry, a different control from
  another's `levels`, and saved as `levels` within its effect. Amount is
  the one shared control, the built-in `amount`, which the renderer mixes
  a look by.
- The project and preset shapes strict loading checks against are made
  at each load, from the registry, so they always know its packages.
- `LookRenderer` hands every package look to `PackageLookRenderer`, which
  draws it one way, from the package; it has no `case` per look left.
  `PackageKernels` compiles each package's kernel once, keyed by its
  content hash.
- Strict loading checks a package effect against its definition, as
  `ProjectFile.ShapeKit.effect` checks a built-in one, and missing
  effects as above.
- `LookRecipes` names a shipped package's kind by a static member
  (`EffectKind.posterize`) and its controls by saved name. Recipes use
  only effects that ship with the app, which a test checks load and
  compile.

## Testing

- Each look moved into a package draws the same picture as before it
  moved, against reference frames taken before the move
  (`LookReferenceTests`, recorded for all 21 before any moved), within
  the tolerance of [Testing](psychedelic-effects.md#testing).
- A project saved before the move opens unchanged, and saves to the same
  JSON.
- Package loading checked against a package per kind of error (bad key,
  unknown expression name, unknown filter, duplicate `id`, kernel that
  doesn't compile), for the message and its place.
- A project or preset with a missing effect opens, draws without it,
  and saves it back as the same JSON; after installing the package it
  loads as the effect.
- Changing a kernel's source changes the render key.

## Not yet

- **Reloading without relaunching**, by watching the Effects folder.
- **Embedding packages in a project** (`Effects/` in the `.amv`
  package), so a project opens with its effects elsewhere. Needs a rule
  for when the embedded and installed versions differ.
- **Inputs and Against** for package effects, so Displace can move.
- **Several kernels in one package**, chained, with intermediate images.
- **New categories** defined by packages.
- **A package's own help text** and a preview picture in the library.

## Building it

In order, each step usable on its own:

1. `EffectKind` and `ControlKind` as structs over their strings, and the
   `EffectRegistry` with every effect registered from Swift. No change in
   behavior or saved files. **Built.**
2. The package reader and its strict checks, the expression parser, and
   the Effects folders; packages load but none ship. **Built**: the
   person's folder only, since there are no built-in packages to read yet.
3. `LookRenderer` drawing a package look, and Posterize moved into a
   built-in package, checked against its reference frames. **Built.**
4. Missing effects in projects and presets. **Built.**
5. The other Color looks, then the Noise looks, then the Distortion
   looks, as packages, a category at a time. **Built.**
6. Problems and compile errors shown in the effects library. **Built.**
