# IDE UI/UX verification

## Launch the updated build

Run `./scripts/quanta run` from the repository after saving any work in the running app. Building alone does not replace an already running instance. Open this repository as the workspace and open `Examples/ui-ux-check.ipynb`.

Use an interpreter with pandas for the DataFrame checks. The terminal does not depend on Python or pandas. The final example cell and the example script deliberately raise errors.

## 1. Quick Open and command palette

- Press **Command-P**, type `uiux`, and select `ui-ux-check.ipynb` using the arrow keys and Return. File paths distinguish similarly named files. Escape dismisses the picker.
- Press **Shift-Command-P** and search `variables`. Run Toggle Variables. Reopen the palette with an empty query; recently used commands appear first.
- Search `run` with no runnable document selected: unavailable commands should be dimmed and should not execute.
- Open Plot in Separate Window now uses **Option-Command-P**, leaving Shift-Command-P for the command palette.

## 2. Errors and Python console

- Open `Examples/ui-ux-check.py` and run it with **Command-R**. Click the `ui-ux-check.py:2` traceback link in the Python Console. The editor should focus the indicated line.
- Use the console toolbar’s magnifying glass to search for `Intentional`. Open Filter Console Messages and select Errors. The toolbar should show Errors while that scope is active. Close search and choose All to restore the full output; filtering never deletes output. Switching to Terminal and back preserves the console filter state.
- Scroll upward in a longer console transcript. New output should not pull you away from the section you are reading. Use Latest to return to the bottom.
- Run the notebook's final cell and click the traceback's source location. The source cell should expand and receive the caret.
- When a save fails, edits should remain open and a message should explain the failure. A script should not execute after its required save fails. Kernel crashes should offer restart guidance.

## 3. Notebook navigation and execution

- Use Outline to find “Stale output” or a code-cell preview, then select it. The notebook should scroll to that cell.
- Run `answer = 42`, change it to `answer = 43`, and leave it unexecuted. A stale-output indicator should appear. Rerun it: the indicator should clear.
- Run All and, during the two-second cell, use Running Cell to jump to it. The header shows queued cells and progress while additional cells remain queued.
- Stale-output tracking detects source changes since opening or running a cell in this session. It does not infer Python dependencies between cells or prove that saved outputs match saved source.

## 4. Workspace search

- Press **Shift-Command-F**, search `Intentional`, and press Return. Results should be grouped by file with highlighted matches.
- Open Search Options. Toggle Match Case, Whole Word, and Regular Expression and rerun a query.
- Try regex `counter\s*=\s*\d+`, include `**/*.ipynb`, and exclude `QuantaTests/**`. Include/exclude filters accept comma-separated patterns using `*`, `**`, and `?`.
- Enter invalid regex `[` with regex enabled. An explanatory error should appear. Turn regex off or correct the expression to recover.
- Click a notebook result: it should open the matching cell and line, rather than merely opening the notebook at the top.
- Queries exceeding 400 matching lines explicitly say “First 400 matching lines.” Unreadable files and files over 8 MB are counted as skipped. Hidden files and common generated directories are excluded.

## 5. Tabs and split editors

- Open several files. Drag one tab onto another to move it before that tab.
- Right-click a tab and choose Pin Tab. Pinned tabs stay before ordinary tabs and are preserved by Close Other Tabs. Pins for saved files are restored with the session.
- Close a saved file, then press **Shift-Command-T** to reopen it. Reopening uses the file on disk; it does not resurrect deliberately discarded unsaved edits.
- Open files with identical names in different folders. Their tab titles should include paths.
- Press **Command-Backslash** to split the editor. Use each pane’s document menu to choose its document. Click into either editor and verify typing and Run commands act on the focused document. Close the split with the same shortcut.
- In a single editor, the redundant path strip is absent; the tab still shows the edited dot and its tooltip provides the path. Split panes retain their document menus and Edited state.
- Try displaying the same script in both panes. Edits should appear in both; both editor instances remain registered. The path strip shows Edited when there are unsaved changes.

## 6. Variables and tables

- Run the notebook’s setup cells. Click Search Variables and search for `settings`. Use Filter and Sort Variables to choose a type or sort by Name/Type. The selected menu items should be checked. A selected type appears above the list with a clear button. Clear filters to restore every variable.
- Change `counter` and run the cell. New or changed variable summaries receive a dot on the next refresh.
- Click Inspect Variable beside `settings`. Expand the dict/list nodes to find `nested: 7`. Inspection is bounded to four levels and approximately 300 entries; it detects recursive references and labels shallow memory usage.
- Open `sample` as a table. Click Filter Table Rows, enter `keep`, and press Return. There should be three matching rows, including uppercase KEEP.
- Open Sort Table Rows and choose score. Ascending scores should be **1, 8, 20**; reverse the direction for **20, 8, 1**. Clear the filter and choose Original Order to restore **20, 3, 1, 8**.
- Filtering and sorting happen across the DataFrame in the kernel before paging. They leave the original Python variable unchanged. Text filtering searches the displayed columns (up to 60), case-insensitively.
- With a larger table, load another page after sorting/filtering; it should continue the same result order. An empty match should show No Matching Rows and allow clearing the filter.

## 7. Terminal

- Press **Control-Backtick** or choose Navigate → Show Terminal. Run `pwd`: a new session starts in the workspace directory. `cd` and shell state should persist across commands and panel switches.
- Run `printf '\033[31mred\033[0m\n'`. “red” should render in red. Try Up Arrow for shell history and Tab for shell completion.
- Run `sleep 30`, then press **Control-C**. The shell should return to its prompt.
- Run `stty size`, resize the bottom panel/window, then run it again. Rows and columns should change.
- Try `less README.md`, scroll, and press `q`. This checks a full-screen terminal application, not just line-oriented command execution.
- Switch to Python Console and back. The terminal session and scrollback should remain. Python Console still runs in the Python kernel; Terminal runs your login shell.
- Use the plus button for a new session. Replacing a running session asks before stopping its shell/foreground process. Type `exit`: the exit status and New Session action should appear.
- Terminal provides one session at a time. Existing sessions retain their current directory when the workspace changes; a new session starts in the new workspace. It does not automatically activate the selected Python environment.

## Git layout and design consistency

- Open Source Control at sidebar widths around **240, 260, and 400 points**. Branch/repository context should share a row, with upstream status and compact remote actions beneath it.
- Use **All / Staged / Unstaged** to scope the list. A file with staged content and newer working-tree edits appears in both groups under All, and in the correct group under each scope. Conflicts must remain visible in every scope. Switching scope must not change the commit message or commit summary.
- With no staged files, Staged should show No Staged Changes and Show All Changes. Stage a file and verify it appears; unstage it and verify the empty state returns.
- Commit remains the full-width primary workflow action. The scope summary distinguishes staged files from staging all files. Its shortcut is **Option-Command-Return**; **Command-Return** continues to run a cell.
- File statuses and staging actions remain visible. Discard appears on hover and remains available in the file context menu. Discarding still asks for confirmation.
- Check light/dark appearance, larger editor font sizes, keyboard-only navigation, and VoiceOver names. Verify that long names truncate with useful tooltips and that bottom-panel controls remain reachable.
- Primary bars, inset spacing, icon buttons, typography, and empty states reuse the existing design system. Compact secondary controls keep repository context from competing with the commit action.

## Automated verification

The final native UI refinement passed the Debug build, all **79 Swift regression tests**, and **2 Python workflow tests**. An additional temporary rendering check also passed and was removed after inspection. Isolated AppKit/SwiftUI previews were rendered in light/dark appearance, with Git at 240, 260, and 400 points, plus Variables, console, tables, the notebook editor, and the native search bar. These previews do not replace the interactive acceptance checks above; a full VoiceOver and live-window sweep remains.

- `./scripts/quanta build`
- `./scripts/quanta test`
- `/path/to/python-with-pandas scripts/test-ui-workflows.py`

The Swift suite covers staged/unstaged filtering with conflicts always visible, fuzzy file ranking, search options/globs, notebook match coordinates and truncation, stale-output state, traceback navigation, multiple registered editor views, real PTY input and sizing, Ctrl-C, and loading the bundled terminal renderer offline. The Python suite covers bounded nested previews and DataFrame filtering/sorting/paging without modifying the original variable.

See [native UI design decisions](native-ui-design.md) for the reference designs and rationale.
