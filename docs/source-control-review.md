# Source Control UX review

The panel now makes the daily review, stage, commit, and publish workflow more discoverable while retaining Quanta's native macOS controls. This is a focused improvement, not complete feature parity with a dedicated Git client.

## Implemented

- Repository identity, branch selection, upstream tracking, and visible Fetch, Pull, and Push/Publish controls. Repository and branch context share a row; upstream status and compact remote actions occupy the next row.
- Explicit “Commit Staged” versus “Stage All & Commit” labels, a commit scope summary, and a discoverable Option-Command-Return menu shortcut (Command-Return remains Run Cell). Return in the message field no longer directly commits.
- A stable commit composer even when the repository is clean.
- A native All / Staged / Unstaged scope control. Conflicts remain visible in every scope; empty scopes offer Show All Changes. The commit composer keeps its explicit repository-wide scope independent of list selection.
- Collapsible conflict, staged, and unstaged groups with persistent counts and staging actions. Discard remains available on hover and in context menus.
- Native list selection for keyboard navigation and diff review. File status remains visible beside staging and discard actions; directory and rename details have a secondary line.
- Dismissible errors in the panel with access to console details. Git actions are guarded against concurrent mutations.
- Remote capability checks: no publishing without commits, no branch publishing from detached HEAD, and no arbitrary remote selection when multiple non-origin remotes exist.
- Unstaging before an initial commit preserves working-tree files, including edits made after staging. An edited commit draft is preserved when an earlier commit completes.

## Remaining work, in priority order

| Priority | Workflow | Completion criteria |
| --- | --- | --- |
| 1 | Partial staging and diff review | Stage/unstage individual hunks or lines; navigate changes; offer unified and side-by-side views. Keep notebook source comparison intact. |
| 1 | Merge conflict resolution | Show base/current/incoming changes, allow choosing or editing the result, and expose merge/rebase continue and abort actions. Make unresolved state unmistakable. |
| 1 | Multiple-file operations | Command/Shift selection and context actions scoped to the selected files, with clear counts and discard confirmation. |
| 2 | Commit history and recovery | Browse commits and changed files; amend, revert, and undo a local commit with explicit effects and recovery guidance. |
| 2 | Stash and branch management | Save/restore named stashes; search local and remote branches; create tracking branches; compare branches; explain dirty-worktree checkout failures. |
| 2 | Remote setup and credentials | Add/edit/select remotes, establish an upstream, clone repositories, and provide actionable authentication and rejected-push recovery. Respect Git's configured push destination. |
| 2 | Durable feedback and drafts | Persist commit drafts per repository, show operation success and last-fetch time, and provide progress/cancellation for long remote operations. |
| 3 | Large workspaces | Optional tree grouping, multiple repository/worktree selection, and a way to inspect changes beyond the current untracked-file limit. |

## Verification

The initial Git pass passed a Debug build and 67 unit tests. The subsequent IDE workflow pass passed 78 Swift tests plus two Python workflow tests. See `ui-ux-verification.md` for the full verification checklist. New integration tests cover remote discovery and publish-target ambiguity, initial-commit unstaging with newer working-tree edits, and inline error state. Tests use temporary repositories and do not contact remote servers.

The native UI refinement rendered isolated panel previews at 240, 260, and 400 points in light/dark appearance, including staged and unstaged scopes. Live-window acceptance checks remain for VoiceOver, keyboard focus, collapse/expand behavior, large counts, and selection while staging. The new scope regression test verifies that conflicts never disappear when filtering.

## Reference

[VS Code's staging and committing workflow](https://code.visualstudio.com/docs/sourcecontrol/staging-commits) provides a useful comparison for explicit staged/unstaged groups, per-file actions, diff review, and partial staging. Quanta should preserve its native macOS interaction patterns while filling those workflow gaps.
