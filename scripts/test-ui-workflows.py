import json
import pathlib
import subprocess
import sys
import tempfile
import unittest

KERNEL = pathlib.Path(__file__).resolve().parents[1] / "Quanta/Resources/quanta_kernel.py"


def exchange(messages):
    wire = "".join(json.dumps(message) + "\n" for message in messages + [{"op": "shutdown"}])
    command = [sys.executable] + (["-S"] if sys.flags.no_site else []) + [str(KERNEL)]
    result = subprocess.run(command, input=wire, capture_output=True, text=True, timeout=30)
    if result.returncode:
        raise AssertionError(result.stderr)
    decoded = []
    for line in result.stdout.splitlines():
        try:
            decoded.append(json.loads(line))
        except ValueError:
            continue
    return decoded


class InspectionTests(unittest.TestCase):
    def test_execution_reports_directory_after_chdir_and_errors(self):
        with tempfile.TemporaryDirectory() as directory:
            messages = exchange([
                {"id": "move", "op": "execute", "code": f"import os; os.chdir({directory!r})"},
                {"id": "error", "op": "execute", "code": "raise ValueError('test')"},
            ])
            completed = {m["id"]: m for m in messages if m.get("type") == "done"}
            self.assertEqual(pathlib.Path(completed["move"]["cwd"]).resolve(), pathlib.Path(directory).resolve())
            self.assertEqual(completed["error"]["cwd"], completed["move"]["cwd"])
            self.assertEqual(completed["error"]["status"], "error")

    def test_nested_variable_preview_and_cycle_limit(self):
        messages = exchange([
            {"id": "setup", "op": "execute", "code": "nested = {'scores': [1, {'value': 7}]}\ncycle = []\ncycle.append(cycle)"},
            {"id": "nested", "op": "variable", "name": "nested"},
            {"id": "cycle", "op": "variable", "name": "cycle"},
            {"id": "missing", "op": "variable", "name": "absent"},
        ])
        results = {m["id"]: m for m in messages if m.get("type") in ("variable", "variable_error")}
        self.assertEqual(results["nested"]["node"]["children"][0]["name"], "'scores'")
        self.assertIn("recursive", results["cycle"]["node"]["children"][0]["value"])
        self.assertGreater(results["nested"]["bytes"], 0)
        self.assertEqual(results["missing"]["type"], "variable_error")

    def test_dataframe_filter_sort_and_pagination_preserve_source(self):
        try:
            import pandas
        except ImportError:
            self.skipTest("pandas is not installed in this interpreter")
        messages = exchange([
            {"id": "setup", "op": "execute", "code": "import pandas as pd\ndf = pd.DataFrame({'value': [20, 3, 1, 8], 'group': ['keep', 'drop', 'KEEP', 'keep']}, index=['a', 'a', 'b', 'b'])"},
            {"id": "page1", "op": "df", "name": "df", "filter": "keep", "sort_column": 0, "ascending": True, "offset": 0, "limit": 2},
            {"id": "page2", "op": "df", "name": "df", "filter": "keep", "sort_column": 0, "ascending": True, "offset": 2, "limit": 2},
            {"id": "original", "op": "df", "name": "df", "limit": 10},
            {"id": "empty", "op": "df", "name": "df", "filter": "not-present"},
            {"id": "invalid", "op": "df", "name": "df", "sort_column": 99},
        ])
        results = {m["id"]: m for m in messages if m.get("type") in ("dataframe", "df_error")}
        self.assertEqual([r[0] for r in results["page1"]["payload"]["rows"]], ["1", "8"])
        self.assertEqual([r[0] for r in results["page2"]["payload"]["rows"]], ["20"])
        self.assertEqual(results["page1"]["payload"]["total_rows"], 3)
        self.assertEqual([r[0] for r in results["original"]["payload"]["rows"]], ["20", "3", "1", "8"])
        self.assertEqual(results["empty"]["payload"]["total_rows"], 0)
        self.assertEqual(results["invalid"]["type"], "df_error")


class RichOutputTests(unittest.TestCase):
    def test_mime_bundle_and_metadata_are_preserved(self):
        messages = exchange([{"id": "rich", "op": "execute", "code": "class Rich:\n    def _repr_mimebundle_(self):\n        return ({'text/html': '<b>hello</b>', 'application/json': {'x': [1, 2]}, 'application/vnd.example+json': {'keep': True}}, {'text/html': {'isolated': True}})\nRich()"}])
        result = next(m for m in messages if m.get("type") == "rich")
        self.assertEqual(result["mime_bundle"]["application/json"], {"x": [1, 2]})
        self.assertIn("text/plain", result["mime_bundle"])
        self.assertEqual(result["metadata"]["text/html"], {"isolated": True})

    def test_svg_and_binary_jpeg_representations(self):
        messages = exchange([{"id": "rich", "op": "execute", "code": "class Rich:\n    def _repr_svg_(self):\n        return '<svg xmlns=\"http://www.w3.org/2000/svg\"/>'\n    def _repr_jpeg_(self):\n        return b'jpeg-bytes'\nRich()"}])
        result = next(m for m in messages if m.get("type") == "rich")
        self.assertIn("image/svg+xml", result["mime_bundle"])
        self.assertEqual(result["mime_bundle"]["image/jpeg"], "anBlZy1ieXRlcw==")

    def test_dataframe_has_portable_table_and_native_snapshot(self):
        try:
            import pandas
        except ImportError:
            self.skipTest("pandas is not installed")
        messages = exchange([{"id": "df", "op": "execute", "code": "import pandas as pd\npd.DataFrame({'name': ['<script>bad</script>']})"}])
        result = next(m for m in messages if m.get("type") == "dataframe")
        bundle = result["mime_bundle"]
        self.assertIn("&lt;script&gt;", bundle["text/html"])
        self.assertNotIn("<script>", bundle["text/html"])
        self.assertEqual(bundle["application/vnd.quanta.dataframe+json"]["columns"], ["name"])

    def test_plotly_retains_structured_data_without_kaleido(self):
        try:
            import plotly
        except ImportError:
            self.skipTest("plotly is not installed")
        messages = exchange([{"id": "plot", "op": "execute", "code": "import plotly.graph_objects as go\ngo.Figure(data=[go.Scatter(x=[1, 2], y=[3, 4])])"}])
        result = next(m for m in messages if m.get("type") == "plotlyhtml")
        figure = result["mime_bundle"]["application/vnd.plotly.v1+json"]
        self.assertEqual(figure["data"][0]["y"], [3, 4])
        self.assertIn("text/plain", result["mime_bundle"])


class NotebookCompatTests(unittest.TestCase):
    def test_matplotlib_magic_is_ignored(self):
        messages = exchange([
            {"id": "imports", "op": "execute",
             "code": "import math\n%matplotlib inline\nvalue = math.sqrt(4)\n"},
        ])
        done = next(m for m in messages if m.get("id") == "imports" and m.get("type") == "done")
        self.assertEqual(done["status"], "ok")
        self.assertFalse(any(m.get("type") == "error" for m in messages))

    def test_unsupported_commands_fail_before_any_cell_code_runs(self):
        commands = ["%matplotlib notebook", "%matplotlib widget", "%config InlineBackend.figure_format = 'svg'",
                    "%precision 3", "%pylab inline", "%gui qt", "%automagic", "%timeit 1 + 1",
                    "%pip install pandas", "%conda install pandas", "!echo hello", "%%bash\necho hello",
                    "files = !ls", "duration = %time 1 + 1"]
        for command in commands:
            with self.subTest(command=command):
                messages = exchange([
                    {"id": "unsupported", "op": "execute", "code": "sentinel = 1\n" + command},
                    {"id": "check", "op": "execute", "code": "'sentinel' in globals()"},
                ])
                error = next(m for m in messages if m.get("id") == "unsupported" and m.get("type") == "error")
                self.assertEqual(error["ename"], "UnsupportedNotebookCommand")
                self.assertIn("not supported", error["evalue"])
                self.assertIn("line 2", error["traceback"])
                done = next(m for m in messages if m.get("id") == "unsupported" and m.get("type") == "done")
                self.assertEqual(done["status"], "error")
                result = next(m for m in messages if m.get("id") == "check" and m.get("type") == "result")
                self.assertEqual(result["text"], "False")

    def test_multiline_modulo_and_command_strings_remain_python(self):
        messages = exchange([
            {"id": "valid", "op": "execute",
             "code": "%matplotlib inline\ndivisor = 3\nvalue = (10\n%divisor)\npayload = '!ls; %timeit; %%bash'\nvalue"},
        ])
        self.assertFalse(any(m.get("type") == "error" for m in messages))
        result = next(m for m in messages if m.get("type") == "result")
        self.assertEqual(result["text"], "1")

    def test_magic_text_inside_a_string_is_left_alone(self):
        messages = exchange([
            {"id": "literal", "op": "execute",
             "code": 'payload = """before\n%precision 3\nafter"""\nprint(repr(payload))\n'},
            {"id": "indented", "op": "execute",
             "code": 'def f():\n    return """\n%matplotlib inline\n"""\nprint(repr(f()))\n'},
        ])
        printed = [m["text"].strip() for m in messages if m.get("type") == "stream"]
        self.assertEqual(printed[0], repr("before\n%precision 3\nafter"))
        self.assertEqual(printed[1], repr("\n%matplotlib inline\n"))

    def test_magic_beside_a_single_line_string_is_still_ignored(self):
        messages = exchange([
            {"id": "cfg", "op": "execute",
             "code": "%matplotlib inline # already provided\nvalue = 'kept'\nprint(value)\n"},
        ])
        done = next(m for m in messages if m.get("type") == "done")
        self.assertEqual(done["status"], "ok")
        self.assertEqual([m["text"].strip() for m in messages if m.get("type") == "stream"], ["kept"])

    def test_ignored_magic_keeps_traceback_line_numbers(self):
        messages = exchange([
            {"id": "err", "op": "execute",
             "code": "import math\n%matplotlib inline\nvalue = math.sqrt(4)\nboom = value + undefined_name\n"},
        ])
        error = next(m for m in messages if m.get("type") == "error")
        frame = error["frames"][-1]
        self.assertEqual(frame["line"], 4)
        self.assertEqual(frame["code"], "boom = value + undefined_name")

    def test_ordinary_syntax_error_after_modulo_is_not_a_magic(self):
        messages = exchange([
            {"id": "syntax", "op": "execute", "code": "divisor = 3\nvalue = (10\n%divisor)\nif True print(1)"},
        ])
        error = next(m for m in messages if m.get("type") == "error")
        self.assertEqual(error["ename"], "SyntaxError")
        self.assertIn("line 4", error["traceback"])

    def test_unknown_magic_still_fails(self):
        messages = exchange([
            {"id": "time", "op": "execute", "code": "%time x = 1\n"},
        ])
        errors = [m for m in messages if m.get("type") == "error"]
        self.assertEqual(errors[0]["ename"], "UnsupportedNotebookCommand")

    def test_mbox_and_textnormal_latex_render(self):
        try:
            import matplotlib
        except ImportError:
            self.skipTest("matplotlib is not installed in this interpreter")
        messages = exchange([
            {"id": "t0", "op": "latex", "fontsize": 13, "color": "#000000",
             "tex": r"||x_k - x_{k-1}||_2<\mbox{ tolerance}"},
            {"id": "t1", "op": "latex", "fontsize": 13, "color": "#000000",
             "tex": r"\sqrt{(x_k - x_{k-1})^2+(y_k - y_{k-1})^2}<\mbox{ tolerance}"},
            {"id": "t2", "op": "latex", "fontsize": 13, "color": "#000000",
             "tex": r"\textnormal{tolerance}"},
            {"id": "t3", "op": "latex", "fontsize": 13, "color": "#000000",
             "tex": r"\hbox{tolerance}"},
        ])
        kinds = {m["id"]: m["type"] for m in messages
                 if m.get("id") in ("t0", "t1", "t2", "t3")
                 and m.get("type") in ("latex", "latex_error")}
        for key in ("t0", "t1", "t2", "t3"):
            self.assertEqual(kinds.get(key), "latex", kinds)


if __name__ == "__main__":
    unittest.main()
