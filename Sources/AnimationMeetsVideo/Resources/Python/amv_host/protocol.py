"""Frames between the app and the helper (see docs/python-scripting.md,
"The protocol").

A frame is a four-byte little-endian length, that many bytes of a JSON
header, and after it, when the header has `bytes`, that many bytes of
payload: raw little-endian float64s, for tables. The app writes frames to
the helper's standard input and reads them from its standard output, which
the helper keeps for frames alone (see `__main__`).
"""

import contextlib
import json
import signal
import struct
import threading

# Past this a header is taken to be a broken stream, not a message.
MAX_HEADER = 64 * 1024 * 1024


class ClosedError(EOFError):
    """The app closed the helper's input: time to go."""


class Interrupts:
    """Stop (SIGINT) raises `KeyboardInterrupt` in the code being run, but
    never in the middle of reading or writing a frame, which would leave
    the stream cut in two. Inside `held()` it waits, and is raised when the
    outermost hold ends; with `discard`, it is dropped instead, for an
    interrupt that came after the run it was meant for had ended."""

    def __init__(self):
        self._depth = 0
        self._pending = False

    def install(self):
        signal.signal(signal.SIGINT, self._handle)

    def _handle(self, signum, frame):
        if self._depth:
            self._pending = True
        else:
            raise KeyboardInterrupt

    @contextlib.contextmanager
    def held(self, discard=False):
        # Signals are handled on the main thread only; a frame written from
        # another (stray output from C) needs no holding.
        if threading.current_thread() is not threading.main_thread():
            yield
            return
        self._depth += 1
        try:
            yield
        finally:
            self._depth -= 1
            if not self._depth and self._pending:
                self._pending = False
                if not discard:
                    raise KeyboardInterrupt

    def drop(self):
        """Forgets an interrupt waiting to be raised."""
        self._pending = False


class Channel:
    """Reads and writes frames. Writes may come from several threads (the
    readers of stray output from C), so each frame is written whole under a
    lock."""

    def __init__(self, reader, writer, interrupts=None):
        self._reader = reader
        self._writer = writer
        self._lock = threading.Lock()
        self.interrupts = interrupts or Interrupts()

    def read(self, discard_interrupts=False):
        """The next frame as (header, payload). Raises `ClosedError` when
        the app has closed the stream."""
        with self.interrupts.held(discard=discard_interrupts):
            head = self._read_exact(4)
            (length,) = struct.unpack("<I", head)
            if length > MAX_HEADER:
                raise ValueError("A frame's header is %d bytes long" % length)
            header = json.loads(self._read_exact(length).decode("utf-8"))
            size = header.get("bytes", 0)
            payload = self._read_exact(size) if size else b""
            return header, payload

    def send(self, header, payload=b""):
        if payload:
            header = dict(header, bytes=len(payload))
        data = json.dumps(header, separators=(",", ":"), allow_nan=False, default=_plain).encode("utf-8")
        frame = struct.pack("<I", len(data)) + data + payload
        with self.interrupts.held():
            with self._lock:
                self._writer.write(frame)
                self._writer.flush()

    def _read_exact(self, count):
        chunks = []
        while count:
            chunk = self._reader.read(count)
            if not chunk:
                raise ClosedError()
            chunks.append(chunk)
            count -= len(chunk)
        return b"".join(chunks)


def _plain(value):
    """What JSON can't write on its own: fractions as [numerator,
    denominator], and anything iterable as a list."""
    from fractions import Fraction

    if isinstance(value, Fraction):
        return [value.numerator, value.denominator]
    if hasattr(value, "__iter__"):
        return list(value)
    raise TypeError("%s can't be sent to the app" % type(value).__name__)


def pack_floats(values):
    return struct.pack("<%dd" % len(values), *values)


def unpack_floats(payload):
    return list(struct.unpack("<%dd" % (len(payload) // 8), payload))
