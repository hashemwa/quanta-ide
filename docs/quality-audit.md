# Quality audit — October 5–7, 2026

## October 7 staged-change review

Reviewed the complete staged source, tests, tooling, and documentation. The review
added these corrections:

- Exact source comparisons preserve Unicode edits that look identical but use
  different characters. Highlight caches cannot reuse ranges from a different
  representation, saved scripts and cells retain the edit, old output becomes
  stale, and formatting/completion replies cannot apply to the wrong source.
- Windows line endings no longer keep Markdown fences, equations, or tables open.
  Comments after a TeX environment's closing line no longer absorb following
  paragraphs. Python fences with additional metadata retain their edit colors.
- Markdown rich outputs resolve local images relative to the notebook in both
  native preview and HTML/PDF export. Printed Markdown code fences no longer
  inherit the extra indentation reserved for code-cell prompts.
- Export reuses the array heatmap cache and generates static rich HTML once.
  The variables list retains its native local selection binding while mirroring
  persistent inspector selection in both directions.
- The Release test command enables testability only for test builds, fixing its
  previously failing test-module import without changing normal Release builds.

Verification: all 400 native tests passed in Release with no recorded runtime
warnings; the regular Release build passed. Both Python suites passed (58 tests,
including five skips for optional packages). Regression checks include native
editor changes and undo, saved Unicode source, inspector selection after resize,
relative-image snapshots, and PDF code placement.

This review does not resolve the previously recorded native window-resize hitches
or missing SwiftUI instrument events. KaTeX remains a math renderer rather than a
complete LaTeX document compiler; the limits in
[notebook compatibility](notebook-compatibility.md) still apply.

## Earlier audit history

The later [October 6 notebook and app audit](notebook-audit-2026-10-06.md) records
Markdown editing, Copilot Markdown support, export layout, navigation, and
performance fixes, with current verification and remaining limitations.
The subsequent [interaction and output polish](interaction-polish-2026-10-06.md)
covers retained panels, keyboard focus, layout caching, and the enhanced/text output setting.
The [panel layout repair](panel-layout-repair-2026-10-06.md) records the user's
subsequent regression report and reverts panel retention. The later
[performance research](performance-research-2026-10-06.md) restores animations and
records a measured Python lexer improvement and remaining profiling targets.
The [user-supplied Instruments trace audit](instruments-trace-audit-2026-10-06.md)
identifies Release-build resize-associated frame hitches and their layout-heavy
CPU stacks.

This pass reviewed execution, output transport, native notebook rendering, Markdown
and LaTeX, existing editor and data tooling, and readiness for daily data science work.
It started from a clean worktree with all 221 native tests passing. The changes below
are implemented; the roadmap lists remaining work.

## Findings fixed

- **Local imports failed.** The Python bridge started with its resource folder on
  the import path. A notebook could not import a helper module from its workspace.
  Imports now follow the working directory, including after `os.chdir()`. Script
  runs temporarily add their containing directory and restore it after success or
  failure, so sibling imports also work.
- **Compiler settings disappeared between cells.** A `__future__` import now
  persists in subsequent compilations through Python's standard-library compiler
  state, matching the interactive behavior described by
  [Python's codeop documentation](https://docs.python.org/3/library/codeop.html).
- **Semicolons did not suppress results.** A trailing semicolon now suppresses
  the implicit result while preserving execution, prints, and figures. Tokenization
  distinguishes a real terminator from semicolons in strings and comments.
- **Print-heavy cells flooded the app with messages.** Streams now batch small
  writes, flush pending text during a running cell, honor explicit flushes, and
  preserve stdout/stderr order. One shared lock protects the output budget and
  buffered writers. The background flusher waits for actual output while idle.
- **Markdown consumed code as math.** Inline code now protects dollar signs,
  images, and HTML literally. Matching backtick-run lengths and tilde fences keep
  embedded fences inside code. Preview and export share inline parsing. These
  fence and code-span rules follow the
  [CommonMark specification](https://spec.commonmark.org/spec).
- **Math damaged nearby prose and tables.** Ordinary currency remains literal,
  escaped dollars within TeX retain their escape, and backslash equation delimiters
  work. Pipes inside math, code, and escaped table values no longer create extra
  columns. A math block after a table ends that table's rows. Spaces and emphasis
  survive across inline equations and code in the native preview.
- **Equations went stale.** Changes to source or appearance now issue a new render
  request. Late callbacks cannot replace the newer image, including after a renderer
  timeout. Headings and table cells now use the equation renderer. The image cache
  has a 400-entry limit and a 32 MiB estimated-cost limit; transient failures are
  no longer cached permanently.

## Measured output improvement

The same `for i in range(20000): print(i)` cell was run five times before and after
the changes with `/usr/bin/python3 -S`. Every run retained identical output text.
Timing includes Python startup and collecting the protocol output.

| Measurement | Before | After |
| --- | ---: | ---: |
| Stream messages | 20,000 | 14 |
| Protocol bytes | 1,429,292 | 130,202 |
| Median elapsed time | 0.121 s | 0.057 s |

This measures bridge transport overhead, not live scrolling or end-to-end IDE speed.
An Instruments trace and a long-session memory measurement were not captured.

## Native IDE additions

The implementation follow-up adds these everyday workflows without replacing the
SwiftUI/AppKit interface:

- Background syntax checks in a separate selected-Python process, native diagnostic
  underlines, and a clickable Problems panel. Checks are debounced, bounded, and
  discard stale results after edits or interpreter changes.
- Optional Ruff lint checks and undoable formatting for the active script or code
  cell. Notebook cells are checked together with cell-relative locations; syntax
  checks still validate each cell independently. Formatting cannot overwrite edits
  made while its subprocess is running. Ruff is installed only on explicit request.
- Source-name and Python built-in completion before execution, alongside existing
  live-kernel completion. This is lexical completion, not project-wide type inference.
- A native Python Environment window for package inspection, named package installs,
  and workspace `.venv` creation. It uses the selected interpreter, refuses to
  overwrite an existing `.venv`, shows failures and output, and supports cancellation.
  Code execution and session changes pause during package/environment mutations.
- Top-level async execution, built-in `display()` and `clear_output()`, cooperative
  async interrupt recovery, and correct explicit versus implicit saved output types.
  Deferred clears keep the old output visible until replacement output arrives.
  Console clears retain other commands' history.

## Copilot and crash resilience

The completion follow-up adds GitHub Copilot through its official native Apple Silicon
language server, with a SwiftUI popover on a floating editor button and AppKit ghost text. It starts disabled.
Sign-in uses GitHub's browser device flow, validates account access, and enables suggestions
afterward. Global and per-project controls stop the helper and pending work immediately;
sign-out uses a separate Quanta helper profile. The first connection installs a pinned,
SHA-256-verified helper. No Node runtime or Python environment change is required.

Completions use bounded code context, UTF-16 positions, and versioned document updates.
Notebook replies are restricted to the active code cell. Edits, selection changes, hidden
editors, input-method composition, disable actions, and account changes invalidate old
replies. Ghost text is separate from source storage; accepting it is one undoable action.
The initial renderer only shows suggestions it can display completely without obscuring
existing code, including up to eight lines at the end of a cell or script.

The broader crash review covered notebook parsing and serialization, data/table bounds,
virtualized editor lifecycle, Markdown/math/PDF rendering, SQLite and DuckDB requests,
kernel and terminal processes, and startup preferences. Concrete repairs include:

- Malformed saved dataframe dimensions and offsets can no longer overflow integer
  arithmetic; invalid rich payloads fall back to saved text while retaining original data.
- Stale or negative table and clipboard coordinates are rejected before indexing.
- Sparse, ragged array previews cannot expand into enormous bitmap allocations;
  heatmaps are bounded to 512 × 512 pixels and handle nonfinite values.
- Kernel stdout without line breaks cannot grow the app's framing buffer indefinitely.
  Oversized lines are dropped at 64 MiB and the next message can still be read.
- Stop/restart escalates stubborn kernel and terminal processes, including foreground
  terminal jobs. App termination immediately stops its owned processes.
- Nonfinite or corrupt saved window, font, console, and split dimensions cannot reach
  native view geometry. Invalid or stale notebook-find ranges and editor snippet ranges
  are checked before arithmetic, selection, or replacement.
- Copilot pipes handle fragmented messages, invalid framing, broken stdin, timeout,
  cancellation, and helper exit without terminating Quanta or accepting stale results.

No Quanta crash reports were present in the accessible local DiagnosticReports folders.
The official 1.551.2 helper was downloaded and its digest checked; an isolated, signed-out
smoke check passed version, initialization, account status, and clean shutdown. That check
used a temporary account profile and did not send user source or attempt GitHub sign-in.

### Toolbar and syntax-color follow-up

Copilot now floats at the bottom-right of the editor as a native Liquid Glass circle,
using the shared glass icon control style and arrow-cursor handling. It sits above the
bottom panel, with an inset from the editor edges, and opens the existing account and
suggestion controls. It remains available when there are no open documents. The title
toolbar keeps the Python environment, Run/Stop, and layout controls; the tab row keeps
the document tabs.

The existing syntax palette is retained with three readability adjustments. Measured
against the native notebook code well, dark comments improve from 3.29:1 to 4.91:1,
dark built-ins from 3.90:1 to 4.92:1, and light decorators from 4.10:1 to 5.07:1.
All syntax colors are checked against native script and notebook backgrounds using
[4.5:1 text contrast](https://www.w3.org/WAI/WCAG22/Understanding/contrast-minimum.html)
as a benchmark. The palette also strengthens its colors when AppKit requests increased
contrast. This is a text-readability check, not a claim of complete accessibility conformance.

The lexer now keeps `!=` expressions inside f-strings as code and treats annotated
variables named `match` or `case` as ordinary identifiers. Regressions cover these cases,
typical pandas/NumPy code, and palette contrast. No user appearance settings were changed.

## What to add next

These priorities are product recommendations based on the current implementation.
Notebook virtualization, paged pandas tables, variable inspection, native local SQL,
Git review, recovery drafts, and plot export already exist and should be retained.

| Priority | Addition | Current gap and acceptance criteria |
| --- | --- | --- |
| P0 | Optional Jupyter/IPython kernel backend | The bridge still rejects most magics, shell escapes, and `input()`, and has no widget communication. Add genuine IPython display updates, input prompts, and the kernel protocol needed by existing notebooks. Build widget support on a separate reviewed renderer. |
| P0 | Notebook session isolation | `AppState` owns one shared kernel. Two notebooks can overwrite each other's variables and interpreter context. Give each notebook an explicit session association, retain an opt-in shared session, and persist its interpreter and working directory. |
| P0 | Project-wide language tools | Syntax/Ruff diagnostics, formatting, and lexical completion now exist. Add semantic completion, go to definition, references, rename, and quick fixes across notebook cells and project files. |
| P1 | Reproducible dependencies | Environment creation and package installation now have a native UI. Add dependency/lockfile workflows, reproducible restore, private package-index configuration, and package removal. |
| P1 | Debugger | Add breakpoints in scripts and cells, stepping, stack/local inspection, and pause-on-exception. Keep debugging scoped to the selected notebook session. |
| P1 | Broader data workflows | Extend the live inspector beyond pandas to Polars/Arrow and add export of a complete filtered result. Existing data export operates on the current page. Keep pagination and cancellation for large results. |
| P1 | Complete Markdown behavior | The custom parser still needs ordered/nested lists, block quotes, and broader CommonMark coverage. Maintain preview/export agreement and native selection/focus behavior. |
| P1 | Performance and reliability gates | Measure typing and scrolling in 1,000-cell notebooks, repeated plot/equation edits, long output, kernel crashes and restarts, and multi-hour memory use. Include main-thread latency, resident memory, idle CPU, and output-order assertions. |
| P2 | Remote compute and durable execution history | Add reconnectable remote sessions after session identity and kernel lifecycle are reliable. Persist run provenance and environment details so results can be reproduced. |

The [Jupyter messaging specification](https://jupyter-client.readthedocs.io/en/stable/messaging.html)
provides execution, stream/display, input, control, and communication channels. A new
backend would need to implement their routing and lifecycle; switching kernels alone
does not implement widgets or debugging UI. The native SwiftUI/AppKit interface can
remain the frontend.

The current [language tools](language-intelligence.md) include native editor controls,
Python/Ruff checks, and optional Copilot suggestions. Semantic navigation and refactoring
still need a separate analysis backend. For example,
[Ruff's native server](https://docs.astral.sh/ruff/editors/) provides diagnostics,
formatting, and fixes, while a Python analysis server supplies semantic navigation
and completion through the
[Language Server Protocol](https://microsoft.github.io/language-server-protocol/).
Project-wide semantic analysis was not added in this audit.

## Verification and limits

- Native build passed with no compiler warnings or errors. Actor-isolation errors
  found during implementation were corrected before the final build and tests.
- Native suite: **369 passed**, zero failures or skips. The initial audit added
  12 regressions; the IDE follow-up added 61 more, including real cell execution,
  saved output types, formatting undo, asynchronous edit protection, background
  diagnostics, environment operations, and narrow panel layouts. The Copilot/crash
  pass added another 67 covering process transport and installation, authentication
  state and privacy controls, Unicode and notebook context, editor preview and undo,
  constrained popover layout, malformed output, process shutdown, and saved geometry.
  The toolbar/color follow-up added five lexical and contrast checks; all 366 tests
  passed after the updated native build. The final publication review added an export
  regression for paragraphs with many inline code spans and two first-use device
  authentication checks; the final integrated suite passed all 369 tests.
- Python bridge with the local scientific environment: **52 passed** across the
  workflow suite (32) and interactive-kernel suite (20). Matplotlib used temporary
  caches because the sandbox prevents writes to its usual home-directory cache.
- Python bridge with `/usr/bin/python3 -S`: **37 passed, 15 expected optional-package
  skips** across both suites.
- Real **Ruff 0.16.10** in a disposable environment: script/notebook diagnostics,
  cross-cell names, Unicode positions, future flags, configuration, formatting,
  and magic-line preservation passed, including a Swift-to-helper round trip.
- Real environment-manager smoke check with Python 3.9.6: temporary `.venv`
  creation, pip listing, an already-satisfied package install, refresh, and
  existing-environment protection passed. User Python environments were unchanged.
- `git diff --check`: passed.

The first follow-up run found narrow-tab overflow, a completion cursor-boundary
error, and test-fixture issues involving macOS path aliases and access to a helper
under the Desktop source tree. The tab strip now adapts to named icons, completion
rejects positions inside composed characters, and tests use filesystem identity and
the production bundled helper. The final full run passed without increasing timeouts.

The Copilot runs also caught a zero-width AppKit caret rectangle being mistaken for
invalid geometry, a UTF-16 boundary check that accepted half of a surrogate pair, and
an installer path calculation that mixed `/var` with `/private/var`. Those defects
were repaired. A multiline layout test now checks actual cell growth, preview
containment, unchanged inter-cell spacing, and restoration instead of assuming the
gutter has no existing free space. All 361 tests passed together after these fixes.
Xcode recorded zero build warnings/errors and zero failed/skipped native tests.
The previously noted runtime priority-inversion warning remains a profiling follow-up;
the test run did not establish a live responsiveness regression.

Authenticated Copilot suggestions were tested with deterministic protocol fixtures;
the actual GitHub sign-in, account entitlement, and cloud suggestion round trip still
need a signed-in user session. No existing credentials or user code were used in the
real helper smoke test. The app was not relaunched or installed over the user's running
copy. Code inspection and tests cannot establish that an app will never crash;
third-party native Python packages, memory exhaustion, and OS renderer failures remain
outside that guarantee.

The native suite covers rendering/export, editor focus and layout, virtualization,
execution queues, recovery, data tools, and Git behavior. The new math-state tests
exercise delayed callbacks with deterministic results; existing tests exercise the
actual WebKit equation renderer and PDF export. No manual screenshot pass, live UI
automation, VoiceOver session, or Instruments trace was performed. A passing suite
does not establish complete Jupyter or CommonMark compatibility.

---

# Previous audit — September 25, 2026

This pass combined three parallel audits with an integration review. It covered
notebook and editor interaction, execution state, workspace and Git behavior,
kernel output, local data, and clipboard interoperability. Fixes have focused
regression coverage; this is not a claim that every possible defect is eliminated.

## Findings fixed

### Notebook editing and navigation

- Showing the first output or hiding outputs rebuilt the source editor, losing
  focus and selection. Source and output updates now preserve the editor when
  its presentation has not changed.
- Undo appeared available after a cell left the viewport but operated on the old
  editor. The canvas now retains the native editor target for cells with undo or
  redo history. Cell containers and outputs remain virtualized, and unedited
  offscreen editors are released.
- Collapsed source previews could retain old text, while rendered content missed
  font-size updates. Both refresh from their current model and font settings.
- Editor lookup, Page Up/Down, and Escape could select an arbitrary split pane.
  Routing now uses visibility, keyboard focus, document identity, and pane identity,
  including when both panes show the same notebook.
- Dragging a tab temporarily removed its document from the open list, evicting
  its cached editor and losing state. Reordering now publishes one completed
  array update and preserves pinned-tab grouping.
- Back/Forward buttons could remain enabled when their only destinations had
  been closed. Availability now reflects open destinations.
- Narrow split panes measured code at a wider width than the text could use,
  clipping wrapped final lines. Measurement now accounts for text insets and
  the trailing insertion line. Composition text also triggers measurement before
  it is committed. Height changes no longer generate conflicting constraints.
- Deleting cells above or near the bottom of the viewport could index a new cell
  list with old layout offsets. Scroll anchors now retain the matching cell IDs.
- Add-cell buttons now stack when the full labels cannot fit side by side.

### Execution and file safety

- Closing an unrelated tab cleared the active notebook's execution queue, and a
  second Run All could overwrite it. Queue cleanup is scoped to its document,
  and concurrent Run All requests cannot replace the active chain.
- Late callbacks after interrupt, close, or restart could resurrect cancelled
  queue state. A generation check rejects obsolete callbacks.
- Finishing a background cell could change selection in the active notebook.
  Run-and-advance and error navigation now preserve the user's active document.
- External-file detection and autosave conflict checks ignored timestamps that
  moved backward. They now detect any changed modification time and preserve
  unsaved edits.
- Quarantined corrupt notebook drafts were reopened as Python scripts on the
  next startup. Recovery now selects only supported draft extensions.
- Rejected console execution no longer clears a draft or advances a script's
  insertion point as though its line had run.

### Source control and workspace operations

- Stage All and Commit consulted the old staging snapshot and could report that
  nothing was staged. It now commits after staging succeeds, using the requested
  commit message.
- Pull, Push, and Commit disappeared after a successful commit made the working
  tree clean. The action area now stays visible, with unavailable actions disabled.
  Long branch names have a separate row with ahead/behind counts, and the message
  field uses a small continuous corner radius.
- Compare Disk could be replaced by a Git diff on refresh. External comparisons
  now have distinct identities, refresh their Disk/Your Edits contents, and reuse
  their own tabs. Notebook reload also clears obsolete output undo history.
- Conflict warnings now identify the affected file, survive failed reloads, and
  clear after resolution so subsequent conflicts can appear.
- Workspace traversal followed recursive directory aliases repeatedly. It now
  detects canonical ancestor cycles.
- File transfers now reject aliased descendant destinations and skip moves into
  the file's current directory while preserving symlink-item semantics.

### Kernel output and data tools

- Buffered stdout/stderr could appear after results or errors. The bridge now
  flushes streams before subsequent output events.
- Console drafts survive panel recreation and return after browsing command
  history. A busy kernel leaves the draft editable while preventing submission.
  Typing publishes only input state rather than rebuilding the transcript.
- A CR/LF pair split across output chunks could erase the completed line. Stream
  normalization now defers a trailing carriage return until the next chunk.
- Hidden terminal initialization could steal keyboard focus. Focus is now tied
  to the active pane, and early requests survive renderer loading and attachment.
- Terminal fitting counted padding incorrectly and could clip the rightmost
  columns or bottom row. Padding now belongs to the viewport. Font and theme
  requests made before renderer readiness are preserved.
- A shell exit could close the terminal reader before final output arrived.
  Exit status now waits until the PTY has drained; a regression checks 100 KB of
  final output and its last marker. The exit notice occupies a separate footer
  instead of covering the terminal's final rows.
- Array summary badges squeezed into unreadable vertical text in narrow panes.
  The badges now wrap as complete items onto additional rows.
- Infinite DataFrame means produced invalid JSON, leaving statistics requests
  unanswered. Nonfinite means now serialize as null.
- Statistics failed for wide results because aggregate columns exceeded the
  preview limit; a larger aggregate then exposed DuckDB's memory limit. Statistics
  now use bounded batches of 32 source columns and retain whole-result counts,
  cancellation, and the existing preview limit.
- SQLite rejected narrow queries against tables with more than 256 columns.
  The limit now applies to result columns rather than the source schema.
- Copied TSV could split embedded tabs and newlines into extra cells. Values and
  headers now quote separators and embedded quotes.
- Copied Python lists could contain invalid database booleans/nulls or literal
  control characters. Copying now emits valid Python representations.

## Verification and limits

The starting Swift suite passed all 171 tests. New tests exposed actual undo and
wide-summary failures during this audit, and both were repaired. An existing
WebKit security test also needed to await its asynchronous title notification;
its script-blocking assertions remain intact.

Final verification on macOS 27 / Apple Silicon:

- `./scripts/quanta build`: passed, with no compiler warnings or errors.
- `./scripts/quanta test`: 221 passed, zero failures and zero skips; 50 new tests
  were added, with additional assertions in existing tests.
- Python bridge with scientific packages: 25 passed.
- Python bridge with `-S`: 14 passed, 11 expected optional-package skips.
- `git diff --check`: passed.

Test results recorded priority-inversion runtime warnings during Git
integration tests: user-initiated work waited on a default-priority thread. The
commands completed successfully. These warnings remain a profiling follow-up;
this audit did not establish their effect on live UI responsiveness.

The follow-up included read-only inspection of the running app and offscreen
rendering at narrow and wide sizes, including light/dark console output, code
wrapping, composition, array summaries, and Source Control before/after a commit.
The user's active notebook and kernel were not restarted. A VoiceOver session
and Instruments performance trace were not performed. AppKit tests exercise
focus, selection, editor reuse, scrolling, and undo, but do not replace those
checks. Retaining edited native editors trades some memory for correct undo
history; no before/after memory measurements were
captured. Wide statistics may scan the same query several times under the shared
timeout, so expensive queries can still time out. These verification results
were recorded before publication.
