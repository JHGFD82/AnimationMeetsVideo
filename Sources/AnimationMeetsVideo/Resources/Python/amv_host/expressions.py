"""Expressions: code called once per sample, whose value is written as
keyframes (see docs/python-scripting.md, "Expressions in detail").

The app sends an `expression` message: the code, how many samples and how
many numbers each, and in its payload a table of float64s for each name
that changes from sample to sample (`time`, `t`, `frame`, `source_time`,
`value` and the inputs `a` to `d`). The code is compiled once, kept by its
hash, and called per sample, in order; the value of its last line is the
sample. The answer is a `result` whose payload is every sample's numbers,
or an `error` naming the line and the moment it happened at.
"""

import ast
import hashlib
import math
import random as _random

from . import protocol
from .amv import _bridge
from .amv.values import Vector

# Compiled code by the hash of its text, so a run starts with no compile.
_compiled = {}
_KEPT = 64


def compiled(code):
    key = hashlib.sha256(code.encode("utf-8")).hexdigest()
    found = _compiled.get(key)
    if found is None:
        tree = ast.parse(code, "<expression>", "exec")
        if not tree.body or not isinstance(tree.body[-1], ast.Expr):
            raise SyntaxError("The last line of an expression is its value, so it must be an expression, not a statement")
        last = ast.Expression(tree.body.pop().value)
        found = (compile(tree, "<expression>", "exec") if tree.body else None, compile(last, "<expression>", "eval"))
        if len(_compiled) >= _KEPT:
            _compiled.pop(next(iter(_compiled)))
        _compiled[key] = found
    return found


# MARK: - Names in scope

def linear(x, low, high, to_low=None, to_high=None):
    """`x` from [low, high] onto [to_low, to_high], held at the ends, as
    After Effects' linear(x, a, b, c, d); with three numbers, `x` from
    [0, 1] onto [low, high]."""
    if to_low is None:
        low, high, to_low, to_high = 0.0, 1.0, low, high
    if high == low:
        return to_high if x >= high else to_low
    f = min(max((x - low) / (high - low), 0.0), 1.0)
    return to_low + (to_high - to_low) * f


def ease(x, low, high, to_low=None, to_high=None):
    """As `linear`, eased in and out."""
    if to_low is None:
        low, high, to_low, to_high = 0.0, 1.0, low, high
    if high == low:
        return to_high if x >= high else to_low
    f = min(max((x - low) / (high - low), 0.0), 1.0)
    f = f * f * (3 - 2 * f)
    return to_low + (to_high - to_low) * f


def clamp(x, low, high):
    return min(max(x, low), high)


def audio(low, high, floor=-48.0, ceiling=0.0):
    """How loud the frequencies from `low` to `high` Hz are at this sample,
    0 to 1 between `floor` and `ceiling` dB: what Listen To hears, worked
    out by the app as Audio Keys works it out. The levels are read once a
    run for each range asked for."""
    key = ("audio", float(low), float(high), float(floor), float(ceiling))
    levels = _bridge.tables.get(key)
    if levels is None:
        levels = _bridge.call("audio_levels", low=key[1], high=key[2], floor=key[3], ceiling=key[4])
        _bridge.tables[key] = levels
    return levels[_bridge.sample_index]


def noise(x, dimension=0):
    """Wiggler's smooth noise at `x`, about -1 to 1, the same every run for
    the expression's Seed; `dimension` gives another stream, as Wiggler
    moves each component on its own."""
    key = ("noise", int(dimension), float(x))
    found = _bridge.tables.get(key)
    if found is None:
        found = _bridge.call("noise", xs=[key[2]], seed=_bridge.seed, dimension=key[1])[0]
        _bridge.tables[key] = found
    return found


def wiggle(frequency, amount, octaves=1, dimension=0):
    """`amount` times Wiggler's noise at `frequency` wiggles a second, from
    the start of the expression's range: wiggle(2, 30) moves about 30 either
    way, twice a second. Read once a run for each frequency."""
    key = ("wiggle", float(frequency), int(octaves), int(dimension))
    values = _bridge.tables.get(key)
    if values is None:
        values = _bridge.call("wiggle", frequency=key[1], octaves=key[2], seed=_bridge.seed, dimension=key[3])
        _bridge.tables[key] = values
    return amount * values[_bridge.sample_index]


class Beats:
    """The beats of the layer under Beats From, at this sample: `index` (how
    many have passed), `since` and `until` (seconds since the last and to
    the next, None where there is none), `phase` (0 to 1 from one beat to
    the next, 0 before the first and after the last) and `downbeat`
    (whether the last was the first of its measure, in a beat-matched
    song)."""

    def _beats(self):
        beats = _bridge.tables.get("beats")
        if beats is None:
            beats = _bridge.call("beat_times")
            _bridge.tables["beats"] = beats
        return beats

    def _around(self):
        import bisect

        beats = self._beats()
        time = _bridge.sample_time
        passed = bisect.bisect_right([b[0] for b in beats], time + 1e-9)
        last = beats[passed - 1] if passed > 0 else None
        upcoming = beats[passed] if passed < len(beats) else None
        return passed, last, upcoming, time

    @property
    def index(self):
        return self._around()[0]

    @property
    def since(self):
        _, last, _, time = self._around()
        return None if last is None else time - last[0]

    @property
    def until(self):
        _, _, upcoming, time = self._around()
        return None if upcoming is None else upcoming[0] - time

    @property
    def phase(self):
        _, last, upcoming, time = self._around()
        if last is None or upcoming is None or upcoming[0] <= last[0]:
            return 0.0
        return (time - last[0]) / (upcoming[0] - last[0])

    @property
    def downbeat(self):
        _, last, _, _ = self._around()
        return last is not None and last[1] == 1

    @property
    def times(self):
        """Every beat's time, in seconds of the timeline."""
        return [b[0] for b in self._beats()]

    def __repr__(self):
        return "<beats: %d so far>" % self.index


def _base_names():
    names = {name: getattr(math, name) for name in dir(math) if not name.startswith("_")}
    names.update({
        "Vector": Vector, "linear": linear, "ease": ease, "clamp": clamp, "abs": abs, "min": min, "max": max,
        "round": round, "len": len, "range": range, "sum": sum,
        "audio": audio,
        "beats": Beats(),
        "noise": noise,
        "wiggle": wiggle,
    })
    return names


# MARK: - A run

def _seeded(seed, effect, sample):
    """`random()` for one sample: the same every run, for this Seed, effect
    and sample."""
    digest = hashlib.sha256(("%r:%s:%d" % (seed, effect, sample)).encode("utf-8")).digest()
    return _random.Random(int.from_bytes(digest[:8], "little")).random


def _numbers(value, width, time):
    """A sample's value as `width` numbers: a number for every component, or
    one number for each."""
    if isinstance(value, bool):
        raise TypeError("The value at %.3f s is %r, not a number" % (time, value))
    if isinstance(value, (int, float)):
        numbers = [float(value)] * width
    else:
        try:
            numbers = [float(v) for v in value]
        except (TypeError, ValueError):
            raise TypeError("The value at %.3f s is a %s, not a number or a list of numbers" % (time, type(value).__name__)) from None
        if len(numbers) != width:
            raise ValueError("The value at %.3f s has %d numbers; the control takes %d" % (time, len(numbers), width))
    for number in numbers:
        if not math.isfinite(number):
            raise ValueError("The value at %.3f s isn't a finite number: %r" % (time, number))
    return numbers


# MARK: - Running only what changed

# Each expression's last run, by its effect: what it was made from and the
# samples it gave, so a run where only some samples' rows changed (one
# keyframe of an input moved) calls the code for those alone. Kept for
# the helper's life; the app says when nothing the run read has changed
# since (`reuse`), the only time they can be used.
_last_runs = {}
_KEPT_RUNS = 64

# Names that make a sample depend on the ones before it in ways a partial
# run can't follow: `state` (kept from sample to sample), and the ways to
# reach names without naming them.
_WHOLE_RUN_NAMES = {"state", "globals", "locals", "vars", "eval", "exec"}


def _uses(code):
    """The names the code mentions."""
    try:
        return {node.id for node in ast.walk(ast.parse(code)) if isinstance(node, ast.Name)}
    except SyntaxError:
        return set()


def _samples_to_run(effect, shape, tables, count, width, reuse, code):
    """Which samples to call the code for, in order, and the results to
    start from: every sample, unless the last run of this expression was
    made from the same code and settings and nothing it read has changed
    (`reuse`). Then only the samples whose rows changed; with `prev`, from
    the first of them to the end, since each follows from the one before;
    with `state`, every sample."""
    every = list(range(count))
    last = _last_runs.get(effect)
    if not reuse or last is None or last["shape"] != shape:
        return every, [0.0] * (count * width)
    sizes = {name: size for name, size in shape[4]}
    changed = [
        k for k in range(count)
        if any(tables[name][k * size:(k + 1) * size] != last["tables"][name][k * size:(k + 1) * size] for name, size in sizes.items())
    ]
    out = list(last["results"])
    if not changed:
        return [], out
    names = _uses(code)
    if names & _WHOLE_RUN_NAMES:
        return every, out
    if "prev" in names:
        return list(range(changed[0], count)), out
    return changed, out


def _ran_alone(indices):
    """Whether the samples run aren't one run from the first to the end, so
    each one's `prev` is the result before it, not the one run before it."""
    return bool(indices) and indices[-1] - indices[0] + 1 != len(indices)


def _previous(out, k, width):
    """The result at sample `k`, as `prev` is given: a number, or a Vector
    for several; None before the first."""
    if k < 0:
        return None
    numbers = out[k * width:(k + 1) * width]
    return numbers[0] if width == 1 else Vector(numbers)


def _remember(effect, shape, tables, results):
    _last_runs.pop(effect, None)
    if len(_last_runs) >= _KEPT_RUNS:
        _last_runs.pop(next(iter(_last_runs)))
    _last_runs[effect] = {"shape": shape, "tables": tables, "results": list(results)}


def _forget(effect):
    _last_runs.pop(effect, None)


def run(host, header, payload):
    """Runs an expression over its samples, sending its `result` or
    `error`."""
    from . import amv, runner

    count = header["count"]
    width = header["width"]
    floats = protocol.unpack_floats(payload)
    tables = {}
    at = 0
    for name, size in header["tables"]:
        tables[name] = floats[at:at + count * size]
        at += count * size

    sizes = dict(header["tables"])

    def column(name, k):
        size = sizes[name]
        values = tables[name][k * size:(k + 1) * size]
        return values[0] if size == 1 else Vector(values)

    context = header.get("context") or {}
    host.begin(header)
    _bridge.tables = {}
    names = _base_names()
    names.update({
        "fps": header.get("fps", 0.0), "duration": header.get("duration", 0.0), "state": {},
        "project": amv.project,
        "timeline": amv.Timeline(context["timeline"]) if context.get("timeline") else None,
        "clip": amv.Clip(context["timeline"], context["clip"]) if context.get("clip") else None,
        "layer": amv.Layer(context["timeline"], context["layer"]) if context.get("layer") else None,
    })
    seed = header.get("seed", 1)
    _bridge.seed = seed
    effect = header.get("effect", "")
    time = 0.0
    try:
        statements, last = compiled(header["code"])
        shape = (header.get("key"), header["code"], count, width, tuple(map(tuple, header["tables"])))
        indices, out = _samples_to_run(effect, shape, tables, count, width, header.get("reuse", False), header["code"])
        prev = _previous(out, indices[0] - 1, width) if indices else None
        for k in indices:
            time = tables["time"][k]
            _bridge.sample_time = time
            _bridge.sample_index = k
            namespace = dict(names)
            for name in ("time", "t", "frame", "source_time", "value", "a", "b", "c", "d"):
                if name in tables:
                    namespace[name] = column(name, k)
            namespace["frame"] = int(round(namespace.get("frame", 0)))
            namespace["prev"] = prev if not _ran_alone(indices) else _previous(out, k - 1, width)
            namespace["random"] = _seeded(seed, effect, k)
            if statements is not None:
                exec(statements, namespace)
            value = eval(last, namespace)
            out[k * width:(k + 1) * width] = _numbers(value, width, time)
            prev = _previous(out, k, width)
            names["state"] = namespace["state"]
        _remember(effect, shape, tables, out)
        message = {"type": "result", "ran": len(indices)}
        result_payload = protocol.pack_floats(out)
    except BaseException as error:  # noqa: B902 – everything is reported, KeyboardInterrupt too
        _forget(effect)
        message = runner.error_message(error, "<expression>")
        message["time"] = time
        result_payload = b""
    finally:
        _bridge.sample_time = None
        _bridge.sample_index = None
        _bridge.tables = {}
    host.end(message, result_payload)
