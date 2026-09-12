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

## Architecture

- `Quanta/AppState.swift` owns the workspace, open documents, execution, and session state.
- `Quanta/Kernel/` discovers Python environments and manages a subprocess over JSON-lines stdio.
- `Quanta/Resources/quanta_kernel.py` provides execution, variable inspection, completion, and rich output using the Python standard library. pandas, numpy, matplotlib, and Plotly are optional integrations.
- `Quanta/Editor/` wraps AppKit TextKit 1 editors. `Quanta/Views/Controls.swift` defines shared UI tokens and controls.
- `Quanta/Models/` reads and writes notebooks in Jupyter-compatible JSON. Native DataFrame viewers use paged `NSTableView` tables.
- `Quanta/Git/` handles repository status, staging, and diffs. Notebook comparisons ignore outputs and execution counts.

Cell views observe their own state rather than the entire app model. Keep kernel I/O off
the main thread, and preserve unsaved edits when files change externally. The app is
unsandboxed so it can launch the user's Python interpreter and work with local files.

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
