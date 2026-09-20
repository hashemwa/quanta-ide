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

The macOS job also installs Pyright 1.1.414 and exercises the real language server.
Locally, that integration test uses a standard Pyright installation or an explicit path:

```sh
TEST_RUNNER_QUANTA_TEST_PYRIGHT=/absolute/path/to/pyright-langserver ./scripts/quanta test
```

Without Pyright, only the live-server test is skipped; mapping, protocol framing, and
workspace-trust tests still run. The app never downloads or installs a server automatically.

## Architecture

- `Quanta/AppState.swift` owns the workspace, open documents, execution, and session state.
- `Quanta/Kernel/` discovers Python environments and manages a subprocess over JSON-lines stdio.
- `Quanta/Resources/quanta_kernel.py` provides execution, variable inspection, completion, and rich output using the Python standard library. pandas, numpy, matplotlib, and Plotly are optional integrations.
- `Quanta/Editor/` wraps AppKit TextKit 1 editors. `Quanta/Views/Controls.swift` defines shared UI tokens and controls.
- `Quanta/Language/` owns the optional Pyright process, LSP framing, document synchronization, UTF-16 mapping, and static editor actions.
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

Python analysis requires a trusted workspace and trusted selected interpreter because
Pyright can probe Python to resolve imports. It runs separately from the execution
kernel. Interpreter/workspace changes restart analysis; closing or renaming documents
sends the corresponding LSP close/open notifications. Server failures remain visible in
Editor settings and require a restart or configuration change, avoiding crash loops.
Native workspace file events invalidate the server's import caches when modules are
created, changed, renamed, or deleted. Changes to installed libraries outside the workspace
may require **Restart Python Analysis**.

Each notebook is presented as an in-memory Python file beside its notebook, with code
cells joined in document order and Markdown omitted. No temporary source file is written
into the workspace. Cell IDs and UTF-16 offsets map diagnostics, completions, and
definitions back to the original editors. This models document order, not kernel execution
history. Unsupported IPython syntax is not translated. Versioned diagnostics and request
results are discarded after the corresponding source changes; requests have cancellation
and timeouts. Automatic imports and server-initiated workspace edits are disabled.

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

The screenshots show `Examples/exploration.ipynb` running in Quanta with numpy,
pandas, and matplotlib. The notebook generates a small synthetic dataset locally.
Images live in `docs/images/` and show the app's actual interface.
