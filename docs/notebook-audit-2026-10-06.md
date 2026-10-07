# Notebook and app audit — October 6, 2026

The later [interaction and output polish](interaction-polish-2026-10-06.md)
adds panel/state retention, more layout improvements, output reading refinements,
and a Settings toggle for enhanced versus text data outputs. Its verification
supersedes the test counts below.

This audit started with a clean worktree and 369 passing native tests. It addressed
the reported red `\mbox` command, Markdown editing, notebook resizing and window
zoom, closing/reopening file tabs, Copilot, exported documents, and code-cell outputs.
It also reviewed existing regression coverage for kernel execution, saving,
diagnostics, data tables, Git, terminals, workspace trust, and process cancellation.

The changes are in the source tree. A Release build is available after verification;
an already-running copy of Quanta must be restarted to load the new code. No user
notebook was rewritten, account was signed in, or running app was forcibly relaunched.
The screenshot's equation was recreated because the original notebook was not supplied.

## What changes for a user

| Experience | Before | After |
| --- | --- | --- |
| Textbook matrix sums | `\mbox` appeared as a red unknown command and its text was italicized. | The command renders its text labels correctly in preview, HTML, and PDF. |
| Multiline mathematics | Joining lines could let a TeX `%` comment consume the next line. Some whitespace and bare display environments were missed. | Line breaks survive; backslash delimiters accept surrounding spaces; common display environments and `displaymath` render. |
| Wide equations | Equations could overflow the native cell or be cropped in PDF. | Native display equations scroll horizontally and remain centered when they fit. HTML has horizontal overflow; PDF scales display mathematics to the available width. |
| Editing Markdown cells | Python coloring and completion behavior did not match Markdown source. | Headings, emphasis, links, code, math, and TeX commands have Markdown colors. Python fences have Python colors. Python popups and colon indentation no longer interfere. |
| Reopening a closed file | Clicking an already-selected sidebar row could do nothing. | A file-row click opens the file even when the selection has not changed. Keyboard selection still opens a file. |
| Resizing or zooming a notebook window | A burst of viewport notifications repeated layout work and retained old offscreen height estimates. | Notifications coalesce into one queued layout using the latest bounds. Offscreen heights are invalidated when width changes. |
| Large outputs | Large final-expression text and expanded JSON containers could create excessive native view work. Invalid sparkline numbers could reach drawing geometry. | Text preview and JSON children are bounded. Sparklines sample at most 512 finite-safe points. Full saved text remains available for copy/export. |
| Copilot in Markdown | Only code cells were connected to Copilot. | An active Markdown cell uses its own virtual Markdown document. Code-cell context and existing stale-reply protections remain in place. |
| Printed colors | ANSI formatting was stripped during serialization and disappeared from exports. | Basic, 256-color, and RGB foreground colors plus bold survive save/reopen and export. |
| Rich text output | `_repr_latex_` depended on matplotlib image rendering, and Markdown MIME output was not recognized. | LaTeX and Markdown MIME output render using the native notebook renderers without matplotlib. |
| Exporting arrays and model cards | Their useful native presentation became plain text. | Arrays export shape, dtype, statistics, sparkline/heatmap, and source text. Model cards export title, subtitle, badges, fields, and source text. |
| Multipage PDF | Continuation table pages lacked headings; an output card could split unnecessarily. | Table headings repeat. Cards stay together when they fit. Python cell and fence syntax colors survive export. |
| Git and Python environment operations | Higher-priority command workers waited on default-priority output readers, producing thread-priority warnings. | Output readers use the same user-initiated priority as their command workers. |

## Code-cell output assessment

| Output | Assessment |
| --- | --- |
| Ordinary values and printed text | Existing text selection, copy, save/reopen, output ordering, batching, and output budgets were sound in the covered tests. Added a final-expression preview cap and retained stream colors. |
| Tracebacks | Existing native error presentation and preserved traceback text passed regressions. |
| pandas tables | Existing native table snapshots, bounded previews, copying, sorting/filtering, and saved HTML were already useful. Repeated PDF headings improve long table exports. Saved previews remain bounded snapshots rather than complete datasets. |
| NumPy arrays | Existing shape/dtype/statistics and sparkline/heatmap views were useful. Fixed invalid/extreme sparkline geometry and added structured exports. |
| JSON trees | Existing expandable structure was useful. Added a 300-child preview limit per expanded container; full saved JSON remains intact. |
| Model/object cards | Existing native cards were useful. Added structured HTML/PDF cards and kept fitting cards together on PDF pages. |
| Images and matplotlib figures | Existing image save/reopen and export coverage passed. The optional matplotlib package was absent, so live matplotlib bridge tests were skipped in this environment. |
| Plotly | Existing offline interactive rendering, saved MIME data, and PDF render-readiness tests passed. Exported HTML is interactive; PDF is a static figure. |
| HTML and SVG | Existing sanitization, blocked remote resources, and MIME preservation passed coverage. Arbitrary scripts, styles, and widget communication remain deliberately unsupported. |
| LaTeX and Markdown MIME | Newly supported native rendering and export; explicit `display()` and implicit final results keep their distinct notebook output types. |
| Unknown Jupyter MIME output | Existing fallback warns that it cannot render the MIME type and preserves the original bundle on save. |

## What was already sound

Copilot already used GitHub's official native helper, a pinned version and checked
download, opt-in account/project controls, UTF-16 positions, bounded context,
versioned synchronization, stale-reply rejection, and completion acceptance as a
single undoable edit. Markdown now uses the correct document language. Protocol,
transport, authentication-state, and ghost-text behavior are covered by mocks;
this audit did not validate a live signed-in cloud suggestion.

Notebook virtualization already kept only nearby cells realized and retained editor
focus/undo state. Output transport was already batched. The audit refined resize
handling and large output presentation rather than replacing those mechanisms.

HTML/PDF already escaped code, preserved full saved text, embedded images, rendered
math offline, and awaited Plotly readiness. The existing multipage export regression
includes a long table, hundreds of output lines, math, and a completed Plotly figure.

## Verification

- `./scripts/quanta test`: 382 native tests pass, including 13 new audit regressions.
- `./scripts/quanta build --release`: optimized app builds successfully.
- `python3 scripts/test-kernel-interactive.py`: 21 tests, 2 optional-dependency skips.
- `python3 scripts/test-ui-workflows.py`: 32 tests, 3 optional-dependency skips.
- Standard-library-only runs using `/usr/bin/python3 -S` also passed: 21 tests with
  3 skips and 32 tests with 11 skips, respectively.
- The audit export was loaded in WKWebView, checked for 68 MathML equations,
  65 table rows, syntax-color spans, and saved output content, then exported to PDF.
- All four PDF pages were rendered with Poppler and inspected visually. The final
  equation marker remains within Letter margins, continuation tables retain their
  headings and all rows, Python colors survive, and the model card occupies one page.
- A native 400-cell notebook was resized through six widths and zoomed twice;
  realized views stayed below 80 and their geometry remained valid.
- The Git/environment output-reader change removed the thread-priority warnings
  observed in the earlier test diagnostics. The completed test result reported no
  runtime warnings.
- `git diff --check` passed.

Resize timing samples included a deliberate 30 ms settling interval and concurrent
test workload. They are useful smoke checks, not an end-to-end performance benchmark.
No Instruments trace or long-session memory profile was captured. Calling native
`NSWindow.zoom` is covered; the physical toolbar double-click gesture and its
macOS preference were not manually verified in the user's running app.

Scratch preview images, HTML, PDF, and rendered pages are under the ignored
`.build/notebook-audit/` directory.

## Remaining limitations

The reported `\mbox` defect and the additional math parsing/layout defects found in
this audit are fixed. Universal LaTeX compatibility is not achieved: Quanta uses
KaTeX/MathML, not a full LaTeX compiler. Cross-equation `\label`/`\eqref`, `multline`,
TikZ, external packages, and macro definitions shared between separate equations
remain unsupported. Local macro definitions and manual tags are covered. Very large
native equations exceeding the 2200 × 500 rendering bounds fall back to source;
very long equations scaled into PDF can become small and are better written as
several aligned lines. Unsupported or malformed TeX remains visibly reported.
See the [KaTeX support table](https://katex.org/docs/support_table.html).

Markdown remains a custom subset: nested lists, ordered-list preview, and block
quotes need further work. Fenced syntax colors currently cover Python; other fence
languages remain plain text. Standalone files opened as scripts still use Python
editor tooling; the new Markdown language handling applies to notebook cells.

ANSI background colors and other terminal effects are not reproduced. DataFrame,
array, and JSON snapshots retain the kernel's existing preview/size/depth bounds.
PDF is static, US Letter, and limited to 500 pages and 35 seconds. Very large
output cards can still split when they cannot fit on one page.

Quanta's Python bridge still does not implement interactive Jupyter widgets,
`display_id`/`update_display`, `input()`, most IPython magics, or arbitrary display
keyword arguments. These are compatibility gaps, separate from the fixed output
rendering defects. The [compatibility guide](notebook-compatibility.md) lists them.

Copilot previews are intentionally limited to insertions at line ends and up to
eight visible lines at the end of a cell/script. Full project semantic completion,
definition navigation, references, and rename are not implemented. Live account
access and the quality of GitHub's generated suggestions were not tested.

The passing suites and visual checks provide regression evidence for the audited
paths. They do not certify that every possible UI interaction or notebook is bug-free.
