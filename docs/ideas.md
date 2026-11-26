# Ideas

Status: **planned, not designed**. Features to add, each short enough to
talk through before it gets a design doc of its own. When an idea is
taken up, move it into the document it belongs to (or a new one) and
take it out of here.

## Strobe keyframes in the Keyframe Designer

A new Keyframing method, picked for a control in the
[Keyframe Designer](keyframing-effects.md#the-keyframe-designer) like
the others, that writes a repeating on/off pulse onto the control: a
strobe on Opacity, a Glow's Intensity, a Scale, a Volume (a gate). It
writes real keyframes, as every method does
([The idea](keyframing-effects.md#the-idea-they-write-real-keyframes)),
so it can be baked and edited by hand afterwards.

### Settings

- **Timing**, one of:
  - **Beats**: each pulse starts on a beat marker of a beat map, from a
    Sound or Music layer (Beats From, as Beat Keys has).
  - **Frames**: a pulse every N frames of the clip's timeline.
- **Offset**: shifts every pulse later (or earlier, if negative), in
  frames, or in beats when timed to beats.
- **Envelope** of each pulse, in frames:
  - **Attack**: from Min up to Max.
  - **Sustain**: how long it stays at Max.
  - **Release**: from Max back down to Min.
  - The rest of the interval stays at Min.
- **Min** and **Max**: the values the pulse moves between, with a
  **Swap** button that exchanges them, so the control dips on each pulse
  instead of rising (an opacity that blinks off rather than on).

With Attack and Release at 0 the pulse is a hard step, written as hold
keyframes so it doesn't ramp between frames.

### Worth deciding

- **Name.** Stylize already has a Strobe effect
  ([effects-stylize.md](effects-stylize.md)), which flashes the picture
  itself. "Strobe Keys" or "Gate" would keep the two apart in the
  menus.
- **ADSR or AHR.** In a synth's ADSR, Sustain is a *level* and Decay is
  the drop from the peak to it. The settings above treat Sustain as a
  *time* (a hold). A full ADSR would add Decay and a Sustain level
  between Min and Max, for a flash that spikes and settles before it
  goes out.
- **Envelope units.** Frames are exact but don't follow the tempo. When
  timed to beats, the envelope could instead be in fractions of the
  interval (attack 10%, sustain 30%, release 20%), so a tempo ramp in
  the beat map stretches the pulses with it. A single **Duty** setting
  (the share of the interval that's on) is the simple form of this.
- **Beat subdivision.** Every N beats (as Beat Keys has), and also
  halves, quarters and triplets of a beat for fast strobes; downbeats
  only; an accent on the one.
- **Envelope curves.** Linear, eased or exponential attack and release;
  exponential release is what a flash of light looks like.
- **Pulses that overlap.** When Attack + Sustain + Release is longer
  than the interval: cut the pulse short at the next one, or let the
  next start from wherever the last had reached (retrigger).
- **Variation.** Swing (every other pulse late), a skip chance or a
  pattern of steps per bar (`x.x.xx..`), and a seed, so it doesn't feel
  mechanical.
- **Fade** of the whole strobe in and out at the ends of its Range, as
  Oscillator has.
- **Combine.** Every method has Replace, Add and Multiply; Multiply on
  Opacity is the classic strobe, so it may be the better default here
  than Add.
- **"Frames" vs. Between Frames.** The app already uses *between frames*
  for moments inside one frame under motion blur
  ([python-scripting.md](python-scripting.md#between-frames)). The
  Frames timing here means whole frames between pulses; the label
  should say so ("Every N frames") to keep them apart. A rate in
  pulses a second is another option, but anything that isn't a whole
  number of frames beats against the frame rate.
- **Overlap with Beat Keys.** Beat Keys already has a pulse with peak
  and decay on each beat. Strobe could instead be new shapes and an
  envelope added to Beat Keys, plus a Frames timing; a separate method
  is clearer in the designer.
- **Flashing safety.** Like the Stylize Strobe, it should warn above
  three flashes a second when its target changes brightness (Opacity,
  light and color controls), and its defaults should stay below
  ([Safety](psychedelic-effects.md#safety-flashing)).
