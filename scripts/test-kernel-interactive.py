import json
import os
import pathlib
import queue
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest


KERNEL = pathlib.Path(__file__).resolve().parents[1] / "Quanta/Resources/quanta_kernel.py"


def kernel_command():
    return [sys.executable] + (["-S"] if sys.flags.no_site else []) + [str(KERNEL)]


def exchange(codes):
    messages = [{"op": "execute", "id": str(index), "code": code}
                for index, code in enumerate(codes)]
    wire = "".join(json.dumps(message) + "\n" for message in messages + [{"op": "shutdown"}])
    result = subprocess.run(kernel_command(), input=wire, capture_output=True, text=True, timeout=30)
    if result.returncode or result.stderr:
        raise AssertionError(result.stderr or result.stdout)
    decoded = []
    for line in result.stdout.splitlines():
        try:
            decoded.append(json.loads(line))
        except ValueError:
            continue
    if any("never awaited" in message.get("text", "")
           or "Task was destroyed" in message.get("text", "") for message in decoded):
        raise AssertionError(decoded)
    return decoded


def outputs(messages, identity=None):
    return [message for message in messages
            if message.get("type") not in ("ready", "done")
            and (identity is None or message.get("id") == str(identity))]


class AsyncExecutionTests(unittest.TestCase):
    def assert_success(self, messages):
        self.assertFalse([message for message in messages if message.get("type") == "error"])
        self.assertTrue(all(message["status"] == "ok" for message in messages if message.get("type") == "done"))

    def test_top_level_await_returns_value(self):
        messages = exchange(["import asyncio\nasync def answer():\n    await asyncio.sleep(0.01)\n    return 42\nawait answer()"])
        self.assert_success(messages)
        self.assertEqual(outputs(messages)[0]["text"], "42")

    def test_body_and_final_expression_share_running_loop(self):
        messages = exchange(["import asyncio\nloop = asyncio.get_running_loop()\nawait asyncio.sleep(0)\nloop is asyncio.get_running_loop()"])
        self.assert_success(messages)
        self.assertEqual(outputs(messages)[0]["text"], "True")

    def test_await_in_final_expression_gives_body_running_loop(self):
        messages = exchange(["import asyncio\nloop = asyncio.get_running_loop()\nawait asyncio.sleep(0, result=loop is asyncio.get_running_loop())"])
        self.assert_success(messages)
        self.assertEqual(outputs(messages)[0]["text"], "True")

    def test_loop_bound_tasks_and_futures_survive_between_cells(self):
        messages = exchange([
            "import asyncio\nloop = asyncio.get_running_loop()\nfuture = loop.create_future()\ntask = asyncio.create_task(asyncio.sleep(0.01, result=7))\nawait asyncio.sleep(0)",
            "future.set_result(5)\n(loop is asyncio.get_running_loop(), await future, await task)",
        ])
        self.assert_success(messages)
        self.assertEqual(outputs(messages, 1)[0]["text"], "(True, 5, 7)")

    def test_async_for_and_async_with(self):
        code = "\n".join([
            "import asyncio",
            "class Context:",
            "    async def __aenter__(self):",
            "        return 3",
            "    async def __aexit__(self, *args):",
            "        pass",
            "async def values():",
            "    for value in range(3):",
            "        await asyncio.sleep(0)",
            "        yield value",
            "total = 0",
            "async with Context() as amount:",
            "    async for value in values():",
            "        total += amount + value",
            "total",
        ])
        messages = exchange([code])
        self.assert_success(messages)
        self.assertEqual(outputs(messages)[0]["text"], "12")

    def test_asyncio_run_still_works_in_synchronous_cells(self):
        messages = exchange([
            "import asyncio\nasync def answer():\n    return 17\nawait answer()",
            "asyncio.run(answer())",
            "await answer()",
        ])
        self.assert_success(messages)
        self.assertEqual([message["text"] for message in outputs(messages)], ["17", "17", "17"])

    def test_future_annotations_and_semicolon_survive_await(self):
        messages = exchange([
            "from __future__ import annotations\nimport asyncio\nawait asyncio.sleep(0)",
            "async def answer(value: Unknown) -> Unknown:\n    return value\nawait answer(12);",
            "answer.__annotations__",
        ])
        self.assert_success(messages)
        self.assertEqual(outputs(messages, 1), [])
        self.assertEqual(outputs(messages, 2)[0]["text"], "{'value': 'Unknown', 'return': 'Unknown'}")

    def test_returned_coroutine_is_not_implicitly_awaited(self):
        messages = exchange([
            "import asyncio\ncalled = False\nasync def answer():\n    global called\n    called = True\n    return 42\nawait asyncio.sleep(0)\nanswer()",
            "_.close()\ncalled",
        ])
        self.assert_success(messages)
        self.assertIn("coroutine object", outputs(messages, 0)[0]["text"])
        self.assertEqual(outputs(messages, 1)[0]["text"], "False")

    def test_async_error_cleans_children_and_recovers(self):
        code = "\n".join([
            "import asyncio",
            "cleaned = []",
            "async def child():",
            "    try:",
            "        await asyncio.sleep(30)",
            "    finally:",
            "        cleaned.append('child')",
            "task = asyncio.create_task(child())",
            "await asyncio.sleep(0)",
            "raise ValueError('expected')",
        ])
        messages = exchange([code, "await asyncio.sleep(0)\n(cleaned, task.cancelled())"])
        self.assertEqual(outputs(messages, 0)[0]["ename"], "ValueError")
        self.assertEqual(outputs(messages, 1)[0]["text"], "(['child'], True)")
        self.assertEqual([message["status"] for message in messages if message.get("type") == "done"], ["error", "ok"])

    def test_shutdown_cancels_tasks_and_closes_async_generators(self):
        with tempfile.TemporaryDirectory() as directory:
            destination = pathlib.Path(directory) / "cleanup.txt"
            code = "\n".join([
                "import asyncio",
                "from pathlib import Path",
                f"destination = Path({str(destination)!r})",
                "async def child():",
                "    try:",
                "        await asyncio.sleep(30)",
                "    finally:",
                "        with destination.open('a') as stream:",
                "            stream.write('task\\n')",
                "async def values():",
                "    try:",
                "        yield 1",
                "    finally:",
                "        with destination.open('a') as stream:",
                "            stream.write('generator\\n')",
                "task = asyncio.create_task(child())",
                "generator = values()",
                "await generator.__anext__()",
                "await asyncio.sleep(0)",
            ])
            self.assert_success(exchange([code]))
            self.assertEqual(set(destination.read_text().splitlines()), {"task", "generator"})

    def test_interrupt_cleans_async_execution_and_next_cell_runs(self):
        process = subprocess.Popen(kernel_command(), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True, bufsize=1)
        incoming = queue.Queue()

        def read_messages():
            for line in process.stdout:
                try:
                    incoming.put(json.loads(line))
                except ValueError:
                    pass

        reader = threading.Thread(target=read_messages, daemon=True)
        reader.start()

        def send(message):
            process.stdin.write(json.dumps(message) + "\n")
            process.stdin.flush()

        def receive_until(predicate):
            received = []
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                message = incoming.get(timeout=max(0.01, deadline - time.monotonic()))
                received.append(message)
                if predicate(message):
                    return received
            self.fail("Kernel did not respond")

        try:
            receive_until(lambda message: message.get("type") == "ready")
            send({"op": "execute", "id": "interrupt", "code": "import asyncio\ncleaned = False\ntry:\n    print('started', flush=True)\n    await asyncio.sleep(30)\nfinally:\n    cleaned = True"})
            receive_until(lambda message: message.get("type") == "stream" and "started" in message["text"])
            started = time.monotonic()
            process.send_signal(signal.SIGINT)
            interrupted = receive_until(lambda message: message.get("type") == "done")
            self.assertLess(time.monotonic() - started, 3)
            self.assertEqual(next(message["ename"] for message in interrupted if message.get("type") == "error"), "KeyboardInterrupt")
            send({"op": "execute", "id": "recovery", "code": "await asyncio.sleep(0)\ncleaned"})
            recovered = receive_until(lambda message: message.get("type") == "done")
            self.assertEqual(next(message["text"] for message in recovered if message.get("type") == "result"), "True")
            self.assertEqual(recovered[-1]["status"], "ok")
            send({"op": "shutdown"})
            process.stdin.close()
            process.wait(timeout=5)
            self.assertEqual(process.returncode, 0)
            self.assertEqual(process.stderr.read(), "")
        finally:
            if process.poll() is None:
                process.kill()
                process.wait(timeout=5)
            reader.join(timeout=1)
            for stream in (process.stdin, process.stdout, process.stderr):
                stream.close()


class DisplayTests(unittest.TestCase):
    def test_display_preserves_output_order_and_underscore(self):
        messages = exchange([
            "99",
            "import sys\nprint('before', end='')\ndisplay('first', None, 42)\nprint('error', file=sys.stderr, end='')\nprint('after', end='')",
            "_",
        ])
        emitted = outputs(messages, 1)
        self.assertEqual([message["type"] for message in emitted], ["stream", "result", "result", "result", "stream", "stream"])
        self.assertEqual([message["text"] for message in emitted], ["before", "'first'", "None", "42", "error", "after"])
        for message in emitted[1:4]:
            self.assertEqual(message["output_type"], "display_data")
            self.assertEqual(message["mime_bundle"], {"text/plain": message["text"]})
        self.assertEqual(outputs(messages, 2)[0]["text"], "99")
        self.assertEqual(outputs(messages, 2)[0]["output_type"], "execute_result")

    def test_display_none_and_no_arguments_do_not_produce_extra_results(self):
        messages = exchange(["display(None)", "display()", "display(5);"])
        self.assertEqual([message["text"] for message in outputs(messages)], ["None", "5"])

    def test_rich_display_reuses_mime_bundles(self):
        code = "class Rich:\n    def _repr_mimebundle_(self):\n        return ({'text/html': '<b>hello</b>'}, {'text/html': {'isolated': True}})\ndisplay(Rich())"
        message = outputs(exchange([code]))[0]
        self.assertEqual(message["type"], "rich")
        self.assertEqual(message["output_type"], "display_data")
        self.assertEqual(message["mime_bundle"]["text/html"], "<b>hello</b>")
        self.assertEqual(message["metadata"]["text/html"], {"isolated": True})

    def test_nested_display_does_not_change_final_result_type(self):
        code = "class Rich:\n    def _repr_html_(self):\n        display('inside')\n        return '<b>outside</b>'\nRich()"
        emitted = outputs(exchange([code, "42"]))
        self.assertEqual([message["type"] for message in emitted], ["result", "rich", "result"])
        self.assertEqual([message["output_type"] for message in emitted], ["display_data", "execute_result", "execute_result"])

    def test_latex_display_and_final_result_keep_distinct_output_types(self):
        code = "class Formula:\n    def _repr_latex_(self):\n        return '$x^2$'\nvalue = Formula()\ndisplay(value)\nvalue"
        emitted = outputs(exchange([code]))
        self.assertEqual([message["type"] for message in emitted], ["rich", "rich"])
        self.assertEqual([message["output_type"] for message in emitted], ["display_data", "execute_result"])
        self.assertEqual(emitted[0]["mime_bundle"], emitted[1]["mime_bundle"])
        self.assertEqual(emitted[0]["mime_bundle"]["text/latex"], "$x^2$")

    def test_markdown_repr_retains_source_without_python_packages(self):
        code = "class Notes:\n    def _repr_markdown_(self):\n        return '# Result\\nThe value is $x^2$'\nNotes()"
        emitted = outputs(exchange([code]))
        self.assertEqual(emitted[0]["type"], "rich")
        self.assertEqual(emitted[0]["mime_bundle"]["text/markdown"], "# Result\nThe value is $x^2$")

    def test_clear_output_flushes_preceding_streams_and_keeps_wait_flag(self):
        code = "print('old', end='')\nclear_output()\ndisplay(1)\nclear_output(wait=True)\nprint('new', end='')"
        emitted = outputs(exchange([code]))
        self.assertEqual([message["type"] for message in emitted], ["stream", "clear_output", "result", "clear_output", "stream"])
        self.assertEqual([message["wait"] for message in emitted if message["type"] == "clear_output"], [False, True])
        self.assertEqual(emitted[0]["text"], "old")
        self.assertEqual(emitted[-1]["text"], "new")

    def test_dataframe_display_uses_native_payload_and_name(self):
        try:
            import pandas
        except ImportError:
            self.skipTest("pandas is not installed")
        messages = exchange(["import pandas as pd\nframe = pd.DataFrame({'value': [1, 2]})\ndisplay(frame)"])
        message = outputs(messages)[0]
        self.assertEqual(message["type"], "dataframe")
        self.assertEqual(message["output_type"], "display_data")
        self.assertEqual(message["payload"]["name"], "frame")
        self.assertEqual(message["payload"]["rows"], [["1"], ["2"]])

    def test_explicit_figures_are_ordered_without_automatic_duplicates(self):
        try:
            import matplotlib
        except ImportError:
            self.skipTest("matplotlib is not installed")
        code = "first, a = plt.subplots()\na.plot([1, 2])\nsecond, b = plt.subplots()\nb.plot([2, 1])\nprint('before', end='')\ndisplay(first)\nprint('after', end='')"
        emitted = outputs(exchange(["import matplotlib.pyplot as plt", code]), 1)
        self.assertEqual([message["type"] for message in emitted], ["stream", "display", "stream", "display"])
        self.assertEqual(emitted[1]["output_type"], "display_data")
        self.assertEqual(emitted[3]["output_type"], "display_data")
        self.assertNotEqual(emitted[1]["data"], emitted[3]["data"])

    def test_real_ipython_imports_remain_real(self):
        try:
            import IPython
        except ImportError:
            self.skipTest("IPython is not installed")
        messages = exchange(["import IPython\nfrom IPython.display import HTML\ndisplay(HTML('<b>hello</b>'))\nIPython.get_ipython() is None"])
        emitted = outputs(messages)
        self.assertEqual(emitted[0]["type"], "rich")
        self.assertEqual(emitted[0]["mime_bundle"]["text/html"], "<b>hello</b>")
        self.assertEqual(emitted[1]["text"], "True")


class IPythonSyntaxTests(unittest.TestCase):
    def assert_ok(self, messages):
        self.assertFalse([m for m in messages if m.get("type") == "error"], messages)

    def text(self, messages, identity, name="stdout"):
        return "".join(m["text"] for m in outputs(messages, identity)
                       if m.get("type") == "stream" and m.get("name") == name)

    def test_time_reports_and_returns_expression_value(self):
        messages = exchange(["%time total = sum(range(10))", "%time total * 2", "%%time\nvalue = 4\nvalue + 1"])
        self.assert_ok(messages)
        for identity in range(3):
            self.assertRegex(self.text(messages, identity), r"CPU times: user .*, sys: .*, total: .*\nWall time: ")
        self.assertEqual([m["text"] for m in outputs(messages, 1) if m.get("type") == "result"], ["90"])
        self.assertEqual([m["text"] for m in outputs(messages, 2) if m.get("type") == "result"], ["5"])

    def test_timeit_line_cell_and_result_object(self):
        messages = exchange(["%timeit -n 10 -r 2 sum(range(10))",
                             "%%timeit -n 5 -r 2 values = list(range(10))\nsum(values)",
                             "result = %timeit -o -q -n 3 -r 2 1 + 1\n(result.loops, result.repeat, len(result.all_runs))"])
        self.assert_ok(messages)
        self.assertIn("per loop (mean ± std. dev. of 2 runs, 10 loops each)", self.text(messages, 0))
        self.assertIn("5 loops each", self.text(messages, 1))
        self.assertEqual(outputs(messages, 2)[-1]["text"], "(3, 2, 2)")

    def test_shell_commands_stream_capture_and_expand_variables(self):
        messages = exchange(["name = 'quanta'\n!echo hello {name} $name '$$HOME'",
                             "lines = !printf 'a\\nb\\n'\n(lines, lines.n, type(lines).__name__)",
                             "for item in ['x', 'y']:\n    !echo {item}",
                             "!!echo direct"])
        self.assert_ok(messages)
        self.assertEqual(self.text(messages, 0), "hello quanta quanta $HOME\n")
        self.assertEqual(outputs(messages, 1)[-1]["text"], "(['a', 'b'], 'a\\nb', 'SList')")
        self.assertEqual(self.text(messages, 2), "x\ny\n")
        self.assertEqual(outputs(messages, 3)[-1]["text"], "['direct']")

    def test_cell_scripts_separate_streams_and_raise_on_failure(self):
        messages = exchange(["%%bash\necho out\necho err 1>&2\nexit 3", "%%bash --no-raise-error\nexit 4"])
        self.assertEqual(self.text(messages, 0), "out\n")
        self.assertEqual(self.text(messages, 0, "stderr"), "err\n")
        self.assertEqual(next(m for m in messages if m.get("type") == "error")["ename"], "CalledProcessError")
        self.assertEqual([m["status"] for m in messages if m.get("type") == "done"], ["error", "ok"])

    def test_help_shows_signature_docstring_and_source(self):
        messages = exchange(["def documented(a, b=2):\n    \"\"\"Adds numbers.\"\"\"\n    return a + b",
                             "documented?", "?documented", "documented??", "missing_name?"])
        self.assert_ok(messages)
        for identity in (1, 2):
            self.assertIn("documented(a, b=2)", self.text(messages, identity))
            self.assertIn("Adds numbers.", self.text(messages, identity))
        self.assertIn("return a + b", self.text(messages, 3))
        self.assertIn("Object `missing_name` not found.", self.text(messages, 4))

    def test_directory_environment_and_namespace_magics(self):
        with tempfile.TemporaryDirectory() as directory:
            messages = exchange([f"%cd {directory}", "%pwd", "%env QUANTA_TEST=1", "%env QUANTA_TEST",
                                 "alpha = 1\nbeta = 'b'\n%who", "%who_ls str", "%reset -f\n%who"])
            self.assert_ok(messages)
            resolved = str(pathlib.Path(directory).resolve())
            self.assertEqual(str(pathlib.Path(self.text(messages, 0).strip()).resolve()), resolved)
            self.assertEqual(self.text(messages, 2), "env: QUANTA_TEST=1\n")
            self.assertEqual(outputs(messages, 3)[-1]["text"], "'1'")
            self.assertEqual(self.text(messages, 4), "alpha\tbeta\n")
            self.assertEqual(outputs(messages, 5)[-1]["text"], "['beta']")
            self.assertEqual(self.text(messages, 6), "Interactive namespace is empty.\n")

    def test_precision_config_and_inline_matplotlib_are_accepted(self):
        messages = exchange(["%precision 2\n3.14159",
                             "%config InlineBackend.figure_format = 'retina'\n%matplotlib inline\n%precision\n2.5"])
        self.assert_ok(messages)
        self.assertEqual([m["text"] for m in outputs(messages) if m.get("type") == "result"], ["3.14", "2.5"])

    def test_writefile_run_and_capture(self):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "helper.py")
            messages = exchange([f"%%writefile {path}\nimport sys\nARGS = sys.argv[1:]\nprint('ran', __name__)",
                                 f"%run {path} one two\nARGS",
                                 "%%capture captured\nprint('hidden')\ndisplay('shown later')",
                                 "captured.stdout, len(captured.outputs)"])
            self.assert_ok(messages)
            self.assertEqual(self.text(messages, 0), f"Writing {path}\n")
            self.assertEqual(self.text(messages, 1), "ran __main__\n")
            self.assertEqual(outputs(messages, 1)[-1]["text"], "['one', 'two']")
            self.assertEqual(outputs(messages, 2), [])
            self.assertEqual(outputs(messages, 3)[-1]["text"], "('hidden\\n', 1)")

    def test_autoreload_updates_functions_and_existing_instances(self):
        with tempfile.TemporaryDirectory() as directory:
            module = pathlib.Path(directory, "reloaded_module.py")
            module.write_text("def value():\n    return 1\nclass Item:\n    def label(self):\n        return 'old'\n")
            messages = exchange([f"import sys\nsys.path.insert(0, {directory!r})\n%load_ext autoreload\n%autoreload 2",
                                 "import reloaded_module\nfrom reloaded_module import value\nitem = reloaded_module.Item()\n(value(), item.label())",
                                 f"open({str(module)!r}, 'w').write(\"def value():\\n    return 2\\nclass Item:\\n    def label(self):\\n        return 'new'\\n\")",
                                 "(value(), item.label())"])
            self.assert_ok(messages)
            self.assertEqual(outputs(messages, 1)[-1]["text"], "(1, 'old')")
            self.assertEqual(outputs(messages, 3)[-1]["text"], "(2, 'new')")

    def test_magics_keep_traceback_lines_and_strings(self):
        messages = exchange(["%time x = 1\n!true\nlabel = '%time !ls'\nraise ValueError(label)"])
        error = next(m for m in messages if m.get("type") == "error")
        self.assertEqual(error["evalue"], "%time !ls")
        self.assertEqual(error["frames"][-1]["line"], 4)
        self.assertNotIn("quanta_kernel", error["traceback"])

    def test_notebooks_run_in_their_own_folders_and_remember_cd(self):
        with tempfile.TemporaryDirectory() as first, tempfile.TemporaryDirectory() as second:
            def cell(identity, code, folder):
                return {"op": "execute", "id": identity, "code": code,
                        "notebook": os.path.join(folder, "analysis.ipynb"), "directory": folder}
            wire = [cell("a", "import os\nos.getcwd()", first), cell("cd", "%cd -q ..\nos.getcwd()", first),
                    cell("b", "os.getcwd()", second), cell("back", "os.getcwd()", first),
                    {"op": "execute", "id": "console", "code": "os.getcwd()"}, {"op": "shutdown"}]
            result = subprocess.run(kernel_command(), input="".join(json.dumps(m) + "\n" for m in wire),
                                    capture_output=True, text=True, timeout=30)
            values = {m["id"]: m["text"] for m in map(json.loads, filter(str.strip, result.stdout.splitlines()))
                      if m.get("type") == "result"}
            parent = os.path.dirname(first)
            self.assertEqual(values["a"], repr(first))
            self.assertEqual(values["cd"], repr(parent))
            self.assertEqual(values["b"], repr(second))
            self.assertEqual(values["back"], repr(parent))
            self.assertEqual(values["console"], repr(parent))

    def test_get_ipython_api_matches_converted_scripts(self):
        messages = exchange(["get_ipython().run_line_magic('matplotlib', 'inline')\nget_ipython().system('echo converted')\nget_ipython().getoutput('echo captured')"])
        self.assert_ok(messages)
        self.assertEqual(self.text(messages, 0), "Using matplotlib backend: inline\nconverted\n")
        self.assertEqual(outputs(messages, 0)[-1]["text"], "['captured']")

    def test_unknown_magic_names_fail_before_the_cell_runs(self):
        messages = exchange(["ran = True\n%definitely_unknown", "'ran' in globals()"])
        self.assertEqual(next(m for m in messages if m.get("type") == "error")["ename"], "UnsupportedNotebookCommand")
        self.assertEqual(outputs(messages, 1)[-1]["text"], "False")

    def test_input_requests_wait_for_replies_and_defer_other_requests(self):
        process = subprocess.Popen(kernel_command(), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True, bufsize=1)
        incoming = queue.Queue()
        reader = threading.Thread(target=lambda: [incoming.put(json.loads(line)) for line in process.stdout if line.strip()],
                                  daemon=True)
        reader.start()

        def send(message):
            process.stdin.write(json.dumps(message) + "\n")
            process.stdin.flush()

        def until(predicate):
            received = []
            while not received or not predicate(received[-1]):
                received.append(incoming.get(timeout=10))
            return received

        try:
            until(lambda m: m.get("type") == "ready")
            send({"op": "execute", "id": "off", "code": "input('x')"})
            self.assertIn("needs a Quanta window", next(m for m in until(lambda m: m.get("type") == "done")
                                                        if m.get("type") == "error")["evalue"])
            send({"op": "config", "input_requests": True})
            send({"op": "execute", "id": "ask", "code": "import getpass\nname = input('Name? ')\nsecret = getpass.getpass()\n(name, secret)"})
            request = until(lambda m: m.get("type") == "input_request")[-1]
            self.assertEqual((request["prompt"], request["password"]), ("Name? ", False))
            send({"op": "vars", "id": "deferred"})
            send({"op": "input_reply", "value": "Ada"})
            second = until(lambda m: m.get("type") == "input_request")
            self.assertTrue(second[-1]["password"])
            send({"op": "input_reply", "value": "hunter2"})
            finished = second + until(lambda m: m.get("type") == "done")
            self.assertEqual(next(m for m in finished if m.get("type") == "result")["text"], "('Ada', 'hunter2')")
            self.assertEqual("".join(m["text"] for m in finished if m.get("type") == "stream"), "Name? Ada\nPassword: \n")
            self.assertEqual(until(lambda m: m.get("type") == "vars")[-1]["id"], "deferred")
            send({"op": "execute", "id": "cancel", "code": "input()"})
            until(lambda m: m.get("type") == "input_request")
            send({"op": "input_reply", "interrupt": True})
            cancelled = until(lambda m: m.get("type") == "done")
            self.assertEqual(next(m for m in cancelled if m.get("type") == "error")["ename"], "KeyboardInterrupt")
        finally:
            process.kill()
            process.wait(timeout=5)
            reader.join(timeout=1)
            for stream in (process.stdin, process.stdout, process.stderr):
                stream.close()

    def test_interrupt_stops_shell_command(self):
        process = subprocess.Popen(kernel_command(), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, text=True, bufsize=1)
        incoming = queue.Queue()
        reader = threading.Thread(target=lambda: [incoming.put(json.loads(line)) for line in process.stdout if line.strip()],
                                  daemon=True)
        reader.start()
        try:
            self.assertEqual(incoming.get(timeout=10)["type"], "ready")
            process.stdin.write(json.dumps({"op": "execute", "id": "sleep", "code": "!echo started; sleep 30"}) + "\n")
            process.stdin.flush()
            self.assertEqual(incoming.get(timeout=10)["text"], "started\n")
            started = time.monotonic()
            process.send_signal(signal.SIGINT)
            received = []
            while not received or received[-1].get("type") != "done":
                received.append(incoming.get(timeout=10))
            self.assertLess(time.monotonic() - started, 5)
            self.assertEqual(next(m["ename"] for m in received if m.get("type") == "error"), "KeyboardInterrupt")
        finally:
            process.kill()
            process.wait(timeout=5)
            reader.join(timeout=1)
            for stream in (process.stdin, process.stdout, process.stderr):
                stream.close()


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="quanta-kernel-tests-") as cache:
        os.environ.setdefault("MPLCONFIGDIR", os.path.join(cache, "matplotlib"))
        os.environ.setdefault("XDG_CACHE_HOME", os.path.join(cache, "cache"))
        os.environ.setdefault("IPYTHONDIR", os.path.join(cache, "ipython"))
        unittest.main()
