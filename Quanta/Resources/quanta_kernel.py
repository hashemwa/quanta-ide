#!/usr/bin/env python3
import ast
import base64
import builtins
import datetime
import functools
import importlib.machinery
import io
import html as html_escape
import json
import linecache
import math
import numbers
import os
import re
import reprlib
import signal
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

_lock = threading.Lock()
_current_id = None
_stream_budget = MAX_STREAM_BYTES
_exec_count = 0
_interruptible = False

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
    if _current_id is not None and obj.get("id") == _current_id and "mime_bundle" not in obj:
        bundle = _portable_output(obj)
        if bundle:
            obj["mime_bundle"] = bundle
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
        self._wlock = threading.RLock()
        self._last_flush = time.monotonic()

    def writable(self):
        return True

    def isatty(self):
        return False

    def write(self, s):
        global _stream_budget
        s = str(s)
        if not s:
            return 0
        length = len(s)
        with self._wlock:
            if _stream_budget <= 0:
                return length
            if len(s) > _stream_budget:
                s = s[:_stream_budget]
            if not self.buf:
                self._last_flush = time.monotonic()
            self.buf += s
            if ("\n" in self.buf or len(self.buf) >= 8192
                    or time.monotonic() - self._last_flush > 0.2):
                self.flush()
        return length

    def flush(self):
        global _stream_budget
        with self._wlock:
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

def _no_input(prompt=""):
    raise RuntimeError("input() is not supported in Quanta yet")

builtins.input = _no_input

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
                "mime": "image/png",
                "data": base64.b64encode(buf.getvalue()).decode(),
            })
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
                       ("_repr_json_", "application/json")]:
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
    repr_latex = getattr(obj, "_repr_latex_", None)
    if callable(repr_latex):
        try:
            tex = repr_latex()
        except Exception:
            tex = None
        if isinstance(tex, str) and tex.strip():
            tex = _rewrite_tex(tex.strip().strip("$").replace("\n", " "))
            try:
                png, _ = _render_mathtext(tex, 14, _appearance_fg())
                emit({"id": _current_id, "type": "display", "mime": "image/png",
                      "data": base64.b64encode(png).decode()})
                return True
            except Exception:
                pass
    return False

def _try_ndarray(obj):
    np = sys.modules.get("numpy")
    if np is None or not isinstance(obj, np.ndarray) or obj.dtype.kind not in "biuf":
        return False
    payload = {"shape": [int(d) for d in obj.shape], "dtype": str(obj.dtype)}
    try:
        if obj.size:
            arr = obj.astype(float, copy=False)
            payload["stats"] = {k: v for k, v in {
                "min": _finite(np.nanmin(arr)), "max": _finite(np.nanmax(arr)),
                "mean": _finite(np.nanmean(arr)), "std": _finite(np.nanstd(arr)),
            }.items() if v is not None}
    except Exception:
        pass
    try:
        if obj.ndim == 1 and obj.size > 1:
            n = min(int(obj.size), 300)
            idx = np.linspace(0, obj.size - 1, n).astype(int)
            payload["series"] = [_finite(v) for v in obj[idx]]
        elif obj.ndim == 2 and obj.size > 0:
            rows, cols = obj.shape
            rstep = max(1, -(-rows // 80))
            cstep = max(1, -(-cols // 120))
            grid = obj[::rstep, ::cstep].astype(float)
            lo = np.nanmin(grid)
            hi = np.nanmax(grid)
            span = float(hi - lo) or 1.0
            norm = (grid - lo) / span
            payload["grid"] = [[_finite(v) for v in row] for row in norm]
    except Exception:
        pass
    payload["text"] = _capped(_clean(repr(obj)), 2000)
    emit({"id": _current_id, "type": "ndarray", "payload": payload})
    return True

def _try_model_card(obj):
    get_params = getattr(obj, "get_params", None)
    module = getattr(type(obj), "__module__", "") or ""
    if not callable(get_params) or not module.startswith("sklearn"):
        return False
    try:
        params = get_params()
    except Exception:
        return False
    fields = {str(k): _clean(repr(v))[:80] for k, v in sorted(params.items())}
    try:
        fitted = sorted(a for a in vars(obj)
                        if a.endswith("_") and not a.startswith("_"))[:12]
    except Exception:
        fitted = []
    emit({"id": _current_id, "type": "objectcard",
          "title": type(obj).__name__, "subtitle": _clean(module),
          "fields": fields, "badges": fitted,
          "text": _capped(_clean(repr(obj)), 1000)})
    return True

def _try_jsonlike(obj):
    if not isinstance(obj, (dict, list, tuple)):
        return False
    try:
        r = repr(obj)
    except Exception:
        r = ""
    if len(r) <= 120:
        return False

    def convert(o, depth):
        if depth > 6:
            return "…"
        if isinstance(o, dict):
            out = {}
            for i, (k, v) in enumerate(o.items()):
                if i >= 100:
                    out["…"] = "+%d more" % (len(o) - 100)
                    break
                out[_clean(str(k))[:80]] = convert(v, depth + 1)
            return out
        if isinstance(o, (list, tuple)):
            res = [convert(v, depth + 1) for v in list(o)[:100]]
            if len(o) > 100:
                res.append("… +%d more" % (len(o) - 100))
            return res
        if o is None or isinstance(o, bool):
            return o
        if isinstance(o, int):
            return o if abs(o) < 2**53 else str(o)
        if isinstance(o, float):
            return o if math.isfinite(o) else str(o)
        if isinstance(o, str):
            return _clean(o[:300])
        return _clean(repr(o))[:200]

    emit({"id": _current_id, "type": "jsontree", "data": convert(obj, 0),
          "summary": "%s · %d items" % (type(obj).__name__, len(obj)),
          "text": _capped(_clean(r), 2000)})
    return True

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
    if kind == "ndarray":
        return {"text/plain": payload["text"], "application/json": payload,
                "application/vnd.quanta.ndarray+json": payload}
    if kind == "objectcard":
        card = {k: message[k] for k in ("title", "subtitle", "fields", "badges", "text")}
        return {"text/plain": card["text"], "application/json": card,
                "application/vnd.quanta.objectcard+json": card}
    if kind == "jsontree":
        return {"text/plain": message["text"], "application/json": message["data"]}
    return None

def emit_result(obj, name_hint):
    payload = dataframe_payload(obj, name=name_hint, max_cols=40, head_tail=True)
    if payload is not None:
        emit({"id": _current_id, "type": "dataframe", "payload": payload})
        return
    if _is_matplotlib_result(obj):
        return
    if _try_plotly(obj):
        return
    if _try_rich_repr(obj):
        return
    if _try_ndarray(obj):
        return
    if _try_model_card(obj):
        return
    if _try_jsonlike(obj):
        return
    try:
        r = repr(obj)
    except Exception as e:
        r = "<repr failed: %s>" % e
    r = _clean(r)
    r = _capped(r, MAX_REPR_CHARS)
    emit({"id": _current_id, "type": "result", "text": r})

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
    tb = e.__traceback__
    this = os.path.abspath(__file__)
    while tb is not None and os.path.abspath(tb.tb_frame.f_code.co_filename) == this:
        tb = tb.tb_next
    return _clean("".join(traceback.format_exception(type(e), e, tb)))

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

_NOTEBOOK_COMMAND = re.compile(
    r"^[ \t]*(?:[A-Za-z_]\w*(?:[ \t]*,[ \t]*[A-Za-z_]\w*)*[ \t]*=[ \t]*)?(%{1,2}[A-Za-z_]\w*|!!?)"
)
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
    try:
        return ast.parse("".join(lines), filename=filename)
    except SyntaxError as error:
        for i, line in enumerate(lines):
            command = _NOTEBOOK_COMMAND.match(line)
            if command is None or i + 1 in protected or i + 1 != error.lineno:
                continue
            name = command.group(1)
            if name == "%pip" or name == "%conda":
                advice = "Install packages in the selected environment using the terminal."
            elif name.startswith("!"):
                advice = "Run shell commands in the terminal or use Python's subprocess module."
            elif name == "%matplotlib":
                advice = "Quanta supports inline plots; use %matplotlib inline or ordinary matplotlib code."
            else:
                advice = "Use ordinary Python, or run this notebook with an IPython kernel in Jupyter."
            raise UnsupportedNotebookCommand(
                f"{name} is not supported by Quanta's Python runner. {advice}",
                (filename, i + 1, command.start(1) + 1, line),
            ) from None
        raise


def run_code(msg):
    global _current_id, _exec_count, _stream_budget, _interruptible
    _current_id = msg.get("id")
    _stream_budget = MAX_STREAM_BYTES
    code = msg.get("code", "")
    _exec_count += 1

    filename = msg.get("filename") or f"<cell {_exec_count}>"
    status = "ok"
    had_file = "__file__" in user_ns
    old_file = user_ns.get("__file__")
    if msg.get("filename"):
        user_ns["__file__"] = msg["filename"]

    linecache.cache[filename] = (len(code), None, code.splitlines(True), filename)
    compiling = True
    try:
        tree = _parse_notebook_code(code, filename)
        result_name = None
        last_expr = None
        if tree.body and isinstance(tree.body[-1], ast.Expr):
            expr_node = tree.body.pop()
            if isinstance(expr_node.value, ast.Name):
                result_name = expr_node.value.id
            last_expr = ast.Expression(expr_node.value)
            ast.fix_missing_locations(last_expr)
        result = None
        has_result = False
        compiled = compile(tree, filename, "exec") if tree.body else None
        compiled_expr = compile(last_expr, filename, "eval") if last_expr is not None else None
        compiling = False
        _interruptible = True
        try:
            if compiled is not None:
                exec(compiled, user_ns)
            if compiled_expr is not None:
                result = eval(compiled_expr, user_ns)
                has_result = result is not None
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
        try:
            emit_figures()
        except Exception:
            pass
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
                    "shape": shape, "is_dataframe": is_df})
    out.sort(key=lambda d: d["name"].lower())
    return out[:400]

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
        if type(value) not in (dict, list, tuple):
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

def handle_df(msg):
    name = msg.get("name", "")
    val = user_ns.get(name)
    if val is None:
        emit({"id": msg.get("id"), "type": "df_error",
              "error": "'%s' is not defined in the kernel" % name})
        return
    query = msg.get("filter", "")
    sort_column = msg.get("sort_column")
    if query or sort_column is not None:
        try:
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
            val = frame
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

def handle_complete(msg):
    import builtins
    import keyword

    mid = msg.get("id")
    code = msg.get("code") or ""
    cursor = _utf16_to_index(code, int(msg.get("cursor") or 0))
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
    result = {}
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
    emit({
        "type": "ready",
        "python_version": sys.version.split()[0],
        "executable": sys.executable,
        "cwd": os.getcwd(),
        "features": _features(),
        "plotly_js": _plotly_js_path(),
    })
    while True:
        line = _protocol_in.readline()
        if not line:
            break
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except Exception:
            continue
        if not isinstance(msg, dict):
            continue
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
            elif op == "shutdown":
                break
        except Exception:
            _handle_internal_error(op, msg)

if __name__ == "__main__":
    main()
