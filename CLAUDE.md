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
- `Quanta/Resources/quanta_kernel.py` — the bridge. **Standard library only**, JSON-lines over stdio. Ops: `execute`, `vars`, `df`, `latex`, `complete`, `inspect`, `config`, `shutdown`. Test it headless by piping JSON lines into it with `~/miniforge3/envs/msds/bin/python`. Every protocol message is written as `\n` + JSON + `\n` so a partial line that user code or a subprocess wrote straight to fd 1 cannot glue onto it (the Swift framer skips empty lines); the protocol reads `_protocol_in`, and user code sees an empty `sys.stdin`, an `input()` that raises, and an `exit()`/`quit()` that only raises `SystemExit`.
- `Quanta/Editor/` — AppKit editors (`QuantaTextView`, highlighter, ruler, completion panel). TextKit 1 on purpose.
- `Quanta/Views/` — SwiftUI. `Controls.swift` is the design system; `DataFrameViews.swift` is `NSTableView` (never SwiftUI `Table`).
- `Quanta/Git/` — `GitClient` runs the git binary on a serial background queue; `GitSnapshot` parses `status --porcelain=v2`, branches and ahead/behind; `LineDiff` builds the aligned rows for the diff tab; `SourceControl` holds `SourceControlState` and the `AppState` git actions. The sidebar switches between Files (⌘1) and Source Control (⌘2).
- Notebooks are written through `JupyterJSON` (`Notebook.swift`), byte-for-byte the layout `nbformat` writes (`sort_keys=True, indent=1, ensure_ascii=False`, trailing newline), so a Quanta save never rewrites a Jupyter notebook's formatting.
- Window: `NavigationSplitView(sidebar:detail:)`, with `.inspector` attached **to the split view, not to the detail column** — that placement is what gives the toolbar an inspector tracking separator, so editor toolbar items end at the divider and follow it.

## New features and UI

- **Match what exists before inventing anything.** Before building a new view, panel, control or interaction, look at how the nearest existing one does it and copy that: the same tokens, the same control sizes, the same hover/press/focus feedback, the same tooltip wording, the same keyboard conventions, the same empty state. A new surface should be indistinguishable in style from the ones already shipped.
- If the design system genuinely lacks something, add the token or the shared component to `Quanta/Views/Controls.swift` and use it everywhere the pattern applies — never a one-off literal in a single view.
- New behaviour follows the existing verbs: run/interrupt/restart act on the active document and kernel, panels toggle from the same places, destructive actions confirm or are undoable, and every new command gets a menu item so it is discoverable and keyboard-reachable.
- Tell me when a request would break the existing pattern, and say what the consistent alternative is, before writing it.

## UI conventions

- Everything chrome-related comes from `Quanta/Views/Controls.swift`: `DS` tokens (`Space`, `Radius`, `Bar`, `Motion`, `Layout`), `IconButton`, `PanelHeader`, `.hoverHighlight()`, `.outputCard()`, `FloatingToolbar`. Add a token rather than a magic number.
- Let the platform render its own controls. A `Menu` in a `ToolbarItem` is already a native toolbar control — no `menuStyle` or `buttonStyle` override. Before hand-rolling behaviour, check the SDK interface (`$(xcrun --show-sdk-path)/System/Library/Frameworks/SwiftUI.framework/Modules/SwiftUI.swiftmodule/*.swiftinterface`) and Apple's docs.
- macOS 26 APIs go behind `#available(macOS 26.0, *)` with a working macOS 15 fallback. Liquid Glass belongs on floating strips only — never nested inside another glass surface, never on panels, cards, bars or the sidebar.
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
