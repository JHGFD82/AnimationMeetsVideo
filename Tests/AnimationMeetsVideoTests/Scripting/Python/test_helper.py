"""The helper, run as the app runs it, against a fake app.

Run from the repository with any Python 3.11 or later:

    python3 -B -m unittest discover -s Tests/AnimationMeetsVideoTests/Scripting/Python

`PythonHelperTests` runs these from `swift test` when `AMV_PYTHON` is set.
"""

import json
import os
import signal
import struct
import subprocess
import sys
import tempfile
import time
import unittest
from fractions import Fraction

# Importing the helper's code here mustn't leave .pyc files in the app's
# resources, which SwiftPM would copy into the bundle.
sys.dont_write_bytecode = True

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", "..", "..", ".."))
HOST = os.path.join(ROOT, "Sources", "AnimationMeetsVideo", "Resources", "Python", "amv_host", "__main__.py")
PYTHON = os.environ.get("AMV_PYTHON") or sys.executable


class Helper:
    """The helper process, and the app's side of its pipes."""

    def __init__(self):
        self.process = subprocess.Popen(
            [PYTHON, "-E", "-P", "-B", "-X", "utf8", HOST], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE
        )
        self.next_id = 0

    def send(self, header, payload=b""):
        if payload:
            header = dict(header, bytes=len(payload))
        data = json.dumps(header).encode()
        self.process.stdin.write(struct.pack("<I", len(data)) + data + payload)
        self.process.stdin.flush()

    def read(self):
        head = self.process.stdout.read(4)
        if len(head) < 4:
            raise EOFError("The helper ended: %s" % self.process.stderr.read().decode())
        (length,) = struct.unpack("<I", head)
        header = json.loads(self.process.stdout.read(length))
        if header.get("bytes"):
            header["payload"] = self.process.stdout.read(header["bytes"])
        return header

    def run(self, kind, code, app=None, payload=b"", **extra):
        """Runs `code`, answering its calls with `app`; gives the output
        printed and the result or error."""
        self.next_id += 1
        self.send(dict(extra, type=kind, id=self.next_id, code=code), payload)
        printed = []
        while True:
            message = self.read()
            if message["type"] == "call":
                try:
                    value = app.answer(message["method"], message["args"])
                    self.send({"type": "reply", "id": message["id"], "value": value})
                except AppError as error:
                    self.send({"type": "reply", "id": message["id"], "error": {"kind": error.kind, "message": str(error)}})
            elif message["type"] == "output":
                printed.append(message["text"])
            else:
                self.assert_run(message)
                return "".join(printed), message

    def assert_run(self, message):
        assert message["run"] == self.next_id, message

    def close(self):
        if self.process.poll() is None:
            self.process.stdin.close()
            self.process.wait(5)
        self.process.stdout.close()
        self.process.stderr.close()


class AppError(Exception):
    def __init__(self, kind, message):
        super().__init__(message)
        self.kind = kind


class FakeApp:
    """A project of one timeline with one layer and two clips, answering
    the bridge's calls as `ProjectBridge` does, and recording changes."""

    def __init__(self):
        self.changes = []
        self.timeline = {"name": "Main", "frame_size": [1920, 1080], "frame_rate": 24, "frame": [1, 24],
                         "duration": [10, 1], "layers": ["L1"], "sections": [{"name": "Intro", "start": [0, 1], "end": [2, 1]}]}
        self.clips = {
            "C1": {"layer": "L1", "name": "One", "start": [0, 1], "end": [4, 1], "trim_start": [0, 1], "trim_end": [4, 1],
                   "enabled": True, "source": {"kind": "media", "id": "A1"}, "effects": ["E1"], "sound_effects": []},
            "C2": {"layer": "L1", "name": "Two", "start": [4, 1], "end": [10, 1], "trim_start": [1, 2], "trim_end": [13, 2],
                   "enabled": True, "source": {"kind": "graphic", "id": None}, "effects": [], "sound_effects": []},
        }
        self.controls = {
            "K1": {"kind": "position", "name": "Position", "value": [0, 0], "keyframes": [[[0, 1], [0, 0]], [[1, 1], [100, 50]]],
                   "driven_by": None},
            "K2": {"kind": "opacity", "name": "Opacity", "value": 100, "keyframes": [], "driven_by": None},
        }

    def answer(self, method, args):
        if method == "project":
            return {"id": "P", "name": "Demo", "root": "T1", "timelines": ["T1"], "assets": ["A1"]}
        if method == "timeline":
            return self.timeline
        if method == "layer":
            return {"name": "Video 1", "kind": "video", "adjustment": False,
                    "clips": [[cid, c["start"], c["end"]] for cid, c in self.clips.items()]}
        if method == "clip":
            if args["clip"] not in self.clips:
                raise AppError("gone", "The clip is gone.")
            return self.clips[args["clip"]]
        if method == "effect":
            return {"kind": "transform", "name": "Transform", "enabled": True,
                    "controls": [["K1", "position", "Position"], ["K2", "opacity", "Opacity"]]}
        if method == "control":
            return self.controls[args["target"]["control"]]
        if method == "control_frames":
            # Position over 4 s at 24 fps: x climbs 10 a frame, y holds.
            return {"start": 0.0, "frame": 1 / 24, "values": [[10.0 * k, 5.0] for k in range(97)]}
        if method == "control_at":
            return [[50, 25] for _ in args["times"]]
        if method == "asset":
            return {"name": "Clip.mov", "path": "/x/Clip.mov", "kind": "video", "duration": [10, 1], "scenes": [[[0, 1], [3, 1]]]}
        if method == "source_time":
            time = args["time"]
            return [time[0] + time[1], time[1]] if isinstance(time, list) else [int(round((time + 1) * 24)), 24]
        if method == "set_keyframes" and args["target"]["control"] == "K2":
            raise AppError("refused", "Opacity's keyframes are made by Wiggler. Bake them first.")
        if method.startswith("set_") or method in ("split", "add_effect", "delete_clip"):
            self.changes.append((method, args))
            if method == "split":
                return ["C3", "C4"]
            if method == "add_effect":
                return "E2"
            return None
        raise AppError("value", "No such call: %s" % method)


class HelperTests(unittest.TestCase):
    def setUp(self):
        self.helper = Helper()
        self.app = FakeApp()

    def tearDown(self):
        self.helper.close()

    def line(self, code, **extra):
        return self.helper.run("line", code, self.app, **extra)

    def test_ping_names_the_interpreter(self):
        self.helper.send({"type": "ping", "id": 7})
        pong = self.helper.read()
        self.assertEqual(pong["type"], "pong")
        self.assertEqual(pong["id"], 7)
        self.assertEqual(pong["version"], "%d.%d.%d" % sys.version_info[:3] if PYTHON == sys.executable else pong["version"])

    def test_the_last_line_is_the_value(self):
        _, result = self.line("x = 3\nx * 2")
        self.assertEqual(result, {"type": "result", "display": "6", "run": 1})

    def test_names_set_on_one_line_are_there_on_the_next(self):
        self.line("y = 40")
        _, result = self.line("y + 2")
        self.assertEqual(result["display"], "42")

    def test_a_statement_shows_nothing(self):
        _, result = self.line("z = 1")
        self.assertNotIn("display", result)

    def test_print_and_c_output_come_before_the_result(self):
        printed, result = self.line("import os\nprint('from Python')\nos.write(1, b'from C\\n')\nNone")
        self.assertEqual(printed, "from Python\nfrom C\n")
        self.assertEqual(result["type"], "result")

    def test_reading_standard_input_reads_nothing(self):
        _, result = self.line("import sys\nsys.stdin.read()")
        self.assertEqual(result["display"], "''")

    def test_an_error_names_its_line(self):
        _, error = self.line("a = 1\ntim")
        self.assertEqual(error["type"], "error")
        self.assertEqual(error["exception"], "NameError")
        self.assertEqual(error["line"], 2)
        self.assertEqual(error["message"], "name 'tim' is not defined")
        self.assertNotIn("amv_host", error["traceback"])

    def test_an_error_in_a_function_names_the_line_it_happened_at_and_shows_the_call(self):
        _, error = self.line("def f():\n    return 1 / 0\n\nf()")
        self.assertEqual(error["exception"], "ZeroDivisionError")
        self.assertEqual(error["line"], 2)
        self.assertIn("line 4, in <module>", error["traceback"])

    def test_a_syntax_error_names_its_line(self):
        _, error = self.line("x = 1\ndef f(:\n    pass")
        self.assertEqual(error["exception"], "SyntaxError")
        self.assertEqual(error["line"], 2)

    def test_stop_raises_keyboard_interrupt_and_the_helper_runs_on(self):
        self.helper.next_id += 1
        self.helper.send({"type": "line", "id": self.helper.next_id, "code": "while True:\n    pass"})
        time.sleep(0.3)
        self.helper.process.send_signal(signal.SIGINT)
        error = self.helper.read()
        self.assertEqual(error["exception"], "KeyboardInterrupt")
        self.assertEqual(error["message"], "Stopped.")
        _, result = self.line("1 + 1")
        self.assertEqual(result["display"], "2")

    def test_a_stop_after_a_run_ended_is_dropped(self):
        self.line("1")
        self.helper.process.send_signal(signal.SIGINT)
        time.sleep(0.2)
        _, result = self.line("2")
        self.assertEqual(result["display"], "2")

    def test_output_past_the_cap_is_dropped_with_a_note(self):
        printed, result = self.line("for _ in range(3000):\n    print('x' * 999)")
        self.assertEqual(result["type"], "result")
        self.assertTrue(printed.endswith("Output past 1 MB was dropped.\n"))
        self.assertLessEqual(len(printed.encode()), 1024 * 1024 + 100)

    def test_exit_with_no_code_is_a_clean_end(self):
        _, result = self.line("raise SystemExit")
        self.assertEqual(result["type"], "result")

    # MARK: amv

    def test_amv_is_imported_in_the_console(self):
        _, result = self.line("amv.project.name")
        self.assertEqual(result["display"], "'Demo'")

    def test_times_are_fractions(self):
        _, result = self.line("amv.project.timelines[0].frame")
        self.assertEqual(result["display"], repr(Fraction(1, 24)))

    def test_the_context_gives_timeline_selection_and_playhead(self):
        context = {"timeline": "T1", "selection": [["T1", "C2"]], "playhead": [3, 2]}
        _, result = self.line("(amv.timeline.name, [c.name for c in amv.selection], amv.playhead)", context=context)
        self.assertEqual(result["display"], repr(("Main", ["Two"], Fraction(3, 2))))

    def test_lookups_by_name(self):
        _, result = self.line("amv.project.timeline('Main').layer('Video 1').clip_at(5).name")
        self.assertEqual(result["display"], "'Two'")
        _, error = self.line("amv.project.timeline('Titles')")
        self.assertEqual(error["exception"], "LookupError")
        self.assertIn("Titles", error["message"])

    def test_clip_at_a_gap_is_none_and_ends_are_exclusive(self):
        _, result = self.line("layer = amv.project.timelines[0].layers[0]\n(layer.clip_at(4).name, layer.clip_at(10))")
        self.assertEqual(result["display"], repr(("Two", None)))

    def test_a_vector_value_does_arithmetic_by_component(self):
        code = "p = amv.project.timelines[0].layers[0].clips[0].effects[0]['position']\n(p.value + 10, p.at(1) * 2, p.keyframes[1])"
        _, result = self.line(code)
        self.assertEqual(result["display"], "(Vector(10, 10), Vector(100, 50), (Fraction(1, 1), Vector(100, 50)))")

    def test_setting_sends_exact_and_rounded_times(self):
        code = "c = amv.project.timelines[0].layers[0].clips[0]\nc.start = Fraction(1, 3)\nc.start = 0.5\nc.trim_end = 2"
        self.line("from fractions import Fraction\n" + code)
        self.assertEqual(self.app.changes, [
            ("set_start", {"timeline": "T1", "clip": "C1", "time": [1, 3]}),
            ("set_start", {"timeline": "T1", "clip": "C1", "time": 0.5}),
            ("set_trim_end", {"timeline": "T1", "clip": "C1", "time": [2, 1]}),
        ])

    def test_keyframes_are_replaced_in_one_call(self):
        code = "c = amv.project.timelines[0].layers[0].clips[0]\nc.effects[0]['position'].keyframes = [(0, (1, 2)), (Fraction(1, 2), [3, 4])]"
        self.line("from fractions import Fraction\n" + code)
        self.assertEqual(self.app.changes, [("set_keyframes", {
            "target": {"timeline": "T1", "clip": "C1", "effect": "E1", "control": "K1"},
            "keyframes": [[[0, 1], [1.0, 2.0]], [[1, 2], [3.0, 4.0]]],
        })])

    def test_a_refused_change_raises_refused_at_its_line(self):
        _, error = self.line("c = amv.project.timelines[0].layers[0].clips[0]\nc.effects[0]['Opacity'].keyframes = []")
        self.assertEqual(error["exception"], "Refused")
        self.assertEqual(error["line"], 2)
        self.assertIn("amv.Refused", error["traceback"])

    def test_a_gone_thing_raises_gone(self):
        _, error = self.line("amv.Clip('T1', 'C9').start")
        self.assertEqual(error["exception"], "Gone")

    def test_a_misspelt_property_raises_rather_than_setting_nothing(self):
        _, error = self.line("amv.project.timelines[0].layers[0].clips[0].strat = 1")
        self.assertEqual(error["exception"], "AttributeError")
        self.assertEqual(self.app.changes, [])

    def test_a_non_finite_value_is_refused_before_it_is_sent(self):
        _, error = self.line("amv.project.timelines[0].layers[0].clips[0].effects[0]['Opacity'].value = float('nan')")
        self.assertEqual(error["exception"], "ValueError")
        self.assertEqual(self.app.changes, [])

    def test_split_gives_both_halves(self):
        _, result = self.line("[h.id for h in amv.project.timelines[0].layers[0].clips[0].split(2)]")
        self.assertEqual(result["display"], "['C3', 'C4']")

    def test_scenes_and_sections_are_named_tuples(self):
        _, result = self.line("(amv.project.assets[0].scenes[0].end, amv.project.timelines[0].sections[0].name)")
        self.assertEqual(result["display"], repr((Fraction(3), "Intro")))

    # MARK: Scripts

    def test_a_script_runs_in_its_folder_with_a_fresh_namespace(self):
        with tempfile.TemporaryDirectory() as folder:
            with open(os.path.join(folder, "shots.csv"), "w") as file:
                file.write("a,b\n")
            with open(os.path.join(folder, "helpers.py"), "w") as file:
                file.write("WORD = 'helped'\n")
            code = "import amv, helpers\nprint(open('shots.csv').read().strip(), helpers.WORD, __name__)\nleft = 1"
            path = os.path.join(folder, "stagger.py")
            printed, result = self.helper.run("script", code, self.app, path=path, folder=folder)
            self.assertEqual(result["type"], "result")
            self.assertEqual(printed, "a,b helped __main__\n")
            _, error = self.line("left")
            self.assertEqual(error["exception"], "NameError")

    def test_a_scripts_error_names_its_line_in_its_file(self):
        with tempfile.TemporaryDirectory() as folder:
            path = os.path.join(folder, "broken.py")
            _, error = self.helper.run("script", "import amv\n\nraise ValueError('no')", self.app, path=path, folder=folder)
            self.assertEqual(error["line"], 3)
            self.assertIn(path, error["traceback"])

    def test_the_helper_ends_when_the_app_closes_its_input(self):
        self.helper.process.stdin.close()
        self.assertEqual(self.helper.process.wait(5), 0)


class ExpressionTests(unittest.TestCase):
    """Expressions, called once per sample with the tables the app sends."""

    def setUp(self):
        self.helper = Helper()
        self.app = FakeApp()

    def tearDown(self):
        self.helper.close()

    def run_expression(self, code, count=5, width=1, value=None, **extra):
        times = [k / 24 for k in range(count)]
        value = value or [[0.0] * width for _ in range(count)]
        tables = [("time", 1), ("t", 1), ("frame", 1), ("source_time", 1), ("value", width),
                  ("a", 1), ("b", 1), ("c", 1), ("d", 1)]
        columns = {
            "time": times, "t": times, "frame": [float(k) for k in range(count)], "source_time": times,
            "value": [x for v in value for x in v], "a": [2.0] * count, "b": [1.0] * count, "c": [0.0] * count, "d": [0.0] * count,
        }
        floats = [x for name, _ in tables for x in columns[name]]
        payload = struct.pack("<%dd" % len(floats), *floats)
        header = dict(
            count=count, width=width, tables=tables, fps=24.0, duration=count / 24, seed=1, effect="E9",
            context={"timeline": "T1", "clip": "C1", "layer": "L1"}, **extra
        )
        _, result = self.helper.run("expression", code, self.app, payload=payload, **header)
        if result["type"] == "result":
            data = result["payload"] if "payload" in result else b""
            return list(struct.unpack("<%dd" % (len(data) // 8), data))
        return result

    def test_each_sample_is_the_last_lines_value(self):
        self.assertEqual(self.run_expression("frame * 2"), [0, 2, 4, 6, 8])

    def test_lines_before_set_names_and_inputs_are_read(self):
        self.assertEqual(self.run_expression("x = a * 10\nx + b"), [21.0] * 5)

    def test_prev_and_state_carry_from_sample_to_sample(self):
        self.assertEqual(self.run_expression("(prev or 0) + 1"), [1, 2, 3, 4, 5])
        self.assertEqual(self.run_expression("state['n'] = state.get('n', 0) + 1\nstate['n']"), [1, 2, 3, 4, 5])

    def test_a_number_sets_every_component_of_a_vector(self):
        self.assertEqual(self.run_expression("7", count=2, width=2), [7, 7, 7, 7])
        self.assertEqual(self.run_expression("value + [1, 2]", count=1, width=2, value=[[10, 20]]), [11, 22])

    def test_another_control_is_read_on_its_clock(self):
        code = "clip.effect('Transform')['position'].value[0]"
        self.assertEqual(self.run_expression(code, count=3), [0, 10, 20])
        # Half a frame on: halfway between frames.
        self.assertEqual(self.run_expression("clip.effect('Transform')['position'].at(time + 1/48)[0]", count=2), [5, 15])

    def test_random_is_the_same_every_run(self):
        first = self.run_expression("random()")
        self.assertEqual(first, self.run_expression("random()"))
        self.assertEqual(len(set(first)), 5)

    def test_an_error_names_its_line_and_moment(self):
        error = self.run_expression("x = 1\n1 / (frame - 3)")
        self.assertEqual(error["exception"], "ZeroDivisionError")
        self.assertEqual(error["line"], 2)
        self.assertAlmostEqual(error["time"], 3 / 24)

    def test_a_value_that_isnt_a_finite_number_is_an_error(self):
        self.assertEqual(self.run_expression("float('nan')")["exception"], "ValueError")
        self.assertEqual(self.run_expression("'tall'")["exception"], "TypeError")
        self.assertEqual(self.run_expression("[1, 2, 3]", width=2)["exception"], "ValueError")

    def test_the_last_line_must_be_a_value(self):
        self.assertEqual(self.run_expression("x = 1")["exception"], "SyntaxError")

    def test_names_of_later_steps_say_so(self):
        error = self.run_expression("audio(20, 200)")
        self.assertEqual(error["exception"], "NotImplementedError")


class VectorTests(unittest.TestCase):
    def setUp(self):
        sys.path.insert(0, os.path.dirname(os.path.dirname(HOST)))
        from amv_host.amv import Vector

        self.Vector = Vector

    def tearDown(self):
        sys.path.remove(os.path.dirname(os.path.dirname(HOST)))

    def test_arithmetic(self):
        v = self.Vector([1, 2])
        self.assertEqual(v + 1, (2, 3))
        self.assertEqual(1 - v, (0, -1))
        self.assertEqual(v * v, (1, 4))
        self.assertEqual(2 / self.Vector([1, 4]), (2, 0.5))
        self.assertEqual(v + [10, 20], (11, 22))
        self.assertEqual(-v, (-1, -2))
        with self.assertRaises(ValueError):
            v + (1, 2, 3)


if __name__ == "__main__":
    unittest.main()
