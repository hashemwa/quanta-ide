# Quanta

A **fully native macOS IDE for data science** — SwiftUI + AppKit, zero Electron, zero JVM.
Supports `.py` scripts and `.ipynb` Jupyter notebooks with a live Python kernel,
native DataFrame tables, inline plots, and a variable explorer.

There is no truly native data-science IDE on the Mac: JupyterLab Desktop and
Positron are Electron, VS Code is Electron, DataSpell/PyCharm are JVM. Quanta is
the native answer.

## Build & run

Open `Quanta.xcodeproj` in Xcode 26 or later and hit Run (deployment target: macOS 15), or:

```sh
./scripts/quanta run
```

`quanta build` compiles, `quanta test` runs the unit tests, `quanta release` builds Release, and
`quanta logs` streams `os_log`. Without the script:

```sh
xcodebuild -project Quanta.xcodeproj -scheme Quanta -configuration Debug -derivedDataPath build build
open build/Build/Products/Debug/Quanta.app
```

Quanta discovers every Python environment on the machine automatically — workspace
venvs, all conda envs (via `~/.conda/environments.txt` plus install-root scans),
pyenv versions, Homebrew, and the system Python — picks the right one (a workspace
venv always wins), and lists the rest with versions in the toolbar's kernel menu.
pandas/numpy/matplotlib are used when present; nothing is required beyond the stdlib.

Try it: open this folder as the workspace and run `Examples/welcome.ipynb`.

## Upgrading from Vortex

Quanta uses the `nativeviz.Quanta` bundle identifier. On first launch, it copies
existing Vortex preferences into the new settings domain without overwriting Quanta
settings. Recovery drafts are copied into `Application Support/Quanta/Drafts`; the
original drafts are retained. Legacy names in the migration code are intentional.

The development helper is now `./scripts/quanta`. Release packaging uses
`QUANTA_SIGN_IDENTITY` and `QUANTA_NOTARY_PROFILE` (default profile: `quanta`).

## What works today

- **Notebooks (.ipynb)**: nbformat 4 read/write, code + markdown cells, run/run-all,
  insert/move/delete/convert cells, execution counts, ⌘⏎ / ⇧⏎, rendered markdown —
  including LaTeX math (`$…$`, `$$…$$`) drawn natively via matplotlib mathtext.
- **Scripts (.py)**: syntax-highlighted editor with line numbers, auto-indent, 4-space
  tabs, ⌘/ comment toggle; ⌘R runs the file in the shared kernel namespace.
- **Kernel**: out-of-process Python bridge (`Quanta/Resources/quanta_kernel.py`)
  speaking JSON-lines over stdio — no ZeroMQ/jupyter dependency. Streams stdout/stderr
  live, captures matplotlib figures as retina PNGs, interrupt (⌘.) and restart (⌃⌘R).
- **DataFrames**: expression results and the Variables panel open native `NSTableView`
  viewers (only visible rows materialize) with paged fetching from the kernel.
- **Variable explorer**: name/type/shape/preview after every execution.
- **Console**: REPL into the same kernel + streamed script output.
- **Workspace sidebar**: folder tree, new notebook/file, tabs with dirty state.
- **Plots**: matplotlib figures as retina PNGs, restyled for the app appearance without
  touching the user's figure, plus interactive Plotly figures rendered in a `WKWebView`.
- **Explain**: an optional button on an error output that shells out to the Claude Code
  CLI, if you have one installed and logged in, and asks it to diagnose the traceback.
  Nothing is sent anywhere unless you click it; it runs as a subprocess with tools
  disabled and the notebook text fenced as untrusted data.
- **Source control**: a git pane in the sidebar (⌘2) with branch switching, stage/unstage,
  commit, fetch/pull/push, discard, and a per-file diff tab. Notebooks are compared by cell
  source only, so re-running cells never shows up as a change, and saving writes the exact
  JSON layout Jupyter writes so diffs stay minimal.

## Architecture

```
┌────────────────────────── Quanta.app (Swift) ─────────────────────────┐
│ SwiftUI shell: sidebar · tabs · notebook UI · variables · console     │
│ AppKit cores:  NSTextView editors (TextKit 1) · NSTableView tables    │
│ AppState ──── KernelSession (Process + JSON-lines over stdio)         │
└──────────────────────────────────┬────────────────────────────────────┘
                                   │ execute / vars / df ops
                        quanta_kernel.py (user's Python)
                        exec in shared namespace · pandas/matplotlib hooks
```

Design choices:

- **TextKit 1 `NSTextView`** for editors — still the battle-tested path; TextKit 2
  components (STTextView, CodeEditSourceEditor) remain the upgrade candidates once
  they stabilize. The editor is isolated behind small representables so it can be swapped.
- **stdio bridge, not ZMQ** — Swift ZeroMQ bindings are unmaintained; the bridge needs
  zero Python dependencies and keeps the wire protocol trivial. A jupyter-server
  WebSocket client is the path to full Jupyter-kernel compatibility later.
- **NSTableView, not SwiftUI Table** — SwiftUI's Table degrades past a few thousand
  rows; NSTableView with fixed row height handles millions via lazy row materialization.
- **Unsandboxed** — required to launch the user's interpreter and roam the filesystem
  (same as VS Code/iTerm). Ship with hardened runtime + notarization for distribution.

## Roadmap

- Tree-sitter incremental highlighting (SwiftTreeSitter + Neon), completions via
  Jedi/LSP (`python-lsp-server` over stdio)
- Metal-accelerated native plotting for 100k+ point interactive charts
  (matplotlib PNGs stay the compatibility path)
- Full Jupyter kernel protocol (jupyter-server REST/WebSocket) for non-Python kernels
- DataFrame viewer: sort/filter, column stats, polars support
- rich display: HTML/`_repr_html_` and Vega
- Git history, blame, and stash

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) — in particular, this codebase carries no
comments by design, so please match the surrounding style before opening a PR.

## License

MIT — see [LICENSE](LICENSE).
