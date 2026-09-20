# Notebook compatibility

Quanta reads and writes Jupyter notebook format 4 and runs Python using its own
standard-library bridge. It does not run an IPython or Jupyter kernel.

| Operation | Current behavior |
| --- | --- |
| Ordinary Python, imports, final expressions | Supported in the shared Python session. Packages must be installed in the selected interpreter. |
| `%matplotlib inline` | Accepted because Quanta already captures inline figures. The line is blanked without changing traceback line numbers. |
| Other `%matplotlib` modes | Rejected with an explanation; use inline plotting. |
| `%config`, `%precision`, `%pylab`, `%gui`, `%automagic` | Rejected rather than silently ignored. Replace them with explicit Python configuration or imports. |
| `%time`, `%timeit`, other line magics and `%%` cell magics | Unsupported. Use ordinary Python or an IPython kernel in Jupyter. |
| `%pip`, `%conda` | Unsupported. Install packages from the terminal in the selected environment. |
| `!command`, `!!command`, shell or magic assignments | Unsupported. Use the terminal or Python's `subprocess` module. |
| `input()` | Raises an explicit unsupported-operation error. Assign parameters in code instead. |
| Interactive Jupyter widgets | Not supported by the current bridge. |
| Imported rich output dictionaries | Preserved on save, even when Quanta cannot display a representation. |
| HTML, SVG, JPEG and JSON | MIME bundles survive save/reopen. HTML and SVG use a script-disabled renderer; remote resources and navigation are blocked. |
| DataFrames | Save an HTML table preview, text fallback, and a native snapshot. Reopened snapshots do not query a variable in the current kernel. |
| Plotly | Save structured Plotly JSON plus an available PNG fallback. Reopen interactively using a bundled offline renderer. |
| Arrays, JSON trees and model cards | Save structured snapshots and text fallbacks; array/card snapshots retain their native views. |
| HTML export | Markdown tables, offline MathML equations, full text outputs, and sanitized rich HTML. SVG/JPEG images are embedded. Plotly embeds an offline renderer in an isolated frame and can substantially increase file size. |
| PDF export | Paginated US Letter pages with margins, wrapped code/text, tables, equations, embedded images, and rendered Plotly figures. Figures finish rendering before capture; exports are limited to 500 pages and 35 seconds. |

Recognized unsupported commands fail the entire cell before any Python statements in
it execute. Subsequent cells can still run. Text inside Python strings is preserved,
and ordinary Python syntax errors retain their normal diagnostics.

The terminal is a separate shell session. Its active Python environment can differ
from the notebook interpreter; use the interpreter path shown in Quanta's menu when
installing packages, for example `/path/to/python -m pip install package`.

Rich output is a saved presentation, not a full dataset backup. DataFrames retain the
bounded rows/columns shown in their preview; array and JSON-tree snapshots retain the
bridge's existing size/depth limits. Unknown imported MIME types remain intact. Generic
HTML scripts and Jupyter widget communication are not enabled by workspace trust.

New DataFrame snapshots also retain original string representations for copying,
separately from shortened display previews. These are bounded to 1 MB per value and
4 MB per page. Older snapshots and values over the limit cannot supply original
values; Quanta never substitutes a truncated preview for an original. These strings
are copyable representations, not typed Python object serialization.

Exported rich HTML uses a conservative allowlist of text, tables, lists, links, and
embedded images. Custom styles, scripts, forms, remote images, and embedded frames
are removed. Markdown equations are converted to MathML using bundled KaTeX without
network access. Unsupported TeX remains visible as an error or source fallback.

JupyterLab can display saved DataFrame HTML and generic HTML directly. Interactive
Plotly JSON requires its Plotly renderer extension; Quanta includes its own renderer.

Output dictionaries follow the [Jupyter MIME-bundle format](https://nbformat.readthedocs.io/en/5.5.0/format_description.html).
Plotly's saved JSON is rendered with application-owned code; saved HTML is never treated
as an executable Plotly document.
