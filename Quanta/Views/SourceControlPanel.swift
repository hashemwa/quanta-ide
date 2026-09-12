import AppKit
import SwiftUI

struct SourceControlPanel: View {
    private var app: AppState { AppState.shared }
    @ObservedObject private var git = AppState.shared.git
    @ObservedObject private var draft = AppState.shared.git.draft
    @FocusState private var messageFocused: Bool

    var body: some View {
        VStack(spacing: 0) { content }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var content: some View {
        switch git.availability {
        case .noWorkspace:
            ContentUnavailableView {
                Label("No Folder Open", systemImage: "folder")
            } description: {
                Text("Open a folder to see its git changes.")
            } actions: {
                Button("Open Folder…") { app.openFolderPanel() }
                    .help("Open a folder as the workspace (⇧⌘O)")
            }
        case .gitMissing:
            ContentUnavailableView {
                Label("Git Not Found", systemImage: "arrow.triangle.branch")
            } description: {
                Text("Install the Xcode Command Line Tools, then relaunch Quanta to use source control.")
            } actions: {
                Button("Install Command Line Tools…") { app.installCommandLineTools() }
            }
        case .unknown:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .notRepository:
            ContentUnavailableView {
                Label("Not a Git Repository", systemImage: "arrow.triangle.branch")
            } description: {
                Text("\(folderName) is not under version control yet.")
            } actions: {
                Button("Initialize Repository") { app.initializeRepository() }
                    .disabled(git.isBusy)
            }
        case .failed(let message):
            ContentUnavailableView {
                Label("Git Status Failed", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { app.refreshSourceControl() }
            }
        case .ready:
            if let snapshot = git.snapshot {
                repository(snapshot)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var folderName: String {
        git.workspace?.lastPathComponent ?? "This folder"
    }

    @ViewBuilder
    private func repository(_ snapshot: GitSnapshot) -> some View {
        branchRow(snapshot)
        if snapshot.isClean {
            Divider()
            ContentUnavailableView {
                Label("No Changes", systemImage: "checkmark.circle")
            } description: {
                Text("The working tree is clean.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: draft.focusRequest, initial: true) { _, value in
                draft.handledFocusRequest = value
            }
        } else {
            commitBox(snapshot)
            Divider()
            changeList(snapshot)
        }
        if !snapshot.hiddenNotebooks.isEmpty || snapshot.truncatedCount > 0 {
            footer(snapshot)
        }
    }

    private func branchRow(_ snapshot: GitSnapshot) -> some View {
        PanelBar(rule: .none) {
            LabelMenu(help: branchHelp(snapshot),
                      accessibilityName: "Branch \(snapshot.headDescription)") {
                ForEach(snapshot.branches, id: \.self) { branch in
                    Button {
                        app.checkout(branch: branch)
                    } label: {
                        if branch == snapshot.branch {
                            Label(branch, systemImage: "checkmark")
                        } else {
                            Text(branch)
                        }
                    }
                }
                if !snapshot.branches.isEmpty {
                    Divider()
                }
                Button("New Branch…") { app.createBranch() }
            } label: {
                HStack(spacing: DS.Space.xs) {
                    Image(systemName: "arrow.triangle.branch")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(snapshot.headDescription)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .disabled(git.isBusy)
            Spacer(minLength: DS.Space.s)
            branchTrailing(snapshot)
        }
    }

    @ViewBuilder
    private func branchTrailing(_ snapshot: GitSnapshot) -> some View {
        if let operation = git.activeOperation {
            Text(operation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .layoutPriority(1)
        } else if snapshot.ahead > 0 || snapshot.behind > 0 {
            Text(syncLabel(snapshot))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .fixedSize()
                .layoutPriority(1)
                .help(syncHelp(snapshot))
        }
    }

    private func branchHelp(_ snapshot: GitSnapshot) -> String {
        var parts = ["Switch branch"]
        if let upstream = snapshot.upstream { parts.append("tracking \(upstream)") }
        if !snapshot.hasCommits { parts.append("no commits yet") }
        return parts.joined(separator: " · ")
    }

    private func syncLabel(_ snapshot: GitSnapshot) -> String {
        var parts: [String] = []
        if snapshot.ahead > 0 { parts.append("↑\(snapshot.ahead)") }
        if snapshot.behind > 0 { parts.append("↓\(snapshot.behind)") }
        return parts.joined(separator: " ")
    }

    private func syncHelp(_ snapshot: GitSnapshot) -> String {
        var parts: [String] = []
        if snapshot.ahead > 0 {
            parts.append("\(snapshot.ahead) commit\(snapshot.ahead == 1 ? "" : "s") to push")
        }
        if snapshot.behind > 0 {
            parts.append("\(snapshot.behind) commit\(snapshot.behind == 1 ? "" : "s") to pull")
        }
        return parts.joined(separator: ", ")
    }

    private func commitBox(_ snapshot: GitSnapshot) -> some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            TextField("Message", text: $draft.message, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.callout)
                .lineLimit(DS.Layout.commitLines)
                .padding(.horizontal, DS.Space.s)
                .padding(.vertical, DS.Space.xs)
                .inputCard(focused: messageFocused)
                .focused($messageFocused)
                .onSubmit { app.commit() }
                .onChange(of: draft.focusRequest, initial: true) { _, value in
                    guard value != draft.handledFocusRequest else { return }
                    draft.handledFocusRequest = value
                    DispatchQueue.main.async { messageFocused = true }
                }
            HStack(spacing: DS.Space.s) {
                Text(commitSummary(snapshot))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                Spacer(minLength: DS.Space.s)
                Button("Commit") { app.commit() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(!canCommit(snapshot))
                    .help(commitHelp(snapshot))
            }
        }
        .padding(.horizontal, DS.Space.bar)
        .padding(.vertical, DS.Space.s)
    }

    private func canCommit(_ snapshot: GitSnapshot) -> Bool {
        !git.isBusy
            && !draft.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && snapshot.conflicted.isEmpty
            && !(snapshot.staged.isEmpty && snapshot.unstaged.isEmpty)
    }

    private func commitHelp(_ snapshot: GitSnapshot) -> String {
        if !snapshot.conflicted.isEmpty { return "Resolve the conflicts before committing" }
        if snapshot.staged.isEmpty { return "Stage and commit all changes (↩ in the message field)" }
        return "Commit the staged changes (↩ in the message field)"
    }

    private func commitSummary(_ snapshot: GitSnapshot) -> String {
        if !snapshot.conflicted.isEmpty {
            let count = snapshot.conflicted.count
            return "\(count) conflict\(count == 1 ? "" : "s") to resolve"
        }
        if !snapshot.staged.isEmpty {
            return "\(snapshot.staged.count) staged"
        }
        if !snapshot.unstaged.isEmpty {
            let count = snapshot.unstaged.count
            return "all \(count) change\(count == 1 ? "" : "s")"
        }
        return ""
    }

    private func changeList(_ snapshot: GitSnapshot) -> some View {
        List {
            if !snapshot.conflicted.isEmpty {
                Section {
                    ForEach(snapshot.conflicted) { change in
                        GitChangeRow(change: change)
                    }
                } header: {
                    ChangeSectionHeader(title: "Conflicts", count: snapshot.conflicted.count) {
                        IconButton("checkmark", help: "Mark All Resolved") { app.markAllResolved() }
                    }
                    .contextMenu {
                        Button("Mark All Resolved") { app.markAllResolved() }
                    }
                }
            }
            if !snapshot.staged.isEmpty {
                Section {
                    ForEach(snapshot.staged) { change in
                        GitChangeRow(change: change)
                    }
                } header: {
                    ChangeSectionHeader(title: "Staged Changes", count: snapshot.staged.count) {
                        IconButton("minus", help: "Unstage All Changes") { app.unstageAllChanges() }
                    }
                    .contextMenu {
                        Button("Unstage All Changes") { app.unstageAllChanges() }
                    }
                }
            }
            if !snapshot.unstaged.isEmpty {
                Section {
                    ForEach(snapshot.unstaged) { change in
                        GitChangeRow(change: change)
                    }
                } header: {
                    ChangeSectionHeader(title: "Changes", count: snapshot.unstaged.count) {
                        IconButton("arrow.uturn.backward", help: "Discard All Changes…") {
                            app.discardAllChanges()
                        }
                        IconButton("plus", help: "Stage All Changes") { app.stageAllChanges() }
                    }
                    .contextMenu {
                        Button("Stage All Changes") { app.stageAllChanges() }
                        Button("Discard All Changes…", role: .destructive) { app.discardAllChanges() }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .environment(\.defaultMinListRowHeight, DS.Layout.listRowMinHeight)
    }

    private func footer(_ snapshot: GitSnapshot) -> some View {
        PanelBar(rule: .above) {
            Image(systemName: "eye.slash")
            Text(footerText(snapshot))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.tertiary)
        .contentShape(Rectangle())
        .help(footerHelp(snapshot))
        .contextMenu {
            if !snapshot.hiddenNotebooks.isEmpty {
                Button("Discard Output-Only Changes…", role: .destructive) {
                    app.discardOutputOnlyChanges()
                }
            }
        }
    }

    private func footerText(_ snapshot: GitSnapshot) -> String {
        var parts: [String] = []
        let hidden = snapshot.hiddenNotebooks.count
        if hidden > 0 {
            parts.append("\(hidden) notebook\(hidden == 1 ? "" : "s") changed outputs only")
        }
        if snapshot.truncatedCount > 0 {
            parts.append("\(snapshot.truncatedCount) more untracked files not listed")
        }
        return parts.joined(separator: " · ")
    }

    private func footerHelp(_ snapshot: GitSnapshot) -> String {
        var parts: [String] = []
        if !snapshot.hiddenNotebooks.isEmpty {
            parts.append("Notebooks whose only differences are outputs, execution counts or metadata are hidden: "
                + snapshot.hiddenNotebooks.map(\.fileName).joined(separator: ", ")
                + ". Stage All and Commit skip them; right-click to discard those output changes.")
        }
        if snapshot.truncatedCount > 0 {
            parts.append("Only the first \(GitSnapshot.maximumEntries) untracked files are listed.")
        }
        return parts.joined(separator: " ")
    }
}

struct SourceControlActions: View {
    private var app: AppState { AppState.shared }
    @ObservedObject private var git = AppState.shared.git

    var body: some View {
        HStack(spacing: DS.Space.xxs) {
            ActivitySlot(active: git.isBusy || git.isRefreshing)
            IconButton("arrow.clockwise", help: "Refresh Status") { app.refreshSourceControl() }
                .disabled(git.availability == .noWorkspace || git.availability == .gitMissing)
            IconMenu("ellipsis", help: "Show more actions") { SourceControlMenuItems() }
                .disabled(git.availability != .ready)
        }
    }
}

struct SourceControlMenuItems: View {
    private var app: AppState { AppState.shared }
    @ObservedObject private var git = AppState.shared.git

    var body: some View {
        Button("Fetch") { app.fetch() }
            .disabled(git.isBusy)
        Button("Pull") { app.pull() }
            .disabled(git.isBusy)
        Button("Push") { app.push() }
            .disabled(git.isBusy)
        Divider()
        Button("Stage All Changes") { app.stageAllChanges() }
            .disabled(git.snapshot?.unstaged.isEmpty ?? true)
        Button("Unstage All Changes") { app.unstageAllChanges() }
            .disabled(git.snapshot?.staged.isEmpty ?? true)
        Button("Mark All Resolved") { app.markAllResolved() }
            .disabled(git.snapshot?.conflicted.isEmpty ?? true)
        Button("Discard All Changes…", role: .destructive) { app.discardAllChanges() }
            .disabled(git.snapshot?.unstaged.isEmpty ?? true)
        Button("Discard Output-Only Changes…", role: .destructive) { app.discardOutputOnlyChanges() }
            .disabled(git.snapshot?.hiddenNotebooks.isEmpty ?? true)
        Divider()
        Button("New Branch…") { app.createBranch() }
            .disabled(git.isBusy)
    }
}

private struct ChangeSectionHeader<Actions: View>: View {
    let title: String
    let count: Int
    @ViewBuilder var actions: Actions
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(title: String, count: Int, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.count = count
        self.actions = actions()
    }

    var body: some View {
        HStack(spacing: DS.Space.s) {
            Text(title)
            Spacer(minLength: DS.Space.xs)
            ZStack(alignment: .trailing) {
                Text("\(count)")
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .opacity(hovering ? 0 : 1)
                HStack(spacing: 0) { actions }
                    .opacity(hovering ? 1 : 0)
                    .allowsHitTesting(hovering)
            }
            .frame(width: DS.Layout.rowActionSlot, alignment: .trailing)
            .animation(reduceMotion ? nil : DS.Motion.hover, value: hovering)
        }
        .contentShape(Rectangle())
        .scrollAwareHover($hovering)
    }
}

struct GitChangeRow: View {
    let change: GitChange
    private var app: AppState { AppState.shared }
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var color: Color { DS.Git.color(for: change.status) }

    var body: some View {
        Button {
            app.openDiff(for: change)
        } label: {
            HStack(spacing: DS.Space.s) {
                Label {
                    HStack(spacing: DS.Space.xs) {
                        Text(change.fileName)
                            .strikethrough(change.status == .deleted)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        if !change.directory.isEmpty {
                            Text(change.directory)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                    }
                } icon: {
                    Image(systemName: FileNode.iconName(forExtension: change.url.pathExtension))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: DS.Space.xs)
                trailing
            }
            .frame(minHeight: DS.Layout.listRowMinHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight()
        .scrollAwareHover($hovering)
        .help("\(change.status.label) · \(change.path)")
        .contextMenu { menuItems }
    }

    private var trailing: some View {
        ZStack(alignment: .trailing) {
            Text(change.status.letter)
                .font(.caption.monospaced().weight(.semibold))
                .foregroundStyle(color)
                .help(change.status.label)
                .frame(width: DS.Layout.statusSlot, alignment: .trailing)
                .opacity(hovering ? 0 : 1)
            HStack(spacing: 0) { actions }
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)
        }
        .frame(width: DS.Layout.rowActionSlot, alignment: .trailing)
        .animation(reduceMotion ? nil : DS.Motion.hover, value: hovering)
    }

    @ViewBuilder
    private var actions: some View {
        switch change.area {
        case .unstaged:
            IconButton("arrow.uturn.backward",
                       help: change.status == .untracked ? "Move to Trash…" : "Discard Changes…") {
                app.discardChanges(change)
            }
            IconButton("plus", help: "Stage Changes") { app.stage(change) }
        case .staged:
            IconButton("minus", help: "Unstage Changes") { app.unstage(change) }
        case .conflicted:
            IconButton("checkmark", help: "Mark Resolved") { app.stage(change) }
        }
    }

    @ViewBuilder
    private var menuItems: some View {
        Button("Show Changes") { app.openDiff(for: change) }
        if change.existsOnDisk {
            Button("Open File") { app.openFile(change.url) }
        }
        Divider()
        switch change.area {
        case .unstaged:
            Button("Stage Changes") { app.stage(change) }
            Button(change.status == .untracked ? "Move to Trash…" : "Discard Changes…",
                   role: .destructive) {
                app.discardChanges(change)
            }
        case .staged:
            Button("Unstage Changes") { app.unstage(change) }
        case .conflicted:
            Button("Mark Resolved") { app.stage(change) }
        }
        Divider()
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([change.url])
        }
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(change.url.path, forType: .string)
        }
    }
}
