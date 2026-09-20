import AppKit
import Combine
import Foundation

enum SidebarPane: String, CaseIterable {
    case files
    case sourceControl
    case search

    var title: String {
        switch self {
        case .files: return "Files"
        case .search: return "Search"
        case .sourceControl: return "Source Control"
        }
    }

    var icon: String {
        switch self {
        case .files: return "folder"
        case .search: return "magnifyingglass"
        case .sourceControl: return "arrow.triangle.branch"
        }
    }

    var help: String {
        switch self {
        case .files: return "Show Files (⌘1)"
        case .search: return "Search in Workspace (⇧⌘F)"
        case .sourceControl: return "Show Source Control (⌘2)"
        }
    }
}

final class CommitDraft: ObservableObject {
    @Published var message = ""
    @Published var focusRequest = 0
    var handledFocusRequest = 0
}

final class SourceControlState: ObservableObject {
    enum Availability: Equatable {
        case noWorkspace
        case gitMissing
        case unknown
        case notRepository
        case failed(String)
        case ready
    }

    static let hideOutputOnlyKey = "QuantaGitHideOutputOnlyNotebooks"

    @Published private(set) var availability: Availability = .noWorkspace
    @Published private(set) var snapshot: GitSnapshot?
    @Published private(set) var isRefreshing = false
    @Published private(set) var activeOperation: String?
    @Published private(set) var operationError: String?
    let draft = CommitDraft()

    var onFailure: ((String, String) -> Void)?
    var onSnapshot: (() -> Void)?

    private(set) var workspace: URL?
    private var generation = 0
    private var refreshPending = false
    private var operationsInFlight = 0

    var hidesOutputOnlyNotebooks: Bool {
        QuantaDefaults.store.object(forKey: Self.hideOutputOnlyKey) as? Bool ?? true
    }

    var isBusy: Bool { activeOperation != nil }
    var canFetch: Bool { !isBusy && !(snapshot?.remotes.isEmpty ?? true) }
    var canPull: Bool { canFetch && snapshot?.upstream != nil && snapshot?.isDetached == false }
    var canPush: Bool {
        canFetch && snapshot?.hasCommits == true && snapshot?.isDetached == false
            && (snapshot?.upstream != nil || snapshot?.publishRemote != nil)
    }

    func setWorkspace(_ url: URL?) {
        workspace = url
        generation += 1
        snapshot = nil
        operationError = nil
        draft.message = ""
        if url == nil {
            availability = .noWorkspace
        } else if GitClient.executable == nil {
            availability = .gitMissing
        } else {
            availability = .unknown
        }
        refresh()
    }

    func refresh() {
        guard let workspace, GitClient.executable != nil else { return }
        if isRefreshing {
            refreshPending = true
            return
        }
        isRefreshing = true
        let gen = generation
        let hide = hidesOutputOnlyNotebooks
        GitClient.queue.async { [weak self] in
            let loaded = GitSnapshot.load(workspace: workspace, hideOutputOnlyNotebooks: hide)
            DispatchQueue.main.async {
                guard let self else { return }
                self.isRefreshing = false
                if self.generation == gen {
                    switch loaded {
                    case .none:
                        self.snapshot = nil
                        self.availability = .notRepository
                    case .success(let snapshot):
                        self.snapshot = snapshot
                        self.availability = .ready
                    case .failure(let error):
                        self.availability = self.snapshot == nil ? .failed(error.message) : .ready
                        self.reportFailure("Refresh", error.message)
                    }
                    self.onSnapshot?()
                }
                if self.refreshPending {
                    self.refreshPending = false
                    self.refresh()
                }
            }
        }
    }

    func perform(_ verb: String, progress: String, completion: ((Bool) -> Void)? = nil,
                 _ work: @escaping (URL) -> GitCommandResult) {
        guard !isBusy, let root = snapshot?.root else {
            completion?(false)
            return
        }
        beginOperation(progress)
        let gen = generation
        GitClient.queue.async { [weak self] in
            let result = work(root)
            DispatchQueue.main.async {
                guard let self else { return }
                self.endOperation()
                guard self.generation == gen else {
                    completion?(false)
                    return
                }
                if !result.succeeded { self.reportFailure(verb, result.failureMessage) }
                self.refresh()
                completion?(result.succeeded)
            }
        }
    }

    private func beginOperation(_ progress: String) {
        operationError = nil
        operationsInFlight += 1
        activeOperation = progress
    }

    func dismissError() {
        operationError = nil
    }

    private func reportFailure(_ verb: String, _ message: String) {
        operationError = "\(verb) failed: \(message)"
        onFailure?(verb, message)
    }

    private func endOperation() {
        operationsInFlight = max(0, operationsInFlight - 1)
        if operationsInFlight == 0 { activeOperation = nil }
    }

    func stage(paths: [String], completion: ((Bool) -> Void)? = nil) {
        guard !paths.isEmpty else {
            completion?(false)
            return
        }
        perform("Stage", progress: "Staging…", completion: completion) { root in
            GitClient.run(["add", "-A", "--"] + GitClient.literalPathspecs(paths), in: root)
        }
    }

    func unstage(paths: [String], completion: ((Bool) -> Void)? = nil) {
        guard !paths.isEmpty else {
            completion?(false)
            return
        }
        let hasCommits = snapshot?.hasCommits ?? false
        perform("Unstage", progress: "Unstaging…", completion: completion) { root in
            let arguments = hasCommits ? ["reset", "-q", "--"] : ["rm", "--cached", "-r", "-f", "--"]
            return GitClient.run(arguments + GitClient.literalPathspecs(paths), in: root)
        }
    }

    func discard(paths: [String], completion: ((Bool) -> Void)? = nil) {
        guard !paths.isEmpty else {
            completion?(false)
            return
        }
        perform("Discard", progress: "Discarding…", completion: completion) { root in
            GitClient.run(["restore", "--worktree", "--"] + GitClient.literalPathspecs(paths), in: root)
        }
    }

    func commit(message: String, completion: ((Bool) -> Void)? = nil) {
        perform("Commit", progress: "Committing…", completion: completion) { root in
            GitClient.run(["commit", "-q", "-m", message], in: root)
        }
    }

    func fetch() {
        guard canFetch else { return }
        perform("Fetch", progress: "Fetching…") { root in
            GitClient.run(["fetch", "--prune"], in: root)
        }
    }

    func pull() {
        guard canPull else { return }
        perform("Pull", progress: "Pulling…") { root in
            GitClient.run(["pull"], in: root)
        }
    }

    func push() {
        guard canPush else { return }
        let hasUpstream = snapshot?.upstream != nil
        let remote = snapshot?.publishRemote ?? "origin"
        perform("Push", progress: "Pushing…") { root in
            hasUpstream
                ? GitClient.run(["push"], in: root)
                : GitClient.run(["push", "-u", remote, "HEAD"], in: root)
        }
    }

    func checkout(branch: String, completion: ((Bool) -> Void)? = nil) {
        perform("Checkout", progress: "Switching to \(branch)…", completion: completion) { root in
            GitClient.run(["checkout", branch], in: root)
        }
    }

    func createBranch(named name: String) {
        perform("New Branch", progress: "Creating \(name)…") { root in
            GitClient.run(["checkout", "-b", name], in: root)
        }
    }

    func initializeRepository() {
        guard !isBusy, let workspace, GitClient.executable != nil else { return }
        let gen = generation
        beginOperation("Initializing…")
        GitClient.queue.async { [weak self] in
            let result = GitClient.run(["init", "-q"], in: workspace)
            DispatchQueue.main.async {
                guard let self else { return }
                self.endOperation()
                guard self.generation == gen else { return }
                if !result.succeeded {
                    self.reportFailure("Initialize Repository", result.failureMessage)
                }
                self.refresh()
            }
        }
    }
}

extension AppState {
    func configureSourceControl() {
        git.onFailure = { [weak self] verb, message in
            self?.appendConsole(.system, "\(verb) failed: \(message)")
            if self?.sidebarPane != .sourceControl { self?.revealConsole() }
        }
        git.onSnapshot = { [weak self] in
            self?.reloadDiffDocuments()
            self?.reloadExternallyChangedDocuments()
        }
        _ = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.reloadExternallyChangedDocuments()
        }
    }

    func showSidebarPane(_ pane: SidebarPane) {
        if sidebarPane != pane { sidebarPane = pane }
        sidebarRevealRequest += 1
    }

    func refreshSourceControl() {
        git.refresh()
    }

    func focusCommitMessage() {
        showSidebarPane(.sourceControl)
        git.draft.focusRequest += 1
    }

    func stage(_ change: GitChange) {
        git.stage(paths: [change.path])
    }

    func unstage(_ change: GitChange) {
        git.unstage(paths: [change.path] + (change.originalPath.map { [$0] } ?? []))
    }

    func stage(_ source: DiffSource) {
        git.stage(paths: [source.path])
    }

    func unstage(_ source: DiffSource) {
        git.unstage(paths: [source.path] + (source.originalPath.map { [$0] } ?? []))
    }

    func stageAllChanges() {
        guard let snapshot = git.snapshot else { return }
        git.stage(paths: snapshot.unstaged.map(\.path))
    }

    func unstageAllChanges() {
        guard let snapshot = git.snapshot else { return }
        git.unstage(paths: snapshot.staged.flatMap { [$0.path] + ($0.originalPath.map { [$0] } ?? []) })
    }

    func markAllResolved() {
        guard let snapshot = git.snapshot else { return }
        git.stage(paths: snapshot.conflicted.map(\.path))
    }

    private func hasDirtyTab(for changes: [GitChange]) -> Bool {
        let paths = Set(changes.map { $0.url.path })
        return openDocuments.contains { $0.isFileBacked && $0.isDirty && paths.contains($0.url?.path ?? "") }
    }

    func discardChanges(_ change: GitChange) {
        guard !git.isBusy else { return }
        let name = change.fileName
        let dirty = hasDirtyTab(for: [change])
        if change.status == .untracked {
            confirmDestructive(
                title: "Move \(name) to the Trash?",
                message: dirty
                    ? "Unsaved changes in its open tab will be lost. Only the last saved version goes to the Trash."
                    : "\(name) is not tracked by git. You can restore it from the Trash.",
                button: "Move to Trash") { [weak self] in
                self?.performDiscard([change], reloadDirty: true)
            }
        } else {
            confirmDestructive(
                title: "Discard changes to \(name)?",
                message: "Uncommitted edits to \(name) will be lost. This cannot be undone."
                    + (dirty ? " Unsaved changes in its open tab are discarded too." : ""),
                button: "Discard") { [weak self] in
                self?.performDiscard([change], reloadDirty: true)
            }
        }
    }

    func discardAllChanges() {
        guard !git.isBusy, let snapshot = git.snapshot, !snapshot.unstaged.isEmpty else { return }
        let count = snapshot.unstaged.count
        let dirty = hasDirtyTab(for: snapshot.unstaged)
        confirmDestructive(
            title: "Discard all \(count) change\(count == 1 ? "" : "s")?",
            message: "Uncommitted edits will be lost and untracked files moved to the Trash. This cannot be undone."
                + (dirty ? " Unsaved changes in open tabs are discarded too." : ""),
            button: "Discard All") { [weak self] in
            self?.performDiscard(snapshot.unstaged, reloadDirty: true)
        }
    }

    func discardOutputOnlyChanges() {
        guard !git.isBusy, let snapshot = git.snapshot, !snapshot.hiddenNotebooks.isEmpty else { return }
        let count = snapshot.hiddenNotebooks.count
        confirmDestructive(
            title: "Discard output changes in \(count) notebook\(count == 1 ? "" : "s")?",
            message: "Cell outputs and execution counts on disk revert to the last staged version. Cell sources are not affected, and tabs with unsaved edits keep them.",
            button: "Discard Outputs") { [weak self] in
            self?.performDiscard(snapshot.hiddenNotebooks, reloadDirty: false)
        }
    }

    private func performDiscard(_ changes: [GitChange], reloadDirty: Bool) {
        guard !git.isBusy else { return }
        for change in changes where change.status == .untracked {
            do {
                try FileManager.default.trashItem(at: change.url, resultingItemURL: nil)
                if let document = openDocuments.first(where: { $0.url?.path == change.url.path }) {
                    document.isDirty = false
                    closeDocument(document)
                }
            } catch {
                appendConsole(.system, "Could not move \(change.fileName) to Trash: \(error.localizedDescription)")
                revealConsole()
            }
        }
        let tracked = changes.filter { $0.status != .untracked }
        guard !tracked.isEmpty else {
            git.refresh()
            return
        }
        let paths = Set(tracked.map { $0.url.path })
        git.discard(paths: tracked.map(\.path)) { [weak self] succeeded in
            guard let self, succeeded else { return }
            for document in self.openDocuments
            where document.isFileBacked && (reloadDirty || !document.isDirty) {
                if let path = document.url?.path, paths.contains(path) {
                    self.reloadFromDisk(document)
                }
            }
        }
    }

    func commit() {
        guard let snapshot = git.snapshot, !git.isBusy else { return }
        let message = git.draft.message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else {
            focusCommitMessage()
            return
        }
        guard snapshot.conflicted.isEmpty else {
            appendConsole(.system, "Commit failed: resolve the conflicted files first.")
            revealConsole()
            return
        }
        guard !snapshot.staged.isEmpty else {
            userNotice = "Nothing is staged. Stage the changes you want to commit, or use Stage All and Commit."
            return
        }
        git.commit(message: message) { [weak self] succeeded in
            if succeeded, self?.git.draft.message.trimmingCharacters(in: .whitespacesAndNewlines) == message {
                self?.git.draft.message = ""
            }
        }
    }

    func stageAllAndCommit() {
        guard let snapshot = git.snapshot, !git.isBusy else { return }
        let message = git.draft.message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { focusCommitMessage(); return }
        guard snapshot.conflicted.isEmpty else { return }
        let paths = snapshot.unstaged.map(\.path)
        guard !paths.isEmpty else { commit(); return }
        git.stage(paths: paths) { [weak self] succeeded in
            if succeeded { self?.commit() }
        }
    }

    func fetch() {
        git.fetch()
    }

    func pull() {
        git.pull()
    }

    func push() {
        git.push()
    }

    func checkout(branch: String) {
        guard let snapshot = git.snapshot, branch != snapshot.branch else { return }
        git.checkout(branch: branch) { [weak self] succeeded in
            guard succeeded else { return }
            self?.refreshWorkspace()
        }
    }

    func createBranch() {
        guard git.snapshot != nil,
              let name = promptForName(title: "New Branch",
                                       message: "Name for the new branch:",
                                       initial: "") else { return }
        git.createBranch(named: name)
    }

    func initializeRepository() {
        git.initializeRepository()
    }

    func installCommandLineTools() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
        process.arguments = ["--install"]
        do {
            try process.run()
        } catch {
            appendConsole(.system, "Could not start the Command Line Tools installer: \(error.localizedDescription)")
            revealConsole()
        }
    }

    func openDiff(for change: GitChange) {
        openDiff(DiffSource(change: change))
    }

    func openDiff(_ source: DiffSource) {
        if let existing = openDocuments.first(where: { $0.diffSource == source }) {
            activeDocumentID = existing.id
            reloadDiff(existing)
            return
        }
        let document = Document(diff: source)
        openDocuments.append(document)
        activeDocumentID = document.id
        reloadDiff(document)
    }

    func openDiffForActiveDocument() {
        guard let document = activeDocument, document.isFileBacked, let url = document.url else { return }
        openDiff(forFileAt: url)
    }

    func openDiff(forFileAt url: URL) {
        guard let snapshot = git.snapshot else { return }
        if let change = snapshot.visibleChanges.first(where: { $0.url.path == url.path }) {
            openDiff(for: change)
            return
        }
        guard let path = snapshot.repositoryPath(for: url) else {
            appendConsole(.system, "\(url.lastPathComponent) is outside the git repository.")
            revealConsole()
            return
        }
        openDiff(DiffSource(path: path, url: url, area: .unstaged, status: .modified))
    }

    func reloadDiff(_ document: Document) {
        guard let source = document.diffSource else { return }
        guard let snapshot = git.snapshot else {
            document.diff = nil
            document.diffError = "Not a git repository"
            return
        }
        let live = snapshot.visibleChanges.first { $0.path == source.path && $0.area == source.area }
            ?? snapshot.visibleChanges.first { $0.path == source.path }
        let effective = live.map { DiffSource(change: $0) } ?? source
        if live != nil, effective.area != source.area || effective.status != source.status || source.isAdHoc {
            document.diffSource = effective
        }
        let root = snapshot.root
        GitClient.queue.async { [weak document] in
            let result = DiffSource.load(effective, root: root)
            DispatchQueue.main.async {
                guard let document else { return }
                switch result {
                case .success(let diff):
                    if document.diff == diff, document.diffError == nil { return }
                    document.diff = diff
                    document.diffError = nil
                case .failure(let error):
                    document.diff = nil
                    document.diffError = error.message
                }
            }
        }
    }

    func reloadDiffDocuments() {
        for document in openDocuments where document.kind == .diff {
            reloadDiff(document)
        }
    }

    func fileModificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    func reloadFromDisk(_ document: Document) {
        guard document.isFileBacked, let url = document.url else { return }
        do {
            switch document.kind {
            case .script:
                let text = try String(contentsOf: url, encoding: .utf8)
                if document.text != text { document.text = text }
            case .notebook:
                let notebook = try Notebook.load(from: Data(contentsOf: url))
                if (try? document.notebook?.serializedData()) != (try? notebook.serializedData()) {
                    let selectedNBID = document.notebook?.cells.first { $0.id == selectedCellID }?.nbID
                    document.notebook = notebook
                    document.deletedCells = []
                    document.find.matches = []
                    document.find.currentIndex = 0
                    if activeDocumentID == document.id {
                        selectedCellID = notebook.cells.first { $0.nbID == selectedNBID }?.id
                            ?? notebook.cells.first?.id
                    }
                }
            case .dataFrame, .diff:
                return
            }
            document.isDirty = false
            document.fileModificationDate = fileModificationDate(of: url)
            clearDraft(for: document)
        } catch {
            appendConsole(.system, "Could not reload \(document.displayName): \(error.localizedDescription)")
        }
    }

    func reloadExternallyChangedDocuments() {
        for document in openDocuments where document.isFileBacked {
            guard let url = document.url, let known = document.fileModificationDate,
                  let current = fileModificationDate(of: url), current > known else { continue }
            if document.isDirty {
                externallyChangedDocumentID = document.id
                if activeDocumentID != document.id { activeDocumentID = document.id }
            } else {
                reloadFromDisk(document)
            }
        }
    }

    func keepCurrentVersionAfterExternalChange() {
        guard let id = externallyChangedDocumentID,
              let document = openDocuments.first(where: { $0.id == id }),
              let url = document.url else { return }
        document.fileModificationDate = fileModificationDate(of: url)
        externallyChangedDocumentID = nil
    }

    func reloadExternalVersion() {
        guard let id = externallyChangedDocumentID,
              let document = openDocuments.first(where: { $0.id == id }) else { return }
        reloadFromDisk(document)
        externallyChangedDocumentID = nil
    }

    func compareExternalVersion() {
        guard let id = externallyChangedDocumentID,
              let sourceDocument = openDocuments.first(where: { $0.id == id }),
              let url = sourceDocument.url,
              let diskData = try? Data(contentsOf: url) else { return }
        let disk: String
        let current: String
        if sourceDocument.kind == .notebook,
           let diskNotebook = try? Notebook.load(from: diskData),
           let memoryNotebook = sourceDocument.notebook,
           let diskJSON = try? diskNotebook.serializedData(),
           let memoryJSON = try? memoryNotebook.serializedData() {
            disk = String(decoding: diskJSON, as: UTF8.self)
            current = String(decoding: memoryJSON, as: UTF8.self)
        } else {
            disk = String(decoding: diskData, as: UTF8.self)
            current = sourceDocument.text
        }
        let source = DiffSource(path: relativePath(url), url: url, area: .unstaged, status: .modified)
        let comparison = Document(diff: source)
        comparison.diff = DiffDocument.compare(oldText: disk, newText: current,
                                               oldLabel: "Disk", newLabel: "Your Edits",
                                               isNotebook: sourceDocument.kind == .notebook)
        openDocuments.append(comparison)
        activeDocumentID = comparison.id
    }

    func confirmDestructive(title: String, message: String, button: String,
                            then action: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: button).hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        let proceed = { (response: NSApplication.ModalResponse) in
            if response == .alertFirstButtonReturn { action() }
        }
        if let window = NSApp.keyWindow {
            alert.beginSheetModal(for: window, completionHandler: proceed)
        } else {
            proceed(alert.runModal())
        }
    }
}
