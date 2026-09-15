import json
import pathlib
import subprocess
import sys
import unittest

KERNEL = pathlib.Path(__file__).resolve().parents[1] / "Quanta/Resources/quanta_kernel.py"


def exchange(messages):
    wire = "".join(json.dumps(message) + "\n" for message in messages + [{"op": "shutdown"}])
    result = subprocess.run([sys.executable, str(KERNEL)], input=wire, capture_output=True, text=True, timeout=30)
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


class NotebookCompatTests(unittest.TestCase):
    def test_matplotlib_magic_is_ignored(self):
        messages = exchange([
            {"id": "imports", "op": "execute",
             "code": "import math\n%matplotlib inline\nvalue = math.sqrt(4)\n"},
        ])
        done = next(m for m in messages if m.get("id") == "imports" and m.get("type") == "done")
        self.assertEqual(done["status"], "ok")
        self.assertFalse(any(m.get("type") == "error" for m in messages))

        follow = exchange([
            {"id": "magic_only", "op": "execute", "code": "%matplotlib notebook\n"},
            {"id": "config", "op": "execute",
             "code": "%config InlineBackend.figure_format = 'svg'\nx = 3\n"},
        ])
        statuses = {m["id"]: m["status"] for m in follow if m.get("type") == "done"}
        self.assertEqual(statuses["magic_only"], "ok")
        self.assertEqual(statuses["config"], "ok")

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
             "code": "%config InlineBackend.figure_format = 'svg'\nvalue = 'kept'\nprint(value)\n"},
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

    def test_unknown_magic_still_fails(self):
        messages = exchange([
            {"id": "time", "op": "execute", "code": "%time x = 1\n"},
        ])
        errors = [m for m in messages if m.get("type") == "error"]
        self.assertEqual(errors[0]["ename"], "SyntaxError")

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
