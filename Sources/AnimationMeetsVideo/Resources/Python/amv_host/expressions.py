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


def _later(name, step):
    def unavailable(*args, **kwargs):
        raise NotImplementedError("%s isn't available in expressions yet (%s)." % (name, step))
    return unavailable


class _Later:
    """A name whose reads come in a later step."""

    def __init__(self, name, step):
        self._message = "%s isn't available in expressions yet (%s)." % (name, step)

    def __getattr__(self, attribute):
        raise NotImplementedError(self._message)


def _base_names():
    names = {name: getattr(math, name) for name in dir(math) if not name.startswith("_")}
    names.update({
        "Vector": Vector, "linear": linear, "ease": ease, "clamp": clamp, "abs": abs, "min": min, "max": max,
        "round": round, "len": len, "range": range, "sum": sum,
        "audio": _later("audio()", "it comes with Listen To"),
        "beats": _Later("beats", "it comes with Beats From"),
        "noise": _later("noise()", "it comes with Wiggler's noise"),
        "wiggle": _later("wiggle()", "it comes with Wiggler's noise"),
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
    effect = header.get("effect", "")
    time = 0.0
    try:
        statements, last = compiled(header["code"])
        out = []
        prev = None
        for k in range(count):
            time = tables["time"][k]
            _bridge.sample_time = time
            namespace = dict(names)
            for name in ("time", "t", "frame", "source_time", "value", "a", "b", "c", "d"):
                if name in tables:
                    namespace[name] = column(name, k)
            namespace["frame"] = int(round(namespace.get("frame", 0)))
            namespace["prev"] = prev
            namespace["random"] = _seeded(seed, effect, k)
            if statements is not None:
                exec(statements, namespace)
            value = eval(last, namespace)
            out.extend(_numbers(value, width, time))
            prev = value
            names["state"] = namespace["state"]
        message = {"type": "result"}
        result_payload = protocol.pack_floats(out)
    except BaseException as error:  # noqa: B902 – everything is reported, KeyboardInterrupt too
        message = runner.error_message(error, "<expression>")
        message["time"] = time
        result_payload = b""
    finally:
        _bridge.sample_time = None
        _bridge.tables = {}
    host.end(message, result_payload)
