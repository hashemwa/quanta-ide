# Development

## Build and test

Quanta requires Xcode 26 or later and targets macOS 15 or later.

```sh
./scripts/quanta build
./scripts/quanta test
./scripts/quanta build --release
./scripts/quanta run
```

The helper shares Xcode's DerivedData. Use `./scripts/quanta logs` to stream app logs.
The test command runs the unit suite. The shared Xcode scheme also includes a UI launch test.
For the terminal, navigation, notebook, search, and inspection workflows, see
[UI/UX verification](ui-ux-verification.md). Run `scripts/test-ui-workflows.py` with a
Python interpreter containing pandas to verify kernel-side inspection and table queries.
Terminal rendering uses locally bundled xterm.js assets; licenses and pinned versions
are in `Quanta/Resources/Terminal/DEPENDENCIES.md`.

## Automated checks

`.github/workflows/ci.yml` runs the existing build and unit-test commands on macOS 26
with Xcode 26.3, and the Python bridge suite on Python 3.11 and 3.13. Bridge checks run
both without site packages and with optional scientific packages installed. Failed
macOS runs retain the build/test logs as artifacts. CI activates after the workflow
is pushed; a local test pass is not a hosted CI result.

Builds fetch a checksum-pinned DuckDB 1.5.5 artifact into the ignored
`.build/native-tools` cache. The shared Xcode scheme embeds and signs its universal
macOS library in the application. The first build needs network access; subsequent
builds use the verified cache. The app never installs tools into users' Python environments.

The suite exercises kernel-backed completion edits, native SQLite/DuckDB, CSV/Parquet
previews, read-only enforcement, original values, page limits, and cancellation.
Missing bundled tools fail these tests. No Node.js test dependency remains.

## Architecture

- `Quanta/AppState.swift` owns the workspace, open documents, execution, and session state.
- `Quanta/Kernel/` discovers Python environments and manages a subprocess over JSON-lines stdio.
- `Quanta/Resources/quanta_kernel.py` provides execution, variable inspection, completion, and rich output using the Python standard library. pandas, numpy, matplotlib, and Plotly are optional integrations.
- `Quanta/Editor/` wraps AppKit TextKit 1 editors. `Quanta/Views/Controls.swift` defines shared UI tokens and controls.
- `Quanta/Language/CodeCompletion.swift` owns completion edits, snippet placeholders, and validation for kernel results.
- `Quanta/Models/` reads and writes notebooks in Jupyter-compatible JSON. Native DataFrame viewers use paged `NSTableView` tables.
- `Quanta/Git/` handles repository status, staging, and diffs. Notebook comparisons ignore outputs and execution counts.

Cell views observe their own state rather than the entire app model. Keep kernel I/O off
the main thread, and preserve unsaved edits when files change externally. The app is
unsandboxed so it can launch the user's Python interpreter and work with local files.

Workspace trust gates Python version probes, startup, execution, and kernel-backed
inspection. `WorkspaceTrust` remembers exact canonical folder paths; trusting a parent
does not automatically trust child projects. Saved custom interpreter paths require an
explicit interpreter selection before they can be probed or launched outside a trusted
workspace environment. This is a Python execution policy, not an operating-system sandbox.

Opening another trusted workspace creates a pending `KernelTransition` when either
the directory or interpreter differs from the running session. Execution waits for the
user's restart-or-keep choice. Interpreter preferences change only after confirmation.
The bridge includes its current directory in each execution completion, so the session
display follows `os.chdir()` as well as workspace restarts. An unavailable directory is
reported as unknown rather than retaining a stale path.

Python completion and inspection use the selected execution kernel and therefore follow
the live session. Completion responses are discarded after the source or caret changes,
and edits are range-checked before they reach the AppKit editor.

See [local Data browser architecture](data-browser.md) for provider and query constraints.

## Release packaging

Build Release first. Set your own Developer ID identity and install `create-dmg` before packaging:

```sh
export QUANTA_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)"
./release/package-dmg.sh
```

Notarization uses a keychain profile named `quanta`, or the value of
`QUANTA_NOTARY_PROFILE`. Run `./release/notarize-dmg.sh` without an existing DMG to
see the credential setup instructions, then pass the packaged DMG to that script.

## Upgrading from Vortex

Quanta uses the `nativeviz.Quanta` bundle identifier. On first launch, it copies
existing Vortex preferences without overwriting Quanta settings. Recovery drafts are
copied into `Application Support/Quanta/Drafts`; originals are retained. Legacy names
in migration code and its tests are intentional.

## README screenshots

The screenshots show `Examples/showcase.ipynb` running in Quanta with numpy,
pandas, matplotlib, plotly, and scikit-learn. The notebook generates synthetic
solar and studio energy data locally, plus CSV and SQLite files in a temporary
demo folder. The Data browser screenshot uses that generated SQLite database.
Images live in `docs/images/`: `notebook.png`, `data-browser.jpg`, and `plots.png`.
They are captures of the app's actual interface.
