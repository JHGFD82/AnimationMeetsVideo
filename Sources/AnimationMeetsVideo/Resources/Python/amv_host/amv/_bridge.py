"""How `amv`'s objects ask the app about the project.

Every read and change is a `call` to the app's `ProjectBridge`, answered
from the project as it was when the run began, with the run's own changes
applied (see docs/python-scripting.md, "The bridge"). The helper sets
`connection` for each run and clears it after; outside a run, as when the
module is imported somewhere other than the app, there is nothing to ask.
"""


class Gone(LookupError):
    """The thing an object stands for isn't in the project any more."""


class Refused(Exception):
    """A change the app would refuse by hand: a clip the Motion Designer has
    open, or the keyframes of a control a Keyframing method drives."""


class NotConnected(RuntimeError):
    pass


# Set by the helper while a run is under way: a function taking the
# method's name and its arguments, returning the app's answer or raising
# the app's error.
connection = None

# What the app said about the window the run is for: the timeline shown,
# the clips selected and the playhead.
context = {}


def call(method, **arguments):
    if connection is None:
        raise NotConnected("amv reads the project open in AnimationMeetsVideo, and only runs inside the app.")
    return connection(method, arguments)


# Shown as amv.Gone and amv.Refused in tracebacks, as scripts name them.
Gone.__module__ = Refused.__module__ = NotConnected.__module__ = "amv"

ERRORS = {"gone": Gone, "refused": Refused, "type": TypeError, "value": ValueError, "lookup": LookupError}
