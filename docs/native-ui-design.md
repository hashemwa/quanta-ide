# Native UI refinement

Quanta keeps its macOS window structure and system-rendered controls while reducing the permanent chrome around notebooks. The reference study used official documentation and published screenshots from Xcode, VS Code, Zed, and JupyterLab. These are workflow and hierarchy references, not copied visual assets.

## Reference decisions

| Reference | Observation and application in Quanta |
| --- | --- |
| [Apple HIG: segmented controls](https://developer.apple.com/design/human-interface-guidelines/segmented-controls) | Use short, closely related choices and omit introductory text when labels explain the choice. All / Staged / Unstaged and Python Console / Terminal use the same small native picker, with an accessibility label but no visible form label. |
| [Apple HIG: toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars) | Group actions around the content they affect. Each panel has a compact header with consistently sized actions. Secondary search appears when requested. |
| [Xcode navigator](https://help.apple.com/xcode/mac/current/en.lproj/dev60244b45c.html) | A stable navigator bar, a content list, and native filtering controls establish a clear hierarchy. Quanta retains native list selection and uses NSSearchField for optional panel search. The published Xcode help screenshot is an older reference, not a claim to reproduce Xcode 26 exactly. |
| [VS Code source control](https://code.visualstudio.com/docs/sourcecontrol/overview) | Staged Changes and Changes are separate groups with contextual file actions. Quanta preserves that distinction, labels the latter Unstaged Changes, and adds the requested scope selector. VS Code's grouped staging workflow is distinct from a filename search. |
| [Zed Git](https://zed.dev/git) and [Git documentation](https://zed.dev/docs/git) | Compact repository controls and file-local staging keep review central. Quanta keeps the composer at the top for continuity and explicitly states whether a commit stages everything or commits only staged files. |
| [JupyterLab interface](https://jupyterlab.readthedocs.io/en/stable/user/interface.html) | Documents and notebooks occupy the main work area, with supporting tools in adjacent panels. Quanta removes its redundant single-editor path strip while retaining document identity controls where split panes need them. |

## Shared control rules

- Primary bars remain 32 points; secondary bars remain 28 points, with 10-point horizontal insets and existing icon hit areas.
- Segmented scope controls, menus, search fields, and list selection use native rendering. No extra glass, gradients, or custom dropdown borders were introduced.
- Text entry is reserved for text tasks. Variable types, console message kinds, and table sorting use checked menu choices.
- Search is opened by the same magnifying-glass action in Variables, Console, and Tables. A native search field and close action appear beneath the header.
- Closing console or variable search clears that text filter. Table search is submitted with Return; closing its field leaves the applied filter visible in the table status strip. Reset restores all rows and original order.
- Active variable types and console scopes remain visible. Empty variable results have a clear-filter recovery action.
- The Git scope selector is left aligned with the composer and list. The sidebar has a 240-point minimum, a 260-point preferred width, and a 400-point maximum.
- Conflicts are always included in Git's list, even when Staged or Unstaged is selected. List scope does not change commit semantics or drafts.
- A single editor uses its tab for identity and dirty state. Split editors retain a native document menu per pane.

## Verification scope

The preview review renders the actual SwiftUI/AppKit panels in an isolated test process; it does not relaunch the user's current app or synthesize input into their workspace. It covers compact/default/wide Git widths, both appearances, Variables, Console, Tables, the notebook editor, native search, and programmatic selection of the Git scope control. The temporary render harness is removed after review; the behavior regression test remains.

Use [the verification checklist](ui-ux-verification.md) for live-window resizing, staging transitions, table filtering, terminal interaction, keyboard navigation, and VoiceOver. A visual cleanup is not a claim of complete IDE feature parity or a substitute for user testing.
