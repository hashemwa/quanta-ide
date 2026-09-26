# Quality audit — September 25, 2026

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
