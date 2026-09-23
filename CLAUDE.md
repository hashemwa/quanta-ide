# Quanta

Native macOS data-science IDE for `.py` and `.ipynb` — SwiftUI + AppKit, a Python kernel over stdio, no Electron and no JVM. Built with the macOS 26 SDK, ships to macOS 15.

## Absolute rules

- **No comments in code.** Not `//`, `///`, `/* */`, `#`, or Python docstrings. Names and structure carry the meaning. If something genuinely needs explaining, it goes in the commit message, in this file, or in `README.md` — never in the source.
- **Never commit or push unless I explicitly say so.** Staging is fine, committing is not. "Looks good" is not permission.
- **Never add attribution to commits or PRs.** No `Co-Authored-By`, no "Generated with Claude Code", no tool footers. My name only.
- **Never edit `Quanta.xcodeproj/project.pbxproj` by hand.** Xcode 26 filesystem-synced groups mean any file added under `Quanta/` joins the target automatically.

## Build and test

```
./scripts/quanta build     compile check
./scripts/quanta run       build + relaunch the app (default)
./scripts/quanta release   Release build + relaunch
./scripts/quanta test      unit tests (QuantaTests only)
./scripts/quanta logs      stream os_log
./scripts/quanta clean     wipe this project's DerivedData
```

Add `-r` for Release. The same commands are Zed tasks (`cmd-shift-r`).

- Use the script, not `xcodebuild` directly — it shares Xcode's DerivedData, caches build settings, filters output to diagnostics, and detects "another build is already running".
- Build before claiming anything works. Run the tests after touching models, the kernel, or the exporters.
- Report outcomes exactly: if a build or test fails, say so and show the output. Never describe unverified work as done.

## Architecture

- `Quanta/AppState.swift` — the single app model: workspace, documents, kernel lifecycle, execution routing, variables, console, drafts, session. Main thread only.
- `Quanta/Kernel/` — `KernelSession` (process + JSON-lines framing, parsing off-main, async stdin writes) and `PythonLocator` (environment discovery).
- `Quanta/Resources/quanta_kernel.py` — the bridge. **Standard library only**, JSON-lines over stdio. Ops: `execute`, `vars`, `df`, `latex`, `complete`, `inspect`, `config`, `shutdown`. Test it headless by piping JSON lines into it with `~/miniforge3/envs/msds/bin/python`. Every protocol message is written as `\n` + JSON + `\n` so a partial line that user code or a subprocess wrote straight to fd 1 cannot glue onto it (the Swift framer skips empty lines); the protocol reads `_protocol_in`, and user code sees an empty `sys.stdin`, an `input()` that raises, and an `exit()`/`quit()` that only raises `SystemExit`. `plt.show()` is wrapped on import (`_PyplotShowHook`) so each call flushes pending streams, emits every open figure and closes it, like Jupyter's inline backend; figures still open when a cell ends are emitted then.
- `Quanta/Editor/` — AppKit editors (`QuantaTextView`, highlighter, ruler, completion panel). TextKit 1 on purpose.
- `Quanta/Views/` — SwiftUI. `Controls.swift` is the design system; `DataFrameViews.swift` is `NSTableView` (never SwiftUI `Table`).
- Editor panes: `DocumentContentView` stacks per-document SwiftUI chrome (the notebook find bar) over one persistent `EditorStage` per pane. The stage owns an AppKit canvas for every open notebook (`NotebookCanvas`) and script (`ScriptCanvas`), cached in `DocumentViewCache` by document and pane, and switches tabs by toggling `isHidden`. Data, dataframe and diff documents stay plain SwiftUI layered above the stage.
- Notebook cells: `NotebookCellAppKitView` draws code in a `tertiarySystemFill` well, prose directly on the page, a `controlAccentColor` bar down the left of selected cells and an accent border while editing. One `CellToolbar` (a `FloatingToolbar`) per canvas floats above the selected cell's top-right corner and sticks to the top of the viewport inside tall cells. Spacing after markdown is `notebookProseSpacing`, after code `notebookCellSpacing`, so explanations bind to the code below them. Plot outputs (images and Plotly) put their actions in a `FloatingToolbar` inside the plot's top-right corner that appears on hover (`.plotControls`) and stays pinned while Actual Size, Pan or an export is active; the same actions are VoiceOver actions on the plot.
- `Quanta/Git/` — `GitClient` runs the git binary on a serial background queue; `GitSnapshot` parses `status --porcelain=v2`, branches and ahead/behind; `LineDiff` builds the aligned rows for the diff tab; `SourceControl` holds `SourceControlState` and the `AppState` git actions. The sidebar switches between Files (⌘1), Source Control (⌘2), Data (⌘3), Search (⌘4) and the notebook Outline (⌘5), which lists headings with their cells.
- Notebooks are written through `JupyterJSON` (`Notebook.swift`), byte-for-byte the layout `nbformat` writes (`sort_keys=True, indent=1, ensure_ascii=False`, trailing newline), so a Quanta save never rewrites a Jupyter notebook's formatting.
- Window: `NavigationSplitView(sidebar:detail:)`, with `.inspector` attached **to the split view, not to the detail column** — that placement is what gives the toolbar an inspector tracking separator, so editor toolbar items end at the divider and follow it. The title is the workspace folder with the git branch as subtitle (the document name lives in its tab); the editor toolbar is back/forward on the leading edge and kernel, Run/Stop and layout on the trailing edge, where macOS keeps items visible at every width.

## New features and UI

- **Match what exists before inventing anything.** Before building a new view, panel, control or interaction, look at how the nearest existing one does it and copy that: the same tokens, the same control sizes, the same hover/press/focus feedback, the same tooltip wording, the same keyboard conventions, the same empty state. A new surface should be indistinguishable in style from the ones already shipped.
- If the design system genuinely lacks something, add the token or the shared component to `Quanta/Views/Controls.swift` and use it everywhere the pattern applies — never a one-off literal in a single view.
- New behaviour follows the existing verbs: run/interrupt/restart act on the active document and kernel, panels toggle from the same places, destructive actions confirm or are undoable, and every new command gets a menu item so it is discoverable and keyboard-reachable.
- Tell me when a request would break the existing pattern, and say what the consistent alternative is, before writing it.

## UI conventions

- Everything chrome-related comes from `Quanta/Views/Controls.swift`: `DS` tokens (`Space`, `Radius`, `Bar`, `Motion`, `Layout`), `IconButton`, `PanelHeader`, `.hoverHighlight()`, `.outputCard()`, `FloatingToolbar`, `FilterBar`. Add a token rather than a magic number.
- Let the platform render its own controls. A `Menu` in a `ToolbarItem` is already a native toolbar control — no `menuStyle` or `buttonStyle` override. Before hand-rolling behaviour, check the SDK interface (`$(xcrun --show-sdk-path)/System/Library/Frameworks/SwiftUI.framework/Modules/SwiftUI.swiftmodule/*.swiftinterface`) and Apple's docs.
- macOS 26 APIs go behind `#available(macOS 26.0, *)` with a working macOS 15 fallback. Liquid Glass is for controls that float over content: `FloatingToolbar` strips and the controls of a footer `FilterBar`. Never as the background of a panel, card, bar or the sidebar, and never a glass control inside another glass control.
- Sidebar and inspector footers are a `FilterBar` (`DS.Bar.footer`): an optional glass circle action (`FilterBarButton`/`FilterBarMenu`) and the native filter field at large size. Filter options open from the field's filter icon, which fills in while a non-default option is on; there is no chevron and no `…` menu. Actions that used to live in `…` menus belong in context menus and the menu bar.
- The tab bar and the bottom panel sit on the page colour (`textBackgroundColor`), each separated from the editor by a single hairline `Divider`, as is the split-editor divider.
- Editor tabs have no background of their own. The active tab gets a soft `DS.Radius.selection` rounded fill (`.quaternary`, `.quinary` on hover), inset `DS.Space.xs` so it floats clear of the hairline under the tab bar, the same language as the sidebar's selected row. No accent line, no separators, never a capsule. Capsule pills (`IconSegmentedControl`) are for switching panes.
- Icon-only controls always get `.help("Verb noun (⌘⇧X)")`, which also supplies the VoiceOver name. Shortcut symbols: ⌘ ⇧ ⌥ ⌃ ↩.
- A window column's first row is `DS.Bar.primary` (32) — the sidebar's navigator bar, the tab bar, the inspector's header. A bar inside a column is `DS.Bar.secondary` (28).
- UI text uses semantic styles (`.body`, `.callout`, `.subheadline`, `.caption`); nothing fractional, nothing under 10pt. Monospaced text reads `@Environment(\.monoFontSize)` so it follows ⌘+/⌘−.
- Pointer: arrow over controls, I-beam only in text. Feedback is a fill highlight, never a cursor swap; never `NSCursor.push()`/`pop()`. `CursorZoneView` handles arrow-over-floating-toolbar.
- One accent colour, for focus and selection only.

## Invariants that must not regress

- `CellView`, `OutputItemView` and `DataFrameOutputView` must not observe `AppState` — they reach `AppState.shared` for actions and observe `AppState.shared.selection`. Observing `AppState` re-renders every cell on each kernel publish.
- `FindState` (per document) and `CellSelection` (on `AppState`) are separate observables for the same reason.
- Resolve the command-mode catcher with `CommandCatcherView.activeCatcher(in:)`; never cache a weak reference — a tab switch deallocates it and Esc silently no-ops.
- Floating toolbars fade with opacity and stay in the hierarchy; inserting or removing them mid-scroll causes layout hitches.
- Never re-parent a document canvas. Moving one between superviews, even inside the same window, re-runs constraints and SwiftUI layout for every cell (~60 ms for 27 cells); hiding and showing costs ~1 ms. Hidden canvases skip relayout until shown, and the stage hands keyboard focus to the shown document only when focus was in the one being hidden.
- `NotebookCanvas` only builds views for cells within one viewport of the visible area (the first pass builds just the visible cells), prefetches a second viewport in small batches once scrolling stops, and releases them three viewports away, unless a cell's editor has focus. Heights are measured once built and estimated otherwise. Never assume a cell has a view: set `scrollRequest` first, which builds the target before an editor lookup, and keep per-cell state such as undo history in the canvas, not the view.
- `NSHostingView` reports SwiftUI's unwrapped ideal size, so hosted cell content (`NotebookCellHostingView`) feeds its frame width back into the root (`NotebookHostedContent`); otherwise wrapped markdown and long outputs are measured as single lines and clipped.
- Hover inside scrollable content uses `.scrollAwareHover($hovering)`, not raw `.onHover`.
- Rendered markdown cells are not text-selectable, or clicks never reach the select/edit gestures.
- A SwiftUI `List(selection:)` must own its selection in `@State` and be mirrored from the model. A computed binding gets its stale value pushed back on any re-layout.
- Kernel writes are async and framing happens off-main; stream chunks coalesce at ~30Hz.
- Source Control compares notebooks by cell type and source only. A notebook whose index/working-tree difference is just outputs, execution counts or metadata stays out of the change list, out of Stage All and out of Commit; the diff tab flattens notebooks to cell sources before diffing.
- Clean documents reload when their file changes on disk (`reloadExternallyChangedDocuments`); a dirty document is never overwritten by a reload.

## Working style

- Make the smallest change that fully does the job, then verify it. Screenshots and UI automation only when I ask for them.
- This is a shared machine: before synthesizing mouse or keyboard events, check `ioreg -c IOHIDSystem | awk '/HIDIdleTime/ …'` and skip if I am active. Restore the frontmost app and pointer position afterwards.
- Prefer deleting code to commenting it out. Dead code is a bug.
- When a change spans several concerns, group the work into commits that can be reviewed one at a time — mechanical sweeps stay separate from behaviour changes.
