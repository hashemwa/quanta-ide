# Notebook compatibility

Quanta reads and writes Jupyter notebook format 4 and runs Python using its own
standard-library bridge. It does not run an IPython or Jupyter kernel.

| Operation | Current behavior |
| --- | --- |
| Ordinary Python, imports, final expressions | Supported in the shared Python session. Packages must be installed in the selected interpreter. |
| Local project imports | Notebook imports search the current working directory, including after `os.chdir()`. Running a script temporarily adds its containing folder to the import path and restores the path afterward, including on errors. |
| `__future__` imports | Compiler settings persist across executions in the shared session. |
| Trailing semicolon | Suppresses the implicit final-expression result. The expression still executes, and explicit prints and figures remain visible. |
| Top-level `await`, `async for`, `async with` | Supported with a reusable event loop. The loop advances during async cells, not while waiting for the next cell. Ordinary synchronous cells can still use `asyncio.run()`. |
| `display(value, ...)` | Built in; emits explicit rich or text outputs in order, without changing the implicit-result variable `_`. Explicit outputs save as `display_data`. |
| `clear_output(wait=False)` | Built in; clears the current execution's output immediately. `wait=True` keeps it visible until replacement output arrives. Console clearing preserves other commands' history. |
| `%matplotlib inline` | Accepted because Quanta already captures inline figures. The line is blanked without changing traceback line numbers. |
| Other `%matplotlib` modes | Rejected with an explanation; use inline plotting. |
| `%config`, `%precision`, `%pylab`, `%gui`, `%automagic` | Rejected rather than silently ignored. Replace them with explicit Python configuration or imports. |
| `%time`, `%timeit`, other line magics and `%%` cell magics | Unsupported. Use ordinary Python or an IPython kernel in Jupyter. |
| `%pip`, `%conda` | Unsupported. Use **Run → Python Environment…** to install named packages in the selected interpreter, or use its terminal command. |
| `!command`, `!!command`, shell or magic assignments | Unsupported. Use the terminal or Python's `subprocess` module. |
| `input()` | Raises an explicit unsupported-operation error. Assign parameters in code instead. |
| Interactive Jupyter widgets | Not supported by the current bridge. |
| Imported rich output dictionaries | Preserved on save, even when Quanta cannot display a representation. |
| HTML, SVG, JPEG and JSON | MIME bundles survive save/reopen. HTML and SVG use a script-disabled renderer; remote resources and navigation are blocked. |
| LaTeX and Markdown rich outputs | `text/latex` and `text/markdown` render natively and survive save/reopen. Markdown output images resolve relative to the notebook folder and are embedded in HTML/PDF exports. `_repr_latex_()` and `_repr_markdown_()` work without matplotlib. Higher-priority HTML, images, SVG, and Plotly representations retain precedence. |
| DataFrames | Save an HTML table preview, text fallback, and a native snapshot. Reopened snapshots do not query a variable in the current kernel. |
| Plotly | Save structured Plotly JSON plus an available PNG fallback. Reopen interactively using a bundled offline renderer. |
| Arrays, JSON trees and model cards | Save structured snapshots and text fallbacks; array/card snapshots retain their native views. HTML/PDF exports include array statistics and sparklines/heatmaps, and model-card badges and fields. Expanded JSON containers preview at most 300 children; saved data and exports retain the full saved representation. |
| Enhanced/text data output choice | Settings → General → Notebook Outputs defaults to enhanced views. Turning it off immediately shows saved data outputs as text and makes new Python data results skip custom previews. HTML/PDF use this choice. Switching back restores saved previews; text-only results need rerunning to create previews. Images, plots, HTML and equations retain their formatting. |
| Markdown previews | Native text wraps to the cell width. Basic HTML formatting, character entities and text alignment are supported; arbitrary HTML attributes and scripts are not. `$...$`, `$$...$$`, `\(...\)` and `\[...\]` equations use the bundled offline MathML renderer without a Python kernel. Inline equations also render in headings and tables. Code spans and fenced code keep math literal; table parsing preserves escaped pipes and pipes inside code or equations. Tables require a Markdown separator row. |
| HTML export | Markdown tables, offline MathML equations, syntax-colored Python cells/fences, ANSI-colored streams, full saved text outputs, structured array/model cards, and sanitized rich HTML. SVG/JPEG images are embedded. Plotly embeds an offline renderer in an isolated frame and can substantially increase file size. |
| PDF export | Paginated US Letter pages with margins, wrapped code/text, syntax colors, tables, equations, embedded images, and rendered Plotly figures. Table headings repeat on continuation pages. Wide display equations scale to the page. Output cards stay together when they fit on a page. Figures finish rendering before capture; exports are limited to 500 pages and 35 seconds. |

Recognized unsupported commands fail the entire cell before any Python statements in
it execute. Subsequent cells can still run. Text inside Python strings is preserved,
and ordinary Python syntax errors retain their normal diagnostics.

Quanta's `display` and `clear_output` helpers are already available in each cell.
Rich objects such as `from IPython.display import HTML` work with the built-in
`display`. Importing IPython's own `display` or `clear_output` replaces Quanta's helper
and uses IPython's ordinary-Python fallback. `display_id`, `update_display`, arbitrary
display keyword arguments, and widget communication are not supported.

Async interrupts cancel the running cell and allow cooperative cleanup. Tasks that
ignore cancellation may require a kernel restart. Background tasks do not continue
running between cells.

The terminal is a separate shell session. Its active Python environment can differ
from the notebook interpreter; use the interpreter path shown in Quanta's menu when
installing packages, for example `/path/to/python -m pip install package`.

Printed output is batched in bounded chunks and flushed while execution continues.
Explicit flushes, transitions between stdout and stderr, and subsequent results or
errors flush preceding text. The existing per-execution output cap still applies.
The stream flusher sleeps when no text is pending.
ANSI foreground colors and bold text survive save/reopen and HTML/PDF export,
including 256-color and RGB foreground sequences. ANSI backgrounds and other
terminal effects are not reproduced. Very large text results have a bounded native
preview; copying and exporting retain their full saved text.

Markdown remains a custom subset rather than a complete CommonMark implementation.
Nested lists, ordered lists, and block quotes need further work. Unsupported TeX is
shown as an error or source fallback. Editing equations or changing appearance
invalidates their old render requests; transient renderer failures can be retried.
The shared renderer supports `\mbox{...}` through a `\text{...}` compatibility macro
and recognizes `displaymath` as an unnumbered equation. Display blocks preserve
line breaks so TeX `%` comments cannot swallow the following line. Backslash math
delimiters allow surrounding whitespace; single-dollar delimiters keep their
currency heuristics. Common bare display environments are recognized, wide display
equations scroll horizontally, and Python fences have syntax colors.
Comments after a display environment's closing line leave the next paragraph
separate. Windows line endings are supported in Markdown fences, equations, and
tables; Python fence metadata does not disable edit-mode syntax colors.
This is KaTeX math rather than a full LaTeX document engine: cross-equation
`\label`/`\eqref`, `multline`, TikZ, external packages, and macro definitions shared
between separate equations remain unsupported. Very large native equations
exceeding the renderer's bounds fall back to visible source.

Rich output is a saved presentation, not a full dataset backup. DataFrames retain the
bounded rows/columns shown in their preview; array and JSON-tree snapshots retain the
bridge's existing size/depth limits. Unknown imported MIME types remain intact. Generic
HTML scripts and Jupyter widget communication are not enabled by workspace trust.

Array previews identify sampled/relative values and expose saved text. Large JSON
roots start collapsed. Model cards show 12 parameters initially; expanding shows
up to 300, while saved fields remain intact for export. Model badges identify learned
attribute names rather than certifying that fitting completed successfully.

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
