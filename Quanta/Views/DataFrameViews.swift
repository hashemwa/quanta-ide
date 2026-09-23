import AppKit
import SwiftUI

final class PassthroughScrollView: NSScrollView {
    private var routeGestureToParent = false

    override func scrollWheel(with event: NSEvent) {
        let isGestureEvent = event.phase != [] || event.momentumPhase != []
        if event.phase == .began || event.phase == .mayBegin {
            routeGestureToParent = isVerticalDominant(event)
        }
        let routeToParent = isGestureEvent
            ? routeGestureToParent
            : isVerticalDominant(event)
        if routeToParent {
            nextResponder?.scrollWheel(with: event)
        } else {
            super.scrollWheel(with: event)
        }
    }

    private func isVerticalDominant(_ event: NSEvent) -> Bool {
        if event.scrollingDeltaX == 0, event.scrollingDeltaY == 0 { return true }
        return abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX)
    }
}

struct DataFrameTextStyle {
    let size: CGFloat
    let font: NSFont
    let lineHeight: CGFloat
    let leftAttrs: [NSAttributedString.Key: Any]
    let rightAttrs: [NSAttributedString.Key: Any]
    let indexAttrs: [NSAttributedString.Key: Any]
    let emphasizedLeftAttrs: [NSAttributedString.Key: Any]
    let emphasizedRightAttrs: [NSAttributedString.Key: Any]
    let emphasizedIndexAttrs: [NSAttributedString.Key: Any]

    static func cellSize(forMonoSize monoSize: CGFloat) -> CGFloat { max(10, monoSize - 1) }

    static func rowHeight(forCellSize size: CGFloat) -> CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        return ceil(font.ascender + abs(font.descender)) + 7
    }

    static let `default` = DataFrameTextStyle(size: cellSize(forMonoSize: 12))

    init(size: CGFloat) {
        let font = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        self.size = size
        self.font = font
        self.lineHeight = ceil(font.ascender + abs(font.descender))
        func attrs(color: NSColor, right: Bool) -> [NSAttributedString.Key: Any] {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            paragraph.alignment = right ? .right : .left
            return [.font: font, .foregroundColor: color, .paragraphStyle: paragraph]
        }
        self.leftAttrs = attrs(color: .labelColor, right: false)
        self.rightAttrs = attrs(color: .labelColor, right: true)
        self.indexAttrs = attrs(color: .secondaryLabelColor, right: true)
        let selected = NSColor.alternateSelectedControlTextColor
        self.emphasizedLeftAttrs = attrs(color: selected, right: false)
        self.emphasizedRightAttrs = attrs(color: selected, right: true)
        self.emphasizedIndexAttrs = attrs(color: selected.withAlphaComponent(0.7), right: true)
    }
}

final class DataFrameRowView: NSTableRowView {
    static let reuseID = NSUserInterfaceItemIdentifier("dfRow")

    var values: [String] = []
    var rightAligned: [Bool] = []
    var columnTitles: [String] = []
    var isEllipsis = false

    override func accessibilityLabel() -> String? {
        if isEllipsis { return "Rows omitted" }
        guard let index = values.first else { return nil }
        let cells = values.dropFirst().enumerated().map { offset, value -> String in
            let title = offset < columnTitles.count ? columnTitles[offset] : "Column \(offset + 1)"
            return "\(title), \(value.isEmpty ? "empty" : value)"
        }
        return ([index] + cells).joined(separator: ", ")
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard let table = superview as? NSTableView else { return }
        let style = (table as? DataFrameTableView)?.textStyle ?? .default
        let columnCount = min(values.count, table.tableColumns.count)
        let textInset = max(2, (bounds.height - style.lineHeight) / 2)
        for i in 0..<columnCount {
            let text = values[i]
            if text.isEmpty { continue }
            var rect = table.rect(ofColumn: i)
            rect.origin.y = textInset
            rect.size.height = bounds.height - textInset
            rect.origin.x += 6
            rect.size.width -= 12
            guard rect.width > 4, rect.intersects(dirtyRect) else { continue }
            let emphasized = interiorBackgroundStyle == .emphasized
            let attrs: [NSAttributedString.Key: Any]
            if isEllipsis || i == 0 {
                attrs = emphasized ? style.emphasizedIndexAttrs : style.indexAttrs
            } else if i < rightAligned.count, rightAligned[i] {
                attrs = emphasized ? style.emphasizedRightAttrs : style.rightAttrs
            } else {
                attrs = emphasized ? style.emphasizedLeftAttrs : style.leftAttrs
            }
            (text as NSString).draw(in: rect, withAttributes: attrs)
        }
    }
}

enum DataFrameClipboard {
    static func tsv(header: [String]? = nil, rows: [[String]]) -> String {
        var lines: [String] = []
        if let header { lines.append(header.joined(separator: "\t")) }
        lines.append(contentsOf: rows.map { $0.joined(separator: "\t") })
        return lines.joined(separator: "\n")
    }

    static func markdown(header: [String], rows: [[String]], rightAligned: [Bool] = []) -> String {
        func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "|", with: "\\|")
        }
        let separator = header.indices.map { i -> String in
            (i < rightAligned.count && rightAligned[i]) ? "---:" : "---"
        }
        var lines = ["| " + header.map(escape).joined(separator: " | ") + " |",
                     "| " + separator.joined(separator: " | ") + " |"]
        for row in rows {
            var cells = row.map(escape)
            if cells.count < header.count {
                cells.append(contentsOf: Array(repeating: "", count: header.count - cells.count))
            }
            lines.append("| " + cells.prefix(header.count).joined(separator: " | ") + " |")
        }
        return lines.joined(separator: "\n")
    }

    static func pythonList(_ values: [String], bare: Bool) -> String {
        let items = values.map { value -> String in
            if bare {
                switch value {
                case "", "<NA>", "NaT": return "None"
                case "NaN": return "float('nan')"
                case "inf": return "float('inf')"
                case "-inf": return "float('-inf')"
                default: return value
                }
            }
            let escaped = value
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "'", with: "\\'")
            return "'" + escaped + "'"
        }
        return "[" + items.joined(separator: ", ") + "]"
    }
}

final class DataFrameTableView: NSTableView {
    var textStyle = DataFrameTextStyle.default
    weak var copySource: DataFrameNSTable.Coordinator?
    private var menuRow = -1
    private var menuColumn = -1

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if window?.firstResponder === self,
           modifiers == [.command] || modifiers == [.command, .option],
           event.charactersIgnoringModifiers?.lowercased() == "c" {
            copy(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    @objc func copy(_ sender: Any?) {
        let withHeader = NSEvent.modifierFlags.contains(.option)
        copyRows(withHeader: withHeader)
    }

    override func selectAll(_ sender: Any?) {
        guard numberOfRows > 0 else { return }
        selectRowIndexes(IndexSet(integersIn: 0..<numberOfRows), byExtendingSelection: false)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let source = copySource, source.payload != nil else { return nil }
        let point = convert(event.locationInWindow, from: nil)
        menuRow = row(at: point)
        menuColumn = column(at: point)
        let selectionCount = targetRows().count
        let menu = NSMenu()
        menu.autoenablesItems = false

        if menuRow >= 0, menuColumn >= 0, source.dataRow(forTableRow: menuRow) != nil {
            menu.addItem(item("Copy Cell Preview", #selector(copyCellAction)))
            let original = item("Copy Original Value", #selector(copyOriginalCellAction))
            original.isEnabled = source.payload?.originalRows != nil
            menu.addItem(original)
        }
        let rowsTitle = selectionCount > 1 ? "Copy \(selectionCount) Row Previews" : "Copy Row Preview"
        let primary = item(rowsTitle, #selector(copyRowsAction))
        primary.keyEquivalent = "c"
        primary.keyEquivalentModifierMask = .command
        menu.addItem(primary)
        let alt = item(rowsTitle + " with Header", #selector(copyRowsWithHeaderAction))
        alt.keyEquivalent = "c"
        alt.keyEquivalentModifierMask = [.command, .option]
        alt.isAlternate = true
        menu.addItem(alt)
        let originals = item("Copy Original Row Values", #selector(copyOriginalRowsAction))
        originals.isEnabled = source.payload?.originalRows != nil
        menu.addItem(originals)
        menu.addItem(.separator())
        if menuColumn >= 1 {
            menu.addItem(item("Copy Column Name", #selector(copyColumnNameAction)))
            menu.addItem(item("Copy Column Previews (Loaded Rows)", #selector(copyColumnValuesAction)))
            let original = item("Copy Original Column Values (Loaded Rows)", #selector(copyOriginalColumnAction))
            original.isEnabled = source.payload?.originalRows != nil
            menu.addItem(original)
            menu.addItem(.separator())
        }
        menu.addItem(item("Copy as Markdown Table", #selector(copyMarkdownAction)))
        if source.payload?.name != nil {
            menu.addItem(.separator())
            menu.addItem(item("Open Full Table", #selector(openFullTableAction)))
        }
        return menu
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    private func targetRows() -> [Int] {
        guard let source = copySource, let payload = source.payload else { return [] }
        let selected = selectedRowIndexes.compactMap { source.dataRow(forTableRow: $0) }
        if !selected.isEmpty { return selected }
        if menuRow >= 0, let clicked = source.dataRow(forTableRow: menuRow) { return [clicked] }
        return Array(payload.rows.indices)
    }

    private func setPasteboard(_ text: String, tabular: Bool = false) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        if tabular {
            pasteboard.setString(text, forType: .tabularText)
        }
    }

    private func copyRows(withHeader: Bool) {
        guard let source = copySource, let payload = source.payload else { return }
        let rows = targetRows().map { source.rowValues(payload, dataRow: $0) }
        guard !rows.isEmpty else { return }
        let header = withHeader ? [""] + payload.columns : nil
        setPasteboard(DataFrameClipboard.tsv(header: header, rows: rows), tabular: true)
    }

    @objc private func copyRowsAction(_ sender: Any?) { copyRows(withHeader: false) }
    @objc private func copyRowsWithHeaderAction(_ sender: Any?) { copyRows(withHeader: true) }

    @objc private func copyCellAction(_ sender: Any?) {
        guard let source = copySource, let payload = source.payload,
              menuRow >= 0, menuColumn >= 0,
              let dataRow = source.dataRow(forTableRow: menuRow) else { return }
        let values = source.rowValues(payload, dataRow: dataRow)
        guard menuColumn < values.count else { return }
        setPasteboard(values[menuColumn])
    }

    private func copyOriginal(rows: [Int], columns: [Int], scalar: Bool = false) {
        guard let payload = copySource?.payload else { return }
        guard let values = payload.originalValues(rows: rows, columns: columns) else {
            AppState.shared.userNotice = "Original values are unavailable in this preview. Reload the table, or copy the value directly in Python. Values exceeding the preview's copy limit are never shortened and copied as originals."
            return
        }
        if scalar, let value = values.first?.first { setPasteboard(value) }
        else { setPasteboard(DataFrameClipboard.tsv(header: nil, rows: values), tabular: true) }
    }

    @objc private func copyOriginalCellAction(_ sender: Any?) {
        guard let row = copySource?.dataRow(forTableRow: menuRow), menuColumn >= 0 else { return }
        copyOriginal(rows: [row], columns: [menuColumn], scalar: true)
    }

    @objc private func copyOriginalRowsAction(_ sender: Any?) {
        guard let payload = copySource?.payload else { return }
        copyOriginal(rows: targetRows(), columns: Array(0...payload.columns.count))
    }

    @objc private func copyOriginalColumnAction(_ sender: Any?) {
        guard let payload = copySource?.payload, menuColumn >= 1 else { return }
        copyOriginal(rows: Array(payload.rows.indices), columns: [menuColumn])
    }

    @objc private func copyColumnNameAction(_ sender: Any?) {
        guard let payload = copySource?.payload, menuColumn >= 1,
              menuColumn - 1 < payload.columns.count else { return }
        setPasteboard(payload.columns[menuColumn - 1])
    }

    @objc private func copyColumnValuesAction(_ sender: Any?) {
        guard let payload = copySource?.payload, menuColumn >= 1 else { return }
        let column = menuColumn - 1
        guard column < payload.columns.count else { return }
        let values = payload.rows.map { column < $0.count ? $0[column] : "" }
        let dtype = column < payload.dtypes.count ? payload.dtypes[column].lowercased() : ""
        let bare = payload.isNumericColumn(column) || dtype.hasPrefix("bool")
        setPasteboard(DataFrameClipboard.pythonList(values, bare: bare))
    }

    @objc private func openFullTableAction(_ sender: Any?) {
        guard let name = copySource?.payload?.name else { return }
        AppState.shared.openDataFrame(named: name)
    }

    @objc private func copyMarkdownAction(_ sender: Any?) {
        guard let source = copySource, let payload = source.payload else { return }
        let rows = targetRows().map { source.rowValues(payload, dataRow: $0) }
        guard !rows.isEmpty else { return }
        let rightAligned = [true] + payload.columns.indices.map { payload.isNumericColumn($0) }
        setPasteboard(DataFrameClipboard.markdown(header: [""] + payload.columns,
                                                  rows: rows, rightAligned: rightAligned))
    }
}

final class TableViewCache {
    static let shared = TableViewCache()
    private var store: [UUID: NSScrollView] = [:]
    private var order: [UUID] = []

    func view(for key: UUID) -> NSScrollView? {
        guard let view = store[key], view.superview == nil else { return nil }
        touch(key)
        return view
    }

    func insert(_ view: NSScrollView, for key: UUID) {
        store[key] = view
        touch(key)
        while order.count > 8 {
            store.removeValue(forKey: order.removeFirst())
        }
    }

    private func touch(_ key: UUID) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}

struct DataFrameNSTable: NSViewRepresentable {
    var payload: DataFramePayload
    var cacheKey: UUID
    var isInline = false

    static func inlineHeight(rowCount: Int, monoSize: CGFloat) -> CGFloat {
        let rowHeight = DataFrameTextStyle.rowHeight(
            forCellSize: DataFrameTextStyle.cellSize(forMonoSize: monoSize))
        return CGFloat(rowCount) * (rowHeight + 2) + 32
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        if let cached = TableViewCache.shared.view(for: cacheKey),
           let table = cached.documentView as? DataFrameTableView {
            table.dataSource = context.coordinator
            table.delegate = context.coordinator
            table.copySource = context.coordinator
            context.coordinator.table = table
            context.coordinator.adoptExistingColumns(of: table)
            return cached
        }
        let table = DataFrameTableView()
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.copySource = context.coordinator
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = DataFrameTextStyle.rowHeight(forCellSize: table.textStyle.size)
        table.intercellSpacing = NSSize(width: 12, height: 2)
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = false
        table.usesAutomaticRowHeights = false
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.style = .plain

        let scroll = isInline ? PassthroughScrollView() : NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = !isInline
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        if isInline {
            scroll.verticalScrollElasticity = .none
            scroll.scrollerStyle = .overlay
        }
        context.coordinator.table = table
        TableViewCache.shared.insert(scroll, for: cacheKey)
        return scroll
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let table = context.coordinator.table else { return }
        let dataChanged = context.coordinator.contentVersion != payload.contentVersion
        let columnsChanged = context.coordinator.rebuildColumnsIfNeeded(table, payload: payload)
        let cellSize = DataFrameTextStyle.cellSize(forMonoSize: context.environment.monoFontSize)
        let fontChanged = context.coordinator.applyTextStyleIfNeeded(table, cellSize: cellSize)
        context.coordinator.payload = payload
        context.coordinator.contentVersion = payload.contentVersion
        if dataChanged || columnsChanged || fontChanged {
            context.coordinator.rebuildAlignmentCache(payload: payload)
            table.reloadData()
        }
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var payload: DataFramePayload?
        var contentVersion: UUID?
        weak var table: DataFrameTableView?
        private var columnSignature: [String] = []
        private var rightAligned: [Bool] = []

        func adoptExistingColumns(of table: NSTableView) {
            columnSignature = table.tableColumns.map {
                $0.identifier.rawValue + "|" + $0.title
            }
        }

        private func signature(for payload: DataFramePayload) -> [String] {
            ["__index__|"] + payload.columns.enumerated().map { "c\($0.offset)|\($0.element)" }
        }

        @discardableResult
        func rebuildColumnsIfNeeded(_ table: NSTableView, payload: DataFramePayload) -> Bool {
            let desired = signature(for: payload)
            guard desired != columnSignature else {
                if rightAligned.isEmpty { rebuildAlignmentCache(payload: payload) }
                return false
            }
            columnSignature = desired
            for column in Array(table.tableColumns) {
                table.removeTableColumn(column)
            }
            let indexColumn = NSTableColumn(identifier: .init("__index__"))
            indexColumn.title = ""
            indexColumn.width = 64
            indexColumn.minWidth = 40
            table.addTableColumn(indexColumn)
            for (i, name) in payload.columns.enumerated() {
                let column = NSTableColumn(identifier: .init("c\(i)"))
                column.title = name
                if i < payload.dtypes.count {
                    column.headerToolTip = payload.dtypes[i]
                }
                column.width = 110
                column.minWidth = 50
                column.maxWidth = 600
                table.addTableColumn(column)
            }
            rebuildAlignmentCache(payload: payload)
            return true
        }

        func rebuildAlignmentCache(payload: DataFramePayload) {
            rightAligned = [true] + payload.columns.indices.map { payload.isNumericColumn($0) }
        }

        @discardableResult
        func applyTextStyleIfNeeded(_ table: DataFrameTableView, cellSize: CGFloat) -> Bool {
            let sizeChanged = table.textStyle.size != cellSize
            let headerFont = NSFont.systemFont(ofSize: cellSize)
            let headerStale = table.tableColumns.contains {
                $0.headerCell.font?.pointSize != cellSize
            }
            guard sizeChanged || headerStale else { return false }
            if sizeChanged {
                table.textStyle = DataFrameTextStyle(size: cellSize)
                table.rowHeight = DataFrameTextStyle.rowHeight(forCellSize: cellSize)
            }
            for column in table.tableColumns {
                column.headerCell.font = headerFont
            }
            table.headerView?.needsDisplay = true
            return sizeChanged
        }

        func dataRow(forTableRow row: Int) -> Int? {
            guard let payload else { return nil }
            let index = row
            let ellipsisIndex = payload.rowsTruncated ? payload.headCount : -1
            if index == ellipsisIndex { return nil }
            let dataRow = (ellipsisIndex >= 0 && index > ellipsisIndex) ? index - 1 : index
            return dataRow < payload.rows.count ? dataRow : nil
        }

        func rowValues(_ payload: DataFramePayload, dataRow: Int) -> [String] {
            var values = [dataRow < payload.index.count ? payload.index[dataRow] : "\(dataRow)"]
            values.append(contentsOf: payload.rows[dataRow])
            return values
        }

        func numberOfRows(in tableView: NSTableView) -> Int {
            payload?.displayRowCount ?? 0
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            guard let payload else { return nil }
            let rowView: DataFrameRowView
            if let reused = tableView.makeView(withIdentifier: DataFrameRowView.reuseID,
                                               owner: nil) as? DataFrameRowView {
                rowView = reused
            } else {
                rowView = DataFrameRowView()
                rowView.identifier = DataFrameRowView.reuseID
            }
            rowView.isEllipsis = false

            if let dataRow = dataRow(forTableRow: row) {
                rowView.values = rowValues(payload, dataRow: dataRow)
            } else if row < payload.displayRowCount {
                rowView.values = Array(repeating: "⋯", count: payload.columns.count + 1)
                rowView.isEllipsis = true
            } else {
                return nil
            }
            rowView.rightAligned = rightAligned
            rowView.columnTitles = payload.columns
            rowView.needsDisplay = true
            return rowView
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                       row: Int) -> NSView? {
            nil
        }
    }
}

struct DataFrameTabView: View {
    @State private var filterDraft = ""
    @State private var showingSearch = false
    @ObservedObject var document: Document
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(document.dataFrameName ?? "DataFrame", systemImage: "tablecells") {
                if let payload = document.dataFrame {
                    Text(summary(payload))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .help("\(payload.totalRows) rows × \(payload.totalCols) columns · "
                              + "\(payload.rows.count) rows loaded · \(payload.columnSummary)")
                    if payload.rows.count < payload.totalRows {
                        Button("Load 1,000 more") { app.loadMoreDataFrame(document) }
                            .buttonStyle(.borderless)
                            .font(.caption)
                            .disabled(document.isLoadingDataFrame)
                            .help("Load the next 1,000 rows from the kernel")
                    }
                }
                IconButton("magnifyingglass", help: "Filter Table Rows", isActive: showingSearch || !document.dataFrameFilter.isEmpty) {
                    showingSearch.toggle()
                    filterDraft = document.dataFrameFilter
                }
                IconMenu("arrow.up.arrow.down", help: "Sort Table Rows") {
                    Picker("Column", selection: Binding(
                        get: { document.dataFrameSortColumn ?? -1 },
                        set: { document.dataFrameSortColumn = $0 < 0 ? nil : $0; app.reloadDataFrame(document) }
                    )) {
                        Text("Original Order").tag(-1)
                        if let payload = document.dataFrame {
                            ForEach(Array(payload.columns.enumerated()), id: \.offset) { index, name in
                                Text(name).tag(index)
                            }
                        }
                    }.pickerStyle(.inline)
                    Divider()
                    Picker("Direction", selection: Binding(
                        get: { document.dataFrameSortAscending },
                        set: { document.dataFrameSortAscending = $0; app.reloadDataFrame(document) }
                    )) {
                        Text("Ascending").tag(true)
                        Text("Descending").tag(false)
                    }.pickerStyle(.inline).disabled(document.dataFrameSortColumn == nil)
                }.disabled(document.isLoadingDataFrame)
                IconButton("arrow.clockwise", help: "Reload Table (⌘R)") {
                    app.reloadDataFrame(document)
                }
            }
            if showingSearch {
                PanelSearchBar(prompt: "Filter rows — press Return", text: $filterDraft, onSubmit: applyFilter) {
                    showingSearch = false
                    filterDraft = document.dataFrameFilter
                }
                .disabled(document.isLoadingDataFrame)
                .onChange(of: filterDraft) { _, text in
                    if text.isEmpty, !document.dataFrameFilter.isEmpty { applyFilter() }
                }
            }
            if !document.dataFrameFilter.isEmpty || document.dataFrameSortColumn != nil {
                HStack {
                    Text(document.dataFrameFilter.isEmpty ? "All rows" : "Matching “\(document.dataFrameFilter)”")
                    if let index = document.dataFrameSortColumn, let payload = document.dataFrame, payload.columns.indices.contains(index) {
                        Text("· \(payload.columns[index]) \(document.dataFrameSortAscending ? "ascending" : "descending")")
                    }
                    Spacer()
                    IconButton("xmark.circle.fill", help: "Reset Table Filters and Sort") {
                        filterDraft = ""
                        document.dataFrameFilter = ""
                        document.dataFrameSortColumn = nil
                        app.reloadDataFrame(document)
                    }.disabled(document.isLoadingDataFrame)
                    if document.isLoadingDataFrame { ProgressView().controlSize(.mini) }
                }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, DS.Space.bar).padding(.vertical, DS.Space.xs)
            }
            if let payload = document.dataFrame {
                if payload.totalRows == 0 {
                    ContentUnavailableView {
                        Label(document.dataFrameFilter.isEmpty ? "Empty DataFrame" : "No Matching Rows", systemImage: "tablecells")
                    } description: {
                        Text(document.dataFrameFilter.isEmpty ? "\(document.dataFrameName ?? "The frame") has no rows · \(payload.columnSummary)" : "Change or clear the filter to see more rows.")
                    }
                } else {
                    DataFrameNSTable(payload: payload, cacheKey: document.id)
                }
            } else if let error = document.dataFrameError {
                ContentUnavailableView {
                    Label("Couldn't Load Table", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry") { app.reloadDataFrame(document) }
                        .controlSize(.small)
                }
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func applyFilter() {
        document.dataFrameFilter = filterDraft
        app.reloadDataFrame(document)
    }

    private func summary(_ payload: DataFramePayload) -> String {
        let shape = "\(payload.totalRows.formatted()) rows × \(payload.totalCols.formatted()) columns"
        if payload.rows.count < payload.totalRows || payload.colsTruncated {
            return shape + " · \(payload.rows.count.formatted()) loaded"
                + (payload.colsTruncated ? " · \(payload.columnSummary)" : "")
        }
        return shape
    }
}
