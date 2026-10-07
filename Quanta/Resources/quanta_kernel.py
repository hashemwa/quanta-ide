#!/usr/bin/env python3
import ast
import asyncio
import base64
import builtins
import codecs
import codeop
import datetime
import functools
import importlib.machinery
import inspect
import io
import html as html_escape
import importlib
import importlib.util
import json
import linecache
import math
import numbers
import os
import pprint
import re
import reprlib
import selectors
import shlex
import shutil
import signal
import subprocess
import sys
import threading
import time
import tokenize
import traceback
import types
import warnings

os.environ.setdefault("MPLBACKEND", "Agg")

warnings.filterwarnings("ignore", message=".*FigureCanvasAgg is non-interactive.*")
warnings.filterwarnings("ignore", message=".*which is a non-GUI backend.*")

_dark_appearance = False
_adapt_plot_theme = True

ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")
MAX_STREAM_BYTES = 2_000_000
MAX_REPR_CHARS = 20_000
PRETTY_WIDTH = 79

_lock = threading.Lock()
_stream_lock = threading.RLock()
_stream_flush_stop = threading.Event()
_stream_flush_requested = threading.Event()
_active_writer = None
_current_id = None
_stream_budget = MAX_STREAM_BYTES
_exec_count = 0
_interruptible = False
_compiler = codeop.Compile()
_compiler.flags |= ast.PyCF_ALLOW_TOP_LEVEL_AWAIT
_async_loop = None
_display_depth = 0
_result_depth = 0

_DISPLAY_TYPES = frozenset(("result", "display", "dataframe", "plotlyhtml", "rich"))

user_ns = {"__name__": "__main__", "__builtins__": __builtins__}

def _sanitize(s):
    try:
        s.encode("utf-8")
        return s
    except UnicodeEncodeError:
        return s.encode("utf-8", "backslashreplace").decode("utf-8", "replace")

def _clean(s):
    return _sanitize(ANSI_RE.sub("", s))

def _capped(text, limit):
    if len(text) <= limit:
        return text
    return text[:limit] + "\n... [%d chars total]" % len(text)

def _finite(v):
    try:
        f = float(v)
    except Exception:
        return None
    return f if math.isfinite(f) else None

def emit(obj):
    if _current_id is not None and obj.get("id") == _current_id and obj.get("type") != "stream":
        stdout_writer.flush()
        stderr_writer.flush()
    if _current_id is not None and obj.get("id") == _current_id and "mime_bundle" not in obj:
        bundle = _portable_output(obj)
        if bundle:
            obj["mime_bundle"] = bundle
    if obj.get("type") in _DISPLAY_TYPES:
        if _display_depth:
            obj.setdefault("output_type", "display_data")
        elif _result_depth:
            obj.setdefault("output_type", "execute_result")
        elif obj.get("type") == "display":
            obj.setdefault("output_type", "display_data")
        if obj.get("type") == "result":
            obj.setdefault("mime_bundle", {"text/plain": obj["text"]})
    if _capture_stack and obj.get("id") == _current_id and (
            obj.get("type") in _DISPLAY_TYPES or obj.get("type") == "clear_output"):
        _capture_stack[-1].append(obj)
        return
    with _lock:
        sys.__stdout__.write("\n" + json.dumps(obj) + "\n")
        sys.__stdout__.flush()

def _sigint_handler(signum, frame):
    if _interruptible:
        raise KeyboardInterrupt

class StreamWriter(io.TextIOBase):

    def __init__(self, name):
        self.name = name
        self.buf = ""
        self._last_flush = time.monotonic()

    def writable(self):
        return True

    def isatty(self):
        return False

    def write(self, s):
        global _active_writer
        s = str(s)
        if not s:
            return 0
        length = len(s)
        with _stream_lock:
            if _active_writer is not None and _active_writer is not self:
                _active_writer.flush()
            _active_writer = self
            if _stream_budget <= 0:
                return length
            if len(s) > _stream_budget:
                s = s[:_stream_budget]
            if not self.buf:
                self._last_flush = time.monotonic()
                _stream_flush_requested.set()
            self.buf += s
            if len(self.buf) >= 8192 or time.monotonic() - self._last_flush >= 1 / 30:
                self.flush()
        return length

    def flush(self):
        global _stream_budget
        stream_lock = _stream_lock
        if stream_lock is None:
            return
        with stream_lock:
            if not self.buf:
                return

            text = _sanitize(self.buf)
            self.buf = ""
            self._last_flush = time.monotonic()
            if _stream_budget <= 0:
                return
            if len(text) >= _stream_budget:
                text = text[:_stream_budget] + "\n... [output truncated]\n"
                _stream_budget = 0
            else:
                _stream_budget -= len(text)
            emit({"id": _current_id, "type": "stream", "name": self.name, "text": text})

stdout_writer = StreamWriter("stdout")
stderr_writer = StreamWriter("stderr")
sys.stdout = stdout_writer
sys.stderr = stderr_writer

def _flush_streams_periodically():
    while True:
        _stream_flush_requested.wait()
        _stream_flush_requested.clear()
        if _stream_flush_stop.wait(1 / 30):
            return
        stdout_writer.flush()
        stderr_writer.flush()

_input_requests = False
_deferred_messages = []


def _read_protocol_message():
    while True:
        line = _protocol_in.readline()
        if not line:
            return None
        line = line.strip()
        if not line:
            continue
        try:
            message = json.loads(line)
        except Exception:
            continue
        if isinstance(message, dict):
            return message


def _next_protocol_message():
    if _deferred_messages:
        return _deferred_messages.pop(0)
    return _read_protocol_message()


def _request_input(prompt="", password=False):
    if not _input_requests or _current_id is None:
        raise RuntimeError("input() needs a Quanta window to answer it; assign the value in code instead")
    prompt = "" if prompt is None else str(prompt)
    sys.stdout.flush()
    sys.stderr.flush()
    emit({"id": _current_id, "type": "input_request", "prompt": _clean(prompt), "password": bool(password)})
    while True:
        message = _read_protocol_message()
        if message is None:
            raise EOFError("Quanta closed the input request")
        if message.get("op") == "input_reply":
            break
        _deferred_messages.append(message)
    if message.get("interrupt"):
        raise KeyboardInterrupt
    value = str(message.get("value", ""))
    sys.stdout.write(prompt + ("" if password else value) + "\n")
    return value


def _input(prompt=""):
    return _request_input(prompt)


def _getpass(prompt="Password: ", stream=None):
    return _request_input(prompt, password=True)


builtins.input = _input

def _no_exit(code=None):
    raise SystemExit(code)

builtins.exit = _no_exit
builtins.quit = _no_exit

_protocol_in = os.fdopen(os.dup(sys.stdin.fileno()), "r", encoding="utf-8", errors="replace")
_devnull_fd = os.open(os.devnull, os.O_RDONLY)
os.dup2(_devnull_fd, sys.stdin.fileno())
os.close(_devnull_fd)
sys.stdin = io.StringIO()

_short_repr = reprlib.Repr()
_short_repr.maxlevel = 3
_short_repr.maxtuple = 6
_short_repr.maxlist = 6
_short_repr.maxarray = 6
_short_repr.maxdict = 6
_short_repr.maxset = 6
_short_repr.maxfrozenset = 6
_short_repr.maxdeque = 6
_short_repr.maxstring = 80
_short_repr.maxlong = 40
_short_repr.maxother = 80

def _fmt_float(v):
    if v != v:
        return "NaN"
    if v in (float("inf"), float("-inf")):
        return "inf" if v > 0 else "-inf"
    if v == int(v) and abs(v) < 1e16:
        return format(v, ".1f")
    return format(v, ".12g")

def _fmt_cell(v):
    try:
        if v is None:
            return ""

        if isinstance(v, bool):
            return "True" if v else "False"
        if isinstance(v, float):
            return _fmt_float(v)
        if isinstance(v, numbers.Real) and not isinstance(v, numbers.Integral):

            return _fmt_float(float(v))
        if isinstance(v, datetime.datetime):
            s = v.isoformat(sep=" ")
            if s.endswith(" 00:00:00"):
                s = s[:-9]
        else:
            s = str(v)
    except Exception:
        return "<err>"
    if len(s) > 200:
        s = s[:200] + "…"
    return _clean(s.replace("\n", "⏎"))

def dataframe_payload(obj, offset=0, limit=30, name=None, max_cols=150, head_tail=False):
    pd = sys.modules.get("pandas")
    if pd is None:
        return None
    if isinstance(obj, pd.Series):
        obj = obj.to_frame()
    if not isinstance(obj, pd.DataFrame):
        return None
    total_rows = int(obj.shape[0])
    total_cols = int(obj.shape[1])
    offset = max(0, int(offset))
    limit = max(1, int(limit))

    max_cols = max(1, int(max_cols)) if max_cols else total_cols
    cols_truncated = total_cols > max_cols
    view = obj.iloc[:, :max_cols] if cols_truncated else obj

    rows_truncated = False
    head_count = 0
    if head_tail:
        if total_rows > 20:
            windows = [view.iloc[:10], view.iloc[-10:]]
            rows_truncated = True
            head_count = 10
        else:
            windows = [view]
    else:
        windows = [view.iloc[offset : offset + limit]]

    rows = []
    index = []
    original_rows = []
    original_index = []
    copy_budget = 4_000_000
    def original(value):
        nonlocal copy_budget
        try:
            if isinstance(value, str):
                if len(value) > min(1_000_000, copy_budget):
                    return None
                text = value
            else:
                text = str(value)
            size = len(text.encode("utf-8"))
            if size > min(1_000_000, copy_budget):
                return None
            copy_budget -= size
            return text
        except Exception:
            return None
    for window in windows:
        rows.extend([_fmt_cell(v) for v in row]
                    for row in window.itertuples(index=False, name=None))
        index.extend(_fmt_cell(i) for i in window.index)
        original_rows.extend([original(v) for v in row]
                             for row in window.itertuples(index=False, name=None))
        original_index.extend(original(i) for i in window.index)
    preview = windows[0].head(10)
    try:
        text = preview.to_string(max_cols=12)
    except Exception:
        text = repr(preview)
    shown_rows = int(getattr(preview, "shape", (0,))[0])
    if total_rows > shown_rows or cols_truncated or total_cols > 12:
        text += "\n\n[%d rows x %d columns — preview shows the first %d]" % (
            total_rows, total_cols, shown_rows)
    return {
        "name": name,
        "columns": [_clean(str(c)) for c in view.columns],
        "dtypes": [str(t) for t in view.dtypes],
        "index": index,
        "rows": rows,
        "offset": offset,
        "total_rows": total_rows,
        "total_cols": total_cols,
        "cols_truncated": cols_truncated,
        "rows_truncated": rows_truncated,
        "head_count": head_count,
        "original_rows": original_rows,
        "original_index": original_index,
        "text": _clean(text),
    }

def _is_default_white(color):
    try:
        from matplotlib.colors import to_rgba
        r, g, b, a = to_rgba(color)
        return r > 0.92 and g > 0.92 and b > 0.92 and a > 0.99
    except Exception:
        return False

def _relative_luminance(rgba):
    channels = [c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4
                for c in rgba[:3]]
    return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]

def _readable_on(rgba):
    return "#1D1D1F" if _relative_luminance(rgba) > 0.179 else "#E8E8E8"

def _text_backdrop(ax, text):
    try:
        point = text.get_transform().transform(text.get_position())
    except Exception:
        return None
    for patch in reversed(ax.patches):
        try:
            if not patch.get_visible():
                continue
            rgba = patch.get_facecolor()
            if rgba[3] < 0.9 or not patch.contains_point(point):
                continue
            return rgba
        except Exception:
            continue
    return None

def _keeps_default_color(text):
    try:
        from matplotlib import rcParams
        from matplotlib.colors import to_rgba
        return to_rgba(text.get_color()) == to_rgba(rcParams["text.color"])
    except Exception:
        return False

def _restore_figure(restores):
    for setter, value in reversed(restores or ()):
        try:
            setter(value)
        except Exception:
            pass

def _record_tick_colors(ax, restores):
    for axis in (ax.xaxis, ax.yaxis):
        try:
            ticks = list(axis.get_major_ticks()) + list(axis.get_minor_ticks())
        except Exception:
            continue
        for tick in ticks:
            for artist in (getattr(tick, "tick1line", None), getattr(tick, "tick2line", None),
                           getattr(tick, "label1", None), getattr(tick, "label2", None)):
                if artist is None:
                    continue
                try:
                    restores.append((artist.set_color, artist.get_color()))
                except Exception:
                    pass

def _style_figure(fig):
    if not _adapt_plot_theme or not _is_default_white(fig.get_facecolor()):
        return None
    fg = _appearance_fg()
    restores = []

    def recolor(artist, color):
        try:
            restores.append((artist.set_color, artist.get_color()))
        except Exception:
            return
        artist.set_color(color)

    for text in fig.texts:
        recolor(text, fg)
    for ax in fig.get_axes():
        for spine in ax.spines.values():
            try:
                restores.append((spine.set_color, spine.get_edgecolor()))
            except Exception:
                pass
            spine.set_color(fg)
        _record_tick_colors(ax, restores)
        ax.tick_params(colors=fg, which="both")
        recolor(ax.xaxis.label, fg)
        recolor(ax.yaxis.label, fg)
        recolor(ax.title, fg)
        legend = ax.get_legend()
        if legend is not None:
            for t in legend.get_texts():
                recolor(t, fg)
            try:
                frame = legend.get_frame()
                restores.append((frame.set_alpha, frame.get_alpha()))
                frame.set_alpha(0.15)
            except Exception:
                pass
        for text in ax.texts:
            if not _keeps_default_color(text):
                continue
            backdrop = _text_backdrop(ax, text)
            recolor(text, _readable_on(backdrop) if backdrop is not None else fg)
    return restores

def _emit_figure(fig):
    try:
        restores = _style_figure(fig)
    except Exception:
        restores = None
    buf = io.BytesIO()
    try:
        if not _adapt_plot_theme:
            fig.savefig(buf, format="png", dpi=144, bbox_inches="tight")
        elif restores is not None:
            fig.savefig(buf, format="png", dpi=144, bbox_inches="tight",
                        transparent=True)
        else:
            fig.savefig(buf, format="png", dpi=144, bbox_inches="tight",
                        facecolor=fig.get_facecolor())
    finally:
        _restore_figure(restores)
    emit({
        "id": _current_id,
        "type": "display",
        "output_type": "display_data",
        "mime": "image/png",
        "data": base64.b64encode(buf.getvalue()).decode(),
    })

def emit_figures():
    if "matplotlib" not in sys.modules:
        return
    try:
        import matplotlib.pyplot as plt
    except Exception:
        return
    try:
        nums = plt.get_fignums()
    except Exception:
        return
    for num in nums:
        try:
            fig = plt.figure(num)
            if not fig.get_axes():
                continue
            _emit_figure(fig)
        except Exception:
            continue
    try:
        plt.close("all")
    except Exception:
        pass

def _flush_figures_on_show(pyplot):
    original = pyplot.show

    @functools.wraps(original)
    def show(*args, **kwargs):
        if _current_id is None:
            return original(*args, **kwargs)
        stdout_writer.flush()
        stderr_writer.flush()
        emit_figures()

    pyplot.show = show


class _PyplotShowHook:
    def find_spec(self, fullname, path=None, target=None):
        if fullname != "matplotlib.pyplot":
            return None
        spec = importlib.machinery.PathFinder.find_spec(fullname, path)
        if spec is None or not hasattr(spec.loader, "exec_module"):
            return None
        load = spec.loader.exec_module

        def exec_module(module):
            load(module)
            _flush_figures_on_show(module)

        spec.loader.exec_module = exec_module
        return spec


sys.meta_path.insert(0, _PyplotShowHook())

try:
    import getpass as _getpass_module
    _getpass_module.getpass = _getpass
except Exception:
    pass

def _is_matplotlib_result(obj):
    if "matplotlib" not in sys.modules:
        return False
    try:
        from matplotlib.artist import Artist
        from matplotlib.figure import Figure
    except Exception:
        return False
    if isinstance(obj, (Artist, Figure)):
        return True
    if isinstance(obj, (list, tuple)) and obj and all(isinstance(o, Artist) for o in obj):
        return True
    return False

def _display_matplotlib(obj):
    from matplotlib.figure import Figure
    import matplotlib.pyplot as plt

    figures = []
    for artist in obj if isinstance(obj, (list, tuple)) else (obj,):
        figure = artist if isinstance(artist, Figure) else artist.get_figure()
        if figure is not None and not any(figure is other for other in figures):
            figures.append(figure)
    for figure in figures:
        _emit_figure(figure)
        plt.close(figure)

def _try_plotly(obj):
    module = getattr(type(obj), "__module__", "") or ""
    if module.split(".")[0] != "plotly" or not hasattr(obj, "to_image"):
        return False
    try:
        import plotly
        import plotly.graph_objects as go
        import plotly.io as pio
    except Exception:
        return False
    fig = go.Figure(obj)
    if _adapt_plot_theme and _dark_appearance:
        fig.update_layout(template="plotly_dark",
                          paper_bgcolor="rgba(0,0,0,0)",
                          plot_bgcolor="rgba(0,0,0,0)")
    elif _adapt_plot_theme:
        fig.update_layout(paper_bgcolor="rgba(0,0,0,0)")

    png = None
    try:
        png = fig.to_image(format="png", scale=2)
    except Exception:
        png = None
    if png is not None:
        emit({"id": _current_id, "type": "display", "mime": "image/png",
              "data": base64.b64encode(png).decode()})

    js_path = os.path.join(os.path.dirname(plotly.__file__), "package_data", "plotly.min.js")
    html_fig = fig
    try:

        points = sum(len(tr.x) if tr.x is not None else 0
                     for tr in fig.data if tr.type == "scatter")
        if points > 1000:
            html_fig = go.Figure(
                [go.Scattergl({k: v for k, v in tr.to_plotly_json().items() if k != "type"})
                 if tr.type == "scatter" else tr
                 for tr in fig.data],
                layout=fig.layout)
    except Exception:
        html_fig = fig
    try:

        html = pio.to_html(html_fig, full_html=False, include_plotlyjs=False,
                           config={"responsive": True, "displaylogo": False,
                                   "displayModeBar": False, "scrollZoom": True})
    except Exception:
        return True
    emit({"id": _current_id, "type": "plotlyhtml",
          "html": html, "js_path": js_path,
          "height": float(_finite(fig.layout.height) or 450.0),
          "has_png": png is not None,
          "mime_bundle": dict({"application/vnd.plotly.v1+json": json.loads(fig.to_json()),
                               "text/plain": "Plotly figure"},
                              **({"image/png": base64.b64encode(png).decode()} if png else {}))})
    return True

def _try_rich_repr(obj):
    bundle = {}
    metadata = {}
    method = getattr(obj, "_repr_mimebundle_", None)
    if callable(method):
        try:
            result = method()
            if isinstance(result, tuple):
                result, metadata = result
            if isinstance(result, dict):
                bundle.update(result)
        except Exception:
            pass
    for name, mime in [("_repr_html_", "text/html"), ("_repr_svg_", "image/svg+xml"),
                       ("_repr_png_", "image/png"), ("_repr_jpeg_", "image/jpeg"),
                       ("_repr_json_", "application/json"), ("_repr_latex_", "text/latex"),
                       ("_repr_markdown_", "text/markdown")]:
        if mime in bundle:
            continue
        method = getattr(obj, name, None)
        if not callable(method):
            continue
        try:
            value = method()
            if isinstance(value, tuple):
                value, details = value
                if isinstance(details, dict):
                    metadata[mime] = details
            if isinstance(value, (bytes, bytearray)):
                value = base64.b64encode(value).decode() if mime.startswith("image/") and mime != "image/svg+xml" else value.decode("utf-8")
            if value is not None:
                json.dumps(value, allow_nan=False)
                bundle[mime] = value
        except Exception:
            pass
    if bundle:
        normalized = {}
        for mime, value in bundle.items():
            if not isinstance(mime, str):
                continue
            try:
                if isinstance(value, (bytes, bytearray)):
                    value = base64.b64encode(value).decode() if mime in ("image/png", "image/jpeg") else value.decode("utf-8")
                json.dumps(value, allow_nan=False)
                normalized[mime] = value
            except Exception:
                continue
        bundle = normalized
    if bundle:
        try:
            bundle.setdefault("text/plain", _capped(_clean(repr(obj)), MAX_REPR_CHARS))
            json.dumps([bundle, metadata], allow_nan=False)
            emit({"id": _current_id, "type": "rich", "mime_bundle": bundle,
                  "metadata": metadata if isinstance(metadata, dict) else {}})
            return True
        except Exception:
            pass
    return False

def _portable_output(message):
    kind = message.get("type")
    payload = message.get("payload", {})
    if kind == "display" and message.get("mime") == "image/png":
        return {"image/png": message["data"]}
    if kind == "dataframe":
        escape = lambda value: html_escape.escape(str(value))
        headers = "".join("<th>" + escape(c) + "</th>" for c in ["Index"] + payload["columns"])
        rows = []
        for i, row in enumerate(payload["rows"]):
            index = payload.get("index", [])
            label = index[i] if i < len(index) else i
            rows.append("<tr>" + "".join("<td>" + escape(v) + "</td>" for v in [label] + row) + "</tr>")
        caption = "Display preview: %s of %s rows, %s of %s columns" % (len(payload["rows"]), payload["total_rows"], len(payload["columns"]), payload["total_cols"])
        html = "<table><caption>" + caption + "</caption><thead><tr>" + headers + "</tr></thead><tbody>" + "".join(rows) + "</tbody></table>"
        return {"text/plain": payload["text"], "text/html": html,
                "application/vnd.quanta.dataframe+json": payload}
    return None

def _emit_result(obj, name_hint, explicit=False):
    payload = dataframe_payload(obj, name=name_hint, max_cols=40, head_tail=True)
    if payload is not None:
        emit({"id": _current_id, "type": "dataframe", "payload": payload})
        return
    if _is_matplotlib_result(obj):
        if explicit:
            _display_matplotlib(obj)
        return
    if _try_plotly(obj):
        return
    if _try_rich_repr(obj):
        return
    _emit_plain_result(obj)

def _plain_text(obj):
    if _float_format is not None and isinstance(obj, float):
        return _float_format % obj
    text = repr(obj)
    if isinstance(obj, (dict, list, tuple, set, frozenset)) and PRETTY_WIDTH < len(text) <= MAX_REPR_CHARS:
        try:
            return pprint.pformat(obj, width=PRETTY_WIDTH, sort_dicts=False)
        except Exception:
            return text
    return text

def _emit_plain_result(obj):
    try:
        r = _plain_text(obj)
    except Exception as e:
        r = "<repr failed: %s>" % e
    r = _clean(r)
    r = _capped(r, MAX_REPR_CHARS)
    emit({"id": _current_id, "type": "result", "text": r})

def emit_result(obj, name_hint, explicit=False):
    global _result_depth
    _result_depth += 1
    try:
        _emit_result(obj, name_hint, explicit=explicit)
    finally:
        _result_depth -= 1

def display(*objects):
    global _display_depth
    _display_depth += 1
    try:
        for obj in objects:
            name = next((name for name, value in list(user_ns.items())
                         if isinstance(name, str) and not name.startswith("_")
                         and value is obj), None)
            emit_result(obj, name, explicit=True)
    finally:
        _display_depth -= 1

def clear_output(wait=False):
    emit({"id": _current_id, "type": "clear_output", "wait": bool(wait)})

def _error_report(e):
    try:
        ename = type(e).__name__
    except Exception:
        ename = "Exception"
    try:
        evalue = _clean(str(e))
    except Exception:
        evalue = "<error message could not be rendered>"
    try:
        tb = _user_traceback(e)
    except Exception:
        tb = ""
    try:
        frames = _traceback_frames(e)
    except Exception:
        frames = []
    return {"ename": ename, "evalue": evalue, "traceback": tb, "frames": frames}

def _user_traceback(e):
    if isinstance(e, UsageError):
        return _clean("UsageError: %s\n" % e)
    this = os.path.abspath(__file__)
    report = traceback.TracebackException(type(e), e, e.__traceback__)
    pending = [report]
    seen = set()
    while pending:
        current = pending.pop()
        if id(current) in seen:
            continue
        seen.add(id(current))
        current.stack = traceback.StackSummary.from_list(
            [frame for frame in current.stack if os.path.abspath(frame.filename) != this])
        pending.extend(item for item in (current.__cause__, current.__context__) if item is not None)
    return _clean("".join(report.format()))

def _traceback_frames(e):
    frames = []
    tb = e.__traceback__
    this = os.path.abspath(__file__)
    while tb is not None and len(frames) < 40:
        code_obj = tb.tb_frame.f_code
        fname = code_obj.co_filename
        if os.path.abspath(fname) != this:
            line_text = linecache.getline(fname, tb.tb_lineno)
            is_user = "site-packages" not in fname and "lib/python" not in fname
            frames.append({
                "file": _clean(fname),
                "line": int(tb.tb_lineno),
                "func": _clean(code_obj.co_name),
                "code": _clean(line_text.strip())[:200],
                "is_user": bool(is_user),
            })
        tb = tb.tb_next
    return frames

_INLINE_MATPLOTLIB = re.compile(r"^[ \t]*%matplotlib[ \t]+inline[ \t]*(?:#[^\r\n]*)?[\r\n]*$")


class UnsupportedNotebookCommand(SyntaxError):
    pass


_STRING_TOKENS = frozenset(
    getattr(tokenize, name) for name in (
        "STRING", "FSTRING_START", "FSTRING_MIDDLE", "FSTRING_END",
        "TSTRING_START", "TSTRING_MIDDLE", "TSTRING_END",
    ) if hasattr(tokenize, name)
)


def _rows_inside_multiline_strings(code):
    rows = set()
    try:
        for token in tokenize.generate_tokens(io.StringIO(code).readline):
            if token.type in _STRING_TOKENS and token.end[0] > token.start[0]:
                rows.update(range(token.start[0] + 1, token.end[0] + 1))
    except (tokenize.TokenError, IndentationError, SyntaxError):
        pass
    return rows


def _parse_notebook_code(code, filename):
    lines = code.splitlines(True)
    protected = _rows_inside_multiline_strings(code)
    for i, line in enumerate(lines):
        if i + 1 not in protected and _INLINE_MATPLOTLIB.fullmatch(line):
            lines[i] = "\n" if line.endswith("\n") else ""
    source = "".join(lines)
    flags = ast.PyCF_ONLY_AST | _compiler.flags
    try:
        return compile(source, filename, "exec", flags=flags, dont_inherit=True), source
    except SyntaxError:
        transformed = _transform_ipython(source, filename)
        if transformed is None:
            raise
    return compile(transformed, filename, "exec", flags=flags, dont_inherit=True), transformed


def _suppresses_result(code):
    ignored = {tokenize.NL, tokenize.NEWLINE, tokenize.COMMENT,
               tokenize.INDENT, tokenize.DEDENT, tokenize.ENDMARKER}
    last = None
    for token in tokenize.generate_tokens(io.StringIO(code).readline):
        if token.type not in ignored:
            last = token
    return last is not None and last.type == tokenize.OP and last.string == ";"


def _cancel_async_tasks(loop):
    tasks = asyncio.all_tasks(loop)
    for task in tasks:
        task.cancel()
    if tasks:
        try:
            loop.run_until_complete(asyncio.wait(tasks, timeout=0.5))
        except BaseException:
            pass
    for task in tasks:
        if task.done() and not task.cancelled():
            try:
                task.exception()
            except BaseException:
                pass
    pending = {task for task in tasks if not task.done()}
    if pending:
        stderr_writer.write("Some asynchronous tasks did not stop after cancellation. Restart the kernel to stop them.\n")
    return pending


async def _evaluate_async_cell(compiled, compiled_expr):
    if compiled is not None:
        value = eval(compiled, user_ns)
        if compiled.co_flags & inspect.CO_COROUTINE:
            await value
    if compiled_expr is not None:
        value = eval(compiled_expr, user_ns)
        if compiled_expr.co_flags & inspect.CO_COROUTINE:
            return await value
        return value
    return None


def _evaluate_cell(compiled, compiled_expr):
    global _async_loop, _interruptible
    asynchronous = any(code is not None and code.co_flags & inspect.CO_COROUTINE
                       for code in (compiled, compiled_expr))
    if not asynchronous:
        if compiled is not None:
            exec(compiled, user_ns)
        return eval(compiled_expr, user_ns) if compiled_expr is not None else None
    if _async_loop is None or _async_loop.is_closed():
        _async_loop = asyncio.new_event_loop()
    asyncio.set_event_loop(_async_loop)
    coroutine = _evaluate_async_cell(compiled, compiled_expr)
    try:
        task = _async_loop.create_task(coroutine)
    except BaseException:
        coroutine.close()
        raise
    try:
        return _async_loop.run_until_complete(task)
    except BaseException:
        _interruptible = False
        _cancel_async_tasks(_async_loop)
        if task.done() and not task.cancelled():
            task.exception()
        raise


def _shutdown_async_loop():
    global _async_loop
    loop = _async_loop
    _async_loop = None
    if loop is None or loop.is_closed():
        return
    try:
        _cancel_async_tasks(loop)
        cleanup = loop.create_task(loop.shutdown_asyncgens())
        loop.run_until_complete(asyncio.wait({cleanup}, timeout=0.5))
        if not cleanup.done():
            _cancel_async_tasks(loop)
        elif not cleanup.cancelled():
            cleanup.exception()
    except BaseException:
        pass
    finally:
        loop.close()
        asyncio.set_event_loop(None)


class UsageError(Exception):
    pass


class SList(list):
    @property
    def s(self):
        return " ".join(self)

    @property
    def n(self):
        return "\n".join(self)

    @property
    def l(self):
        return list(self)

    def grep(self, pattern, prune=False):
        match = re.compile(pattern, re.IGNORECASE).search if isinstance(pattern, str) else pattern
        return SList(item for item in self if bool(match(item)) != bool(prune))

    def fields(self, *indices):
        rows = [line.split() for line in self]
        if not indices:
            return SList(" ".join(row) for row in rows)
        return SList(" ".join(row[i] for i in indices if -len(row) <= i < len(row)) for row in rows)


class CapturedIO:
    def __init__(self, stdout, stderr, outputs):
        self.stdout = stdout
        self.stderr = stderr
        self.outputs = outputs

    def show(self):
        if self.stdout:
            sys.stdout.write(self.stdout)
        if self.stderr:
            sys.stderr.write(self.stderr)
        for output in self.outputs:
            replay = dict(output)
            replay["id"] = _current_id
            emit(replay)

    __call__ = show


class TimeitResult:
    def __init__(self, loops, repeat, best, worst, all_runs, precision):
        self.loops = loops
        self.repeat = repeat
        self.best = best
        self.worst = worst
        self.all_runs = all_runs
        self.timings = [run / loops for run in all_runs]
        self.average = sum(self.timings) / len(self.timings)
        self.stdev = (sum((t - self.average) ** 2 for t in self.timings) / len(self.timings)) ** 0.5
        self._precision = precision

    def __str__(self):
        runs = "s" if self.repeat != 1 else ""
        loops = "s" if self.loops != 1 else ""
        return "%s ± %s per loop (mean ± std. dev. of %d run%s, %s loop%s each)" % (
            _format_time(self.average, self._precision), _format_time(self.stdev, self._precision),
            self.repeat, runs, "{:,}".format(self.loops), loops)

    def __repr__(self):
        return "<TimeitResult : %s>" % self


_line_magics = {}
_cell_magics = {}
_cell_body_offset = 0
_current_filename = None
_previous_directory = None
_notebook_directories = {}
_float_format = None
_capture_stack = []
_autoreload_mode = 0
_autoreload_explicit = set()
_autoreload_skipped = set()
_module_mtimes = {}
_UNSUPPORTED_MATPLOTLIB = frozenset(("notebook", "widget", "ipympl", "qt", "qt5", "qt6", "tk",
                                     "osx", "macosx", "gtk", "gtk3", "gtk4", "wx", "nbagg"))


def _line_magic(*names):
    def register(function):
        for name in names:
            _line_magics[name] = function
        return function
    return register


def _cell_magic(*names):
    def register(function):
        for name in names:
            _cell_magics[name] = function
        return function
    return register


def _namespaces(frame):
    if frame is None:
        return user_ns, user_ns
    return frame.f_globals, frame.f_locals


def _at_top_level(frame):
    return frame is None or (frame.f_globals is user_ns and frame.f_code.co_name == "<module>")


_EXPANSION = re.compile(r"\$\$|\{\{|\}\}|\$([A-Za-z_]\w*)|\{([^{}]+)\}")


def _expand(text, frame):
    globals_ns, locals_ns = _namespaces(frame)

    def replace(match):
        token = match.group(0)
        if token == "$$":
            return "$"
        if token == "{{":
            return "{"
        if token == "}}":
            return "}"
        try:
            return str(eval(match.group(1) or match.group(2), globals_ns, locals_ns))
        except Exception:
            return token

    return _EXPANSION.sub(replace, text)


def _format_time(seconds, precision=3):
    if seconds >= 60:
        minutes, remainder = divmod(seconds, 60)
        hours, minutes = divmod(minutes, 60)
        parts = [("%d%s" % (value, unit)) for value, unit in
                 ((hours, "h"), (minutes, "min"), (round(remainder), "s")) if int(value)]
        return " ".join(parts) or "0s"
    units = ["s", "ms", "µs", "ns"]
    scaling = [1, 1e3, 1e6, 1e9]
    order = min(-int(math.floor(math.log10(seconds)) // 3), 3) if seconds > 0 else 3
    return "%.*g %s" % (precision, seconds * scaling[order], units[order])


def _process_environment():
    environment = dict(os.environ)
    environment.setdefault("PAGER", "cat")
    environment.setdefault("GIT_PAGER", "cat")
    interpreter_directory = os.path.dirname(sys.executable)
    path = environment.get("PATH", "")
    if interpreter_directory and interpreter_directory not in path.split(os.pathsep):
        environment["PATH"] = interpreter_directory + (os.pathsep + path if path else "")
    return environment


def _stop_process(process):
    for signal_number, wait in ((signal.SIGINT, 1.0), (signal.SIGTERM, 1.0), (signal.SIGKILL, None)):
        if process.poll() is not None:
            return
        try:
            os.killpg(process.pid, signal_number)
        except (ProcessLookupError, PermissionError):
            return
        if wait is not None:
            try:
                process.wait(wait)
            except subprocess.TimeoutExpired:
                continue
    try:
        process.wait(1)
    except subprocess.TimeoutExpired:
        pass


def _feed_input(pipe, text):
    try:
        pipe.write(text.encode("utf-8"))
    except (BrokenPipeError, OSError):
        pass
    finally:
        try:
            pipe.close()
        except OSError:
            pass


def _run_process(arguments, shell=False, merge=True, input_text=None, capture=False):
    sys.stdout.flush()
    sys.stderr.flush()
    process = subprocess.Popen(
        arguments, shell=shell,
        stdin=subprocess.PIPE if input_text is not None else subprocess.DEVNULL,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT if merge else subprocess.PIPE,
        cwd=execution_directory(), env=_process_environment(), start_new_session=True)
    if input_text is not None:
        threading.Thread(target=_feed_input, args=(process.stdin, input_text), daemon=True).start()
    captured = []
    targets = {process.stdout: sys.stdout}
    if not merge:
        targets[process.stderr] = sys.stderr
    decoders = {pipe: codecs.getincrementaldecoder("utf-8")("replace") for pipe in targets}
    selector = selectors.DefaultSelector()
    try:
        for pipe in targets:
            selector.register(pipe, selectors.EVENT_READ)
        while selector.get_map():
            for key, _ in selector.select():
                chunk = os.read(key.fd, 65536)
                if chunk:
                    text = decoders[key.fileobj].decode(chunk)
                else:
                    selector.unregister(key.fileobj)
                    text = decoders[key.fileobj].decode(b"", final=True)
                if not text:
                    continue
                if capture:
                    captured.append(text)
                else:
                    targets[key.fileobj].write(text)
        code = process.wait()
    except BaseException:
        _stop_process(process)
        raise
    finally:
        selector.close()
        for pipe in targets:
            try:
                pipe.close()
            except OSError:
                pass
    user_ns["_exit_code"] = code
    return ("".join(captured), code) if capture else code


def _system(command):
    _run_process(command, shell=True)


def _getoutput(command):
    text, _ = _run_process(command, shell=True, capture=True)
    return SList(text.splitlines())


def _compile_block(source, offset=0, filename=None):
    name = filename or _current_filename or "<magic>"
    padded = "\n" * offset + source
    if filename is not None:
        linecache.cache[filename] = (len(padded), None, padded.splitlines(True), filename)
    tree, prepared = _parse_notebook_code(padded, name)
    last_expr = None
    if tree.body and isinstance(tree.body[-1], ast.Expr) and not _suppresses_result(prepared):
        last_expr = ast.Expression(tree.body.pop().value)
        ast.fix_missing_locations(last_expr)
    compiled = _compiler(tree, name, "exec") if tree.body else None
    compiled_expr = _compiler(last_expr, name, "eval") if last_expr is not None else None
    return compiled, compiled_expr


def _evaluate_block(compiled, compiled_expr, frame):
    if _at_top_level(frame):
        return _evaluate_cell(compiled, compiled_expr)
    globals_ns, locals_ns = _namespaces(frame)
    if compiled is not None:
        exec(compiled, globals_ns, locals_ns)
    return eval(compiled_expr, globals_ns, locals_ns) if compiled_expr is not None else None


def _magic_source(line, cell):
    if cell is not None:
        return _compile_block(cell, _cell_body_offset)
    return _compile_block(line, 0, "<timed exec>")


@_line_magic("time")
def _magic_time(line, frame, cell=None):
    compiled, compiled_expr = _magic_source(line, cell)
    start = os.times()
    wall = time.perf_counter()
    result = _evaluate_block(compiled, compiled_expr, frame)
    wall = time.perf_counter() - wall
    end = os.times()
    user = end.user - start.user
    system = end.system - start.system
    sys.stdout.write("CPU times: user %s, sys: %s, total: %s\nWall time: %s\n" % (
        _format_time(user), _format_time(system), _format_time(user + system), _format_time(wall)))
    return result


_cell_magics["time"] = lambda line, cell, frame: _magic_time(line, frame, cell)


_TIMEIT_OPTION = re.compile(r"\s*-(?:([nrp])\s*(\d+)|([qo]))(?=\s|$)")


def _timeit_options(line):
    options = {}
    position = 0
    while True:
        match = _TIMEIT_OPTION.match(line, position)
        if match is None:
            break
        if match.group(1):
            options[match.group(1)] = int(match.group(2))
        else:
            options[match.group(3)] = True
        position = match.end()
    return options, line[position:].strip()


@_line_magic("timeit")
def _magic_timeit(line, frame, cell=None):
    import timeit
    options, rest = _timeit_options(line)
    statement, setup = (cell, rest or "pass") if cell is not None else (rest, "pass")
    if not statement.strip():
        raise UsageError("%timeit needs a statement to time")
    globals_ns, locals_ns = _namespaces(frame)
    namespace = globals_ns if locals_ns is globals_ns else dict(globals_ns, **dict(locals_ns))
    timer = timeit.Timer(statement, setup, timer=time.perf_counter, globals=namespace)
    repeat = max(1, options.get("r", 7))
    precision = max(1, options.get("p", 3))
    number = options.get("n", 0)
    if number <= 0:
        for exponent in range(10):
            number = 10 ** exponent
            if timer.timeit(number) >= 0.2:
                break
    runs = timer.repeat(repeat, number)
    result = TimeitResult(number, repeat, min(runs) / number, max(runs) / number, runs, precision)
    if not options.get("q"):
        sys.stdout.write(str(result) + "\n")
    return result if options.get("o") else None


_cell_magics["timeit"] = lambda line, cell, frame: _magic_timeit(line, frame, cell)


@_line_magic("prun")
def _magic_prun(line, frame, cell=None):
    import cProfile
    import pstats
    sort = "tottime"
    limit = 30
    quiet = False
    returns_stats = False
    tokens = line.split()
    rest = []
    index = 0
    while index < len(tokens):
        token = tokens[index]
        if token in ("-s", "-l") and index + 1 < len(tokens):
            if token == "-s":
                sort = tokens[index + 1]
            elif tokens[index + 1].isdigit():
                limit = int(tokens[index + 1])
            index += 2
            continue
        if token in ("-q", "-r"):
            quiet = quiet or token == "-q"
            returns_stats = returns_stats or token == "-r"
            index += 1
            continue
        rest = tokens[index:]
        break
    source = cell if cell is not None else line[line.find(rest[0]):] if rest else ""
    if not source.strip():
        raise UsageError("%prun needs a statement to profile")
    if cell is not None:
        compiled, compiled_expr = _compile_block(cell, _cell_body_offset)
    else:
        compiled, compiled_expr = _compile_block(source, 0, "<profiled exec>")
    globals_ns, locals_ns = _namespaces(frame)
    profiler = cProfile.Profile()
    profiler.enable()
    try:
        if compiled is not None:
            exec(compiled, globals_ns, locals_ns)
        if compiled_expr is not None:
            eval(compiled_expr, globals_ns, locals_ns)
    finally:
        profiler.disable()
    stats = pstats.Stats(profiler, stream=sys.stdout)
    stats.sort_stats({"time": "tottime", "cumulative": "cumtime"}.get(sort, sort))
    if not quiet:
        stats.print_stats(limit)
    return stats if returns_stats else None


_cell_magics["prun"] = lambda line, cell, frame: _magic_prun(line, frame, cell)


def _install_note(arguments):
    if arguments and arguments[0] in ("install", "uninstall", "remove", "update", "upgrade"):
        importlib.invalidate_caches()
        sys.stdout.write("Note: you may need to restart the kernel to use updated packages.\n")


@_line_magic("pip")
def _magic_pip(line, frame):
    arguments = shlex.split(_expand(line, frame))
    if arguments and arguments[0] == "uninstall" and not {"-y", "--yes"} & set(arguments):
        arguments.insert(1, "--yes")
    _run_process([sys.executable, "-m", "pip"] + arguments)
    _install_note(arguments)


def _conda_executable():
    for variable in ("CONDA_EXE", "MAMBA_EXE"):
        candidate = os.environ.get(variable)
        if candidate and os.path.exists(candidate):
            return candidate
    roots = [sys.prefix, os.path.dirname(os.path.dirname(sys.prefix))]
    for root in roots:
        for relative in ("bin/mamba", "bin/conda", "condabin/conda"):
            candidate = os.path.join(root, relative)
            if os.path.exists(candidate):
                return candidate
    return shutil.which("mamba") or shutil.which("conda")


@_line_magic("conda", "mamba")
def _magic_conda(line, frame):
    executable = _conda_executable()
    if executable is None:
        raise UsageError("conda was not found for this interpreter. Use %pip or the Python Environment window.")
    arguments = shlex.split(_expand(line, frame))
    if arguments and arguments[0] in ("install", "remove", "uninstall", "update", "upgrade"):
        if not {"-p", "--prefix", "-n", "--name"} & set(arguments):
            arguments[1:1] = ["--prefix", sys.prefix]
        if not {"-y", "--yes"} & set(arguments):
            arguments.insert(1, "--yes")
    _run_process([executable] + arguments)
    _install_note(arguments)


@_line_magic("cd")
def _magic_cd(line, frame):
    global _previous_directory
    text = _expand(line, frame).strip()
    quiet = False
    if text == "-q" or text.startswith("-q "):
        quiet = True
        text = text[2:].strip()
    if not text:
        target = os.path.expanduser("~")
    elif text == "-":
        if _previous_directory is None:
            raise UsageError("cd -: no previous directory")
        target = _previous_directory
    else:
        parts = shlex.split(text)
        target = os.path.expanduser(parts[0] if parts else text)
    current = execution_directory()
    os.chdir(target)
    _previous_directory = current
    if not quiet:
        sys.stdout.write(os.getcwd() + "\n")


@_line_magic("pwd")
def _magic_pwd(line, frame):
    return os.getcwd()


def _alias(command):
    def run(line, frame):
        expanded = _expand(line, frame).strip()
        _system(command + (" " + expanded if expanded else ""))
    return run


for _alias_name, _alias_command in (("ls", "ls"), ("ll", "ls -F -l"), ("cat", "cat"), ("cp", "cp"),
                                    ("mv", "mv"), ("rm", "rm"), ("rmdir", "rmdir"), ("mkdir", "mkdir")):
    _line_magics[_alias_name] = _alias(_alias_command)


@_line_magic("sx", "system")
def _magic_sx(line, frame):
    return _getoutput(_expand(line, frame))


@_line_magic("env")
def _magic_env(line, frame):
    text = _expand(line, frame).strip()
    if not text:
        return dict(os.environ)
    if "=" in text:
        name, value = text.split("=", 1)
    elif " " in text:
        name, value = text.split(None, 1)
    else:
        if text not in os.environ:
            raise UsageError("Environment does not have key: %s" % text)
        return os.environ[text]
    name = name.strip()
    value = value.strip()
    os.environ[name] = value
    sys.stdout.write("env: %s=%s\n" % (name, value))


@_line_magic("set_env")
def _magic_set_env(line, frame):
    parts = _expand(line, frame).strip().replace("=", " ", 1).split(None, 1)
    if len(parts) != 2:
        raise UsageError("Usage: %set_env NAME VALUE")
    os.environ[parts[0]] = parts[1]
    sys.stdout.write("env: %s=%s\n" % (parts[0], parts[1]))


def _is_helper(name, value):
    return _helpers.get(name, _helpers) is value


def _interactive_names(type_names=()):
    names = []
    for name, value in list(user_ns.items()):
        if not isinstance(name, str) or name.startswith("_") or name in ("In", "Out") or _is_helper(name, value):
            continue
        if type_names and type(value).__name__ not in type_names:
            continue
        names.append(name)
    return sorted(names, key=str.lower)


@_line_magic("who")
def _magic_who(line, frame):
    names = _interactive_names(tuple(line.split()))
    if not names:
        sys.stdout.write("Interactive namespace is empty.\n")
        return
    sys.stdout.write("\t".join(names) + "\n")


@_line_magic("who_ls")
def _magic_who_ls(line, frame):
    return _interactive_names(tuple(line.split()))


@_line_magic("whos")
def _magic_whos(line, frame):
    names = _interactive_names(tuple(line.split()))
    if not names:
        sys.stdout.write("Interactive namespace is empty.\n")
        return
    rows = [(name, type(user_ns[name]).__name__, safe_repr(user_ns[name], limit=60, short=True)) for name in names]
    name_width = max(len("Variable"), *(len(row[0]) for row in rows)) + 3
    type_width = max(len("Type"), *(len(row[1]) for row in rows)) + 3
    lines = ["Variable".ljust(name_width) + "Type".ljust(type_width) + "Data/Info",
             "-" * (name_width + type_width + 9)]
    lines.extend(name.ljust(name_width) + kind.ljust(type_width) + info for name, kind, info in rows)
    sys.stdout.write("\n".join(lines) + "\n")


def _clear_namespace(matches):
    for name in list(user_ns):
        if not isinstance(name, str) or name in ("__name__", "__builtins__"):
            continue
        if _is_helper(name, user_ns[name]) or not matches(name):
            continue
        del user_ns[name]


@_line_magic("reset")
def _magic_reset(line, frame):
    if "-f" not in line.split():
        raise UsageError("Quanta cannot ask for confirmation; use %reset -f to delete all variables.")
    _clear_namespace(lambda name: True)


@_line_magic("reset_selective")
def _magic_reset_selective(line, frame):
    arguments = [part for part in line.split() if part != "-f"]
    if "-f" not in line.split() or not arguments:
        raise UsageError("Use %reset_selective -f pattern.")
    pattern = re.compile(arguments[0])
    _clear_namespace(lambda name: pattern.search(name) is not None)


@_line_magic("xdel")
def _magic_xdel(line, frame):
    for name in line.split():
        if name not in user_ns:
            raise UsageError("name '%s' is not defined" % name)
        del user_ns[name]


@_line_magic("precision")
def _magic_precision(line, frame):
    global _float_format
    text = line.strip()
    numpy = sys.modules.get("numpy")
    if not text:
        _float_format = None
        if numpy is not None:
            numpy.set_printoptions(precision=8)
        return "%r"
    if text.isdigit():
        _float_format = "%%.%df" % int(text)
        if numpy is not None:
            numpy.set_printoptions(precision=int(text))
        return _float_format
    try:
        text % math.pi
    except Exception:
        raise UsageError("Invalid format: %s" % text) from None
    _float_format = text
    return _float_format


_ACCEPTED_CONFIG = frozenset(("InlineBackend", "Completer", "IPCompleter", "InteractiveShell",
                              "ZMQInteractiveShell", "HistoryManager", "IPKernelApp", "Application"))


@_line_magic("config")
def _magic_config(line, frame):
    target = line.split("=", 1)[0].strip().split(".")[0]
    if not target:
        sys.stdout.write("Quanta accepts InlineBackend and Completer settings for compatibility.\n")
    elif target not in _ACCEPTED_CONFIG:
        sys.stderr.write("%%config %s has no effect in Quanta.\n" % target)


@_line_magic("matplotlib")
def _magic_matplotlib(line, frame):
    sys.stdout.write("Using matplotlib backend: inline\n")


@_line_magic("xmode", "colors", "unload_ext", "aimport_off")
def _magic_ignored(line, frame):
    return None


@_line_magic("clear")
def _magic_clear(line, frame):
    clear_output()


@_line_magic("pinfo")
def _magic_pinfo(line, frame):
    _show_help(line.strip(), frame, False)


@_line_magic("pinfo2")
def _magic_pinfo2(line, frame):
    _show_help(line.strip(), frame, True)


def _show_help(expression, frame, detailed):
    globals_ns, locals_ns = _namespaces(frame)
    try:
        value = eval(expression, globals_ns, locals_ns)
    except Exception:
        sys.stdout.write("Object `%s` not found.\n" % expression)
        return
    fields = []
    if callable(value):
        try:
            fields.append(("Signature", expression.rsplit(".", 1)[-1] + str(inspect.signature(value))))
        except (TypeError, ValueError):
            pass
    fields.append(("Type", type(value).__name__))
    if not isinstance(value, (types.ModuleType, types.FunctionType, types.BuiltinFunctionType, type)):
        fields.append(("String form", safe_repr(value, limit=200)))
        try:
            fields.append(("Length", str(len(value))))
        except Exception:
            pass
    try:
        fields.append(("File", inspect.getsourcefile(value) or inspect.getfile(value)))
    except (TypeError, OSError):
        pass
    source = None
    if detailed:
        try:
            source = inspect.getsource(value)
        except (TypeError, OSError):
            source = None
    if source is not None:
        fields.append(("Source", source.rstrip("\n")))
    else:
        fields.append(("Docstring", inspect.getdoc(value) or "<no docstring>"))
    lines = []
    for label, text in fields:
        heading = "\x1b[31m%s:\x1b[0m" % label
        if "\n" in text or label in ("Docstring", "Source"):
            lines.append(heading + "\n" + text)
        else:
            lines.append(heading + " " * max(1, 14 - len(label)) + text)
    sys.stdout.write("\n".join(lines) + "\n")


def _module_source(module):
    path = getattr(module, "__file__", None)
    if not isinstance(path, str) or not path.endswith(".py"):
        return None
    if "site-packages" in path or "dist-packages" in path:
        return None
    if path.startswith(_standard_library):
        return None
    return path


_standard_library = os.path.dirname(os.__file__) + os.sep


def _record_module_times():
    for name, module in list(sys.modules.items()):
        if name in _module_mtimes or name == "__main__":
            continue
        path = _module_source(module)
        if path is None:
            continue
        try:
            _module_mtimes[name] = os.stat(path).st_mtime
        except OSError:
            continue


def _update_function(old, new):
    for attribute in ("__code__", "__defaults__", "__kwdefaults__", "__doc__", "__annotations__"):
        try:
            setattr(old, attribute, getattr(new, attribute))
        except (AttributeError, TypeError, ValueError):
            pass
    try:
        old.__dict__.update(new.__dict__)
    except (AttributeError, TypeError):
        pass


def _update_class(old, new, seen):
    for key in list(old.__dict__):
        if key not in new.__dict__ and key not in ("__dict__", "__weakref__"):
            try:
                delattr(old, key)
            except (AttributeError, TypeError):
                pass
    for key, value in list(new.__dict__.items()):
        if key in ("__dict__", "__weakref__", "__doc__"):
            continue
        current = old.__dict__.get(key)
        if current is not None and _update_object(current, value, seen):
            continue
        try:
            setattr(old, key, value)
        except (AttributeError, TypeError):
            pass


def _update_object(old, new, seen):
    if id(old) in seen:
        return True
    seen.add(id(old))
    if isinstance(old, types.FunctionType) and isinstance(new, types.FunctionType):
        _update_function(old, new)
        return True
    if isinstance(old, (classmethod, staticmethod)) and isinstance(new, type(old)):
        return _update_object(old.__func__, new.__func__, seen)
    if isinstance(old, property) and isinstance(new, property):
        for accessor in ("fget", "fset", "fdel"):
            before, after = getattr(old, accessor), getattr(new, accessor)
            if before is not None and after is not None:
                _update_object(before, after, seen)
        return False
    if isinstance(old, type) and isinstance(new, type):
        _update_class(old, new, seen)
        return True
    return False


def _reload_module(name, module, path):
    try:
        os.remove(importlib.util.cache_from_source(path))
    except (OSError, NotImplementedError, ValueError):
        pass
    previous = dict(module.__dict__)
    importlib.reload(module)
    seen = set()
    for key, old in previous.items():
        new = module.__dict__.get(key)
        if new is None or new is old:
            continue
        if getattr(old, "__module__", None) == name or isinstance(old, types.FunctionType):
            _update_object(old, new, seen)


def _autoreload(force=False):
    if not force and _autoreload_mode == 0:
        return
    for name, module in list(sys.modules.items()):
        if name == "__main__" or name in _autoreload_skipped:
            continue
        if _autoreload_mode == 1 and not force and name not in _autoreload_explicit:
            continue
        path = _module_source(module)
        if path is None:
            continue
        try:
            modified = os.stat(path).st_mtime
        except OSError:
            continue
        previous = _module_mtimes.get(name)
        _module_mtimes[name] = modified
        if previous is None or previous == modified:
            continue
        try:
            _reload_module(name, module, path)
        except BaseException as error:
            if isinstance(error, KeyboardInterrupt):
                raise
            sys.stderr.write("[autoreload of %s failed]\n%s" % (
                name, _clean("".join(traceback.format_exception_only(type(error), error)))))


_AUTORELOAD_MODES = {"0": 0, "off": 0, "1": 1, "explicit": 1, "2": 2, "all": 2, "3": 2, "complete": 2}


@_line_magic("autoreload")
def _magic_autoreload(line, frame):
    global _autoreload_mode
    words = [word for word in line.split() if not word.startswith("-")]
    if not words or words[0] == "now":
        _record_module_times()
        _autoreload(force=True)
        return
    if words[0] not in _AUTORELOAD_MODES:
        raise UsageError("Unknown %%autoreload mode: %s" % words[0])
    _autoreload_mode = _AUTORELOAD_MODES[words[0]]
    _record_module_times()


@_line_magic("aimport")
def _magic_aimport(line, frame):
    names = [part.strip() for part in line.replace(",", " ").split() if part.strip()]
    if not names:
        sys.stdout.write("Modules to reload:\n%s\n\nModules to skip:\n%s\n" % (
            " ".join(sorted(_autoreload_explicit)), " ".join(sorted(_autoreload_skipped))))
        return
    for name in names:
        if name.startswith("-"):
            _autoreload_skipped.add(name[1:])
            _autoreload_explicit.discard(name[1:])
            continue
        module = importlib.import_module(name)
        _autoreload_explicit.add(name)
        _autoreload_skipped.discard(name)
        user_ns[name.split(".")[0]] = sys.modules[name.split(".")[0]] if "." in name else module
    _record_module_times()


def _load_dotenv(line, frame):
    try:
        from dotenv import find_dotenv, load_dotenv
    except ImportError:
        raise ModuleNotFoundError("%dotenv needs the python-dotenv package in the selected environment") from None
    arguments = shlex.split(_expand(line, frame))
    override = "-o" in arguments or "--override" in arguments
    paths = [argument for argument in arguments if not argument.startswith("-")]
    path = os.path.expanduser(paths[0]) if paths else find_dotenv(usecwd=True)
    load_dotenv(path, override=override)


@_line_magic("load_ext", "reload_ext")
def _magic_load_ext(line, frame):
    for name in line.split():
        if name == "autoreload":
            _record_module_times()
            continue
        if name == "dotenv":
            _line_magics["dotenv"] = _load_dotenv
            continue
        module = importlib.import_module(name)
        loader = getattr(module, "load_ipython_extension", None)
        if not callable(loader):
            sys.stderr.write("The %s module is not an IPython extension.\n" % name)
            continue
        try:
            loader(_shell)
        except Exception as error:
            sys.stderr.write("Quanta could not load the IPython extension %s: %s\n" % (name, _clean(str(error))))


@_line_magic("dotenv")
def _magic_dotenv(line, frame):
    _load_dotenv(line, frame)


def _read_notebook_sources(path):
    with open(path, encoding="utf-8") as handle:
        notebook = json.load(handle)
    sources = []
    for cell in notebook.get("cells", []):
        if cell.get("cell_type") != "code":
            continue
        source = cell.get("source", "")
        sources.append("".join(source) if isinstance(source, list) else str(source))
    return sources


@_line_magic("run")
def _magic_run(line, frame):
    arguments = shlex.split(_expand(line, frame))
    interactive = False
    as_main = True
    timed = False
    module_name = None
    while arguments and arguments[0].startswith("-"):
        option = arguments.pop(0)
        if option == "-i":
            interactive = True
        elif option == "-n":
            as_main = False
        elif option == "-t":
            timed = True
        elif option == "-m" and arguments:
            module_name = arguments.pop(0)
            break
        else:
            raise UsageError("%%run option %s is not supported" % option)
    start = time.perf_counter()
    saved_argv = sys.argv
    if module_name is not None:
        import runpy
        sys.argv = [module_name] + arguments
        try:
            namespace = runpy.run_module(module_name, run_name="__main__" if as_main else module_name,
                                         alter_sys=True)
        except SystemExit as error:
            if error.code not in (None, 0):
                raise
            namespace = {}
        finally:
            sys.argv = saved_argv
        user_ns.update({k: v for k, v in namespace.items() if not k.startswith("__")})
    else:
        if not arguments:
            raise UsageError("%run needs a file name")
        path = os.path.expanduser(arguments[0])
        if not os.path.exists(path) and os.path.exists(path + ".py"):
            path += ".py"
        path = os.path.abspath(path)
        if path.endswith(".ipynb"):
            sources = [(source, "%s [cell %d]" % (path, index + 1))
                       for index, source in enumerate(_read_notebook_sources(path))]
        else:
            with open(path, encoding="utf-8") as handle:
                sources = [(handle.read(), path)]
        if interactive:
            namespace = user_ns
        else:
            namespace = {"__name__": "__main__" if as_main else os.path.splitext(os.path.basename(path))[0],
                         "__builtins__": builtins}
            namespace.update(_helpers)
        namespace["__file__"] = path
        directory = os.path.dirname(path)
        added = directory not in sys.path
        if added:
            sys.path.insert(0, directory)
        sys.argv = [path] + arguments[1:]
        try:
            for source, filename in sources:
                linecache.cache[filename] = (len(source), None, source.splitlines(True), filename)
                tree, _ = _parse_notebook_code(source, filename)
                exec(_compiler(tree, filename, "exec"), namespace)
        except SystemExit as error:
            if error.code not in (None, 0):
                raise
        finally:
            sys.argv = saved_argv
            if added and directory in sys.path:
                sys.path.remove(directory)
        if not interactive:
            user_ns.update({k: v for k, v in namespace.items()
                            if not k.startswith("__") and not _is_helper(k, v)})
    if timed:
        sys.stdout.write("Wall time: %s\n" % _format_time(time.perf_counter() - start))


@_line_magic("lsmagic")
def _magic_lsmagic(line, frame):
    sys.stdout.write("Available line magics:\n%s\n\nAvailable cell magics:\n%s\n" % (
        "  ".join("%" + name for name in sorted(_line_magics)),
        "  ".join("%%" + name for name in sorted(_cell_magics))))


@_cell_magic("writefile", "file")
def _magic_writefile(line, cell, frame):
    arguments = shlex.split(_expand(line, frame))
    append = "-a" in arguments or "--append" in arguments
    names = [argument for argument in arguments if argument not in ("-a", "--append")]
    if not names:
        raise UsageError("%%writefile needs a file name")
    path = os.path.expanduser(names[0])
    if append:
        sys.stdout.write("Appending to %s\n" % path)
    else:
        sys.stdout.write(("Overwriting %s\n" if os.path.exists(path) else "Writing %s\n") % path)
    with open(path, "a" if append else "w", encoding="utf-8") as handle:
        handle.write(cell)


@_cell_magic("capture")
def _magic_capture(line, cell, frame):
    words = line.split()
    names = [word for word in words if not word.startswith("-")]
    stdout = io.StringIO() if "--no-stdout" not in words else None
    stderr = io.StringIO() if "--no-stderr" not in words else None
    outputs = []
    saved = sys.stdout, sys.stderr
    sys.stdout.flush()
    sys.stderr.flush()
    if stdout is not None:
        sys.stdout = stdout
    if stderr is not None:
        sys.stderr = stderr
    capturing = "--no-display" not in words
    if capturing:
        _capture_stack.append(outputs)
    try:
        compiled, compiled_expr = _compile_block(cell, _cell_body_offset)
        result = _evaluate_block(compiled, compiled_expr, frame)
        if result is not None:
            display(result)
        emit_figures()
    finally:
        if capturing:
            _capture_stack.pop()
        sys.stdout, sys.stderr = saved
    captured = CapturedIO(stdout.getvalue() if stdout is not None else "",
                          stderr.getvalue() if stderr is not None else "", outputs)
    if names:
        _namespaces(frame)[1][names[0]] = captured
        if not _at_top_level(frame):
            user_ns[names[0]] = captured


def _script_magic(program):
    def run(line, cell, frame):
        arguments = shlex.split(_expand(line, frame))
        raise_error = "--no-raise-error" not in arguments
        arguments = [argument for argument in arguments if argument != "--no-raise-error"]
        if program is None:
            if not arguments:
                raise UsageError("%%script needs a program name")
            command = arguments
        else:
            command = list(program) + arguments
        code = _run_process(command, merge=False, input_text=cell)
        if code and raise_error:
            raise subprocess.CalledProcessError(code, command[0])
    return run


for _script_name, _script_program in (("bash", ["bash"]), ("sh", ["sh"]), ("zsh", ["zsh"]),
                                      ("python", [sys.executable]), ("python3", [sys.executable]),
                                      ("perl", ["perl"]), ("ruby", ["ruby"]), ("script", None)):
    _cell_magics[_script_name] = _script_magic(_script_program)


def _rich_cell(mime):
    def run(line, cell, frame):
        global _display_depth
        _display_depth += 1
        try:
            emit({"id": _current_id, "type": "rich",
                  "mime_bundle": {mime: cell, "text/plain": cell}, "metadata": {}})
        finally:
            _display_depth -= 1
    return run


for _rich_name, _rich_mime in (("html", "text/html"), ("markdown", "text/markdown"),
                               ("latex", "text/latex"), ("svg", "image/svg+xml")):
    _cell_magics[_rich_name] = _rich_cell(_rich_mime)


class QuantaShell:
    def __init__(self):
        self.user_ns = user_ns
        self.config = {}

    def run_line_magic(self, magic_name, line, _stack_depth=1):
        function = _line_magics.get(magic_name)
        if function is None:
            raise UsageError("Line magic function `%%%s` not found." % magic_name)
        return function(line, sys._getframe(_stack_depth))

    def run_cell_magic(self, magic_name, line, cell):
        function = _cell_magics.get(magic_name)
        if function is None:
            raise UsageError("Cell magic `%%%%%s` not found." % magic_name)
        return function(line, cell, sys._getframe(1))

    def magic(self, line):
        name, _, arguments = line.lstrip("%").partition(" ")
        return self.run_line_magic(name, arguments, _stack_depth=2)

    def system(self, command):
        _system(_expand(command, sys._getframe(1)))

    def getoutput(self, command, split=True):
        output = _getoutput(_expand(command, sys._getframe(1)))
        return output if split else output.n

    def ev(self, expression):
        return eval(expression, user_ns)

    def ex(self, command):
        exec(command, user_ns)

    def push(self, variables, interactive=True):
        if isinstance(variables, dict):
            user_ns.update(variables)
        else:
            caller = sys._getframe(1)
            names = variables.split() if isinstance(variables, str) else variables
            for name in names:
                user_ns[name] = eval(name, caller.f_globals, caller.f_locals)

    def register_magic_function(self, function, magic_kind="line", magic_name=None):
        name = magic_name or function.__name__
        if magic_kind in ("line", "line_cell"):
            _line_magics[name] = lambda line, frame: function(line)
        if magic_kind in ("cell", "line_cell"):
            _cell_magics[name] = lambda line, cell, frame: function(line, cell)

    def register_magics(self, *magics):
        raise UsageError("IPython magic classes are not supported by Quanta")

    def __repr__(self):
        return "<QuantaShell>"


_shell = QuantaShell()


def get_ipython():
    return _shell


_helpers = {"display": display, "clear_output": clear_output, "get_ipython": get_ipython}
user_ns.update(_helpers)


_HELP_LINE = re.compile(r"([ \t]*)(\?{1,2})?([A-Za-z_]\w*(?:\.[A-Za-z_]\w*)*)(\?{1,2})?[ \t]*")
_COMMAND_LINE = re.compile(
    r"([ \t]*)(?:([A-Za-z_][\w.]*(?:[ \t]*,[ \t]*[A-Za-z_][\w.]*)*)[ \t]*=[ \t]*)?(!.*|%[A-Za-z_].*)")
_MAGIC_NAME = re.compile(r"%([A-Za-z_][\w.]*)[ \t]*(.*)")


def _unsupported_command(name, filename, row, column, line):
    if name.startswith("%matplotlib"):
        advice = "Quanta supports inline plots; use %matplotlib inline or ordinary matplotlib code."
    else:
        advice = "Use ordinary Python, or run this notebook with an IPython kernel in Jupyter."
    return UnsupportedNotebookCommand(
        f"{name} is not supported by Quanta's Python runner. {advice}", (filename, row, column, line))


def _magic_call(method, *arguments):
    return "get_ipython().%s(%s)" % (method, ", ".join(repr(argument) for argument in arguments))


def _transform_line(line, row, filename, check):
    text = line.rstrip("\r\n")
    ending = line[len(text):]
    help_match = _HELP_LINE.fullmatch(text)
    if help_match is not None and (help_match.group(2) or help_match.group(4)):
        marks = (help_match.group(2) or "") + (help_match.group(4) or "")
        name = "pinfo2" if "??" in marks else "pinfo"
        return help_match.group(1) + _magic_call("run_line_magic", name, help_match.group(3)) + ending
    match = _COMMAND_LINE.fullmatch(text)
    if match is None:
        return None
    indent, target, rest = match.groups()
    prefix = indent + (target.strip() + " = " if target else "")
    if rest.startswith("!!"):
        call = _magic_call("getoutput", rest[2:].strip())
    elif rest.startswith("!"):
        call = _magic_call("getoutput" if target else "system", rest[1:].strip())
    else:
        magic = _MAGIC_NAME.fullmatch(rest)
        if magic is None:
            return None
        name, arguments = magic.group(1), magic.group(2).rstrip()
        if check and name not in _line_magics:
            raise _unsupported_command("%" + name, filename, row, len(indent) + 1, line)
        if name == "matplotlib" and arguments.split()[:1] and arguments.split()[0] in _UNSUPPORTED_MATPLOTLIB:
            raise _unsupported_command("%matplotlib " + arguments.split()[0], filename, row, len(indent) + 1, line)
        call = _magic_call("run_line_magic", name, arguments)
    return prefix + call + ending


def _scan_line(line, depth, quote):
    index = 0
    length = len(line)
    commented = False
    while index < length:
        character = line[index]
        if quote is not None:
            if character == "\\":
                index += 2
                continue
            if line.startswith(quote, index):
                index += len(quote)
                quote = None
                continue
            index += 1
            continue
        if character == "#":
            commented = True
            break
        if character in "\"'":
            quote = line[index:index + 3] if line[index:index + 3] in ('"""', "'''") else character
            index += len(quote)
            continue
        if character in "([{":
            depth += 1
        elif character in ")]}":
            depth = max(0, depth - 1)
        index += 1
    body = line.rstrip("\r\n")
    continued = not commented and body.endswith("\\") and not body.endswith("\\\\")
    if quote is not None and len(quote) == 1 and not continued:
        quote = None
    return depth, quote, continued


def _transform_ipython(code, filename):
    global _cell_body_offset
    lines = code.splitlines(True)
    check = "load_ext" not in code and "register_magic_function" not in code
    first = next((index for index, line in enumerate(lines) if line.strip()), None)
    if first is not None and lines[first].startswith("%%"):
        header = lines[first].rstrip("\r\n")[2:]
        parts = header.split(None, 1)
        name = parts[0] if parts else ""
        if check and name not in _cell_magics:
            raise _unsupported_command("%%" + name, filename, first + 1, 1, lines[first])
        _cell_body_offset = first + 1
        body = "".join(lines[first + 1:])
        return "\n" * first + _magic_call("run_cell_magic", name, parts[1] if len(parts) > 1 else "", body) + "\n"
    output = []
    depth = 0
    quote = None
    continued = False
    changed = False
    for row, line in enumerate(lines, 1):
        if quote is None and depth == 0 and not continued:
            replacement = _transform_line(line, row, filename, check)
            if replacement is not None:
                output.append(replacement)
                changed = True
                continue
        depth, quote, continued = _scan_line(line, depth, quote)
        output.append(line)
    return "".join(output) if changed else None


def _enter_notebook_directory(notebook, default):
    target = _notebook_directories.get(notebook) or (default if isinstance(default, str) else None)
    if not target or target == execution_directory():
        return
    try:
        os.chdir(target)
    except OSError:
        _notebook_directories.pop(notebook, None)


def run_code(msg):
    global _current_id, _exec_count, _stream_budget, _interruptible, _current_filename, _cell_body_offset
    _current_id = msg.get("id")
    _stream_budget = MAX_STREAM_BYTES
    code = msg.get("code", "")
    _exec_count += 1

    filename = msg.get("filename") or f"<cell {_exec_count}>"
    status = "ok"
    had_file = "__file__" in user_ns
    old_file = user_ns.get("__file__")
    script_directory = None
    if msg.get("filename"):
        user_ns["__file__"] = msg["filename"]
        directory = os.path.dirname(os.path.abspath(msg["filename"]))
        if directory not in sys.path:
            script_directory = directory
            sys.path.insert(0, directory)

    linecache.cache[filename] = (len(code), None, code.splitlines(True), filename)
    _current_filename = filename
    _cell_body_offset = 0
    notebook = msg.get("notebook") if isinstance(msg.get("notebook"), str) else None
    if notebook:
        _enter_notebook_directory(notebook, msg.get("directory"))
    compiling = True
    try:
        _autoreload()
        tree, prepared = _parse_notebook_code(code, filename)
        result_name = None
        last_expr = None
        if tree.body and isinstance(tree.body[-1], ast.Expr) and not _suppresses_result(prepared):
            expr_node = tree.body.pop()
            if isinstance(expr_node.value, ast.Name):
                result_name = expr_node.value.id
            last_expr = ast.Expression(expr_node.value)
            ast.fix_missing_locations(last_expr)
        result = None
        has_result = False
        compiled = _compiler(tree, filename, "exec") if tree.body else None
        compiled_expr = _compiler(last_expr, filename, "eval") if last_expr is not None else None
        compiling = False
        _interruptible = True
        try:
            result = _evaluate_cell(compiled, compiled_expr)
            has_result = compiled_expr is not None and result is not None
        finally:
            _interruptible = False
        if has_result:
            user_ns["_"] = result
            _interruptible = True
            try:
                emit_result(result, result_name)
            finally:
                _interruptible = False
    except KeyboardInterrupt:
        status = "error"
        emit({"id": _current_id, "type": "error", "ename": "KeyboardInterrupt",
              "evalue": "execution interrupted", "traceback": ""})
    except SyntaxError as e:
        status = "error"
        if compiling:
            emit({"id": _current_id, "type": "error", "ename": type(e).__name__,
                  "evalue": _clean(str(e)),
                  "traceback": _clean("".join(traceback.format_exception_only(type(e), e)))})
        else:
            report = _error_report(e)
            report.update({"id": _current_id, "type": "error"})
            emit(report)
    except SystemExit as e:
        status = "error"
        try:
            code = str(e.code)
        except Exception:
            code = "<unprintable exit code>"
        emit({"id": _current_id, "type": "error", "ename": "SystemExit",
              "evalue": code, "traceback": ""})
    except BaseException as e:
        status = "error"
        report = _error_report(e)
        report.update({"id": _current_id, "type": "error"})
        emit(report)
    finally:
        _interruptible = False
        try:
            stdout_writer.flush()
            stderr_writer.flush()
        except Exception:
            pass
        if msg.get("filename"):
            if had_file:
                user_ns["__file__"] = old_file
            else:
                user_ns.pop("__file__", None)
        if script_directory is not None and script_directory in sys.path:
            sys.path.remove(script_directory)
        try:
            emit_figures()
        except Exception:
            pass
        if _autoreload_mode:
            _record_module_times()
        if notebook:
            _notebook_directories[notebook] = execution_directory()
        emit({"id": _current_id, "type": "done", "status": status,
              "execution_count": _exec_count, "cwd": execution_directory()})
        _current_id = None

def safe_repr(v, limit=80, short=False):
    try:
        r = _short_repr.repr(v) if short else repr(v)
    except Exception:
        r = "<unrepresentable>"
    r = _clean(r).replace("\n", " ")
    return r[:limit] + ("…" if len(r) > limit else "")

def variables_snapshot():
    out = []
    pd = sys.modules.get("pandas")
    np = sys.modules.get("numpy")
    for name, val in list(user_ns.items()):
        if not isinstance(name, str):
            continue
        if name.startswith("_") or name in ("In", "Out"):
            continue
        if isinstance(val, (types.ModuleType, types.FunctionType,
                            types.BuiltinFunctionType, type)):
            continue
        type_name = type(val).__name__
        shape = None
        is_df = False
        summary = ""
        try:
            if pd is not None and isinstance(val, pd.DataFrame):
                is_df = True
                shape = "%d × %d" % (val.shape[0], val.shape[1])
                cols = [str(c) for c in list(val.columns)[:6]]
                summary = "columns: " + ", ".join(cols) + ("…" if val.shape[1] > 6 else "")
            elif pd is not None and isinstance(val, pd.Series):
                is_df = True
                shape = str(len(val))
                summary = "Series (%s)" % val.dtype
            elif np is not None and isinstance(val, np.ndarray):
                shape = " × ".join(str(d) for d in val.shape)
                summary = "ndarray %s" % val.dtype
            elif isinstance(val, (list, tuple, set, frozenset, dict, str, bytes, bytearray)):
                shape = str(len(val))
                summary = safe_repr(val, short=True)
            else:
                summary = safe_repr(val)
        except Exception:
            summary = "<unreadable>"
        out.append({"name": name, "type": type_name, "summary": _clean(summary),
                    "shape": shape, "is_dataframe": is_df, "inspectable": _inspectable(val)})
    out.sort(key=lambda d: d["name"].lower())
    return out[:400]

_CONTAINERS = (dict, list, tuple)

def _inspectable(value):
    if type(value) not in _CONTAINERS or not value:
        return False
    if len(value) > 10:
        return True
    children = value.values() if type(value) is dict else value
    return any(type(child) in _CONTAINERS for child in children)

def handle_variable(msg):
    name = msg.get("name", "")
    if name not in user_ns:
        emit({"id": msg.get("id"), "type": "variable_error", "error": "Variable no longer exists"})
        return
    remaining = [300]
    seen = set()
    def node(value, label, depth):
        remaining[0] -= 1
        result = {"name": label, "type": type(value).__name__, "value": safe_repr(value, short=True)}
        if type(value) not in _CONTAINERS:
            return result
        if id(value) in seen:
            result["value"] = "<recursive reference>"
            return result
        if depth >= 4 or remaining[0] <= 0:
            result["value"] += " · preview limit reached"
            return result
        seen.add(id(value))
        children = []
        items = value.items() if type(value) is dict else enumerate(value)
        for index, (key, child) in enumerate(items):
            if index >= 100 or remaining[0] <= 0:
                children.append({"name": "…", "type": "", "value": "More items omitted"})
                break
            children.append(node(child, safe_repr(key, short=True), depth + 1))
        seen.remove(id(value))
        result["children"] = children
        return result
    value = user_ns[name]
    emit({"id": msg.get("id"), "type": "variable", "node": node(value, name, 0),
          "bytes": sys.getsizeof(value)})

def _frame_for(val, msg):
    query = msg.get("filter", "")
    sort_column = msg.get("sort_column")
    if not query and sort_column is None:
        return val
    import pandas as pd
    frame = val.to_frame() if isinstance(val, pd.Series) else val
    if not isinstance(frame, pd.DataFrame):
        raise ValueError("The variable is not a DataFrame or Series")
    if query:
        mask = pd.Series(False, index=frame.index)
        for _, column in frame.iloc[:, :msg.get("max_cols", 60)].items():
            mask |= column.astype(str).str.contains(query, case=False, regex=False, na=False)
        frame = frame.loc[mask]
    if sort_column is not None:
        position = int(sort_column)
        if not 0 <= position < len(frame.columns):
            raise ValueError("The sort column no longer exists; clear the sort and retry")
        order = frame.iloc[:, position].reset_index(drop=True).sort_values(
            ascending=bool(msg.get("ascending", True)), kind="stable", na_position="last").index
        frame = frame.iloc[order]
    return frame

def _column_stats(column):
    count = int(column.count())
    try:
        distinct = int(column.nunique(dropna=True))
    except TypeError:
        distinct = int(column.dropna().astype(str).nunique())
    stats = {"count": count, "missing": int(len(column) - count),
             "distinct": distinct, "min": None, "max": None, "mean": None}
    kind = column.dtype.kind
    if count and kind in "iufmM":
        stats["min"] = _clean(str(column.min()))
        stats["max"] = _clean(str(column.max()))
    if count and kind in "iuf":
        stats["mean"] = _finite(column.mean())
    return stats

def handle_dfsummary(msg):
    name = msg.get("name", "")
    val = user_ns.get(name)
    try:
        import pandas as pd
        if not isinstance(val, (pd.DataFrame, pd.Series)):
            raise ValueError("'%s' is not a DataFrame or Series" % name)
        frame = _frame_for(val, msg)
        if isinstance(frame, pd.Series):
            frame = frame.to_frame()
        columns = [_column_stats(column) for _, column in frame.iloc[:, :msg.get("max_cols", 60)].items()]
    except Exception as error:
        emit({"id": msg.get("id"), "type": "dfsummary_error", "error": _clean(str(error))})
        return
    emit({"id": msg.get("id"), "type": "dfsummary", "total_rows": int(len(frame)), "columns": columns})

def handle_df(msg):
    name = msg.get("name", "")
    val = user_ns.get(name)
    if val is None:
        emit({"id": msg.get("id"), "type": "df_error",
              "error": "'%s' is not defined in the kernel" % name})
        return
    try:
        val = _frame_for(val, msg)
    except Exception as error:
        emit({"id": msg.get("id"), "type": "df_error", "error": _clean(str(error))})
        return
    payload = dataframe_payload(val, msg.get("offset", 0), msg.get("limit", 500), name,
                                max_cols=msg.get("max_cols", 150))
    if payload is None:
        emit({"id": msg.get("id"), "type": "df_error",
              "error": "'%s' is not a DataFrame or Series" % name})
        return
    emit({"id": msg.get("id"), "type": "dataframe", "payload": payload})

_TEX_REWRITES = [
    (re.compile(r"\\[bB]igg?[lrm]?(?=\s*[\[\](){}|.])"), ""),
    (re.compile(r"\\textnormal\b"), r"\\mathrm"),
    (re.compile(r"\\textrm\b"), r"\\mathrm"),
    (re.compile(r"\\textbf\b"), r"\\mathbf"),
    (re.compile(r"\\textit\b"), r"\\mathit"),
    (re.compile(r"\\text\b"), r"\\mathrm"),
    (re.compile(r"\\mbox\b"), r"\\mathrm"),
    (re.compile(r"\\hbox\b"), r"\\mathrm"),
    (re.compile(r"\\dfrac\b"), r"\\frac"),
    (re.compile(r"\\tfrac\b"), r"\\frac"),
    (re.compile(r"\\boldsymbol\b"), r"\\mathbf"),
    (re.compile(r"\\operatorname\b"), r"\\mathrm"),
    (re.compile(r"\\displaystyle\b"), ""),
]

def _rewrite_tex(tex):
    for pattern, replacement in _TEX_REWRITES:
        tex = pattern.sub(replacement, tex)
    return tex

def _render_mathtext(tex, fontsize, color):
    from matplotlib import mathtext
    from matplotlib.figure import Figure
    from matplotlib.font_manager import FontProperties

    s = "$%s$" % tex
    prop = FontProperties(size=fontsize)
    parser = mathtext.MathTextParser("path")
    width, height, depth, _, _ = parser.parse(s, dpi=72, prop=prop)
    fig = Figure(figsize=(max(width, 1) / 72.0, max(height, 1) / 72.0))
    fig.text(0, depth / height, s, fontproperties=prop, color=color)
    buf = io.BytesIO()
    fig.savefig(buf, dpi=288, format="png", transparent=True)
    return buf.getvalue(), float(depth)

def _utf16_to_index(text, utf16_offset):
    units = 0
    for i, ch in enumerate(text):
        if units >= utf16_offset:
            return i
        units += 2 if ord(ch) > 0xFFFF else 1
    return len(text)

def _index_to_utf16(text, index):
    return sum(2 if ord(ch) > 0xFFFF else 1 for ch in text[:index])

def _completion_context(code, cursor):
    text = code[:cursor]
    i = len(text)
    while i > 0 and (text[i - 1].isalnum() or text[i - 1] in "._"):
        i -= 1
    expr = text[i:]
    base, dot, segment = expr.rpartition(".")
    if not dot:

        if not expr and i > 0 and text[i - 1] in ")]\"'":
            return "", "", i, False
        return "", expr, i, True
    if not base:

        return "", segment, cursor - len(segment), False
    return base, segment, cursor - len(segment), True

def _resolve_static(base):
    import inspect as _inspect

    parts = base.split(".")
    if not parts or not all(p.isidentifier() for p in parts):
        raise LookupError(base)
    if parts[0] not in user_ns:
        import builtins
        if not hasattr(builtins, parts[0]):
            raise LookupError(base)
        obj = getattr(builtins, parts[0])
    else:
        obj = user_ns[parts[0]]
    for attr in parts[1:]:
        try:
            obj = _inspect.getattr_static(obj, attr)
        except AttributeError:

            obj = getattr(obj, attr)

        if isinstance(obj, (staticmethod, classmethod)):
            obj = obj.__func__
    return obj

_KEY_CONTEXT = re.compile(r"([A-Za-z_][\w.]*)\[\s*(['\"])([^'\"\\\n]*)$")


def _subscript_keys(value):
    import collections.abc
    pd = sys.modules.get("pandas")
    np = sys.modules.get("numpy")
    if pd is not None and isinstance(value, pd.DataFrame):
        return list(value.columns)
    if pd is not None and isinstance(value, pd.Series):
        return list(value.index[:1000])
    if np is not None and isinstance(value, np.ndarray) and value.dtype.names:
        return list(value.dtype.names)
    completer = getattr(value, "_ipython_key_completions_", None)
    if callable(completer) and not isinstance(value, type):
        return list(completer())
    if isinstance(value, collections.abc.Mapping):
        keys = []
        for key in value:
            keys.append(key)
            if len(keys) >= 5000:
                break
        return keys
    return []


def _key_completions(text):
    match = _KEY_CONTEXT.search(text)
    if match is None:
        return None
    base, quote, partial = match.groups()
    try:
        keys = _subscript_keys(_resolve_static(base))
    except Exception:
        return None
    names = sorted({key for key in keys if isinstance(key, str) and key.startswith(partial) and quote not in key})
    return names[:200], len(text) - len(partial)


def handle_complete(msg):
    import builtins
    import keyword

    mid = msg.get("id")
    code = msg.get("code") or ""
    cursor = _utf16_to_index(code, int(msg.get("cursor") or 0))
    keyed = _key_completions(code[:cursor])
    if keyed is not None:
        emit({"id": mid, "type": "completions", "matches": keyed[0], "context": "key",
              "start": _index_to_utf16(code, keyed[1]), "end": _index_to_utf16(code, cursor)})
        return
    base, segment, start, ok = _completion_context(code, cursor)
    matches = []
    if ok:
        try:
            if base:
                names = set(dir(_resolve_static(base)))
            else:
                names = set(user_ns) | set(keyword.kwlist) | set(dir(builtins))
            hidden_ok = segment.startswith("_")
            matches = sorted(
                n for n in names
                if n.startswith(segment) and (hidden_ok or not n.startswith("_")))[:200]
        except Exception:
            matches = []
    emit({"id": mid, "type": "completions", "matches": matches,
          "start": _index_to_utf16(code, start), "end": _index_to_utf16(code, cursor)})

def handle_inspect(msg):
    import inspect as _inspect

    mid = msg.get("id")
    code = msg.get("code") or ""
    cursor = _utf16_to_index(code, int(msg.get("cursor") or 0))
    base, segment, _, ok = _completion_context(code, cursor)
    expr = f"{base}.{segment}" if base else segment
    if not expr or not ok:
        emit({"id": mid, "type": "inspect_error", "error": "nothing to inspect"})
        return
    try:
        obj = _resolve_static(expr)
    except Exception:
        emit({"id": mid, "type": "inspect_error", "error": f"name '{expr}' is not defined"})
        return
    signature = ""
    try:
        signature = expr.rsplit(".", 1)[-1] + str(_inspect.signature(obj))
    except (TypeError, ValueError):
        pass
    doc = _inspect.getdoc(obj) or ""
    emit({"id": mid, "type": "inspection", "signature": signature, "doc": doc[:6000]})

def _appearance_fg():
    return "#E8E8E8" if _dark_appearance else "#1D1D1F"

def handle_latex(msg):
    mid = msg.get("id")
    tex = _rewrite_tex((msg.get("tex") or "").strip().replace("\n", " "))
    if not tex:
        emit({"id": mid, "type": "latex_error", "error": "empty expression"})
        return
    try:
        png, depth = _render_mathtext(tex, float(msg.get("fontsize", 13)),
                                      msg.get("color", "#000000"))
        emit({"id": mid, "type": "latex",
              "data": base64.b64encode(png).decode(), "depth": depth})
    except Exception as e:
        emit({"id": mid, "type": "latex_error", "error": _clean(str(e))})

def _features():
    import importlib.util as u
    result = {"top_level_await": True, "display": True, "clear_output": True, "input": True, "magics": True}
    for mod in ("pandas", "numpy", "matplotlib"):
        try:
            result[mod] = u.find_spec(mod) is not None
        except Exception:
            result[mod] = False
    return result

def _handle_internal_error(op, msg):
    err = _clean(traceback.format_exc())
    if op == "execute":
        emit({"id": msg.get("id"), "type": "error", "ename": "KernelInternalError",
              "evalue": "bridge error while executing", "traceback": err})
        emit({"id": msg.get("id"), "type": "done", "status": "error",
              "execution_count": _exec_count, "cwd": execution_directory()})
    elif op == "vars":
        emit({"id": msg.get("id"), "type": "vars", "variables": []})
    elif op == "variable":
        emit({"id": msg.get("id"), "type": "variable_error", "error": "Could not inspect this variable"})
    elif op == "df":
        last = err.strip().splitlines()[-1] if err.strip() else "internal error"
        emit({"id": msg.get("id"), "type": "df_error", "error": last})
    elif op == "dfsummary":
        emit({"id": msg.get("id"), "type": "dfsummary_error", "error": "internal error"})
    elif op == "latex":
        emit({"id": msg.get("id"), "type": "latex_error", "error": "internal error"})
    elif op == "complete":
        emit({"id": msg.get("id"), "type": "completions", "matches": [],
              "start": 0, "end": 0})
    elif op == "inspect":
        emit({"id": msg.get("id"), "type": "inspect_error", "error": "internal error"})

def _plotly_js_path():
    try:
        import importlib.util
        spec = importlib.util.find_spec("plotly")
        if spec and spec.submodule_search_locations:
            for root in spec.submodule_search_locations:
                path = os.path.join(root, "package_data", "plotly.min.js")
                if os.path.exists(path):
                    return path
    except Exception:
        pass
    return None

def execution_directory():
    try:
        return os.getcwd()
    except OSError:
        return None

def main():
    signal.signal(signal.SIGINT, _sigint_handler)
    if "" not in sys.path:
        sys.path.insert(0, "")
    emit({
        "type": "ready",
        "python_version": sys.version.split()[0],
        "executable": sys.executable,
        "cwd": os.getcwd(),
        "features": _features(),
        "plotly_js": _plotly_js_path(),
    })
    stream_flusher = threading.Thread(target=_flush_streams_periodically, daemon=True)
    stream_flusher.start()
    while True:
        msg = _next_protocol_message()
        if msg is None:
            break
        op = msg.get("op")
        try:
            if op == "execute":
                run_code(msg)
            elif op == "vars":
                emit({"id": msg.get("id"), "type": "vars",
                      "variables": variables_snapshot()})
            elif op == "variable":
                handle_variable(msg)
            elif op == "df":
                handle_df(msg)
            elif op == "dfsummary":
                handle_dfsummary(msg)
            elif op == "latex":
                handle_latex(msg)
            elif op == "complete":
                handle_complete(msg)
            elif op == "inspect":
                handle_inspect(msg)
            elif op == "config":
                if "appearance" in msg:
                    globals()["_dark_appearance"] = msg["appearance"] == "dark"
                if isinstance(msg.get("adapt_plot_theme"), bool):
                    globals()["_adapt_plot_theme"] = msg["adapt_plot_theme"]
                if isinstance(msg.get("input_requests"), bool):
                    globals()["_input_requests"] = msg["input_requests"]
            elif op == "shutdown":
                break
        except Exception:
            _handle_internal_error(op, msg)
    _shutdown_async_loop()
    _stream_flush_stop.set()
    _stream_flush_requested.set()
    stream_flusher.join(timeout=1)
    stdout_writer.flush()
    stderr_writer.flush()

if __name__ == "__main__":
    main()
