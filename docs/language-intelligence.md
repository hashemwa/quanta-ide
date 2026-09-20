# Language intelligence choices

Quanta's editor and suggestions remain AppKit/SwiftUI. The language server is a bundled
native helper; Node.js and npm are not application prerequisites. The selected Python
interpreter supplies import/type context but does not run notebook cells for analysis.

Evaluated September 20, 2026:

| Candidate | Finding |
| --- | --- |
| ty 0.0.82 | Standalone Rust binary, MIT, notebook LSP, completions, auto-imports, signatures, definitions, references and rename. Selected and covered by Quanta integration tests. |
| Pyrefly 1.3.1 | Credible native Rust alternative. Our subprocess probes passed basic completion, definition, signature and cross-cell navigation. No decisive benefit was established for replacing ty in this milestone. |
| Jedi language server | Its repository now recommends its successor and is in maintenance mode; also adds Python tool-environment management. |
| Zuban | Native Rust alternative with notebook support; AGPL-licensed. Not selected for this integration. |
| Pyright | Existing integration worked, but required a separate Node runtime and installation. Removed from app setup and CI. |

The comparison probes are functional checks, not performance or accuracy benchmarks.
A release's feature list is not proof of compatibility: update the pinned server only
after the live notebook, scientific package, edit and diagnostics tests pass. Keep the
LSP client/editor boundary separate so the server can be reconsidered independently.

Native notebook synchronization uses the vscode-notebook-cell URI convention because
ty's tested implementation did not resolve cross-cell symbols using file URIs with
fragments. This is a URI identifier, not a dependency on VS Code or Electron.

Autocomplete appears during identifier/import/attribute typing and with Ctrl-Space.
Suggestions preserve their replacement range, sort/filter data, type details and import
edits. The client supports numbered/default snippet placeholders and rejects unsupported
snippet forms rather than inserting raw snippet syntax. Stale results and invalid edits
are discarded. Imports and the completion are one undoable edit. Rename presents affected
files, edits unsaved models, and supports undo. Arbitrary server-driven edits remain disabled.

Syntax coloring uses a lexical scanner. It handles multiline strings, comments, escaped
quotes, f-string/template-string expressions, decorators, numbers and contextual soft
keywords. It does not claim semantic resolution of shadowed builtins; the analyzer owns
diagnostics and navigation. Color passes rescan source to avoid stale multiline state.

## Predictive whole-line completion

Apple exposes NSTextView.inlinePredictionType for inline text prediction, but it is not
a documented Python-aware code-completion service. Quanta disables that text prediction
in code editors to avoid competing with its own completion UI. A code-trained prediction
provider would need independent quality/latency, hardware, privacy and context evaluation.
Keep that optional and separate from deterministic language-server suggestions.

Primary references:

- https://docs.astral.sh/ty/features/language-server/
- https://docs.astral.sh/ty/installation/
- https://pyrefly.org/en/docs/IDE/
- https://github.com/pappasam/jedi-language-server
- https://docs.zubanls.com/en/latest/
- https://developer.apple.com/documentation/appkit/nstextview/inlinepredictiontype
- https://developer.apple.com/documentation/bundleresources/placing-content-in-a-bundle
