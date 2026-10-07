# JupyterLab parity and resize performance — October 7, 2026

This pass closes the gaps that most often stop a JupyterLab notebook from running
unchanged in Quanta, and reduces the work the notebook canvas does while the window
is resizing or zooming. It was written on a Linux machine without Xcode, so the Swift
changes were **not compiled or run**. The Python bridge changes were tested headless.
Build and run the native tests before relying on any of it:

```sh
./scripts/quanta build
./scripts/quanta test
python3 scripts/test-kernel-interactive.py
python3 scripts/test-ui-workflows.py
```

## What changes for a user

| Area | Before | After |
| --- | --- | --- |
| IPython syntax | Any `%magic`, `!command` or `obj?` failed the cell. | `%time`, `%timeit`, `%prun`, `%pip`, `%conda`, `!cmd`, `x = !cmd`, `%cd`, `%env`, `%who`/`%whos`, `%run`, `%%writefile`, `%%capture`, `%%bash`, `%%html`/`%%markdown`/`%%latex`, `%autoreload`, `%precision`, `%config`, `obj?`/`obj??` and `get_ipython()` work. See [notebook compatibility](notebook-compatibility.md). |
| Working folder | Every notebook ran in the workspace root, so `pd.read_csv("data.csv")` failed next to a notebook in a subfolder. | Each saved notebook runs in its own folder and remembers its own `%cd`. |
| `input()` and `getpass()` | Raised an error. | A sheet asks for the value; Interrupt cancels the cell. |
| Run and advance | ⇧↩ on a running cell did nothing, so cells could not be queued. Every sent cell showed a spinner and its time included the wait. | Selection advances immediately, later cells show the queued clock, timing starts when a cell starts, and an error or interrupt cancels that notebook's queued cells. |
| Running cells | No indication of how long the current cell has run. | The gutter counts elapsed seconds while a cell runs. |
| Command mode | No J/K, ⇧↑/⇧↓ selection, ⇧M, ⇧V, heading keys, raw cells, I I or 0 0. | All of these work. Multi-cell selections are copied, cut, deleted and converted together. New Cell and Run menu items and Command Palette entries cover them. |
| Markdown | Ordered and nested lists, block quotes and rules rendered as paragraphs. | Numbered, bulleted and task lists nest by indentation; block quotes, rules, setext headings and hard line breaks render natively and in HTML/PDF export. |
| LaTeX outputs | `Latex("$x$ and $y$")` rendered as a KaTeX error; LaTeX and Markdown outputs were estimated at 300 pt tall. | LaTeX prose renders with inline math; heights are estimated from line count, so the scroller no longer jumps. |
| Completion | `df["` offered nothing. | Typing a quote after a subscript lists DataFrame columns, dictionary and mapping keys, and `_ipython_key_completions_()` results. |
| Find | Case-insensitive text only. | Match Case, Whole Word and Regular Expression, with `$1` replacement templates. |
| Files | No Save As; new notebooks could only be created untitled. | Save As… (⇧⌘S), New Notebook… in folder context menus, and Restart Kernel and Clear Outputs. |
| Static checks | Supported magics were flagged; `files = !ls` made `files` undefined for Ruff. | Only unsupported magics are reported; `%%time`/`%%timeit`/`%%capture`/`%%prun` bodies are checked as Python. |

## Resize and zoom

An animated zoom (double-clicking the title bar) is not a live resize: AppKit reports
`inLiveResize` only while the user drags the window, and the zoom animation resizes the
window once per frame. Before this change, every frame that changed the notebook column
width re-measured **every realized cell** (up to three viewports of them), each through
Auto Layout and a SwiftUI pass, then measured again when the hosted views reported their
new intrinsic size. The viewport update was also deferred to the next run-loop turn, so
each frame was committed with cells at the old position and width, then corrected.

Changes in `NotebookCanvas` and the cell views:

- While the width is changing (`inLiveResize`, or a width change in the last 200 ms),
  only cells intersecting the visible rect are measured and laid out. Off-screen cells
  keep their size and are moved and re-centered; they are measured once the resize
  settles. No new cells are prefetched mid-resize.
- The document view tracks the clip view width and cells keep their horizontal centering
  through autoresizing masks, so the column stays centered within the same frame.
- When the scroll view's width really changes, the viewport update now runs during the
  scroll view's own layout instead of a frame later. Other updates stay coalesced.
- Hosted cell content no longer asks the canvas to re-measure when its intrinsic height
  already matches its frame (the canvas just measured it).
- The add-cell bar's height is cached by width and font size instead of being solved on
  every layout pass.
- `EditorStage` and the file navigator report the size SwiftUI proposes, so SwiftUI no
  longer asks AppKit to fit their entire subtrees.
- Script editors use non-contiguous TextKit 1 layout, so a width change with wrapping on
  no longer lays out the whole file up to the visible line.
- The file navigator no longer resolves symlinks for every item on each sidebar render
  when the selected file is outside the tree.

Sources consulted: Apple's documentation for `NSHostingView.sizingOptions`,
`NSViewRepresentable.sizeThatFits`, `NSView.inLiveResize`, `NSLayoutManager`
non-contiguous layout, and the *Sizing and Placing Windows* guide; WWDC22 *Use SwiftUI
with AppKit*; and Apple Developer Forums threads 775713 (a root `.frame(minWidth:)`
around `NavigationSplitView` causing animation stutter) and 836901
(`NavigationSplitView` with an inspector repeating constraint passes on macOS 27).

Not changed, pending a trace: the root `.frame(minWidth:minHeight:)` on the window
content. Removing it is the change Apple's engineer recommended in thread 775713, but
it alters how the window enforces its minimum size, so it should be A/B tested with a
Release Instruments recording (zoom in, zoom out, and drag-resize, with the sidebar and
inspector open) before it ships.

## Review fixes for the previous commits

- Exported ANSI colours are resolved in the light appearance, so dim and white terminal
  text no longer disappears on the white PDF page when Quanta is in dark mode.
- ⌘-clicking a selected file to deselect it no longer opens it.
- Git badges refresh on every prepared row, not just the visible ones.

## Remaining gaps

- All notebooks still share one Python process. Variables and execution counts are
  shared, and Restart restarts every notebook's state.
- Jupyter widgets, `display_id`/`update_display`, and JavaScript outputs (Altair, Bokeh,
  folium) are not supported.
- Collapsible heading sections, a cell tag/metadata editor, and Tab-key completion are
  not implemented.
