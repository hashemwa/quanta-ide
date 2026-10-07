# Language intelligence

Quanta uses an AppKit editor with native syntax coloring, diagnostic underlines, and a
Problems panel. Python code checks run in a separate process using the selected
interpreter; they do not execute your code or wait for a running notebook cell.

Syntax checks work without extra packages and refresh after a short pause in typing.
Use **Run → Check Python Code** to check immediately or **Navigate → Show Problems**
to see the results. Select a problem to move to its script line or notebook cell.
Editing a source clears its old diagnostic results while a new check is scheduled.

For additional lint checks and formatting, open **Run → Python Environment…** and
install `ruff` in the selected interpreter. **Run → Format Code** (⇧⌥F) formats the
active script or selected code cell. Formatting is undoable and is discarded if the
source changes before the formatter finishes. Quanta never installs tools automatically.
Workspace-root Ruff configuration is supported; nested and per-file configuration
overrides are not yet represented by the analysis helper's synthetic filenames.

Notebook syntax checks keep cell boundaries and carry compiler flags between cells.
Ruff receives notebook code cells together so a name defined in one cell can be used in
another. This is a check of the written notebook, not a guarantee about its execution
order or live variables. Unsupported IPython commands receive explicit diagnostics.

Completion offers names written in code cells and Python built-ins before execution,
including while the kernel is busy or stopped. The idle live kernel adds member
completions and call documentation for objects that already exist. Source-name
suggestions are lexical: they do not resolve types, imports, scopes, or definitions.
Large-source scanning, analysis input/output, and process time are bounded.

The syntax palette keeps the same hues in light and dark mode, with muted comments
and distinct keywords, strings, numbers, definitions, decorators, and built-in names.
Contrast checks use the actual native script background and notebook code well, using
[4.5:1 text contrast](https://www.w3.org/WAI/WCAG22/Understanding/contrast-minimum.html)
as a readability benchmark. Highlighting remains lexical: member names and pandas/NumPy
attributes are not resolved through a project type-analysis service.

Markdown notebook cells use their own edit-mode coloring for headings, list markers,
emphasis, links, inline code, equations, and TeX commands. Python fenced blocks use
Python syntax colors, including fences with additional metadata and Windows line
endings. Markdown editing does not show Python completion menus,
Python documentation, or Python's colon-triggered indentation. Raw cells remain
plain text.

Source synchronization and cached highlight ranges use exact character sequences,
so Unicode edits that look identical still save correctly and invalidate old
formatting and completion replies.

## GitHub Copilot

Click the floating Copilot icon at the bottom-right of the editor, choose **Sign in with GitHub**, then **Copy Code
and Open GitHub**. Paste the one-time code into GitHub and authorize your account.
Suggestions turn on after GitHub confirms Copilot access. The same controls are in the
**Copilot** menu and the command palette.

Suggestions appear as faint text at the end of a code or Markdown line. **Tab** accepts a visible
suggestion as one undoable edit; **Escape** dismisses it. Normal completion menus and
snippet navigation retain priority. Multiline suggestions appear at the end of a script
or editable code/Markdown cell, with up to eight lines; notebook cells temporarily expand to show them.
Previews that would cover existing code or cannot fit visibly are withheld. Previews do
not change source, saved notebook contents, execution input, or undo history.

Use **Code Suggestions** to pause or resume while keeping your account connected.
**Disable for This Project** remembers the choice for the current workspace folder.
Turning suggestions off cancels pending work, removes previews, closes the helper, and
stops sending code. Untrusted workspaces cannot request suggestions. **Sign Out** clears
the helper's Quanta account connection.

Copilot is an optional cloud service: code context is sent to GitHub for suggestions.
Code-cell context includes bounded neighboring code cells. For a Markdown cell,
Quanta synchronizes only the active cell as a virtual Markdown document; neighboring
cells and execution outputs are excluded. Raw cells cannot request suggestions.
The first sign-in downloads
GitHub's official Apple Silicon language server. No Node.js or Python package install is
needed. The version is pinned and its download is checked against GitHub's SHA-256 digest.
The helper and its separate account profile live under
`~/Library/Application Support/Quanta/Copilot/`; credentials are not stored in Quanta's
preferences. Quanta disables optional helper telemetry and implements the protocol's
completion display and acceptance notifications.

The integration follows the [official Copilot Language Server protocol](https://github.com/github/copilot-language-server-release).
The current pinned helper is **1.551.2**. Offline source-name completion and Python/Ruff
checks work independently of Copilot. Project-wide semantic completion, go to definition,
references, rename, and quick fixes remain future work.
