# Contributing to Quanta

Thanks for taking a look. Quanta is a native macOS app: SwiftUI + AppKit, a Python
kernel over stdio, no Electron and no JVM.

## Before you write code

**This codebase carries no comments — on purpose.** Not `//`, `///`, `/* */`, `#`, or
Python docstrings. Names and structure are expected to carry the meaning. If something
genuinely needs explaining, it goes in the commit message, in `README.md`, or in
`CLAUDE.md`. A PR that adds explanatory comments will be asked to remove them, so please
match the surrounding style from the start.

`CLAUDE.md` is the architecture guide. It documents the layering, the invariants that
must not regress, and the UI conventions. Read it before changing anything structural —
several rules there look arbitrary and are not (for example, cell views deliberately do
not observe `AppState`, because that would re-render every cell on each kernel publish).

## Requirements

- macOS 15 or later
- Xcode 26 or later (the project builds against the macOS 26 SDK and ships to macOS 15)
- A Python 3 interpreter. pandas, numpy and matplotlib are used when present; the kernel
  itself is standard-library only and must stay that way.

## Build and test

```sh
./scripts/quanta build     compile check
./scripts/quanta run       build and relaunch the app
./scripts/quanta test      unit tests
./scripts/quanta logs      stream os_log
./scripts/quanta clean     wipe this project's DerivedData
```

Use the script rather than `xcodebuild` directly: it shares Xcode's DerivedData, caches
build settings, filters output down to diagnostics, and detects a build already running.

Run `./scripts/quanta test` before opening a PR, and always after touching the models, the
kernel, or the exporters. The unit tests write to an isolated `UserDefaults` suite, so
they will not disturb your own Quanta session.

You can exercise the kernel bridge on its own by piping JSON lines into it:

```sh
echo '{"op":"execute","id":"1","code":"print(1+1)"}' | python3 Quanta/Resources/quanta_kernel.py
```

## Project layout

- `Quanta/AppState.swift` — the single app model. Main thread only.
- `Quanta/Kernel/` — the Python subprocess and environment discovery.
- `Quanta/Resources/quanta_kernel.py` — the bridge. Standard library only.
- `Quanta/Editor/` — AppKit editors, TextKit 1 on purpose.
- `Quanta/Views/` — SwiftUI. `Controls.swift` is the design system.
- `Quanta/Git/` — git plumbing and the Source Control pane.
- `Quanta/Models/` — documents, notebooks, outputs, exporters.

## Pull requests

- Keep a PR to one concern. Mechanical sweeps stay separate from behaviour changes.
- New UI should be indistinguishable in style from what already ships: same `DS` tokens,
  same control sizes, same hover and focus feedback, same tooltip wording. Add a token or
  a shared component to `Controls.swift` rather than a one-off literal in a single view.
- Every new command gets a menu item, so it is discoverable and keyboard-reachable.
- Icon-only controls need `.help("Verb noun (⌘⇧X)")`, which also supplies the VoiceOver name.
- macOS 26 APIs go behind `#available(macOS 26.0, *)` with a working macOS 15 fallback.
- Do not edit `Quanta.xcodeproj/project.pbxproj` by hand. The project uses Xcode 26
  filesystem-synced groups, so a new file under `Quanta/` joins the target automatically.
- Prefer deleting code to commenting it out.

## Reporting a security issue

Please do not open a public issue for a security problem. Notebooks are untrusted input:
a `.ipynb` can carry arbitrary HTML, JavaScript and error text that Quanta renders. If you
find a way for opening or running a notebook to reach the filesystem, the network, or the
user's shell in a way it should not, report it privately through GitHub's
[security advisories](https://github.com/hashemwa/quanta-ide/security/advisories/new).
