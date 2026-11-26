"""The project's objects, as proxies.

Each object holds the IDs that find its thing in the project and nothing
else, so it never goes stale by holding data: every read asks the app, and
one whose thing is gone raises `amv.Gone`. Names follow `project.json`'s
keys in snake case; effects and controls are found by the kind they are
saved under ("gaussianBlur", "blurRadius") or by name.

Each change calls the function the editor's own controls call (the table
in docs/python-scripting.md, "The amv module"), on the run's working copy.
"""

from collections import namedtuple
from collections.abc import Sequence

from . import _bridge
from ._bridge import Gone
from .values import Vector, time_in, time_out, value_in, value_out

call = _bridge.call

Section = namedtuple("Section", "name start end")
Scene = namedtuple("Scene", "start end")


class _Proxy:
    __slots__ = ("_key",)

    def __init__(self, *key):
        object.__setattr__(self, "_key", key)

    def __eq__(self, other):
        return type(self) is type(other) and self._key == other._key

    def __hash__(self):
        return hash((type(self).__name__,) + self._key)

    def __setattr__(self, name, value):
        # Only the properties below can be set: a misspelt name raises
        # rather than set something nothing reads.
        if not isinstance(getattr(type(self), name, None), property):
            raise AttributeError("%s has no %r to set" % (type(self).__name__, name))
        object.__setattr__(self, name, value)

    @property
    def id(self):
        return self._key[-1]


def _named(items, name, what, where):
    for item in items:
        if item.name == name:
            return item
    raise LookupError("%s has no %s called “%s”" % (where, what, name))


# MARK: - Project


class Project(_Proxy):
    """The project in the front window."""

    __slots__ = ()

    def __init__(self):
        super().__init__()

    def _read(self):
        return call("project")

    @property
    def id(self):
        return self._read()["id"]

    @property
    def name(self):
        return self._read()["name"]

    @property
    def timelines(self):
        return [Timeline(tid) for tid in self._read()["timelines"]]

    @property
    def main_timeline(self):
        return Timeline(self._read()["root"])

    def timeline(self, name):
        """The timeline called `name`."""
        return _named(self.timelines, name, "timeline", "The project")

    @property
    def assets(self):
        return [Asset(aid) for aid in self._read()["assets"]]

    def asset(self, name):
        return _named(self.assets, name, "asset", "The project")

    def document(self):
        """The project as `project.json` has it, as a dictionary. Changing
        it changes nothing in the project."""
        return call("document")

    def add_timeline(self, name="Timeline", frame_size=None, frame_rate=None):
        """A new, empty timeline, with the main timeline's frame size and
        rate unless given."""
        arguments = {"name": name}
        if frame_size is not None:
            arguments["frame_size"] = [float(frame_size[0]), float(frame_size[1])]
        if frame_rate is not None:
            arguments["frame_rate"] = float(frame_rate)
        return Timeline(call("add_timeline", **arguments))

    def __repr__(self):
        return "<Project %r>" % _try(lambda: self.name)


# MARK: - Timeline


class Timeline(_Proxy):
    __slots__ = ()

    def _read(self):
        return call("timeline", timeline=self._key[0])

    @property
    def name(self):
        return self._read()["name"]

    @name.setter
    def name(self, value):
        call("set_timeline_name", timeline=self._key[0], name=str(value))

    @property
    def frame_size(self):
        return tuple(self._read()["frame_size"])

    @property
    def frame_rate(self):
        return self._read()["frame_rate"]

    @property
    def frame(self):
        """One frame's duration, in seconds."""
        return time_in(self._read()["frame"])

    @property
    def duration(self):
        return time_in(self._read()["duration"])

    @property
    def layers(self):
        """Its layers, the top one first."""
        return [Layer(self._key[0], lid) for lid in self._read()["layers"]]

    def layer(self, name):
        """The layer called `name`; of two with one name, the upper."""
        return _named(self.layers, name, "layer", "“%s”" % self.name)

    @property
    def sections(self):
        return [Section(s["name"], time_in(s["start"]), time_in(s["end"])) for s in self._read()["sections"]]

    def place(self, asset):
        """Puts a whole asset on a new layer at the top, and gives its clip."""
        if not isinstance(asset, Asset):
            raise TypeError("place() takes an Asset, such as amv.project.assets[0]")
        return Clip(self._key[0], call("place", timeline=self._key[0], asset=asset.id))

    def __repr__(self):
        return "<Timeline %r>" % _try(lambda: self.name)


# MARK: - Layer


class Layer(_Proxy):
    __slots__ = ()

    def _read(self):
        return call("layer", timeline=self._key[0], layer=self._key[1])

    @property
    def timeline(self):
        return Timeline(self._key[0])

    @property
    def name(self):
        return self._read()["name"]

    @name.setter
    def name(self, value):
        call("set_layer_name", timeline=self._key[0], layer=self._key[1], name=None if value is None else str(value))

    @property
    def kind(self):
        """"video", "sound" or "music"."""
        return self._read()["kind"]

    @property
    def is_adjustment(self):
        return self._read()["adjustment"]

    @property
    def clips(self):
        return [Clip(self._key[0], clip[0]) for clip in self._read()["clips"]]

    def clip_at(self, time):
        """The clip playing at `time` on the timeline, or None in a gap."""
        seconds = time_in(time_out(time)) if not isinstance(time, float) else time
        for clip in self._read()["clips"]:
            if time_in(clip[1]) <= seconds < time_in(clip[2]):
                return Clip(self._key[0], clip[0])
        return None

    @property
    def beats(self):
        """The times of the beats of the sound on this layer, in its
        timeline's time."""
        return [time_in(t) for t in call("beats", timeline=self._key[0], layer=self._key[1])]

    def move(self, index):
        """Moves it to `index` in the stack, 0 being the top."""
        call("move_layer", timeline=self._key[0], layer=self._key[1], index=int(index))

    def delete(self):
        """Removes the layer and every clip on it."""
        call("delete_layer", timeline=self._key[0], layer=self._key[1])

    def __repr__(self):
        return "<Layer %r>" % _try(lambda: self.name)


# MARK: - Clip


class Clip(_Proxy):
    __slots__ = ()

    def _read(self):
        return call("clip", timeline=self._key[0], clip=self._key[1])

    def _change(self, method, **arguments):
        return call(method, timeline=self._key[0], clip=self._key[1], **arguments)

    @property
    def timeline(self):
        return Timeline(self._key[0])

    @property
    def layer(self):
        return Layer(self._key[0], self._read()["layer"])

    @property
    def name(self):
        return self._read()["name"]

    @property
    def start(self):
        """Where it starts on its timeline. Setting it moves the clip, as
        dragging it does: clips in the way move along."""
        return time_in(self._read()["start"])

    @start.setter
    def start(self, value):
        self._change("set_start", time=time_out(value))

    @property
    def end(self):
        return time_in(self._read()["end"])

    @property
    def trim_start(self):
        """The first moment of its source it plays, in source time."""
        return time_in(self._read()["trim_start"])

    @trim_start.setter
    def trim_start(self, value):
        self._change("set_trim_start", time=time_out(value))

    @property
    def trim_end(self):
        return time_in(self._read()["trim_end"])

    @trim_end.setter
    def trim_end(self, value):
        self._change("set_trim_end", time=time_out(value))

    @property
    def enabled(self):
        return self._read()["enabled"]

    @property
    def source(self):
        """The asset or timeline it plays, or None for an adjustment or a
        graphic clip."""
        source = self._read()["source"]
        if source["kind"] == "media":
            return Asset(source["id"])
        if source["kind"] == "timeline":
            return Timeline(source["id"])
        return None

    @property
    def source_kind(self):
        """"media", "timeline", "adjustment" or "graphic"."""
        return self._read()["source"]["kind"]

    @property
    def effects(self):
        return EffectList(self, "effects", self._read()["effects"])

    @property
    def sound_effects(self):
        return EffectList(self, "sound_effects", self._read()["sound_effects"])

    def effect(self, name):
        """The effect of kind or name `name`, in either stack."""
        for stack in (self.effects, self.sound_effects):
            for effect in stack:
                if name in (effect.kind, effect.name):
                    return effect
        raise LookupError("The clip has no effect called “%s”" % name)

    @property
    def volume(self):
        """Its volume in decibels, keyframed: read only."""
        return Control(self._key[0], self._key[1], None, "volume")

    def source_time(self, time):
        """The moment of its source playing at `time` on the timeline."""
        return time_in(self._change("source_time", time=time_out(time)))

    def timeline_time(self, time):
        """Where the moment `time` of its source plays on the timeline."""
        return time_in(self._change("timeline_time", time=time_out(time)))

    def split(self, at):
        """Splits it at `at`, a time on the timeline strictly inside it.
        Both halves are new clips, which are returned."""
        first, second = self._change("split", time=time_out(at))
        return Clip(self._key[0], first), Clip(self._key[0], second)

    def delete(self):
        self._change("delete_clip")

    def __repr__(self):
        return "<Clip %r>" % _try(lambda: self.name)


class EffectList(Sequence):
    """A clip's stack of effects, the top one first."""

    def __init__(self, clip, stack, ids):
        self._clip = clip
        self._stack = stack
        self._ids = ids

    def _effect(self, eid):
        return Effect(self._clip._key[0], self._clip._key[1], eid)

    def __len__(self):
        return len(self._ids)

    def __getitem__(self, index):
        if isinstance(index, str):
            for effect in self:
                if index in (effect.kind, effect.name):
                    return effect
            raise LookupError("The clip has no effect called “%s”" % index)
        if isinstance(index, slice):
            return [self._effect(eid) for eid in self._ids[index]]
        return self._effect(self._ids[index])

    def add(self, kind, index=None):
        """Adds an effect of `kind` ("gaussianBlur") at `index`, or at the
        bottom (a Keyframing effect at the top), and gives it."""
        arguments = {"kind": str(kind), "sound": self._stack == "sound_effects"}
        if index is not None:
            arguments["index"] = int(index)
        return self._effect(self._clip._change("add_effect", **arguments))

    def __repr__(self):
        return repr(list(self))


# MARK: - Effect


class Effect(_Proxy):
    __slots__ = ()

    def _read(self):
        return call("effect", timeline=self._key[0], clip=self._key[1], effect=self._key[2])

    def _change(self, method, **arguments):
        return call(method, timeline=self._key[0], clip=self._key[1], effect=self._key[2], **arguments)

    @property
    def clip(self):
        return Clip(self._key[0], self._key[1])

    @property
    def kind(self):
        return self._read()["kind"]

    @property
    def name(self):
        return self._read()["name"]

    @name.setter
    def name(self, value):
        self._change("set_effect", name=None if value is None else str(value))

    @property
    def enabled(self):
        return self._read()["enabled"]

    @enabled.setter
    def enabled(self, value):
        self._change("set_effect", enabled=bool(value))

    @property
    def controls(self):
        return [Control(self._key[0], self._key[1], self._key[2], c[0]) for c in self._read()["controls"]]

    def __getitem__(self, name):
        for cid, kind, title in self._read()["controls"]:
            if name in (kind, title):
                return Control(self._key[0], self._key[1], self._key[2], cid)
        raise LookupError("%s has no control called “%s”" % (_try(lambda: self.name), name))

    def remove(self):
        self._change("remove_effect")

    def move(self, index):
        """Moves it to `index` in its stack, 0 being the top."""
        self._change("move_effect", index=int(index))

    def __repr__(self):
        return "<Effect %r>" % _try(lambda: self.name)


# MARK: - Control


class Control(_Proxy):
    """One control of an effect, or a clip's volume (with no effect)."""

    __slots__ = ()

    def _target(self):
        timeline, clip, effect, control = self._key
        if effect is None:
            return {"timeline": timeline, "clip": clip, "property": control}
        return {"timeline": timeline, "clip": clip, "effect": effect, "control": control}

    def _read(self):
        return call("control", target=self._target())

    @property
    def clip(self):
        return Clip(self._key[0], self._key[1])

    @property
    def effect(self):
        return None if self._key[2] is None else Effect(*self._key[:3])

    @property
    def kind(self):
        return self._read()["kind"]

    @property
    def name(self):
        return self._read()["name"]

    @property
    def value(self):
        """Its value where it isn't keyframed: a number, a Vector, or for a
        choice its option. Setting it sets that value.

        In an expression, its value at this sample, read on its own
        timeline's clock: as many seconds from that timeline's start as
        `time` is from this one's."""
        if _bridge.sample_time is not None:
            return self.at(_bridge.sample_time)
        return value_in(self._read()["value"])

    @value.setter
    def value(self, value):
        call("set_control", target=self._target(), value=value_out(value))

    @property
    def keyframes(self):
        """Every keyframe, as (time, value), the time in its clip's source
        time as it is saved. Assigning a list replaces them all."""
        return [(time_in(t), value_in(v)) for t, v in self._read()["keyframes"]]

    @keyframes.setter
    def keyframes(self, keyframes):
        pairs = []
        for keyframe in keyframes:
            time, value = keyframe
            pairs.append([time_out(time), value_out(value)])
        call("set_keyframes", target=self._target(), keyframes=pairs)

    def at(self, time):
        """Its value at `time`, a moment of its clip's source. In an
        expression, `time` is a moment of its timeline instead, as `time`
        is, and the value is read in a straight line between the frames
        of its clip."""
        if _bridge.sample_time is not None:
            return self._sampled(float(time))
        return value_in(call("control_at", target=self._target(), times=[time_out(time)])[0])

    def _sampled(self, seconds):
        key = self._key
        table = _bridge.tables.get(key)
        if table is None:
            table = call("control_frames", target=self._target())
            _bridge.tables[key] = table
        values = table["values"]
        if not values:
            raise Gone("%s has no frames to read" % _try(lambda: self.name))
        if isinstance(values[0], str):
            return values[0]
        position = (seconds - table["start"]) / table["frame"] if table["frame"] > 0 else 0.0
        if position <= 0:
            return value_in(values[0])
        if position >= len(values) - 1:
            return value_in(values[-1])
        low = int(position)
        f = position - low
        a, b = values[low], values[low + 1]
        if isinstance(a, list):
            return Vector(x + (y - x) * f for x, y in zip(a, b))
        return a + (b - a) * f

    @property
    def driven_by(self):
        """The Keyframing effect that writes its keyframes, or None."""
        driver = self._read()["driven_by"]
        return None if driver is None else Effect(self._key[0], self._key[1], driver)

    def drive(self, method, **settings):
        """Gives it a Keyframing method ("wiggler", "oscillator", …), with
        the method's controls set from `settings` by kind (and Strobe
        Keys' `pattern`, such as "x.X."), and gives the method's effect."""
        arguments = {name: value_out(value) for name, value in settings.items()}
        return Effect(self._key[0], self._key[1], call("drive", target=self._target(), method=str(method), settings=arguments))

    def bake(self):
        """Keeps the keyframes its method made as its own, and takes the
        method away."""
        call("bake", target=self._target())

    def __repr__(self):
        return "<Control %r>" % _try(lambda: self.name)


# MARK: - Asset


class Asset(_Proxy):
    __slots__ = ()

    def _read(self):
        return call("asset", asset=self._key[0])

    @property
    def name(self):
        return self._read()["name"]

    @name.setter
    def name(self, value):
        call("set_asset_name", asset=self._key[0], name=str(value))

    @property
    def path(self):
        return self._read()["path"]

    @property
    def kind(self):
        return self._read()["kind"]

    @property
    def duration(self):
        return time_in(self._read()["duration"])

    @property
    def scenes(self):
        """Its scenes, as found and edited, in its own time; empty until
        they are found."""
        return [Scene(time_in(a), time_in(b)) for a, b in self._read()["scenes"]]

    def __repr__(self):
        return "<Asset %r>" % _try(lambda: self.name)


def _try(read):
    try:
        return read()
    except Exception:
        return "?"
