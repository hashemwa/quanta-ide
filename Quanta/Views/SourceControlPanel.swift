import AppKit
import SwiftUI

struct SourceControlPanel: View {
    @ObservedObject private var app = AppState.shared
    @ObservedObject private var git = AppState.shared.git
    @ObservedObject private var draft = AppState.shared.git.draft
    @FocusState private var messageFocused: Bool
    @State private var scope = GitChangeScope.all
    @State private var selectedChangeID: String?
    @State private var conflictsExpanded = true
    @State private var stagedExpanded = true
    @State private var changesExpanded = true
    @State private var filenameFilter = ""

    var body: some View {
        VStack(spacing: 0) {
            if let error = git.operationError { errorBanner(error) }
            content
        }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .onChange(of: git.workspace) { _, _ in
                scope = .all
                selectedChangeID = nil
                filenameFilter = ""
            }
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
            ContentUnavailableView {
                Label("No Changes", systemImage: "checkmark.circle")
            } description: {
                Text(snapshot.hiddenNotebooks.isEmpty
                     ? "Your working tree is clean."
                     : "No source changes. Notebook output changes are hidden.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            changeList(snapshot)
        }
        if !snapshot.hiddenNotebooks.isEmpty || snapshot.truncatedCount > 0 {
            footer(snapshot)
        }
        if !snapshot.isClean {
            Divider()
            commitBox(snapshot)
        }
        filterBar
    }

    private var filterBar: some View {
        PanelBar(height: DS.Bar.footer, rule: .above) {
            FilterField(text: $filenameFilter,
                        prompt: scope == .all ? "Filter" : "Filter \(scope.rawValue)")
            IconMenu("ellipsis", help: "Show more actions") {
                Picker("Show", selection: $scope) {
                    ForEach(GitChangeScope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.inline)
                Divider()
                Button("Refresh Status") { app.refreshSourceControl() }
                Divider()
                SourceControlMenuItems()
            }
        }
    }

    private func errorBanner(_ error: String) -> some View {
        HStack(alignment: .top, spacing: DS.Space.s) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(DS.Git.modified)
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text(error).lineLimit(4).help(error)
                Button("Show Details in Console") { app.focusConsoleInput() }
                    .buttonStyle(.link)
            }
            Spacer(minLength: 0)
            IconButton("xmark", help: "Dismiss Git Error") { git.dismissError() }
        }
        .font(.caption)
        .padding(DS.Space.bar)
        .background(DS.Git.modified.opacity(0.1))
        .accessibilityElement(children: .contain)
    }

    private func remoteDescription(_ snapshot: GitSnapshot) -> String {
        if snapshot.isDetached { return "Detached HEAD" }
        if let upstream = snapshot.upstream { return "Tracking \(upstream)" }
        return snapshot.remotes.isEmpty ? "Local repository · no remote" : "Branch not published"
    }

    private func branchRow(_ snapshot: GitSnapshot) -> some View {
        PanelBar(rule: .below) {
            LabelMenu(help: branchHelp(snapshot),
                      accessibilityName: "Branch \(snapshot.headDescription)") {
                Text(remoteDescription(snapshot))
                Divider()
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
            ActivitySlot(active: git.isBusy || git.isRefreshing)
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
            TextField("Commit message", text: $draft.message, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.callout)
                .lineLimit(DS.Layout.commitLines)
                .padding(.horizontal, DS.Space.s)
                .padding(.vertical, DS.Space.xs)
                .inputCard(focused: messageFocused)
                .focused($messageFocused)
                .accessibilityLabel("Commit message")
                .onChange(of: draft.focusRequest, initial: true) { _, value in
                    guard value != draft.handledFocusRequest else { return }
                    draft.handledFocusRequest = value
                    DispatchQueue.main.async { messageFocused = true }
                }
            HStack(alignment: .firstTextBaseline, spacing: DS.Space.s) {
                Text(commitSummary(snapshot))
                    .font(.caption)
                    .foregroundStyle(snapshot.conflicted.isEmpty ? Color.secondary : DS.Git.removed)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: DS.Space.s)
                if snapshot.staged.isEmpty && !snapshot.unstaged.isEmpty {
                    Button("Stage All and Commit") { app.stageAllAndCommit() }
                        .disabled(!hasCommitMessage || git.isBusy || !snapshot.conflicted.isEmpty)
                        .help(commitHelp(snapshot))
                } else {
                    Button("Commit") { app.commit() }
                        .disabled(!canCommit(snapshot))
                        .help(commitHelp(snapshot))
                }
            }
            .controlSize(.small)
        }
        .padding(.horizontal, DS.Space.bar)
        .padding(.vertical, DS.Space.m)
    }

    private var hasCommitMessage: Bool {
        !draft.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func canCommit(_ snapshot: GitSnapshot) -> Bool {
        !git.isBusy && hasCommitMessage && snapshot.conflicted.isEmpty && !snapshot.staged.isEmpty
    }

    private func commitHelp(_ snapshot: GitSnapshot) -> String {
        if !snapshot.conflicted.isEmpty { return "Resolve the conflicts before committing" }
        if snapshot.isClean { return "Make changes before committing" }
        if !hasCommitMessage { return "Enter a commit message" }
        if snapshot.staged.isEmpty { return "Stage every change, then commit" }
        return "Commit the staged changes (⌥⌘↩)"
    }

    private func commitSummary(_ snapshot: GitSnapshot) -> String {
        if !snapshot.conflicted.isEmpty {
            let count = snapshot.conflicted.count
            return "\(count) conflict\(count == 1 ? "" : "s") to resolve"
        }
        if !snapshot.staged.isEmpty {
            let staged = snapshot.staged.count
            let remaining = snapshot.unstaged.count
            return "\(staged) staged file\(staged == 1 ? "" : "s")"
                + (remaining > 0 ? " · \(remaining) unstaged, excluded" : " ready to commit")
        }
        if !snapshot.unstaged.isEmpty {
            let count = snapshot.unstaged.count
            return "\(count) unstaged file\(count == 1 ? "" : "s"), nothing staged"
        }
        return "No changes to commit."
    }

    private func filtered(_ changes: [GitChange]) -> [GitChange] {
        changes.filter { scope.includes($0.area) && (filenameFilter.isEmpty || $0.path.localizedStandardContains(filenameFilter)) }
    }

    private func changeList(_ snapshot: GitSnapshot) -> some View {
        List(selection: $selectedChangeID) {
            if !filtered(snapshot.conflicted).isEmpty {
                Section(isExpanded: $conflictsExpanded) {
                    ForEach(filtered(snapshot.conflicted)) { change in
                        GitChangeRow(change: change)
                            .tag(change.id)
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
            if !filtered(snapshot.staged).isEmpty {
                Section(isExpanded: $stagedExpanded) {
                    ForEach(filtered(snapshot.staged)) { change in
                        GitChangeRow(change: change)
                            .tag(change.id)
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
            if !filtered(snapshot.unstaged).isEmpty {
                Section(isExpanded: $changesExpanded) {
                    ForEach(filtered(snapshot.unstaged)) { change in
                        GitChangeRow(change: change)
                            .tag(change.id)
                    }
                } header: {
                    ChangeSectionHeader(title: "Unstaged Changes", count: snapshot.unstaged.count) {
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
        .overlay {
            if filtered(snapshot.visibleChanges).isEmpty {
                if filenameFilter.isEmpty {
                    ContentUnavailableView {
                        Label("No \(scope.rawValue) Changes", systemImage: "checkmark.circle")
                    } description: {
                        Text(scope == .staged ? "Stage files to include them in your next commit." : "All your changes have been staged.")
                    } actions: {
                        Button("Show All Changes") { scope = .all }
                    }
                } else {
                    ContentUnavailableView.search(text: filenameFilter)
                }
            }
        }
        .onChange(of: selectedChangeID) { _, id in
            guard let change = snapshot.visibleChanges.first(where: { $0.id == id }) else { return }
            if app.activeDocument?.diffSource != DiffSource(change: change) {
                app.openDiff(for: change)
            }
        }
        .onChange(of: app.activeDocument?.diffSource, initial: true) { _, source in
            selectedChangeID = snapshot.visibleChanges.first { DiffSource(change: $0) == source }?.id
        }
        .onChange(of: scope) { _, _ in
            selectedChangeID = nil
            conflictsExpanded = true
            stagedExpanded = true
            changesExpanded = true
        }
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

struct SourceControlMenuItems: View {
    private var app: AppState { AppState.shared }
    @ObservedObject private var git = AppState.shared.git

    var body: some View {
        Button("Fetch") { app.fetch() }
            .disabled(!git.canFetch)
        Button("Pull") { app.pull() }
            .disabled(!git.canPull)
        Button("Push") { app.push() }
            .disabled(!git.canPush)
        Divider()
        Button("Stage All Changes") { app.stageAllChanges() }
            .disabled(git.isBusy || (git.snapshot?.unstaged.isEmpty ?? true))
        Button("Unstage All Changes") { app.unstageAllChanges() }
            .disabled(git.isBusy || (git.snapshot?.staged.isEmpty ?? true))
        Button("Mark All Resolved") { app.markAllResolved() }
            .disabled(git.isBusy || (git.snapshot?.conflicted.isEmpty ?? true))
        Button("Discard All Changes…", role: .destructive) { app.discardAllChanges() }
            .disabled(git.isBusy || (git.snapshot?.unstaged.isEmpty ?? true))
        Button("Discard Output-Only Changes…", role: .destructive) { app.discardOutputOnlyChanges() }
            .disabled(git.isBusy || (git.snapshot?.hiddenNotebooks.isEmpty ?? true))
        Divider()
        Button("New Branch…") { app.createBranch() }
            .disabled(git.isBusy)
    }
}

private struct ChangeSectionHeader<Actions: View>: View {
    let title: String
    let count: Int
    @ViewBuilder var actions: Actions
    @ObservedObject private var git = AppState.shared.git

    init(title: String, count: Int, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.count = count
        self.actions = actions()
    }

    var body: some View {
        HStack(spacing: DS.Space.s) {
            Text(title).lineLimit(1)
            Text("\(count)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .padding(.horizontal, DS.Space.xs)
                .background(.quaternary, in: Capsule())
                .fixedSize()
            Spacer(minLength: DS.Space.xs)
            HStack(spacing: 0) { actions }
                .disabled(git.isBusy)
        }
        .contentShape(Rectangle())
    }
}

struct GitChangeRow: View {
    let change: GitChange
    private var app: AppState { AppState.shared }
    @ObservedObject private var git = AppState.shared.git
    @State private var hovering = false

    private var color: Color { DS.Git.color(for: change.status) }

    var body: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: FileNode.iconName(forExtension: change.url.pathExtension))
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                Text(change.fileName)
                    .strikethrough(change.status == .deleted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let original = change.originalPath {
                    Text("\(original) → \(change.path)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else if !change.directory.isEmpty {
                    Text(change.directory)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(change.status.letter)
                .font(.caption.monospaced().weight(.semibold))
                .foregroundStyle(color)
                .frame(width: DS.Layout.statusSlot)
                .help(change.status.label)
                .accessibilityLabel(change.status.label)
            HStack(spacing: 0) { actions }
                .disabled(git.isBusy)
        }
        .frame(minHeight: DS.Layout.listRowMinHeight)
        .contentShape(Rectangle())
        .scrollAwareHover($hovering)
        .help("\(change.area.label) · \(change.status.label) · \(change.path)")
        .contextMenu { menuItems }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(change.fileName), \(change.area.label), \(change.status.label)")
    }

    @ViewBuilder
    private var actions: some View {
        switch change.area {
        case .unstaged:
            IconButton("arrow.uturn.backward",
                       help: change.status == .untracked ? "Move to Trash…" : "Discard Changes…") {
                app.discardChanges(change)
            }
            .opacity(hovering ? 1 : 0)
            .allowsHitTesting(hovering)
            .accessibilityHidden(!hovering)
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
