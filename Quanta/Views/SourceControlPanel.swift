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
            NavigatorEmptyState("No Folder Open", systemImage: "folder",
                                detail: "Open a folder to see its git changes.") {
                Button("Open Folder…") { app.openFolderPanel() }
                    .help("Open Folder as Workspace (⇧⌘O)")
            }
        case .gitMissing:
            NavigatorEmptyState("Git Not Found", systemImage: "arrow.triangle.branch",
                                detail: "Install the Xcode Command Line Tools, then relaunch Quanta to use source control.") {
                Button("Install Command Line Tools…") { app.installCommandLineTools() }
            }
        case .unknown:
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .notRepository:
            NavigatorEmptyState("Not a Git Repository", systemImage: "arrow.triangle.branch",
                                detail: "\(folderName) is not under version control yet.") {
                Button("Initialize Repository") { app.initializeRepository() }
                    .disabled(git.isBusy)
            }
        case .failed(let message):
            NavigatorEmptyState("Git Status Failed", systemImage: "exclamationmark.triangle",
                                detail: message) {
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
        if snapshot.isClean {
            NavigatorEmptyState("No Changes", systemImage: "checkmark.circle",
                                detail: snapshot.hiddenNotebooks.isEmpty
                                ? "On \(snapshot.headDescription). Your working tree is clean."
                                : "On \(snapshot.headDescription). No source changes. Notebook output changes are hidden.")
        } else {
            changeList(snapshot)
        }
        if !snapshot.hiddenNotebooks.isEmpty || snapshot.truncatedCount > 0 {
            footer(snapshot)
        }
        if !snapshot.isClean {
            commitBox(snapshot)
        }
        filterBar
    }

    private var filterBar: some View {
        PanelBar(height: DS.Bar.footer) {
            IconButton("arrow.clockwise", help: "Refresh Git Status") {
                app.refreshSourceControl()
            }
            .disabled(git.isBusy || git.isRefreshing)
            FilterField(text: $filenameFilter)
            if git.isBusy || git.isRefreshing {
                ActivitySlot(active: true)
            }
            IconMenu("ellipsis", help: "More Actions") {
                Picker("Show", selection: $scope) {
                    ForEach(GitChangeScope.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.inline)
                Divider()
                Button("Refresh Status") { app.refreshSourceControl() }
                Divider()
                Button("Stage All and Commit…") { app.stageAllAndCommit() }
                    .disabled(!hasCommitMessage || git.isBusy || !((git.snapshot?.conflicted.isEmpty) ?? false)
                              || ((git.snapshot?.unstaged.isEmpty) ?? true))
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

    private func branchMenu(_ snapshot: GitSnapshot) -> some View {
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
                    .font(.system(size: DS.Layout.symbolGlyph, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(snapshot.headDescription)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Image(systemName: "chevron.down")
                    .font(.system(size: DS.Layout.symbolGlyph, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func branchHelp(_ snapshot: GitSnapshot) -> String {
        var parts = ["Switch branch"]
        if let upstream = snapshot.upstream { parts.append("tracking \(upstream)") }
        if !snapshot.hasCommits { parts.append("no commits yet") }
        if snapshot.ahead > 0 || snapshot.behind > 0 { parts.append(syncHelp(snapshot)) }
        return parts.joined(separator: " · ")
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
            HStack(spacing: DS.Space.s) {
                branchMenu(snapshot)
                    .disabled(git.isBusy)
                    .fixedSize()
                Spacer(minLength: DS.Space.s)
                Button("Pull", systemImage: "arrow.down") { app.pull() }
                    .disabled(!git.canPull)
                    .help(pullHelp(snapshot))
                    .fixedSize()
                Button("Push", systemImage: "arrow.up") { app.push() }
                    .disabled(!git.canPush)
                    .help(pushHelp(snapshot))
                    .fixedSize()
                commitButton(snapshot)
            }
            .controlSize(.small)
        }
        .padding(.horizontal, DS.Space.bar)
        .padding(.vertical, DS.Space.m)
    }

    private func pullHelp(_ snapshot: GitSnapshot) -> String {
        if snapshot.behind > 0 {
            return "Pull \(snapshot.behind) commit\(snapshot.behind == 1 ? "" : "s")"
        }
        return "Pull from Upstream"
    }

    private func pushHelp(_ snapshot: GitSnapshot) -> String {
        if snapshot.ahead > 0 {
            return "Push \(snapshot.ahead) commit\(snapshot.ahead == 1 ? "" : "s")"
        }
        if snapshot.upstream == nil { return "Publish Branch" }
        return "Push to Remote"
    }

    private func commitButton(_ snapshot: GitSnapshot) -> some View {
        Button("Commit", systemImage: "checkmark") { app.commit() }
            .disabled(!canCommit(snapshot))
            .help(commitHelp(snapshot))
            .fixedSize()
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
        if snapshot.staged.isEmpty { return "Stage the changes you want to commit" }
        return "Commit staged changes (⌥⌘↩)"
    }

    private func filtered(_ changes: [GitChange]) -> [GitChange] {
        changes.filter { scope.includes($0.area) && (filenameFilter.isEmpty || $0.path.localizedStandardContains(filenameFilter)) }
    }

    private func changeList(_ snapshot: GitSnapshot) -> some View {
        List(selection: $selectedChangeID) {
            if !filtered(snapshot.conflicted).isEmpty {
                Section {
                    if conflictsExpanded {
                        ForEach(filtered(snapshot.conflicted)) { change in
                            GitChangeRow(change: change, isSelected: selectedChangeID == change.id)
                                .tag(change.id)
                        }
                    }
                } header: {
                    ChangeSectionHeader(title: "Conflicts", count: snapshot.conflicted.count, isExpanded: $conflictsExpanded) {
                        IconButton("checkmark", help: "Mark All Resolved") { app.markAllResolved() }
                    }
                    .contextMenu {
                        Button("Mark All Resolved") { app.markAllResolved() }
                    }
                }
            }
            if !filtered(snapshot.staged).isEmpty {
                Section {
                    if stagedExpanded {
                        ForEach(filtered(snapshot.staged)) { change in
                            GitChangeRow(change: change, isSelected: selectedChangeID == change.id)
                                .tag(change.id)
                        }
                    }
                } header: {
                    ChangeSectionHeader(title: "Staged Changes", count: snapshot.staged.count, isExpanded: $stagedExpanded) {
                        IconButton("minus", help: "Unstage All Changes") { app.unstageAllChanges() }
                    }
                    .contextMenu {
                        Button("Unstage All Changes") { app.unstageAllChanges() }
                    }
                }
            }
            if !filtered(snapshot.unstaged).isEmpty {
                Section {
                    if changesExpanded {
                        ForEach(filtered(snapshot.unstaged)) { change in
                            GitChangeRow(change: change, isSelected: selectedChangeID == change.id)
                                .tag(change.id)
                        }
                    }
                } header: {
                    ChangeSectionHeader(title: "Unstaged Changes", count: snapshot.unstaged.count, isExpanded: $changesExpanded) {
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
                    NavigatorEmptyState("No \(scope.rawValue) Changes", systemImage: "checkmark.circle",
                                        detail: scope == .staged ? "Stage files to include them in your next commit." : "All your changes have been staged.") {
                        Button("Show All Changes") { scope = .all }
                    }
                } else {
                    NavigatorEmptyState("No Results", systemImage: "magnifyingglass",
                                        detail: "No changed file matches “\(filenameFilter)”.")
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
        PanelBar {
            Image(systemName: "eye.slash")
            Text(footerText(snapshot))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
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
        if let snapshot = git.snapshot {
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
                .disabled(git.isBusy)
            }
        }
        Button("New Branch…") { app.createBranch() }
            .disabled(git.isBusy)
        Divider()
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
    }
}

private struct ChangeSectionHeader<Actions: View>: View {
    let title: String
    let count: Int
    @Binding var isExpanded: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ViewBuilder var actions: Actions
    @ObservedObject private var git = AppState.shared.git
    @State private var hovering = false

    init(title: String, count: Int, isExpanded: Binding<Bool>, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.count = count
        self._isExpanded = isExpanded
        self.actions = actions()
    }

    var body: some View {
        HStack(spacing: DS.Space.s) {
            Button {
                withAnimation(reduceMotion ? nil : DS.Motion.quick) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: DS.Space.s) {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .font(.caption.weight(.semibold))
                        .frame(width: DS.Layout.iconSlot)
                    Text(title)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("\(isExpanded ? "Collapse" : "Expand") \(title)")
            .accessibilityLabel(title)
            .accessibilityValue("\(isExpanded ? "Expanded" : "Collapsed"), \(count) files")
            Spacer(minLength: DS.Space.xs)
            HStack(spacing: 0) { actions }
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)
                .disabled(git.isBusy)
            Pill("\(count)", tone: .strong)
                .fixedSize()
                .accessibilityHidden(true)
        }
        .padding(.trailing, DS.Space.bar)
        .contentShape(Rectangle())
        .scrollAwareHover($hovering)
    }
}

struct GitChangeRow: View {
    let change: GitChange
    var isSelected = false
    private var app: AppState { AppState.shared }
    @ObservedObject private var git = AppState.shared.git
    @State private var hovering = false
    @FocusState private var discardFocused: Bool

    private var color: Color { DS.Git.color(for: change.status) }
    private var showsActions: Bool { hovering || isSelected || discardFocused }

    var body: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: FileNode.iconName(forExtension: change.url.pathExtension))
                .foregroundStyle(.secondary)
                .frame(width: DS.Layout.iconSlot)
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
        }
        .overlay(alignment: .trailing) {
            HStack(spacing: 0) {
                actions
                Color.clear.frame(width: DS.Layout.statusSlot)
            }
            .opacity(showsActions ? 1 : 0)
            .allowsHitTesting(showsActions)
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
        if change.existsOnDisk {
            IconButton("arrow.up.forward", help: "Open File") { app.openFile(change.url) }
        }
        switch change.area {
        case .unstaged:
            IconButton("arrow.uturn.backward",
                       help: change.status == .untracked ? "Move to Trash…" : "Discard Changes…") {
                app.discardChanges(change)
            }
            .focused($discardFocused)
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
