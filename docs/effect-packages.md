# Effect packages

Status: **built** (see [Building it](#building-it)): every look is a
package, reading [pictures besides the
clip's](#pictures-besides-the-clips) where it needs them; there is a
guide to [writing a package](#making-a-package), and the app makes one
new or from a look, and installs one opened from Finder. What remains is
under [Not yet](#not-yet). `EffectKind` and `ControlKind`
are names looked up in an `EffectRegistry` of the effects written in
Swift (BuiltInEffects.swift), the 77 looks that ship as packages
(Resources/Effects) and the person's packages, which
`EffectPackageStore` reads from the Effects folder at launch, and again
as one changes there while the app runs. A
package's look is listed, saved and drawn like any other
(`PackageLookRenderer`), and one whose package is missing is kept.
The looks of [psychedelic-effects.md](psychedelic-effects.md) moved out
of Swift into these **effect packages**: folders the app reads at
launch, which can be written, shared and installed without building the
app. Effects that need
more than a Core Image kernel stay in Swift (see
[What stays in Swift](#what-stays-in-swift)).

## Why it is possible

A look is already data plus Metal source. Its kernel is Metal text that
`PackageKernels` compiles at run time with
`CIKernel.kernels(withMetalString:)`, and Core Image's built-in filters
are named by string (`CIBloom`). What was Swift before packages was the
glue: the effect's name, icon and controls, and a case per look in
`LookRenderer.apply` that turned control values into kernel arguments
(degrees to radians, a speed times the clip's seconds, a choice to 0, 1
or 2). A package describes that glue as data.

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
| `category` | `correction` (Color Correction), `blur` (Blur & Sharpen), `keying` (Keying & Masks), `light`, `stylize`, `recolor` (Color), `noise` or `distortion`. A package whose kernel is a warp or general one, or that has `after` filters, reads beside each pixel (`EffectKind.readsBesidePixels`): opacity and shapes above it are settled first, as for Distortion. Categories defined by packages are under [Not yet](#not-yet). |
| `kernel` | The Metal file, the function in it, and its type: `color`, `warp` or `general`, the rungs of [Efficiency](psychedelic-effects.md#efficiency). |
| `controls` | The controls a new effect of this kind lists, in order. |
| `amount` | Whether the standard Amount control (0–100%, default 100%) comes last. A look with it is a no-op at 0%, as today. A `{ "type": "amount" }` entry in `controls` puts it there instead (Grain lists it first). |
| `arguments` | What the kernel receives after the fixed ones, in order (see [Arguments](#arguments)). |
| `generates` | `true` for a generator, which replaces the picture and fills the frame where nothing was. |
| `changesEveryFrame` | `true` when it draws a new picture every frame (Grain, Static, Block Glitch), so the renderer never reuses a frame of it. |
| `dependsOnPixelSize` | `true` when the picture depends on the size it is drawn at (Neon Edges, Dither), as `EffectKind.dependsOnPixelSize`. |
| `flashes` | `true` for an effect that can flash several times a second, or a condition saying when, such as `"abs(hueSpeed) > 3"`, checked with each control at its largest value across its keyframes; the panel shows the warning of [Safety](psychedelic-effects.md#safety-flashing). |
| `reach` | Warp and general kernels: how far, in output pixels, it reads from each pixel, an [expression](#arguments). Core Image renders only the pixels needed from it. Left out, the whole canvas. |
| `perPixel` | `true` for a general kernel that reads its picture only at the pixel it draws: it draws over the picture as a color kernel does and doesn't read beside each pixel (`EffectPackage.readsOnlyItsPixel`), so it can read other pictures, such as a [curve's table](#curves), and still work pixel by pixel. It has no `reach` or `input`. |
| `graph` | The tone graph the effects panel shows above its controls (see [Graph](#graph)). |
| `input` | General kernels: `"clamped"` (edges repeat, for kernels that read beside a pixel) or `"clear"` (transparent past the edges, the default). |
| `after` | Built-in Core Image filters applied to the kernel's result, in order (see [Built-in filters](#built-in-filters)). |
| `linear` | `true` for a look that works on linear light (1 is reference white) rather than on the picture as the timeline encodes it: every picture it reads is turned into light, premultiplied, before its first pass, and its result back after its last pass and its filters (`LinearLight`). A blur needs it to average light, so a highlight keeps its brightness as it spreads and it looks the same in SDR and HDR (see [effects-blur.md](effects-blur.md#light-not-code-values)). |

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
| `curve` | A tone curve: points from black to white (see [Curves](#curves)) | `default` (`[[0, 0], [1, 1]]`, the points), `tint` (`white`, `red`, `green` or `blue`: its line's color on the graph) |

`unit` is one of `%`, `°`, `px`, `s`, `×`, `/s`, `turns/s`, `frames` or
none, and decides how a value is shown and dragged (`ControlKind.unit`).
`step` is the drag step: by default 1, a hundredth for speeds and `×`, a
tenth for `s`. A number with `"rate": true` is a speed:
the effect changes on its own while it isn't 0, as Hue Cycle's Speed does
(`Effect.changesOnItsOwn`).

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
- `pow(x, y)` and `log(x)` (the natural logarithm), each 0 where it has
  no real value (a logarithm of 0 or less), as dividing by zero is

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
it with a **prelude** of its own in front (`LookKernels.prelude`),
among them `toLinear`, `fromLinear`,
`toTones`, `fromTones`, `straight`, `mixed`, `luma`, `hsv`,
`hueRotated`, `rand`, `hash3`, `noise3` and `bayer`. The prelude is part of
the format: its functions keep their names and behavior within a
`formatVersion`, and new ones may be added.

Each package's kernel is compiled from its own source, because Core
Image within one `CIContext` mistook kernels compiled from one source for
each other. A kernel that compiles as another type
than `kernel.type` says (a warp declared as a color kernel) is refused
with that mistake.

Reading the package checks what it can of the kernel before compiling:
`kernel.function` must appear as a whole name followed by `(`, and the
function's parameters (`[[stitchable]]`, `float4` or a warp's `float2`,
then the name) are counted against what the app passes: the picture and
the color space (not to a warp), the other `pictures`, the `arguments`
and Amount, a `destination` not counting. A count that differs is
reported at `arguments` with both counts ("exGlow takes 9 parameters,
but is given 8: its picture, the color space, 5 arguments and Amount").
The list may span lines and hold comments, qualifiers (`const`,
`constant float2&`) and default values. The check runs last, so a more
particular problem is said first, and is skipped, for compiling to
report instead, when the declaration isn't found or returns another
type than `kernel.type` implies, and when the list can't be read with
certainty (brackets that don't balance, a preprocessor line inside),
which is logged once. Types aren't checked; compiling does that.

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

A filter reads the kernel's result as transparent past the picture's
edges, so a blur fades them. With `"input": "clamped"` it reads them
repeating instead, and its result is kept to the picture; a `when` on
each of two copies of the filter lets a choice pick.

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
  reads the folder at launch, away from the main thread
  (`EffectPackageStatus.installAtLaunch`). Opening a project, and making
  or installing a package, wait until it has (`packagesInstalled`), so a
  project's package effects are known before it is read.

The person's packages load after the built-in ones. One whose `id` is
already taken is refused, so a built-in effect can't be replaced by
mistake. Each package that can't be used is listed at the end of the
effects library, under "Can't Be Used", with why and Show in Finder, as
preset problems are in its Presets tab.

Kernels are compiled in the background just after launch, not at first
use, so a mistake shows up in the library at once
(`EffectPackageStatus`), several at a time, one fewer than the Mac has
cores. A package installed or changed while that runs keeps its own
result: each package's problem is set or cleared as it is compiled, and
a result for a version older than the newest sent to compile is dropped. One that doesn't compile stays listed, its
chip marked with a warning, and is listed under "Can't Be Used" too; it
can be added, but leaves the picture as it is, and its note in the
effects panel says why. The message is the Metal compiler's first error
at its place in the package's file ("kernel.metal:4:12: use of
undeclared identifier 'turnn'"): Core Image's own error is only a
code, and counts lines from a header of its own, whose length the app
finds once by compiling an error on a kernel's first line.

## Making a package

A package can be [written by hand](#writing-one-by-hand), or
[started from the app](#starting-one-from-the-app), new or as a copy of a
look, and then edited by hand.

### Writing one by hand

1. In `~/Library/Application Support/AnimationMeetsVideo/Effects/`,
   make a folder named for the effect, ending in `.amveffect`:
   `Tint.amveffect`.
2. In it, write `effect.json`. This one has a color, a strength and the
   standard Amount:

   ```json
   {
     "formatVersion": 1,
     "id": "com.example.tint",
     "version": 1,
     "name": "Tint",
     "category": "recolor",
     "symbol": "drop.halffull",
     "kernel": { "file": "kernel.metal", "function": "exTint", "type": "color" },
     "controls": [
       { "id": "tint", "name": "Tint", "type": "color", "default": [1, 0.6, 0.2] },
       { "id": "strength", "name": "Strength", "type": "number", "default": 100, "range": [0, 200], "unit": "%" }
     ],
     "amount": true,
     "arguments": ["tint", "strength / 100"]
   }
   ```

3. Beside it, write `kernel.metal`, the function `kernel.function` names.
   A color kernel's arguments are the pixel and the color space, then the
   expressions of `arguments` in order, then Amount; the prelude's
   functions (see [The kernel](#the-kernel)) turn the timeline's values
   into tones and back:

   ```metal
   // Each pixel's tones multiplied by a color, `strength` of the way.
   extern "C" [[stitchable]] float4 exTint(coreimage::sample_t s, float space, float4 tint, float strength, float amount) {
       float3 t = toTones(straight(s), space);
       float3 tinted = t * mix(float3(1.0), tint.rgb, strength);
       return mixed(s, fromTones(tinted, space), amount);
   }
   ```

4. Open the app. The effect is in the library under its category, and
   adds, keyframes and saves as any other. If it isn't there, it is at
   the end of the library under "Can't Be Used", with what is wrong and
   where: a line of `effect.json`'s path ("Unknown name \"strenght\" at
   arguments[1]") or of `kernel.metal`'s ("kernel.metal:3:24: use of
   undeclared identifier 'tnt'").
5. Change it and save: the app reads it again (see [Changing one while
   the app runs](#changing-one-while-the-app-runs)). A change to its
   controls shows when the app is opened again.

What to know:

- **The ID needs a dot**, reverse-DNS style, and never changes: projects
  save the effect under it.
- **Renaming or removing a control loses its values** in projects that
  use the package: an effect saved with a control its package doesn't
  list opens without it, says so, and leaves it out when saved (see
  [Changing one while the app runs](#changing-one-while-the-app-runs)).
  Changing a control's size or options resets its value. Once a package
  is shared, leave a control that is no longer needed, unused.
- **Raise `version`** when a control is added or a picture changes, so
  others can tell versions apart. Render caches follow the files
  themselves, so an edit never shows a stale frame either way.
- **Names in expressions** are the controls' IDs, so they are letters and
  digits, and not the names expressions already have (`seconds`,
  `scale`, `amount`, …). Kernel parameter names are Metal's: `half`,
  `float` and the other type names can't be used.
- **The looks that ship are packages too**, in
  `Sources/AnimationMeetsVideo/Resources/Effects/` in the source: a
  starting point for each kind of kernel (Posterize for a color kernel,
  Neon Edges for a general one with a filter after, Twirl for a warp).

### Starting one from the app

Status: **built**.

- **New Effect Package…**, in the File menu and the effects library's
  context menu (beside **Show Effects Folder**), asks for a name and
  writes a package into the Effects folder, under the ID `user.` and the
  name's letters and digits in camel case ("My Glow" is `user.myGlow`),
  other scripts written in Latin letters first ("Crème Brûlée" is
  `user.cremeBrulee`, "光" is `user.guang`), its kernel function `user`
  and the same (`userMyGlow`, never a Metal word). A name with no letter
  to start it ("2 Fast", "★") takes `user.effect`, or `user.effect2` and
  on, the first neither installed nor given by a package in the folder;
  the package keeps the name as typed. It is installed at once and its
  `kernel.metal` shown in Finder. An empty name, or one whose folder or
  ID is taken, says so instead (`EffectPackageStore.makePackage`). The
  package is copied from a template that ships with the others,
  `Resources/Effects/.template.amveffect` (a Tint like the one above),
  with `__ID__`, `__NAME__` and `__FUNCTION__` filled in; hidden, it is
  never read as a package, and changing it changes what new ones start
  as without changing the code.
- **Make a Package from This**, in the context menu of a look's chip in
  the library (every look is a package), copies its folder into the
  Effects folder as a new one, "Twirl Copy" with the ID `user.twirlCopy`
  and version 1 ("Twirl Copy 2" for a second), its controls and kernel as
  they were, then installs it and shows its kernel in Finder. Its ID
  falls back as a new one's does. Only the manifest's first `id`, `name`
  and `version` change, the top level's, so its layout stays. When each
  was found once that is certain; otherwise (a control named as the
  package, say) the copy is read back, and one that doesn't read as
  intended is written whole instead (`EffectPackageStore.copyPackage`).
- **Opening a package**: `Packaging/Info.plist` declares `.amveffect` as
  a package type (`com.jhgfd.animationmeetsvideo.effect`, kept in sync
  with `EffectPackageStore.packageTypeIdentifier`), so Finder shows one
  as a single item. Double-clicking one, or dropping it on the app's icon,
  reads it (`EffectPackageStore.opening`):
  - one that can't be used says why;
  - a new one is copied into the Effects folder and installed, and the app
    says where it is in the library;
  - one already in the Effects folder and installed says so;
  - one whose folder name or ID another package there has asks whether to
    replace it. Replacing removes the other's folder and takes effect at
    the next launch, or at once for one of the same folder name and shape
    (see [Changing one while the app runs](#changing-one-while-the-app-runs)). A look of the app's can't be replaced: their IDs
    have no dot, and every other package's needs one.

A package made or opened this way is installed at once, beside the others
in the registry (`EffectRegistry.adding`), without opening the app again:
adding an effect kind changes no effect already in a project. The
library lists it as `EffectPackageStatus`, which it watches, says one
was installed, and its kernel is compiled then. An effect of its kind in the open
project that loaded as missing comes back when the project is opened
again. Replacing an installed package takes effect as editing one does
(see below), since effects in the open project use its controls.

### Changing one while the app runs

The app watches the person's Effects folder with FSEvents
(`EffectFolderWatcher`, `EffectPackageStatus.startWatching`), making it
first if there is none yet; the packages that ship with the app, in its
bundle, aren't watched. FSEvents sees a change anywhere inside a
package. Each package changed is read again
(`EffectPackageStatus.reload`) once it has gone 0.3 s without changing,
so an editor's save and rename into place read it once. Reloads run one
after another, so an older read never lands after a newer one. Only the
packages changed are read, and one whose files' modification dates are
as when it was last read isn't read again. The app's own writes
(making, copying or installing one) are read once and found installed
as they are. What a read finds (`EffectRegistry.reloading`):

- **A new package** is installed, as one opened from Finder is.
- **A changed package** replaces the one installed, and its kernel is
  compiled again. Its effects in every open project are fitted to it
  (`ProjectSession.fitPackageEffects`, not an undo step), as a project
  read from a file is (see [Missing effects](#missing-effects)):
  - a control it **added** is added to them at its default;
  - a control it **removed** is held, noted, and left out when the
    project is saved;
  - a control whose values **changed size** goes back to its new
    default, noted ("`offset` was reset: it is now 2 numbers");
  - a choice whose **options changed** keeps its option if it is still
    offered, and otherwise goes back to the default;
  - a change to the **pictures** it reads needs nothing: the renderer
    takes them from the package each time it draws.

  Undo fits each step it restores the same way, as does pasting an
  effect copied before the change, so an old value never reaches the
  renderer. The renderer, which reads a control's numbers by position,
  asserts that their count is the control's, naming the control, so a
  value that missed fitting traps in a debug build rather than reading
  its neighbor's. The viewer draws again at once: the composition's key
  holds the content hash of each of the person's packages its clips use,
  and render keys hold it too.
- **A package that can no longer be read** is listed under "Can't Be
  Used" with its problem, and the version installed before stays in use.
- **A package removed, or whose ID changed**, is no longer listed, and
  the new ID is installed. Effects of the old one already in open
  projects draw and edit as they did, and their note in the effects
  panel says so; saved, they open as missing.

Effects keep working through all of this because the registry keeps the
definitions of the effects and controls it stops listing
(`retiredEffects` and `retiredControls`), so looking up a kind in an
open project never fails for a package changed under it.

## Pictures besides the clip's

Status: **built**; Displace, Feedback, Slit-Scan and Flow Smear are
packages that use it. These four looks, the last to leave Swift, each
draw from a picture besides the one reaching them: Displace from a dropped picture
or an earlier step's, Feedback and Slit-Scan from the footage at other
moments, Flow Smear from its motion. The app fetches these before the
kernel runs, so a package says which it needs, and its kernel receives
each as one more `coreimage::sampler`, after its picture and color
space, in the order listed:

```json
"pictures": [
  { "id": "map", "from": "input" },
  { "id": "earlier", "from": "against" }
]
```

| `from` | The picture | Names it adds |
| --- | --- | --- |
| `input` | One dropped from the browser onto the effect, as Matte's (see [Inputs](effects.md#inputs)). | `hasInput`: 1 while it has one |
| `against` | The clip's picture as it was before an earlier step, picked in the effect's Against row (see [Against](effects.md#against)). | `hasAgainst` |
| `moment` | The picture reaching this step `delay` seconds earlier, an expression rounded to a frame; at each [pass](#repeating), that pass's. No delay is the picture reaching the step before any pass. One the composition hasn't is transparent, or with `"missing": "picture"` the picture reaching the step, as Slit-Scan's bands are. | |
| `motion` | The motion from this frame to the footage's frame `ahead` frames later, an expression, as a picture: red across and green up, in output pixels, measured by `BlockMatchFlow`, the block matcher morphs use, over the frame. Not measured while the viewer plays. The composition loads the frame ahead with each control at its largest, as it plans moments. | `hasMotion` |
| `curve` | The curve control `control` names, as its table: see [Curves](#curves). Several may be read, one per curve. | |

A picture that isn't there (no input dropped, no earlier frame yet, no
motion while playing) is transparent. One that is set but can't be had,
a dropped file that is missing or an Against step no longer above this
one, leaves the picture as it is, and the effects panel says why.
`"drawsWhen"`, an expression reading only the `has…` names, says when
the effect does anything; while it is 0 the effect is a no-op and the
effects panel says what it lacks ("Drop a picture from the browser onto
it, or set Against to an earlier step, for the picture it reads").
Displace's is `"hasInput + hasAgainst > 0"`, and its kernel picks its
roles itself: the earlier picture moved by the one reaching it with
Against set, else the one reaching it moved by its input.

A look reading an input or Against has the effects panel's Input or
Against row, as Matte and Blending do; Against's first option is "Its
Input" for a look that takes one, "None" for one that doesn't. Its
pictures are what makes a kind `takesInput` or `readsAgainst`, so saving,
pasting and presets treat them as the built-in effects'.

Pictures need a general kernel, the only kind that reads more than one.
Expressions also gain `frameDuration` (the timeline's frame, in seconds)
and the functions `mod` and `round`.

### Curves

Status: **built**; Curves uses it. A `curve` control holds a tone curve
(`ToneCurve`): points from black (0) to reference white (1) across and
up, joined by a monotone cubic that passes through each and never
overshoots between two, so a curve that rises keeps the tones in order.
Before its first point it holds that point's tone, after its last that
one's, and past white (HDR highlights) a curve ending at white carries
on along the slope of its last stretch. Its points are at least 0.01
apart. Its first and last points are its edges: they can be moved but
not deleted, and points are added only between them.

A curve is saved as its points' numbers in turn, `[x0, y0, x1, y1, …]`,
and keyframes as any control's numbers do, point by point: adding or
removing a point does so at every keyframe, each on its own curve there
(`EffectControl.insertCurvePoint`), so keyframes always have the same
points to blend. A curve has no components for the keyframe graph editor
and can't be a Keyframing effect's target; its row in the effects panel
says how many points it has, and it is edited on the effect's
[graph](#graph), which a package with curves should have.

Expressions can't read a curve. The kernel does, through a picture:

```json
"pictures": [{ "id": "master", "from": "curve", "control": "masterCurve" }]
```

The app makes it from the curve at that moment (`ToneCurveTable`): one
row of 512 pixels, tones from black to white across, each holding the
tone it becomes in red and in green the slope past white. The kernel
receives it as a `coreimage::sampler` and reads it with the prelude's
`curveTone(table, t)`, which interpolates between pixels, holds below
black and carries on past white. Pictures need a general kernel; give it
`"perPixel": true` so it still works pixel by pixel. Curves's kernel is
the example:

```metal
float4 s = src.sample(src.transform(dest.coord()));
float3 t = toTones(straight(s), space);
float3 m = float3(curveTone(master, t.r), curveTone(master, t.g), curveTone(master, t.b));
```

### Graph

Status: **built**. `graph` gives the effect a tone graph in the effects
panel, above its controls: tones from black to white across, what they
become up (see [effects-correction.md](effects-correction.md#tone-graphs)
for how it is used).

```json
"graph": {
  "curves": ["masterCurve", "redCurve", "greenCurve", "blueCurve"],
  "handles": [
    { "name": "Gamma",
      "x": "(inputBlack + (inputWhite - inputBlack) * pow(0.5, levelsGamma)) / 100",
      "y": "(outputBlack + outputWhite) / 200",
      "set": { "levelsGamma": "log((x * 100 - inputBlack) / (inputWhite - inputBlack)) / log(0.5)" } }
  ]
}
```

| Key | Meaning |
| --- | --- |
| `curves` | The curve controls it edits, in the order its picker lists them. With curves the graph draws them; without, it draws what the kernel does to each tone, measured by drawing a row of grays through it (`ToneResponse`), red, green and blue apart when they differ. |
| `handles` | Points on the graph that move number controls. `x` and `y` say where one is, in tones, as expressions of the controls. `set` names each number control a drag sets and its new value: an expression of the controls as they were when the drag began, and of `x` and `y`, the tones the handle is dragged to. A handle whose sets never read `y` moves only across, and the other way round. |

Handles are checked when the package loads, as other expressions are:
`x` and `y` read only the controls, `set` names only number controls,
and no control may be called `x` or `y`. Set values are limited to the
control's range as any edit is. The graph is part of the panel, not of
the picture: it changes nothing drawn, so a package's `version` needn't
rise for one.

### Repeating

Feedback and Slit-Scan draw once per copy or band, each over what the
ones before drew. `"repeat"` runs the kernel that many times; each pass
receives as its picture what the pass before made (the first, what
`start` says: the picture reaching the step, or `"clear"`), and its
moments are the pass's own:

```json
"repeat": {
  "count": "copies", "index": "copies - pass",
  "countWhilePlaying": "floor(copies / 2) + (copies < 2)", "indexWhilePlaying": "max(copies - mod(copies, 2) - 2 * pass, 1)"
},
"pictures": [{ "id": "copy", "from": "moment", "delay": "index * max(feedbackDelay, 1) * frameDuration" }]
```

`pass` counts from 0 to `passes`; `index`, which defaults to `pass`, is
which copy or band a pass draws, for the delay and the kernel's
arguments. The `WhilePlaying` forms draw less while the viewer plays, as
Feedback (every other copy) and Slit-Scan (four bands) do now.

The composition loads the earlier frames a package's moments need
before it plays (`EffectPackage.momentDelays`): the delay of every index
up to `count`, with each control at its largest value across its
keyframes.

Feedback's and Slit-Scan's kernels are new, as the Swift drew them with
Core Image filters in a loop; each matches the frames recorded from it.
Two of the filters' habits are now in Feedback's kernel: a copy's color
is held to 0...1 as it fades, as `CIColorMatrix` held it, so a hue turned
past white stays white, and copies are screened as `CIScreenBlendMode`
does. Slit-Scan's bands are cut at the pixels' centers as cropping cut
them.

### What moved

With these, the four left Swift: Displace with an input and Against,
Feedback and Slit-Scan with moments and repeating (Feedback's hue turn,
scale and rotation per copy done in its kernel with the prelude's
`hueRotated`), Flow Smear with its motion. Their pictures are checked
against reference frames recorded before they moved, as the other looks'
were. What stays in Swift is the stack's foundations, the shapes, the
sound effects and the Keyframing effects (see
[What stays in Swift](#what-stays-in-swift)).

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

A saved effect whose package is installed opens with the package's
controls as they now are, however they changed since it was saved
(`Effect.fitToPackage`). The project's shape check takes any control
and any value in a package effect, since a control the package no longer
lists, or a value of another size or kind, is what changing the package
leaves; what no change to a package explains (an unknown key, `enabled`
that isn't true or false, keyframes that aren't a list) is still
refused with where it is. A value of the wrong size in a hand-edited
file can't be told from one a package change left, so it is reset too,
and the next save writes the default.

- A saved control the package doesn't list (removed, renamed, or one a
  newer version added) is held on the effect as saved, never drawn, and
  its note in the effects panel says so ("Saved with a control this
  package no longer has: `glow`; saving leaves it out."). Saving the
  project leaves it out.
- A saved value of another count than the control now has goes back to
  its default ("`offset` was reset: it is now 2 numbers."), and a choice
  no longer among the options to the default option. A saved control
  that doesn't read at all is reset the same way.
- A control the package lists that the saved effect lacks was deleted,
  as for built-in effects.

A `kind` without a dot that the app doesn't know is still refused, as
today: it is a typo or a built-in kind of a newer app. So is a package's
kind in a sound's stack, since package effects are all pictures'.

Inside the app a missing effect is an `Effect` of the hidden kind
`missing`, which `EffectKind.all` leaves out, holding a `MissingEffect`:
the kind it was saved as and the saved JSON.

## Render keys and caches

A look step's render key gains the package's `id`, `version` and a hash
of its kernel source, so editing a kernel never shows a frame cached
from the old one, in the viewer or in `Cache/Renders/`.

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

No look stays: the 25 that were written in Swift are built-in
packages, the eight Color looks, the seven Noise looks and the ten
Distortion looks. Each was checked against
the Swift it replaced: its controls one by one, its pictures against
reference frames recorded from the Swift, and the recipes using it.
Most were generated from that Swift; Feedback, Slit-Scan and Flow
Smear, which the Swift drew by chaining Core Image filters, have
kernels of their own. The 52 looks added since were written as packages
from the start: Color Correction
([effects-correction.md](effects-correction.md)), Blur & Sharpen
([effects-blur.md](effects-blur.md)), Keying & Masks
([effects-keying.md](effects-keying.md)), Light
([effects-light.md](effects-light.md)) and Stylize
([effects-stylize.md](effects-stylize.md)).

## Inside the app

- `EffectKind` and `ControlKind` are structs wrapping a string. The
  built-in kinds have static members (`EffectKind.transform`), so most
  code reads as it did when they were enums.
- The `EffectRegistry` maps each kind to an `EffectDefinition` or a
  `ControlDefinition`: name, symbol, category, controls, ranges, units,
  defaults and flags. The built-in definitions are tables in
  BuiltInEffects.swift; `EffectPackageStore.installAtLaunch` adds each
  package's, read from `effect.json` in the background, before a project
  is opened. Tests
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

- **Embedding packages in a project** (`Effects/` in the `.amv`
  package), so a project opens with its effects elsewhere. Needs a rule
  for when the embedded and installed versions differ.
- **Several kernels in one package**, chained, with intermediate images.
- **New categories** defined by packages.
- **A package's own help text** and a preview picture in the library.
- **Other graph axes**: a curve across the hues, which wraps around, for
  hue-versus-hue and hue-versus-saturation curves; and a graph in linear
  light, for handles on light rather than tones (Broadcast Safe's
  Brightest).

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
7. Reference frames for Displace, Feedback, Slit-Scan and Flow Smear,
   recorded from Swift (`PicturedLookReferenceTests`): from a map and
   against an earlier step, from twelve earlier moments, and from a frame
   ahead, each picture different, paused and playing. **Built.**
8. Pictures from inputs and Against, and Displace moved into a package.
   **Built.**
9. Moments and repeating, and Feedback and Slit-Scan moved. **Built.**
10. Motion, and Flow Smear moved. **Built.**
11. Writing a package by hand, described above. **Built.**
12. Installing a package while the app runs, and New Effect Package.
    **Built.**
13. Make a Package from This. **Built.**
14. `.amveffect` as a Finder package type, opened by the app. **Built.**
15. Reading packages at launch in the background, compiling kernels
    several at a time, and reading a package again as it changes in the
    Effects folder, effects of a changed or removed one in open projects
    kept working and the viewer drawn again. **Built.**
16. Counting a kernel's parameters against its arguments on reading,
    and new packages made from a template that ships. **Built.**
