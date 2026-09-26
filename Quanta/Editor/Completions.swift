import AppKit

final class EditorRegistry {
    static let shared = EditorRegistry()
    private var map: [UUID: NSHashTable<QuantaTextView>] = [:]

    func register(_ textView: QuantaTextView, for id: UUID) {
        map = map.filter { !$0.value.allObjects.isEmpty }
        let views = map[id] ?? NSHashTable<QuantaTextView>.weakObjects()
        views.add(textView)
        map[id] = views
    }

    func view(for id: UUID) -> QuantaTextView? {
        let views = map[id]?.allObjects ?? []
        return views.first { $0.window?.firstResponder === $0 && !$0.isHiddenOrHasHiddenAncestor }
            ?? views.first { $0.window != nil && !$0.isHiddenOrHasHiddenAncestor }
            ?? views.first { $0.window != nil } ?? views.first
    }

    var allViews: [QuantaTextView] { map.values.flatMap(\.allObjects) }

}

extension AppState {
    var focusedCodeEditor: QuantaTextView? {
        (NSApp.keyWindow?.firstResponder as? QuantaTextView)
            ?? selectedCellID.flatMap { EditorRegistry.shared.view(for: $0) }
            ?? activeDocumentID.flatMap { EditorRegistry.shared.view(for: $0) }
    }

    func showEditorDocumentation() { focusedCodeEditor?.requestDocumentation() }
    func showEditorCompletions() { focusedCodeEditor?.requestCompletions() }
}

struct InspectionInfo {
    let signature: String
    let doc: String
}

@MainActor
final class CompletionPanel {
    static let shared = CompletionPanel()

    private var panel: NSPanel?
    private var tableView: NSTableView?
    private weak var host: QuantaTextView?
    private var allMatches: [CodeCompletion] = []
    private var source = ""
    private var filtered: [CodeCompletion] = []
    private var replaceStart = 0

    var isVisible: Bool { panel?.isVisible ?? false }

    func isShowing(for textView: QuantaTextView) -> Bool {
        isVisible && host === textView
    }

    private var scrollObserver: NSObjectProtocol?

    func show(matches: [CodeCompletion], for textView: QuantaTextView) {
        guard textView.window != nil else { hide(); return }
        host = textView
        source = textView.string
        allMatches = Self.valid(matches, sourceLength: (source as NSString).length)
        refilter()
        guard let first = filtered.first else {
            hide()
            return
        }
        replaceStart = first.edit.range.location
        buildPanelIfNeeded()
        reload()
        position(near: textView)
        panel?.orderFront(nil)
        if scrollObserver == nil {
            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSScrollView.willStartLiveScrollNotification, object: nil,
                queue: .main) { [weak self] _ in MainActor.assumeIsolated { self?.hide() } }
        }
    }

    func hide() {
        if let panel {
            panel.orderOut(nil)
        }
        if let scrollObserver {
            NotificationCenter.default.removeObserver(scrollObserver)
            self.scrollObserver = nil
        }
        host = nil
        allMatches = []
        filtered = []
    }

    static func valid(_ matches: [CodeCompletion], sourceLength: Int) -> [CodeCompletion] {
        matches.filter {
            $0.edit.range.location >= 0
                && $0.edit.range.length >= 0
                && $0.edit.range.location <= sourceLength
                && $0.edit.range.length <= sourceLength - $0.edit.range.location
        }
    }

    func caretMoved(in textView: QuantaTextView) {
        guard isShowing(for: textView) else { return }
        let sel = textView.selectedRange()
        let ns = textView.string as NSString
        guard sel.length == 0, sel.location >= replaceStart, replaceStart <= ns.length,
              sel.location <= ns.length else {
            hide()
            return
        }
        let segment = ns.substring(with: NSRange(location: replaceStart,
                                                 length: sel.location - replaceStart))
        if !segment.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) { hide() }
    }

    func refresh(from textView: QuantaTextView) {
        if isShowing(for: textView), textView.string != source { hide() }
    }

    private func refilter() {
        guard let host else { filtered = []; return }
        let ns = source as NSString
        let caret = host.selectedRange().location
        filtered = allMatches.compactMap { item -> (CodeCompletion, Int)? in
            guard item.edit.range.location <= caret, caret <= ns.length else { return nil }
            let query = ns.substring(with: NSRange(location: item.edit.range.location, length: caret - item.edit.range.location))
            return CodeCompletion.rank(item.filterText, query: query).map { (item, $0) }
        }.sorted { ($0.1, $0.0.sortText, $0.0.label) < ($1.1, $1.0.sortText, $1.0.label) }.map(\.0)
    }

    func handle(_ event: NSEvent, for textView: QuantaTextView) -> Bool {
        guard isShowing(for: textView) else { return false }
        if !event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty {
            if event.keyCode == 36 || event.keyCode == 48 { hide() }
            return false
        }
        switch event.keyCode {
        case 125: move(1); return true
        case 126: move(-1); return true
        case 36, 48: acceptSelection(); return true
        case 53: hide(); return true
        default: return false
        }
    }

    private func move(_ delta: Int) {
        guard let tableView, filtered.count > 0 else { return }
        let row = max(0, min(filtered.count - 1, tableView.selectedRow + delta))
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    @objc private func acceptSelection() {
        guard let host, let tableView else { return }
        let row = max(0, tableView.selectedRow)
        guard row < filtered.count else {
            hide()
            return
        }
        let completion = filtered[row]
        guard host.string == source, let transaction = CompletionTransaction(source: source, completion: completion) else { hide(); return }
        hide()
        let ranges = transaction.edits.map { NSValue(range: $0.range) }
        guard host.shouldChangeText(inRanges: ranges, replacementStrings: transaction.edits.map(\.text)) else { return }
        host.undoManager?.beginUndoGrouping()
        host.textStorage?.beginEditing()
        for edit in transaction.edits.reversed() { host.textStorage?.replaceCharacters(in: edit.range, with: edit.text) }
        host.textStorage?.endEditing()
        host.didChangeText()
        host.setSelectedRange(transaction.selection)
        host.snippetRanges = Array(transaction.placeholders.dropFirst())
        host.undoManager?.endUndoGrouping()
        host.undoManager?.setActionName("Complete Code")
    }

    private func buildPanelIfNeeded() {
        guard panel == nil else { return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 160),
                            styleMask: [.nonactivatingPanel, .borderless],
                            backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.transient, .fullScreenAuxiliary]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true

        let content = NSView()

        let table = NSTableView()
        table.headerView = nil
        table.rowHeight = 19
        table.intercellSpacing = NSSize(width: 0, height: 2)
        table.backgroundColor = .clear
        table.style = .plain
        table.selectionHighlightStyle = .regular
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("match"))
        table.addTableColumn(column)
        table.dataSource = dataSource
        table.delegate = dataSource
        table.target = self
        table.action = #selector(acceptSelection)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.autohidesScrollers = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: content.topAnchor, constant: 4),
            scroll.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -4),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 4),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -4),
        ])

        panel.contentView = FloatingPanelSurface.make(content: content)
        self.panel = panel
        self.tableView = table
    }

    private lazy var dataSource = CompletionDataSource(owner: self)

    fileprivate var rows: [CodeCompletion] { filtered }

    private func reload() {
        let rowFont = NSFont.monospacedSystemFont(ofSize: EditorTheme.fontSize - 1, weight: .regular)
        let rowHeight = max(19, ceil(rowFont.ascender - rowFont.descender + rowFont.leading) + 4)
        tableView?.rowHeight = rowHeight
        tableView?.reloadData()
        if !filtered.isEmpty {
            tableView?.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            tableView?.scrollRowToVisible(0)
        }
        let height = min(CGFloat(filtered.count) * (rowHeight + 2) + 8, 8 * (rowHeight + 2) + 8)
        let width = max(220, min(420, 24 + 8 * CGFloat(filtered.map { $0.label.count + min(35, $0.detail.count) }.max() ?? 20)))
        panel?.setContentSize(NSSize(width: width, height: height))
    }

    private func position(near textView: QuantaTextView) {
        guard let panel else { return }
        let caretRange = NSRange(location: replaceStart, length: 0)
        let rect = textView.firstRect(forCharacterRange: caretRange, actualRange: nil)
        var origin = NSPoint(x: rect.minX - 6, y: rect.minY - panel.frame.height - 2)
        if let screen = textView.window?.screen {
            if origin.y < screen.visibleFrame.minY {
                origin.y = rect.maxY + 2
            }
            origin.x = min(origin.x, screen.visibleFrame.maxX - panel.frame.width - 8)
            origin.x = max(origin.x, screen.visibleFrame.minX + 8)
        }
        panel.setFrameOrigin(origin)
    }
}

private final class CompletionDataSource: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    unowned let owner: CompletionPanel

    init(owner: CompletionPanel) { self.owner = owner }

    func numberOfRows(in tableView: NSTableView) -> Int { owner.rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        guard owner.rows.indices.contains(row) else { return nil }
        let id = NSUserInterfaceItemIdentifier("cell")
        let field: NSTextField
        if let reused = tableView.makeView(withIdentifier: id, owner: nil) as? NSTextField {
            field = reused
        } else {
            field = NSTextField(labelWithString: "")
            field.identifier = id
            field.lineBreakMode = .byTruncatingTail
        }
        field.font = NSFont.monospacedSystemFont(ofSize: EditorTheme.fontSize - 1, weight: .regular)
        let item = owner.rows[row]
        field.stringValue = item.label + (item.detail.isEmpty ? (item.kindLabel.isEmpty ? "" : "  · " + item.kindLabel) : "  · " + item.detail.replacingOccurrences(of: "\n", with: " "))
        field.toolTip = [item.detail, item.documentation].filter { !$0.isEmpty }.joined(separator: "\n\n")
        return field
    }
}

enum DocumentationPopover {
    private static var popover: NSPopover?

    static func show(_ info: InspectionInfo, for textView: QuantaTextView) {
        popover?.close()
        let text = NSMutableAttributedString()
        if !info.signature.isEmpty {
            text.append(NSAttributedString(
                string: info.signature + "\n\n",
                attributes: [.font: NSFont.monospacedSystemFont(ofSize: EditorTheme.fontSize, weight: .semibold),
                             .foregroundColor: NSColor.labelColor]))
        }
        text.append(NSAttributedString(
            string: info.doc.isEmpty ? "(no docstring)" : info.doc,
            attributes: [.font: NSFont.monospacedSystemFont(ofSize: EditorTheme.fontSize - 1, weight: .regular),
                         .foregroundColor: NSColor.secondaryLabelColor]))

        let textView2 = NSTextView(frame: NSRect(x: 0, y: 0, width: 480, height: 10))
        textView2.isEditable = false
        textView2.drawsBackground = false
        textView2.textStorage?.setAttributedString(text)
        textView2.textContainerInset = NSSize(width: 8, height: 8)

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        scroll.documentView = textView2
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        textView2.autoresizingMask = [.width]
        textView2.isVerticallyResizable = true
        textView2.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                                   height: CGFloat.greatestFiniteMagnitude)

        let controller = NSViewController()
        controller.view = scroll

        let pop = NSPopover()
        pop.contentViewController = controller
        pop.contentSize = NSSize(width: 500, height: 300)
        pop.behavior = .transient
        popover = pop

        let caret = textView.selectedRange()
        let rect = textView.firstRect(forCharacterRange: NSRange(location: caret.location, length: 0),
                                      actualRange: nil)
        guard let window = textView.window else { return }
        let windowRect = window.convertFromScreen(rect)
        let viewRect = textView.convert(windowRect, from: nil)
        pop.show(relativeTo: viewRect.insetBy(dx: -2, dy: -2), of: textView, preferredEdge: .maxY)
    }
}
