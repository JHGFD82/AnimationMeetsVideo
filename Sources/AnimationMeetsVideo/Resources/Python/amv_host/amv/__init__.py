"""AnimationMeetsVideo's project, for scripts and the console.

    import amv

    for n, clip in enumerate(amv.selection):
        clip.start += n * 2 * amv.timeline.frame

`amv.project` is the project in the front window, `amv.timeline` the
timeline it shows, `amv.selection` its selected clips and `amv.playhead`
the playhead's time. A run of a script is one undo step, and all or
nothing: one that raises changes nothing. See docs/python-scripting.md.
"""

from ._bridge import Gone, NotConnected, Refused
from .objects import Asset, Clip, Control, Effect, EffectList, Layer, Project, Scene, Section, Timeline
from .values import Vector

__all__ = [
    "Asset", "Clip", "Control", "Effect", "EffectList", "Gone", "Layer", "NotConnected", "Project", "Refused",
    "Scene", "Section", "Timeline", "Vector", "playhead", "project", "selection", "timeline",
]

project = Project()


def __getattr__(name):
    # Read anew for each run: they are the window's, as the run began.
    from . import _bridge
    from .values import time_in

    if name == "timeline":
        timeline = _bridge.context.get("timeline")
        return None if timeline is None else Timeline(timeline)
    if name == "selection":
        return [Clip(timeline, clip) for timeline, clip in _bridge.context.get("selection", [])]
    if name == "playhead":
        return time_in(_bridge.context.get("playhead"))
    raise AttributeError("module 'amv' has no attribute %r" % name)


def __dir__():
    return sorted(set(globals()) | {"timeline", "selection", "playhead"})
