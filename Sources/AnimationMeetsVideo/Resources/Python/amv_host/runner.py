"""Runs what the app sends: a script's text, a console line, and answers
its `call`s while it runs.

One thing runs at a time. Printed text goes to the app as `output`
messages, at most `OUTPUT_CAP` bytes a run. A run ends with `result` (for a
console line, the value of its last line as the console shows it) or with
`error`, naming the exception, the line it happened at in the code that
was run, and the traceback without the helper's own frames.
"""

import ast
import io
import os
import sys
import traceback

from . import protocol

OUTPUT_CAP = 1024 * 1024
HOST_FOLDER = os.path.dirname(os.path.abspath(__file__))


class AppError(Exception):
    """The app answered a call with an error of a kind `amv` doesn't name."""


class Output(io.TextIOBase):
    """`sys.stdout` or `sys.stderr` while the helper runs: each write is an
    `output` message of the run under way."""

    def __init__(self, host, stream):
        self._host = host
        self._stream = stream

    @property
    def encoding(self):
        return "utf-8"

    def writable(self):
        return True

    def write(self, text):
        if not isinstance(text, str):
            raise TypeError("write() argument must be str, not %s" % type(text).__name__)
        self._host.output(self._stream, text)
        return len(text)

    def isatty(self):
        return False


class Host:
    def __init__(self, channel):
        self.channel = channel
        self.run_id = None
        self._written = 0
        self._capped = False
        self._next_call = 0
        self.console = None
        # Waits for what C wrote during the run to be sent (see
        # `__main__.StrayOutput`); nothing to wait for without the pipes.
        self.drain = lambda: None

    # MARK: Output

    def output(self, stream, text):
        """Sends printed text, while under the run's cap; past it, once, a
        note that the rest was dropped."""
        if self.run_id is None or not text:
            return
        if self._capped:
            return
        size = len(text.encode("utf-8", "replace"))
        if self._written + size > OUTPUT_CAP:
            room = max(OUTPUT_CAP - self._written, 0)
            text = text.encode("utf-8", "replace")[:room].decode("utf-8", "ignore")
            self._capped = True
            if text:
                self.channel.send({"type": "output", "run": self.run_id, "stream": stream, "text": text})
            self.channel.send({
                "type": "output", "run": self.run_id, "stream": "note",
                "text": "Output past 1 MB was dropped.\n",
            })
            return
        self._written += size
        self.channel.send({"type": "output", "run": self.run_id, "stream": stream, "text": text})

    # MARK: Calls

    def call(self, method, arguments):
        """Asks the app, and waits for its answer. Other messages arriving
        meanwhile can only be stale replies, which are dropped."""
        self._next_call += 1
        call_id = self._next_call
        self.channel.send({"type": "call", "run": self.run_id, "id": call_id, "method": method, "args": arguments})
        while True:
            header, _ = self.channel.read()
            if header.get("type") != "reply" or header.get("id") != call_id:
                continue
            error = header.get("error")
            if error is not None:
                from .amv import _bridge

                kind = _bridge.ERRORS.get(error.get("kind"), AppError)
                raise kind(error.get("message", "The app couldn't answer."))
            return header.get("value")

    # MARK: Runs

    def begin(self, header):
        from .amv import _bridge

        self.run_id = header["id"]
        self._written = 0
        self._capped = False
        _bridge.connection = self.call
        _bridge.context = header.get("context") or {}

    def end(self, message, payload=b""):
        from .amv import _bridge

        _bridge.connection = None
        _bridge.context = {}
        sys.stdout.flush()
        sys.stderr.flush()
        self.drain()
        # The run is over: a Stop arriving now was for it, not for the next.
        with self.channel.interrupts.held(discard=True):
            self.channel.send(dict(message, run=self.run_id), payload)
        self.run_id = None

    def run_script(self, header):
        """Runs a script's text in a namespace of its own, with its folder
        as the working directory and first on the import path."""
        self.begin(header)
        path = header.get("path") or "<script>"
        folder = header.get("folder")
        namespace = {"__name__": "__main__", "__file__": path, "__builtins__": __builtins__}
        previous = os.getcwd()
        added = False
        imported_before = set(sys.modules)
        try:
            if folder:
                try:
                    os.chdir(folder)
                except OSError as error:
                    self.end(error_message(error, path))
                    return
                sys.path.insert(0, folder)
                added = True
            message = self._execute(header["code"], path, namespace, show=False)
        finally:
            if added and folder in sys.path:
                sys.path.remove(folder)
            if folder:
                _forget_modules_from(folder, set(sys.modules) - imported_before)
            try:
                os.chdir(previous)
            except OSError:
                pass
        self.end(message)

    def run_line(self, header):
        """Runs one console line, in the console's namespace, which keeps
        the names set from one line to the next."""
        self.begin(header)
        if self.console is None or header.get("fresh"):
            from . import amv

            self.console = {"__name__": "__console__", "__builtins__": __builtins__, "amv": amv}
        message = self._execute(header["code"], "<console>", self.console, show=True)
        self.end(message)

    def _execute(self, code, filename, namespace, show):
        """The `result` or `error` message for running `code`."""
        try:
            value = run_code(code, filename, namespace)
        except SystemExit as stop:
            if stop.code in (None, 0):
                return {"type": "result"}
            return error_message(stop, filename)
        except BaseException as error:  # noqa: B902 – everything is reported, KeyboardInterrupt too
            return error_message(error, filename)
        if show and value is not None:
            try:
                shown = repr(value)
            except Exception as error:
                return error_message(error, filename)
            return {"type": "result", "display": shown}
        return {"type": "result"}


def run_code(code, filename, namespace):
    """Runs `code`, giving the value of its last line when that is an
    expression, as a notebook does."""
    tree = ast.parse(code, filename, "exec")
    last = None
    if tree.body and isinstance(tree.body[-1], ast.Expr):
        last = ast.Expression(tree.body.pop().value)
    if tree.body:
        exec(compile(tree, filename, "exec"), namespace)
    if last is not None:
        return eval(compile(last, filename, "eval"), namespace)
    return None


def _forget_modules_from(folder, names):
    """Drops the modules among `names` that were loaded from `folder`, so
    a later script, perhaps of another project, imports its own rather
    than getting this one's `util` from the cache."""
    root = os.path.realpath(folder) + os.sep
    for name in names:
        module = sys.modules.get(name)
        location = getattr(module, "__file__", None)
        if location and os.path.realpath(location).startswith(root):
            del sys.modules[name]


def error_message(error, filename):
    """An `error` message: the exception's type and text, the line of
    `filename` it happened at, and the traceback without the helper's own
    frames."""
    line = None
    if isinstance(error, SyntaxError) and error.filename == filename:
        line = error.lineno
    frames = [frame for frame in traceback.extract_tb(error.__traceback__) if not _is_host(frame.filename)]
    for frame in frames:
        if frame.filename == filename:
            line = frame.lineno
    if isinstance(error, SyntaxError):
        shown = traceback.format_exception_only(type(error), error)
    else:
        shown = ["Traceback (most recent call last):\n"] + traceback.format_list(frames) if frames else []
        shown += traceback.format_exception_only(type(error), error)
    # Every frame, the helper's too, for the app's log when a run fails
    # where the reason isn't plain from the code alone.
    full = "".join(traceback.format_exception(type(error), error, error.__traceback__))
    message = str(error)
    if isinstance(error, SyntaxError):
        message = error.msg or message
    elif isinstance(error, KeyboardInterrupt):
        message = "Stopped."
    return {
        "type": "error",
        "exception": type(error).__name__,
        "message": message,
        "line": line,
        "traceback": "".join(shown),
        "full_traceback": full,
    }


def internal_error(error):
    """An `error` for a mistake in the helper itself, not in the code it
    ran: with the whole traceback, the helper's own frames too, so it can
    be reported."""
    shown = "".join(traceback.format_exception(type(error), error, error.__traceback__))
    return {
        "type": "error",
        "exception": type(error).__name__,
        "message": "The Python helper failed: %s: %s" % (type(error).__name__, error),
        "line": None,
        "traceback": shown,
    }


def _is_host(path):
    # A frame's file is an absolute path for code loaded from a file, and
    # a name like "<expression>" otherwise, which is never the helper's.
    # abspath of such a name would ask for the working folder, which can
    # fail, and then the error being written up is lost.
    return os.path.isabs(path) and os.path.normpath(path).startswith(HOST_FOLDER + os.sep)


def serve(channel, on_host=None):
    """Answers the app's messages until it closes the stream."""
    host = Host(channel)
    if on_host is not None:
        on_host(host)
    sys.stdout = Output(host, "stdout")
    sys.stderr = Output(host, "stderr")
    while True:
        try:
            header, payload = channel.read(discard_interrupts=True)
        except protocol.ClosedError:
            return host
        kind = header.get("type")
        try:
            if kind == "ping":
                channel.send({
                    "type": "pong", "id": header.get("id"),
                    "version": "%d.%d.%d" % sys.version_info[:3],
                    "executable": sys.executable,
                })
            elif kind == "script":
                host.run_script(header)
            elif kind == "line":
                host.run_line(header)
            elif kind == "expression":
                from . import expressions

                expressions.run(host, header, payload)
            elif kind == "quit":
                return host
            # Anything else (a reply to a call of a run that was stopped)
            # is dropped.
        except KeyboardInterrupt:
            # Stop came between the code ending and its result being sent.
            if host.run_id is not None:
                host.end(error_message(KeyboardInterrupt(), "<stopped>"))
        except protocol.ClosedError:
            return host
        except Exception as error:  # noqa: B902 – a mistake in the helper ends the run, not the helper
            if host.run_id is None:
                # It failed before the run began: it is still that run's.
                if kind not in ("script", "line", "expression") or header.get("id") is None:
                    raise
                host.run_id = header["id"]
            host.end(internal_error(error))
