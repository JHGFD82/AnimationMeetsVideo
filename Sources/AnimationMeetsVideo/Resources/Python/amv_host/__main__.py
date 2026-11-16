"""AnimationMeetsVideo's Python helper.

The app starts it as `python -E -P <this file>` and talks to it in frames
over its standard input and output (see `protocol`). Before anything else
it takes those two for frames alone: printed text, and anything C writes
to file descriptors 1 and 2, goes to the app as `output` messages, and
code reading standard input reads nothing. Only the standard library is
used, so any Python 3.11 or later runs it.
"""

import os
import sys
import threading


def _take_standard_streams():
    """Keeps the frames' descriptors for the channel and points 0, 1 and 2
    elsewhere. Gives the two ends of the channel and the pipes stray output
    arrives on."""
    frames_in = os.fdopen(os.dup(0), "rb")
    frames_out = os.fdopen(os.dup(1), "wb")
    nothing = os.open(os.devnull, os.O_RDONLY)
    os.dup2(nothing, 0)
    os.close(nothing)
    pipes = {}
    for fd, stream in ((1, "stdout"), (2, "stderr")):
        read_end, write_end = os.pipe()
        os.dup2(write_end, fd)
        os.close(write_end)
        pipes[stream] = read_end
    sys.stdin = open(os.devnull)
    return frames_in, frames_out, pipes


class StrayOutput:
    """What C writes to descriptors 1 and 2, read off their pipes on
    threads of its own and sent as the output of the run under way.

    `drain()` writes a marker down each pipe and waits for both to come out
    the other end, so everything written before a run ended is sent before
    its result."""

    MARK = b"\x00amv-drained\x00"

    def __init__(self, pipes):
        self.host = None
        self._pipes = pipes
        self._drained = threading.Condition()
        self._marks = 0

    def start(self):
        for stream, read_end in self._pipes.items():
            threading.Thread(target=self._forward, args=(read_end, stream), daemon=True).start()

    def drain(self, timeout=0.5):
        with self._drained:
            self._marks = 0
            for fd in (1, 2):
                try:
                    os.write(fd, self.MARK)
                except OSError:
                    return
            self._drained.wait_for(lambda: self._marks >= 2, timeout)

    def _forward(self, read_end, stream):
        pending = b""
        with os.fdopen(read_end, "rb", buffering=0) as pipe:
            while True:
                data = pipe.read(65536)
                if not data:
                    return
                pending += data
                while True:
                    at = pending.find(self.MARK)
                    if at < 0:
                        # Hold back what could be the start of a mark.
                        keep = next((n for n in range(len(self.MARK) - 1, 0, -1) if pending.endswith(self.MARK[:n])), 0)
                        text, pending = (pending[:-keep], pending[-keep:]) if keep else (pending, b"")
                        self._send(stream, text)
                        break
                    self._send(stream, pending[:at])
                    pending = pending[at + len(self.MARK):]
                    with self._drained:
                        self._marks += 1
                        self._drained.notify_all()

    def _send(self, stream, data):
        if data and self.host is not None:
            self.host.output(stream, data.decode("utf-8", "replace"))


def main():
    frames_in, frames_out, pipes = _take_standard_streams()
    sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

    from amv_host import protocol, runner
    from amv_host import amv

    # Scripts `import amv`; it is the helper's own copy, found by that name.
    sys.modules["amv"] = amv

    interrupts = protocol.Interrupts()
    interrupts.install()
    channel = protocol.Channel(frames_in, frames_out, interrupts)
    stray = StrayOutput(pipes)
    stray.start()

    def connect(host):
        stray.host = host
        host.drain = stray.drain

    runner.serve(channel, on_host=connect)


if __name__ == "__main__":
    main()
