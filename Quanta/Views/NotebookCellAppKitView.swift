import AppKit
import Combine
import SwiftUI

final class NotebookCellAppKitView: NSView, NSTextViewDelegate, NSDraggingSource {
    var onSizeChange: (() -> Void)?

    private let gutter = NotebookCellGutterView()
    private let gutterStack = NSStackView()
    private let statusContainer = NSView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let statusImage = NSImageView()
    private let progress = NSProgressIndicator()
    private let staleImage = NSImageView()
    private let durationLabel = NSTextField(labelWithString: "")
    private let runButton = NotebookIconButton()
    private let markdownButton = NotebookIconButton()
    private let addButton = NotebookIconButton()
    private let contentStack = NSStackView()
    private let sourceCard = NotebookCellCardView()
    private var sourceView: NSView?
    private var outputView: NSView?
    private var sourceWidthConstraint: NSLayoutConstraint?
    private var outputWidthConstraint: NSLayoutConstraint?
    private var editor: QuantaTextView?
    private var editorHeightConstraint: NSLayoutConstraint?
    private var trackingArea: NSTrackingArea?
    private var cancellables: Set<AnyCancellable> = []
    private let editorUndoManager = UndoManager()
    private var cell: NotebookCell?
    var cellID: UUID? { cell?.id }
    private weak var document: Document?
    private weak var notebook: Notebook?
    private var monoFontSize: CGFloat = 12
    private var lastPresentation = Presentation.empty
    private var lastSource = ""
    private var hovering = false
    private var measurementPending = false

    private struct Presentation: Equatable {
        let type: String
        let sourceCollapsed: Bool
        let outputCollapsed: Bool
        let editingMarkdown: Bool
        let hasOutputs: Bool

        static let empty = Presentation(type: "", sourceCollapsed: false,
                                        outputCollapsed: false, editingMarkdown: false,
                                        hasOutputs: false)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureLayout()
        configureControls()
        gutter.onClick = { [weak self] in self?.selectCell() }
        gutter.onDrag = { [weak self] event in self?.beginCellDrag(with: event) }
        registerForDraggedTypes([.string])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(cell: NotebookCell, document: Document, notebook: Notebook,
                   monoFontSize: CGFloat) {
        let changedCell = self.cell !== cell || self.document !== document || self.notebook !== notebook
        self.cell = cell
        self.document = document
        self.notebook = notebook
        self.monoFontSize = monoFontSize
        if changedCell {
            cancellables.removeAll()
            lastPresentation = .empty
            lastSource = ""
            bindModel()
        }
        refresh(force: changedCell)
    }

    func resetForReuse() {
        cancellables.removeAll()
        hovering = false
        cell = nil
        document = nil
        notebook = nil
        editor = nil
        editorHeightConstraint = nil
        replaceSource(with: nil)
        replaceOutput(with: nil)
        lastPresentation = .empty
        lastSource = ""
    }

    override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let next = NSTrackingArea(rect: bounds,
                                  options: [.activeInActiveApp, .mouseEnteredAndExited, .inVisibleRect],
                                  owner: self)
        addTrackingArea(next)
        trackingArea = next
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        guard !ScrollActivityMonitor.shared.isLiveScrolling else { return }
        hovering = true
        updateControlVisibility()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        updateControlVisibility()
    }

    override func menu(for event: NSEvent) -> NSMenu? { makeMenu() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let raw = sender.draggingPasteboard.string(forType: .string),
              UUID(uuidString: raw) != nil else { return [] }
        return .move
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let raw = sender.draggingPasteboard.string(forType: .string),
              let draggedID = UUID(uuidString: raw), let cell, let notebook, let document else {
            return false
        }
        AppState.shared.reorderCells(draggedID: draggedID, before: cell.id,
                                     in: notebook, document: document)
        return true
    }

    func draggingSession(_ session: NSDraggingSession,
                         sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .move
    }

    private func configureLayout() {
        gutter.translatesAutoresizingMaskIntoConstraints = false
        gutterStack.translatesAutoresizingMaskIntoConstraints = false
        gutterStack.orientation = .vertical
        gutterStack.alignment = .centerX
        gutterStack.spacing = 4
        gutterStack.edgeInsets = NSEdgeInsets(top: DS.Space.m, left: 0, bottom: 0, right: 0)
        gutter.addSubview(gutterStack)

        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.orientation = .vertical
        contentStack.alignment = .width
        contentStack.spacing = DS.Space.s

        addSubview(gutter)
        addSubview(contentStack)
        NSLayoutConstraint.activate([
            gutterStack.topAnchor.constraint(equalTo: gutter.topAnchor),
            gutterStack.leadingAnchor.constraint(equalTo: gutter.leadingAnchor),
            gutterStack.trailingAnchor.constraint(equalTo: gutter.trailingAnchor),
            gutterStack.bottomAnchor.constraint(lessThanOrEqualTo: gutter.bottomAnchor),
            gutter.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DS.Space.m),
            gutter.topAnchor.constraint(equalTo: topAnchor),
            gutter.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
            gutter.widthAnchor.constraint(equalToConstant: DS.Layout.cellGutterWidth),
            contentStack.leadingAnchor.constraint(equalTo: gutter.trailingAnchor, constant: DS.Space.m),
            contentStack.topAnchor.constraint(equalTo: topAnchor),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func configureControls() {
        statusContainer.translatesAutoresizingMaskIntoConstraints = false
        statusContainer.heightAnchor.constraint(equalToConstant: DS.Layout.statusSlot).isActive = true

        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.font = .monospacedSystemFont(ofSize: NSFont.smallSystemFontSize,
                                                 weight: .regular)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center

        statusImage.translatesAutoresizingMaskIntoConstraints = false
        statusImage.symbolConfiguration = .init(pointSize: NSFont.smallSystemFontSize,
                                                weight: .regular)
        statusImage.contentTintColor = .tertiaryLabelColor

        progress.translatesAutoresizingMaskIntoConstraints = false
        progress.style = .spinning
        progress.controlSize = .mini

        statusContainer.addSubview(statusLabel)
        statusContainer.addSubview(statusImage)
        statusContainer.addSubview(progress)
        for view in [statusLabel, statusImage, progress] {
            NSLayoutConstraint.activate([
                view.centerXAnchor.constraint(equalTo: statusContainer.centerXAnchor),
                view.centerYAnchor.constraint(equalTo: statusContainer.centerYAnchor),
            ])
        }

        staleImage.image = NSImage(systemSymbolName: "clock.badge.exclamationmark",
                                   accessibilityDescription: "Output is stale")
        staleImage.symbolConfiguration = .init(pointSize: NSFont.smallSystemFontSize,
                                               weight: .regular)
        staleImage.contentTintColor = .systemOrange
        staleImage.toolTip = "Output is stale: the source changed after the last run"

        durationLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize - 1,
                                                        weight: .regular)
        durationLabel.textColor = .tertiaryLabelColor
        durationLabel.alignment = .center

        configureButton(runButton, symbol: "play.fill", help: "Run cell (⌘↩)",
                        action: #selector(runCell))
        configureButton(markdownButton, symbol: "pencil", help: "Edit markdown",
                        action: #selector(toggleMarkdown))
        configureButton(addButton, symbol: "plus", help: "Insert Code or Markdown Above or Below",
                        action: #selector(showInsertionMenu))

        gutterStack.addArrangedSubview(statusContainer)
        gutterStack.addArrangedSubview(staleImage)
        gutterStack.addArrangedSubview(durationLabel)
        gutterStack.addArrangedSubview(runButton)
        gutterStack.addArrangedSubview(markdownButton)
        gutterStack.addArrangedSubview(addButton)
        statusContainer.widthAnchor.constraint(equalTo: gutterStack.widthAnchor).isActive = true
    }

    private func configureButton(_ button: NotebookIconButton, symbol: String, help: String,
                                 action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: help)
        button.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        button.contentTintColor = .labelColor
        button.imagePosition = .imageOnly
        button.bezelStyle = .inline
        button.isBordered = false
        button.target = self
        button.action = action
        button.toolTip = help
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: DS.Layout.slot),
            button.heightAnchor.constraint(equalToConstant: DS.Layout.slot),
        ])
    }

    private func bindModel() {
        guard let cell else { return }
        cell.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.refresh(force: false) }
            }
            .store(in: &cancellables)
        AppState.shared.selection.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.refreshSelection() }
            }
            .store(in: &cancellables)
        ScrollActivityMonitor.shared.$isLiveScrolling
            .receive(on: DispatchQueue.main)
            .sink { [weak self] active in
                guard let self else { return }
                if active {
                    self.hovering = false
                } else {
                    self.updateHoverFromPointer()
                }
                self.updateControlVisibility()
            }
            .store(in: &cancellables)
    }

    private func refresh(force: Bool) {
        guard let cell else { return }
        let presentation = Presentation(type: cell.cellType.rawValue,
                                        sourceCollapsed: cell.isSourceCollapsed,
                                        outputCollapsed: cell.isOutputCollapsed,
                                        editingMarkdown: cell.isEditingMarkdown,
                                        hasOutputs: !cell.outputs.isEmpty)
        if force || presentation != lastPresentation {
            rebuildSource()
            rebuildOutput()
            lastPresentation = presentation
            lastSource = cell.source
        } else if cell.source != lastSource {
            if let editor, !editor.hasMarkedText(), editor.string != cell.source {
                let selection = editor.selectedRange()
                editor.string = cell.source
                editorUndoManager.removeAllActions()
                if let storage = editor.textStorage { PythonHighlighter.highlight(storage) }
                editor.setSelectedRange(NSRange(location: min(selection.location,
                                                                (editor.string as NSString).length),
                                                length: 0))
                scheduleEditorMeasurement(force: true)
            } else if cell.cellType == .markdown && !cell.isEditingMarkdown {
                rebuildSource()
            }
            lastSource = cell.source
        }
        refreshStatus()
        refreshSelection()
        onSizeChange?()
    }

    private func rebuildSource() {
        guard let cell else { return }
        editor = nil
        editorHeightConstraint = nil
        if cell.isSourceCollapsed {
            sourceCard.style = .editor
            let button = NSButton(title: "›  \(collapsedPreview(cell))  ⋯",
                                  target: self, action: #selector(expandSource))
            button.isBordered = false
            button.alignment = .left
            button.font = .monospacedSystemFont(ofSize: max(10, monoFontSize - 1),
                                                weight: .regular)
            button.contentTintColor = .secondaryLabelColor
            sourceCard.setContent(button, insets: NSEdgeInsets(top: DS.Space.s,
                                                               left: DS.Space.m,
                                                               bottom: DS.Space.s,
                                                               right: DS.Space.m))
            replaceSource(with: sourceCard)
            return
        }
        if cell.cellType == .markdown && !cell.isEditingMarkdown {
            sourceCard.style = .markdown
            let markdown = NotebookMarkdownHostingView(rootView: markdownRoot(for: cell))
            markdown.sizingOptions = [.intrinsicContentSize]
            markdown.onSingleClick = { [weak self] in self?.selectMarkdown() }
            markdown.onDoubleClick = { [weak self] in self?.beginMarkdownEditing() }
            markdown.onSizeChange = { [weak self] in self?.onSizeChange?() }
            sourceCard.setContent(markdown,
                                  insets: NSEdgeInsets(top: DS.Space.s,
                                                      left: DS.Layout.cellTextInset,
                                                      bottom: DS.Space.s,
                                                      right: DS.Layout.cellTextInset))
            replaceSource(with: sourceCard)
            return
        }
        sourceCard.style = .editor
        let editor = makeEditor(for: cell)
        self.editor = editor
        let constraint = editor.heightAnchor.constraint(equalToConstant: max(30, cell.editorHeight))
        constraint.isActive = true
        editorHeightConstraint = constraint
        sourceCard.setContent(editor, insets: NSEdgeInsets(top: 0, left: DS.Space.xs,
                                                           bottom: 0, right: DS.Space.xs))
        replaceSource(with: sourceCard)
        scheduleEditorMeasurement(force: true)
    }

    private func markdownRoot(for cell: NotebookCell) -> AnyView {
        AnyView(
            MarkdownView(source: cell.source.isEmpty
                         ? "*Empty markdown cell — double-click to edit*"
                         : cell.source,
                         selectable: false,
                         attachments: Notebook.attachmentData(cell.extraKeys["attachments"]),
                         baseDirectory: document?.url?.deletingLastPathComponent())
                .environment(\.monoFontSize, monoFontSize)
                .frame(maxWidth: .infinity, alignment: .leading)
        )
    }

    private func makeEditor(for cell: NotebookCell) -> QuantaTextView {
        let editor = CodeEditorFactory.makeTextView()
        editor.translatesAutoresizingMaskIntoConstraints = false
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = []
        editor.drawsBackground = false
        editor.delegate = self
        editor.string = cell.source
        if let storage = editor.textStorage { PythonHighlighter.highlight(storage) }
        EditorRegistry.shared.register(editor, for: cell.id)
        editor.onCommand = { [weak self] command in
            guard let self, let cell = self.cell, let document = self.document else { return false }
            AppState.shared.handleCellCommand(command, cell: cell, document: document)
            return true
        }
        editor.onEscape = { AppState.shared.enterCommandMode() }
        editor.onFocusChange = { [weak self] focused in
            guard focused, let self, let cell = self.cell, let document = self.document else { return }
            AppState.shared.activeDocumentID = document.id
            AppState.shared.selectedCellID = cell.id
        }
        editor.onLayoutChange = { [weak self] in self?.scheduleEditorMeasurement(force: false) }
        return editor
    }

    private func rebuildOutput() {
        guard let cell, cell.cellType == .code, !cell.outputs.isEmpty else {
            replaceOutput(with: nil)
            return
        }
        if cell.isOutputCollapsed {
            let button = NSButton(title: "›  Output hidden", target: self,
                                  action: #selector(expandOutput))
            button.isBordered = false
            button.alignment = .left
            button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            button.contentTintColor = .tertiaryLabelColor
            replaceOutput(with: button)
            return
        }
        let output = NotebookCellHostingView(rootView: AnyView(
            OutputListView(cell: cell)
                .environment(\.monoFontSize, monoFontSize)
        ))
        output.sizingOptions = [.intrinsicContentSize]
        output.onSizeChange = { [weak self] in self?.onSizeChange?() }
        replaceOutput(with: output)
    }

    private func replaceSource(with view: NSView?) {
        sourceWidthConstraint?.isActive = false
        sourceWidthConstraint = nil
        if let sourceView {
            contentStack.removeArrangedSubview(sourceView)
            sourceView.removeFromSuperview()
        }
        sourceView = view
        if let view {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentStack.insertArrangedSubview(view, at: 0)
            let constraint = view.widthAnchor.constraint(equalTo: contentStack.widthAnchor)
            constraint.isActive = true
            sourceWidthConstraint = constraint
        }
    }

    private func replaceOutput(with view: NSView?) {
        outputWidthConstraint?.isActive = false
        outputWidthConstraint = nil
        if let outputView {
            contentStack.removeArrangedSubview(outputView)
            outputView.removeFromSuperview()
        }
        outputView = view
        if let view {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentStack.addArrangedSubview(view)
            let constraint = view.widthAnchor.constraint(equalTo: contentStack.widthAnchor)
            constraint.isActive = true
            outputWidthConstraint = constraint
        }
    }

    private func refreshStatus() {
        guard let cell else { return }
        let isCode = cell.cellType == .code
        statusContainer.isHidden = !isCode
        runButton.isHidden = !isCode
        markdownButton.isHidden = cell.cellType != .markdown
        progress.isHidden = !cell.isRunning
        statusImage.isHidden = !cell.isQueued || cell.isRunning
        statusLabel.isHidden = cell.isRunning || cell.isQueued
        if cell.isQueued {
            statusImage.image = NSImage(systemSymbolName: "clock", accessibilityDescription: "Queued")
            statusImage.toolTip = "Queued — waiting for earlier cells"
        }
        statusLabel.stringValue = cell.executionCount.map { "[\($0)]" } ?? "[ ]"
        staleImage.isHidden = !cell.hasStaleOutput || cell.isRunning || !isCode
        durationLabel.isHidden = cell.lastDuration == nil || cell.isRunning || !isCode
        if let duration = cell.lastDuration {
            let formatted = Self.durationLabel(duration)
            durationLabel.stringValue = formatted
            durationLabel.toolTip = "Last run time: \(formatted)"
        } else {
            durationLabel.stringValue = ""
            durationLabel.toolTip = nil
        }
        runButton.isEnabled = !cell.isRunning
        markdownButton.image = NSImage(systemSymbolName: cell.isEditingMarkdown ? "eye" : "pencil",
                                       accessibilityDescription: cell.isEditingMarkdown
                                       ? "Preview markdown" : "Edit markdown")
        markdownButton.toolTip = cell.isEditingMarkdown ? "Preview markdown" : "Edit markdown"
        if cell.isRunning { progress.startAnimation(nil) } else { progress.stopAnimation(nil) }
    }

    private func refreshSelection() {
        guard let cell else { return }
        let selection = AppState.shared.selection
        let selected = selection.selectedCellID == cell.id || selection.selectedCellIDs.contains(cell.id)
        sourceCard.isSelected = selected
        statusLabel.textColor = selected ? .controlAccentColor : .secondaryLabelColor
        updateControlVisibility()
    }

    private func updateControlVisibility() {
        guard let cell else { return }
        let selection = AppState.shared.selection
        let selected = selection.selectedCellID == cell.id || selection.selectedCellIDs.contains(cell.id)
        let visible = (hovering || selected) && !ScrollActivityMonitor.shared.isLiveScrolling
        runButton.setInteractionVisible(visible, enabled: !cell.isRunning)
        markdownButton.setInteractionVisible(visible, enabled: true)
        addButton.setInteractionVisible(visible, enabled: true)
    }

    private func updateHoverFromPointer() {
        guard let window, !isHiddenOrHasHiddenAncestor else {
            hovering = false
            return
        }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        hovering = bounds.contains(point)
    }

    private func scheduleEditorMeasurement(force: Bool) {
        guard !measurementPending else { return }
        measurementPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.measurementPending = false
            self.measureEditor(force: force)
        }
    }

    private func measureEditor(force: Bool) {
        guard let editor, let cell, let layoutManager = editor.layoutManager,
              let container = editor.textContainer else { return }
        let width = editor.bounds.width
        guard width > 0 else { return }
        container.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        let height = max(used.height + editor.textContainerInset.height * 2 + 2, 30)
        guard force || abs(height - (editorHeightConstraint?.constant ?? 0)) > 0.5 else { return }
        editorHeightConstraint?.constant = height
        if abs(cell.editorHeight - height) > 0.5 { cell.editorHeight = height }
        onSizeChange?()
    }

    func textDidChange(_ notification: Notification) {
        guard let editor, let cell, let document, !editor.hasMarkedText() else { return }
        if cell.source != editor.string {
            cell.source = editor.string
            if !document.isDirty { document.isDirty = true }
        }
        if let storage = editor.textStorage {
            PythonHighlighter.highlight(storage, editedRange: editor.lastEditedRange)
        }
        lastSource = editor.string
        scheduleEditorMeasurement(force: true)
    }

    func undoManager(for view: NSTextView) -> UndoManager? { editorUndoManager }

    private func selectCell() {
        guard let cell, let notebook, let document else { return }
        AppState.shared.activeDocumentID = document.id
        AppState.shared.selectCell(cell, in: notebook, modifiers: NSEvent.modifierFlags)
    }

    private func selectMarkdown() {
        guard let cell, let document else { return }
        AppState.shared.activeDocumentID = document.id
        AppState.shared.selectedCellID = cell.id
        AppState.shared.enterCommandMode()
    }

    private func beginMarkdownEditing() {
        guard let cell, let document else { return }
        AppState.shared.activeDocumentID = document.id
        AppState.shared.selectedCellID = cell.id
        cell.isEditingMarkdown = true
        refresh(force: true)
        guard let editor else { return }
        window?.makeFirstResponder(editor)
        DispatchQueue.main.async { [weak editor] in editor?.window?.makeFirstResponder(editor) }
    }

    private func beginCellDrag(with event: NSEvent) {
        guard let cell else { return }
        let pasteboard = NSPasteboardItem()
        pasteboard.setString(cell.id.uuidString, forType: .string)
        let item = NSDraggingItem(pasteboardWriter: pasteboard)
        let image = NSImage(size: bounds.size)
        if let representation = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: representation)
            image.addRepresentation(representation)
        }
        item.setDraggingFrame(bounds, contents: image)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    private func collapsedPreview(_ cell: NotebookCell) -> String {
        cell.source.components(separatedBy: "\n").first { !$0.isEmpty } ?? "(empty cell)"
    }

    static func durationLabel(_ seconds: Double) -> String {
        if seconds < 0.1 { return "<0.1s" }
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        return "\(Int(seconds) / 60)m \(Int(seconds) % 60)s"
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()
        addItem("Run Cell", #selector(runCell), to: menu)
        if AppState.shared.selection.selectedCellIDs.count > 1 {
            addItem("Run Selected Cells", #selector(runSelected), to: menu)
        }
        addItem("Run Cells Above", #selector(runAbove), to: menu)
        addItem("Run Cells Below", #selector(runBelow), to: menu)
        addItem("Run All Cells", #selector(runAll), to: menu)
        menu.addItem(.separator())
        addItem("Copy Cell", #selector(copyCell), to: menu)
        addItem("Cut Cell", #selector(cutCell), to: menu)
        addItem("Paste Cell Below", #selector(pasteCell), to: menu)
        addItem("Duplicate Cell", #selector(duplicateCell), to: menu)
        menu.addItem(.separator())
        let insert = NSMenuItem(title: "Insert Cell", action: nil, keyEquivalent: "")
        insert.submenu = insertionMenu()
        menu.addItem(insert)
        menu.addItem(.separator())
        if let cell {
            addItem(cell.cellType == .code ? "Convert to Markdown" : "Convert to Code",
                    #selector(convertCell), to: menu)
            addItem(cell.isSourceCollapsed ? "Expand Source" : "Collapse Source",
                    #selector(toggleSourceCollapsed), to: menu)
            if cell.cellType == .code {
                addItem(cell.isOutputCollapsed ? "Show Output" : "Hide Output",
                        #selector(toggleOutputCollapsed), to: menu)
                addItem("Clear Output", #selector(clearOutput), to: menu)
                if document?.clearedOutputs.isEmpty == false {
                    addItem("Undo Clear Output", #selector(undoClearOutput), to: menu)
                }
            }
        }
        menu.addItem(.separator())
        addItem("Move Up", #selector(moveCellUp), to: menu)
        addItem("Move Down", #selector(moveCellDown), to: menu)
        menu.addItem(.separator())
        addItem("Delete Cell", #selector(deleteCell), to: menu)
        return menu
    }

    private func insertionMenu() -> NSMenu {
        let menu = NSMenu()
        addItem("Code Cell Above", #selector(insertCodeAbove), to: menu)
        addItem("Markdown Cell Above", #selector(insertMarkdownAbove), to: menu)
        menu.addItem(.separator())
        addItem("Code Cell Below", #selector(insertCodeBelow), to: menu)
        addItem("Markdown Cell Below", #selector(insertMarkdownBelow), to: menu)
        return menu
    }

    private func addItem(_ title: String, _ action: Selector, to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        menu.addItem(item)
    }

    @objc private func runCell() { withContext { AppState.shared.runCell($0, in: $2, advance: false) } }
    @objc private func runSelected() { AppState.shared.runSelectedCells() }
    @objc private func runAbove() { withContext { AppState.shared.runCells(above: $0, in: $2) } }
    @objc private func runBelow() { withContext { AppState.shared.runCells(below: $0, in: $2) } }
    @objc private func runAll() { guard let document else { return }; AppState.shared.runAllCells(in: document) }
    @objc private func copyCell() {
        withContext { cell, notebook, _ in AppState.shared.copyCell(cell, in: notebook) }
    }
    @objc private func cutCell() {
        withContext {
            AppState.shared.copyCell($0, in: $1)
            AppState.shared.deleteCell($0, in: $1, document: $2)
        }
    }
    @objc private func pasteCell() { withContext { AppState.shared.pasteCell(after: $0, in: $1, document: $2) } }
    @objc private func duplicateCell() { withContext { AppState.shared.duplicateCell($0, in: $1, document: $2) } }
    @objc private func convertCell() {
        withContext { AppState.shared.convertCell($0, to: $0.cellType == .code ? .markdown : .code, in: $2) }
    }
    @objc private func toggleSourceCollapsed() {
        withContext { AppState.shared.setSourceCollapsed(!$0.isSourceCollapsed, for: $0, in: $2) }
    }
    @objc private func toggleOutputCollapsed() {
        withContext { AppState.shared.setOutputCollapsed(!$0.isOutputCollapsed, for: $0, in: $2) }
    }
    @objc private func clearOutput() { withContext { AppState.shared.clearOutput(for: $0, in: $2) } }
    @objc private func undoClearOutput() {
        guard let document else { return }
        AppState.shared.undoClearedOutput(in: document)
    }
    @objc private func moveCellUp() {
        withContext { AppState.shared.moveCell($0, direction: -1, in: $1, document: $2) }
    }
    @objc private func moveCellDown() {
        withContext { AppState.shared.moveCell($0, direction: 1, in: $1, document: $2) }
    }
    @objc private func deleteCell() { withContext { AppState.shared.deleteCell($0, in: $1, document: $2) } }
    @objc private func expandSource() {
        withContext { AppState.shared.setSourceCollapsed(false, for: $0, in: $2) }
    }
    @objc private func expandOutput() {
        withContext { AppState.shared.setOutputCollapsed(false, for: $0, in: $2) }
    }
    @objc private func toggleMarkdown() {
        guard let cell else { return }
        if cell.isEditingMarkdown {
            cell.isEditingMarkdown = false
        } else {
            beginMarkdownEditing()
        }
    }
    @objc private func showInsertionMenu(_ sender: NSButton) {
        insertionMenu().popUp(positioning: nil,
                              at: NSPoint(x: 0, y: sender.bounds.maxY + 2), in: sender)
    }
    @objc private func insertCodeAbove() { insert(.code, offset: 0) }
    @objc private func insertMarkdownAbove() { insert(.markdown, offset: 0) }
    @objc private func insertCodeBelow() { insert(.code, offset: 1) }
    @objc private func insertMarkdownBelow() { insert(.markdown, offset: 1) }

    private func insert(_ type: CellType, offset: Int) {
        withContext {
            AppState.shared.insertCell(type: type, nextTo: $0, offset: offset,
                                       in: $1, document: $2, editing: true)
        }
    }

    private func withContext(_ action: (NotebookCell, Notebook, Document) -> Void) {
        guard let cell, let notebook, let document else { return }
        action(cell, notebook, document)
    }
}

private final class NotebookCellGutterView: NSView {
    var onClick: (() -> Void)?
    var onDrag: ((NSEvent) -> Void)?

    override func mouseDown(with event: NSEvent) { onClick?() }
    override func mouseDragged(with event: NSEvent) { onDrag?(event) }
}

private final class NotebookIconButton: NSButton {
    private var hoverTrackingArea: NSTrackingArea?
    private var hovering = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = DS.Radius.control
        layer?.masksToBounds = true
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isHighlighted: Bool {
        didSet { updateAppearance() }
    }

    override func updateTrackingAreas() {
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let next = NSTrackingArea(rect: bounds,
                                  options: [.activeInKeyWindow, .mouseEnteredAndExited,
                                            .inVisibleRect],
                                  owner: self)
        addTrackingArea(next)
        hoverTrackingArea = next
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        guard isEnabled, alphaValue > 0 else { return }
        hovering = true
        updateAppearance()
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        updateAppearance()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    func setInteractionVisible(_ visible: Bool, enabled: Bool) {
        alphaValue = visible ? 1 : 0
        isEnabled = visible && enabled
        if !visible || !enabled {
            hovering = false
            updateAppearance()
        }
    }

    private func updateAppearance() {
        let opacity: CGFloat
        if isHighlighted {
            opacity = 0.16
        } else if hovering {
            opacity = 0.08
        } else {
            opacity = 0
        }
        layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(opacity).cgColor
    }
}

private final class NotebookCellCardView: NSView {
    enum Style {
        case editor
        case markdown
    }

    private var content: NSView?
    var isSelected = false { didSet { updateAppearance() } }
    var style = Style.editor { didSet { updateAppearance() } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = DS.Radius.card
        layer?.masksToBounds = true
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setContent(_ view: NSView, insets: NSEdgeInsets) {
        content?.removeFromSuperview()
        content = view
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: topAnchor, constant: insets.top),
            view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insets.left),
            view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -insets.right),
            view.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -insets.bottom),
        ])
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private func updateAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = (style == .editor ? NSColor.textBackgroundColor : .clear).cgColor
            layer?.borderWidth = DS.Layout.hairline
            let border: NSColor = isSelected ? .controlAccentColor : style == .editor ? .separatorColor : .clear
            layer?.borderColor = border.cgColor
        }
    }
}

private class NotebookCellHostingView: NSHostingView<AnyView> {
    var onSizeChange: (() -> Void)?

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        DispatchQueue.main.async { [weak self] in self?.onSizeChange?() }
    }
}

private final class NotebookMarkdownHostingView: NotebookCellHostingView {
    var onSingleClick: (() -> Void)?
    var onDoubleClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            onDoubleClick?()
        } else {
            onSingleClick?()
        }
    }
}
