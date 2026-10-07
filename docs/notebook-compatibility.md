# Notebook compatibility

Quanta reads and writes Jupyter notebook format 4 and runs Python using its own
standard-library bridge. It does not run an IPython or Jupyter kernel.

| Operation | Current behavior |
| --- | --- |
| Ordinary Python, imports, final expressions | Supported in the shared Python session. Packages must be installed in the selected interpreter. |
| Working folder | Each saved notebook runs in its own folder, like Jupyter, so relative paths such as `pd.read_csv("data.csv")` resolve next to the notebook. A `%cd` or `os.chdir()` in a notebook is remembered for that notebook while other notebooks keep their own folders. Untitled notebooks and the console use the current folder. |
| Local project imports | Notebook imports search the current working directory, including after `os.chdir()`. Running a script temporarily adds its containing folder to the import path and restores the path afterward, including on errors. |
| `__future__` imports | Compiler settings persist across executions in the shared session. |
| Trailing semicolon | Suppresses the implicit final-expression result. The expression still executes, and explicit prints and figures remain visible. |
| Top-level `await`, `async for`, `async with` | Supported with a reusable event loop. The loop advances during async cells, not while waiting for the next cell. Ordinary synchronous cells can still use `asyncio.run()`. |
| `display(value, ...)` | Built in; emits explicit rich or text outputs in order, without changing the implicit-result variable `_`. Explicit outputs save as `display_data`. |
| `clear_output(wait=False)` | Built in; clears the current execution's output immediately. `wait=True` keeps it visible until replacement output arrives. Console clearing preserves other commands' history. |
| `%matplotlib inline` | Accepted because Quanta already captures inline figures. The line is blanked without changing traceback line numbers. |
| Other `%matplotlib` modes, `%pylab`, `%gui`, `%automagic` | Rejected before the cell runs, with an explanation; use inline plotting and explicit imports. |
| Timing and profiling | `%time`/`%%time` print CPU and wall time and return the timed expression. `%timeit`/`%%timeit` accept `-n`, `-r`, `-p`, `-q` and `-o` (returning a `TimeitResult`). `%prun`/`%%prun` print `cProfile` statistics (`-s`, `-l`, `-q`) and return nothing, or the `pstats.Stats` with `-r`. |
| Shell commands | `!command` streams output while it runs, `x = !command` and `!!command` return an `SList` of lines (`.s`, `.n`, `.grep()`, `.fields()`), and `{expression}`/`$name` expand Python values (`$$` and `{{ }}` escape). Commands run in the notebook's current folder with the kernel's interpreter folder first on `PATH`. Interrupting stops the command's process group. `_exit_code` holds the last exit status. |
| Packages | `%pip` runs `pip` for the kernel's interpreter; `%conda`/`%mamba` install into the kernel's prefix with `--yes`. Restart the kernel after upgrading packages that were already imported. |
| Cell scripts | `%%bash`, `%%sh`, `%%zsh`, `%%python`, `%%perl`, `%%ruby` and `%%script program` run the cell body with separate stdout/stderr; a non-zero exit fails the cell unless `--no-raise-error` is given. |
| Files and folders | `%cd` (`-q`, `-`), `%pwd`, `%ls`, `%ll`, `%cat`, `%cp`, `%mv`, `%rm`, `%mkdir`, `%rmdir`, and `%%writefile` (`-a`). |
| Namespace and environment | `%who`, `%whos`, `%who_ls`, `%reset -f`, `%reset_selective -f`, `%xdel`, `%env`, `%set_env`, `%precision`, `%run` (`-i`, `-n`, `-t`, `-m`, and `.ipynb` files), `%%capture` (streams, displays and figures, with `.show()`), `%%html`, `%%markdown`, `%%latex`, `%%svg`, `%lsmagic`. `%config` accepts `InlineBackend` and `Completer` settings without effect and warns about others. |
| Reloading edited modules | `%load_ext autoreload` with `%autoreload 2` (or `all`/`1`/`explicit`/`0`/`off`/`now`) and `%aimport` reload changed workspace modules before each cell, updating existing functions and classes in place. Standard-library and site-packages modules are not reloaded. |
| Help | `obj?`, `?obj`, `obj??`, `%pinfo` and `%pinfo2` print the signature, type, file and docstring (or source with `??`) as cell output. |
| `get_ipython()` | Returns a small compatible shell with `run_line_magic`, `run_cell_magic`, `system`, `getoutput`, `magic`, `ev`, `ex`, `push` and `register_magic_function`, so scripts converted by `nbconvert` run unchanged. `%load_ext` calls an extension's `load_ipython_extension`; extensions that need IPython's magic classes report that they are unsupported. `%load_ext dotenv` and `%dotenv` use python-dotenv when it is installed. |
| Unknown magics | Rejected before any statement in the cell runs. |
| `input()`, `getpass.getpass()` | Open a sheet with the prompt; Submit continues the code and echoes the prompt and value (not passwords) into the output, Interrupt raises `KeyboardInterrupt`. Requests that arrive while the kernel waits are answered afterwards. Code run outside a Quanta window raises an explanatory `RuntimeError`. |
| Interactive Jupyter widgets | Not supported by the current bridge. |
| Imported rich output dictionaries | Preserved on save, even when Quanta cannot display a representation. |
| HTML, SVG, JPEG and JSON | MIME bundles survive save/reopen. HTML and SVG use a script-disabled renderer; remote resources and navigation are blocked. |
| LaTeX and Markdown rich outputs | `text/latex` and `text/markdown` render natively and survive save/reopen. Markdown output images resolve relative to the notebook folder and are embedded in HTML/PDF exports. `_repr_latex_()` and `_repr_markdown_()` work without matplotlib. A `text/latex` value that is one math expression renders as display math; LaTeX prose with inline `$…$` renders as Markdown text with inline math, as in Jupyter. Higher-priority HTML, images, SVG, and Plotly representations retain precedence. |
| DataFrames | Save an HTML table preview, text fallback, and a native snapshot. Reopened snapshots do not query a variable in the current kernel. |
| Plotly | Save structured Plotly JSON plus an available PNG fallback. Reopen interactively using a bundled offline renderer. |
| Arrays, JSON trees and model cards | Save structured snapshots and text fallbacks; array/card snapshots retain their native views. HTML/PDF exports include array statistics and sparklines/heatmaps, and model-card badges and fields. Expanded JSON containers preview at most 300 children; saved data and exports retain the full saved representation. |
| Enhanced/text data output choice | Settings → General → Notebook Outputs defaults to enhanced views. Turning it off immediately shows saved data outputs as text and makes new Python data results skip custom previews. HTML/PDF use this choice. Switching back restores saved previews; text-only results need rerunning to create previews. Images, plots, HTML and equations retain their formatting. |
| Markdown previews | Native text wraps to the cell width. Basic HTML formatting, character entities and text alignment are supported; arbitrary HTML attributes and scripts are not. `$...$`, `$$...$$`, `\(...\)` and `\[...\]` equations use the bundled offline MathML renderer without a Python kernel. Inline equations also render in headings and tables. Code spans and fenced code keep math literal; table parsing preserves escaped pipes and pipes inside code or equations. Tables require a Markdown separator row. |
| HTML export | Markdown tables, offline MathML equations, syntax-colored Python cells/fences, ANSI-colored streams, full saved text outputs, structured array/model cards, and sanitized rich HTML. SVG/JPEG images are embedded. Plotly embeds an offline renderer in an isolated frame and can substantially increase file size. |
| PDF export | Paginated US Letter pages with margins, wrapped code/text, syntax colors, tables, equations, embedded images, and rendered Plotly figures. Table headings repeat on continuation pages. Wide display equations scale to the page. Output cards stay together when they fit on a page. Figures finish rendering before capture; exports are limited to 500 pages and 35 seconds. |

IPython syntax is only rewritten when a cell is not valid Python, and only at the
start of a statement, so text inside strings, bracketed continuations and ordinary
modulo expressions is never changed. Rewritten lines keep their line numbers, so
tracebacks point at the original cell. Unsupported commands fail the entire cell
before any Python statements in it execute; subsequent cells can still run.

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
Bulleted (`-`, `*`, `+`), numbered and task lists nest by indentation and continue
across wrapped lines; block quotes, thematic breaks (`---`, `***`), setext headings
and hard line breaks (two trailing spaces or a trailing backslash) render natively
and in HTML/PDF export. Reference-style links, footnotes and indented code blocks
are not supported. Unsupported TeX is
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
