# Ideas

Status: **planned, not designed**. Features to add, each short enough to
talk through before it gets a design doc of its own. When an idea is
taken up, move it into the document it belongs to (or a new one) and
take it out of here.

## Strobe Keys

A new Keyframing method, picked for a control in the
[Keyframe Designer](keyframing-effects.md#the-keyframe-designer) like
the others, that writes a repeating pulse onto the control: a strobe on
Opacity, a Glow's Intensity, a Scale, a Volume (a gate). It writes real
keyframes, as every method does
([The idea](keyframing-effects.md#the-idea-they-write-real-keyframes)),
so it can be baked and edited by hand afterwards. Its name keeps it
apart from Stylize's Strobe effect
([effects-stylize.md](effects-stylize.md)), which flashes the picture
itself rather than driving a control.

It is a method of its own rather than more shapes for Beat Keys, which
already pulses on each beat with a peak and a decay: the envelope,
timings and variation below would crowd Beat Keys' settings, and a
separate chip is clearer in the designer.

### Timing

Where each pulse starts, one of:

- **Beats**: on the beat markers of a beat map, from a Sound or Music
  layer (Beats From, as Beat Keys has). **Every** N beats (1), or a
  fraction of a beat: 1/2, 1/4, 1/8, and triplets (1/3, 1/6), each
  placed between the beats on either side, so it follows a tempo ramp.
  **Downbeats only** and an **Accent** on the one (+50% of the pulse's
  height) as Beat Keys has them.
- **Every N frames** of the clip's timeline. The label says "frames" in
  full, since *between frames* already means moments inside one frame
  under motion blur
  ([python-scripting.md](python-scripting.md#between-frames)).
- **Per second**: a rate in pulses a second. A rate that isn't a whole
  number of frames puts pulses between frames, so how long each is seen
  for varies from pulse to pulse; the designer says so under the field.

**Offset** shifts every pulse later, or earlier when negative: in
frames, or in beats when timed to beats.

### Envelope

Each pulse is a full ADSR envelope from Min to Max and back:

- **Attack**: from Min up to Max.
- **Decay**: from Max down to the Sustain level.
- **Sustain**: a level, as a share of the way from Min to Max (100%).
- **Sustain For**: how long it stays at that level.
- **Release**: from there back down to Min.
- The rest of the interval stays at Min.

Decay at 0 and Sustain at 100% (the defaults) make it a plain attack,
hold and release. The times are in **frames**, exact but fixed, or as a
**share of the interval**, so pulses stretch with the tempo; the second
is the default when timed to beats. Attack 0, Release 0 and Sustain For
as a share is a duty cycle, which the designer offers as a one-click
**Duty** preset.

**Curves**: Attack, Decay and Release are each linear, eased or
exponential. Exponential is the default for Release, since that is how
a flash of light dies away. An Attack or Release of 0 is a hard step,
written as hold keyframes so it doesn't ramp between frames.

**Overlap**, for an envelope longer than the interval: **Cut**, where
each pulse is cut short at the next (the default), or **Retrigger**,
where the next starts from wherever the last had reached rather than
from Min.

### Min and Max

The values the pulse moves between, with a **Swap** button that
exchanges them, so the control dips on each pulse instead of rising (an
opacity that blinks off rather than on). What they mean follows
**Combine**: values with Replace, amounts added with Add, factors with
Multiply. Multiply is the default over an opacity, scale or gain, where
a strobe should scale what's there (Min 0, Max 1); Add elsewhere.

### Variation

So it doesn't feel mechanical:

- **Swing**: every other pulse late, by a share of the interval (0%).
- **Skip chance**: the share of pulses left out (0%).
- **Pattern**: a row of steps a bar long (`x.x.xx..`), each on, off or
  accented; empty means every pulse.
- **Seed** for the skip chance, so the same seed gives the same
  keyframes.

**Fade**, in seconds, at each end of the Range, as Oscillator has,
eases the whole strobe in and out.

### Keyframes and safety

- It writes keyframes at each pulse's corners, with the curves as eases,
  rather than sampling every frame and reducing, as Beat Keys and
  Oscillator do over a target that holds still. Over an animated target
  with Add or Multiply it samples and reduces like the rest.
- **Flashing**: over a target that changes brightness (Opacity, the
  Light and Color controls), it warns above three flashes a second, as
  Stylize's Strobe does, and its defaults stay below
  ([Safety](psychedelic-effects.md#safety-flashing)).
