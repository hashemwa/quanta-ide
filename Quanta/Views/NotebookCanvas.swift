import AppKit
import Combine
import SwiftUI

final class NotebookCanvas: DocumentCanvas {
    static func spacing(after type: CellType?) -> CGFloat {
        type == .markdown ? DS.Layout.notebookProseSpacing : DS.Layout.notebookCellSpacing
    }

    static let realizedViewports: CGFloat = 1
    static let prefetchedViewports: CGFloat = 2
    static let retainedViewports: CGFloat = 3
    static let prefetchBatch = 2

    private var document: Document
    private var notebook: Notebook
    private var monoFontSize: CGFloat
    private var cells: [NotebookCell] = []
    private var cellIDs: [UUID] = []
    private var views: [UUID: NotebookCellAppKitView] = [:]
    private var heights: [UUID: CGFloat] = [:]
    private var undoManagers: [UUID: UndoManager] = [:]
    private var offsets: [CGFloat] = []
    private var dirtyCellIDs: Set<UUID> = []
    private var measuredWidth: CGFloat = 0
    private var measuredViewportWidth: CGFloat = 0
    private var layoutPending = false
    private var prefetchPending = false
    private var isLayingOut = false
    private var needsReset = true
    private var needsSync = false
    private var handledScrollRequest: UUID?
    private var pendingScrollRequest: UUID?
    private var scrollCancellable: AnyCancellable?
    private var cellsCancellable: AnyCancellable?
    private var scrollView: NotebookNativeScrollView?
    private weak var contentView: NotebookDocumentView?
    private var addView: NSHostingView<AnyView>?
    private var toolbar: CellToolbarHostingView?
    private var selectionCancellable: AnyCancellable?
    private var boundsObserver: NSObjectProtocol?

    var realizedCellCount: Int { views.count }

    init(document: Document, notebook: Notebook, monoFontSize: CGFloat) {
        self.document = document
        self.notebook = notebook
        self.monoFontSize = monoFontSize
        scrollCancellable = ScrollActivityMonitor.shared.$isLiveScrolling
            .receive(on: DispatchQueue.main)
            .sink { [weak self] active in
                guard !active, let self else { return }
                if !self.dirtyCellIDs.isEmpty { self.scheduleLayout() }
                self.schedulePrefetch()
            }
        observeCells(of: notebook)
    }

    private func observeCells(of notebook: Notebook) {
        cellsCancellable = notebook.$cells
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                self.update(document: self.document, notebook: self.notebook,
                            monoFontSize: self.monoFontSize, scrollRequest: self.handledScrollRequest)
            }
    }

    var view: NSView {
        if let scrollView { return scrollView }
        let scrollView = NotebookNativeScrollView()
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .textBackgroundColor
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay

        let contentView = NotebookDocumentView()
        contentView.frame = NSRect(x: 0, y: 0, width: 640, height: 1)
        scrollView.documentView = contentView
        scrollView.onViewportChange = { [weak self] size in
            self?.updateViewport(size)
        }
        self.scrollView = scrollView
        self.contentView = contentView
        installToolbar(in: contentView, scrollView: scrollView)
        NotebookScrolling.register(scrollView: scrollView)
        DispatchQueue.main.async { [weak self] in
            guard let self, let scrollView = self.scrollView else { return }
            self.updateViewport(scrollView.contentView.bounds.size)
        }
        return scrollView
    }

    deinit {
        if let boundsObserver { NotificationCenter.default.removeObserver(boundsObserver) }
    }

    func focus(in window: NSWindow) {
        guard let catcher = CommandCatcherView.activeCatcher(in: window) else { return }
        window.makeFirstResponder(catcher)
    }

    private func installToolbar(in contentView: NSView, scrollView: NSScrollView) {
        let toolbar = CellToolbarHostingView(rootView: CellToolbar(document: document, notebook: notebook))
        toolbar.sizingOptions = [.intrinsicContentSize]
        toolbar.onSizeChange = { [weak self] in self?.positionToolbar() }
        contentView.addSubview(toolbar)
        self.toolbar = toolbar
        scrollView.contentView.postsBoundsChangedNotifications = true
        boundsObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: scrollView.contentView, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.realizeCellsForScroll()
                self?.positionToolbar()
            }
        }
        selectionCancellable = AppState.shared.selection.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.positionToolbar() }
            }
    }

    private var columnX: CGFloat {
        max(0, ((scrollView?.contentView.bounds.width ?? 0) - measuredWidth) / 2)
    }

    private func frame(ofCellAt index: Int) -> NSRect {
        views[cellIDs[index]]?.frame
            ?? NSRect(x: columnX, y: offsets[index], width: measuredWidth, height: height(at: index))
    }

    private func positionToolbar() {
        guard let toolbar, let scrollView else { return }
        let selection = AppState.shared.selection
        guard selection.selectedCellIDs.count <= 1, let id = selection.selectedCellID,
              let index = cellIDs.firstIndex(of: id), index < offsets.count, measuredWidth > 0 else {
            toolbar.passesClicksThrough = true
            return
        }
        toolbar.passesClicksThrough = false
        let cell = frame(ofCellAt: index)
        let size = toolbar.intrinsicContentSize
        let natural = cell.minY + DS.Space.xs - size.height
        let visibleTop = scrollView.contentView.bounds.minY + DS.Space.xs
        let y = natural < visibleTop ? max(natural, min(visibleTop, cell.maxY - size.height)) : natural
        let frame = NSRect(x: cell.maxX - size.width - DS.Space.s, y: y, width: size.width, height: size.height)
        if toolbar.frame != frame { toolbar.frame = frame }
    }

    func update(document: Document, notebook: Notebook, monoFontSize: CGFloat,
                scrollRequest: UUID?) {
        if self.notebook !== notebook { observeCells(of: notebook) }
        if self.document !== document || self.notebook !== notebook {
            needsReset = true
        } else if cellIDs != notebook.cells.map(\.id) {
            needsSync = true
        } else if self.monoFontSize != monoFontSize {
            for (id, cellView) in views {
                guard let cell = cells.first(where: { $0.id == id }) else { continue }
                cellView.configure(cell: cell, document: document, notebook: notebook, monoFontSize: monoFontSize)
                dirtyCellIDs.insert(id)
            }
        }
        self.document = document
        self.notebook = notebook
        self.monoFontSize = monoFontSize
        if scrollRequest == nil {
            handledScrollRequest = nil
        } else if scrollRequest != handledScrollRequest {
            handledScrollRequest = scrollRequest
            pendingScrollRequest = scrollRequest
        }
        if let scrollView, !scrollView.isHiddenOrHasHiddenAncestor {
            updateViewport(scrollView.contentView.bounds.size)
        }
    }

    private func updateViewport(_ size: NSSize) {
        guard size.width > DS.Layout.cellGutterWidth + DS.Space.xl else { return }
        let width = min(DS.Layout.notebookReadingWidth,
                        size.width - DS.Layout.notebookSidePadding * 2)
        let structureChanged = needsReset || needsSync
        if needsReset { reset(width: width) }
        if needsSync { syncCells() }
        if abs(width - measuredWidth) > 0.5 {
            measuredWidth = width
            measuredViewportWidth = size.width
            dirtyCellIDs = Set(views.keys)
            layoutCells()
        } else if structureChanged || abs(size.width - measuredViewportWidth) > 0.5 {
            measuredViewportWidth = size.width
            layoutCells()
        } else if let contentView, contentView.frame.height < size.height {
            contentView.setFrameSize(NSSize(width: size.width, height: size.height))
        }
        scrollToPendingCell()
    }

    private func reset(width: CGFloat) {
        guard let contentView else { return }
        views.keys.forEach(unrealize)
        heights.removeAll()
        undoManagers.removeAll()
        offsets.removeAll()
        dirtyCellIDs.removeAll()
        cells = notebook.cells
        cellIDs = cells.map(\.id)
        addView?.removeFromSuperview()
        let addView = NSHostingView(rootView: AnyView(
            NotebookAddCellView(document: document, notebook: notebook)
                .environment(\.monoFontSize, monoFontSize)
        ))
        addView.sizingOptions = [.intrinsicContentSize]
        addView.translatesAutoresizingMaskIntoConstraints = false
        addView.frame = NSRect(x: 0, y: 0, width: width, height: 40)
        contentView.addSubview(addView, positioned: .below, relativeTo: toolbar)
        self.addView = addView
        toolbar?.rootView = CellToolbar(document: document, notebook: notebook)
        needsReset = false
        needsSync = false
        measuredWidth = 0
        measuredViewportWidth = 0
    }

    private func syncCells() {
        cells = notebook.cells
        cellIDs = cells.map(\.id)
        let present = Set(cellIDs)
        views.keys.filter { !present.contains($0) }.forEach(unrealize)
        heights = heights.filter { present.contains($0.key) }
        undoManagers = undoManagers.filter { present.contains($0.key) }
        needsSync = false
    }

    private func scheduleLayout() {
        guard !layoutPending, !ScrollActivityMonitor.shared.isLiveScrolling else { return }
        layoutPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.layoutPending = false
            guard !ScrollActivityMonitor.shared.isLiveScrolling else { return }
            self.layoutCells()
            self.scrollToPendingCell()
        }
    }

    private func height(at index: Int) -> CGFloat {
        heights[cellIDs[index]] ?? estimatedHeight(of: cells[index])
    }

    private func recomputeOffsets() {
        var y = DS.Layout.notebookTopPadding
        offsets = cells.indices.map { index in
            if index > 0 { y += Self.spacing(after: cells[index - 1].cellType) + height(at: index - 1) }
            return y
        }
    }

    private var cellsBottom: CGFloat {
        guard let last = offsets.indices.last else { return DS.Layout.notebookTopPadding }
        return offsets[last] + height(at: last)
    }

    private func index(atY y: CGFloat) -> Int? {
        guard !offsets.isEmpty else { return nil }
        var low = 0, high = offsets.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if offsets[mid] <= y { low = mid } else { high = mid - 1 }
        }
        return low
    }

    private func indices(from top: CGFloat, to bottom: CGFloat) -> ClosedRange<Int>? {
        guard let first = index(atY: top), let last = index(atY: bottom) else { return nil }
        return first...max(first, last)
    }

    private func realize(at index: Int) -> Bool {
        guard let contentView else { return false }
        let cell = cells[index]
        let cellView = NotebookCellAppKitView(frame: NSRect(x: columnX, y: offsets[index],
                                                          width: measuredWidth, height: height(at: index)))
        cellView.translatesAutoresizingMaskIntoConstraints = false
        let undoManager = undoManagers[cell.id] ?? UndoManager()
        undoManagers[cell.id] = undoManager
        cellView.configure(cell: cell, document: document, notebook: notebook,
                           monoFontSize: monoFontSize, undoManager: undoManager)
        contentView.addSubview(cellView, positioned: .below, relativeTo: toolbar)
        cellView.onSizeChange = { [weak self, weak cellView] in
            guard let self, let cellID = cellView?.cellID else { return }
            self.dirtyCellIDs.insert(cellID)
            self.scheduleLayout()
        }
        views[cell.id] = cellView
        return measure(cell.id, cellView)
    }

    private func measure(_ id: UUID, _ cellView: NSView) -> Bool {
        let height = measuredHeight(of: cellView, width: measuredWidth)
        let changed = abs(height - (heights[id] ?? -1)) > 0.5
        heights[id] = height
        return changed
    }

    private func unrealize(_ id: UUID) {
        guard let cellView = views.removeValue(forKey: id) else { return }
        cellView.onSizeChange = nil
        cellView.resetForReuse()
        cellView.removeFromSuperview()
    }

    private func holdsFocus(_ cellView: NSView) -> Bool {
        (cellView.window?.firstResponder as? NSView)?.isDescendant(of: cellView) == true
    }

    private func realizeCellsForScroll() {
        guard !isLayingOut, measuredWidth > 0, let scrollView, !offsets.isEmpty else { return }
        let visible = scrollView.contentView.bounds
        let margin = visible.height * Self.realizedViewports
        guard let range = indices(from: visible.minY - margin, to: visible.maxY + margin),
              range.contains(where: { views[cellIDs[$0]] == nil }) else { return }
        layoutCells()
    }

    private func layoutCells() {
        guard !isLayingOut, let scrollView, let contentView, measuredWidth > 0 else { return }
        isLayingOut = true
        defer { isLayingOut = false }
        let clipView = scrollView.contentView
        let viewport = clipView.bounds.size
        let oldTop = clipView.bounds.minY
        let anchor = index(atY: oldTop).map { (id: cellIDs[$0], delta: oldTop - offsets[$0]) }
        var changed = false
        for id in dirtyCellIDs {
            if let cellView = views[id], measure(id, cellView) { changed = true }
        }
        dirtyCellIDs.removeAll()

        func anchoredTop() -> CGFloat {
            guard let anchor, let index = cellIDs.firstIndex(of: anchor.id) else { return oldTop }
            return offsets[index] + anchor.delta
        }
        let visibleOnly = views.isEmpty
        for _ in 0..<4 {
            recomputeOffsets()
            let top = anchoredTop()
            let margin = visibleOnly ? 0 : viewport.height * Self.realizedViewports
            guard let range = indices(from: top - margin, to: top + viewport.height + margin) else { break }
            var realized = false
            for index in range where views[cellIDs[index]] == nil {
                if realize(at: index) { changed = true }
                realized = true
            }
            if !realized { break }
        }
        recomputeOffsets()

        let x = columnX
        for (index, id) in cellIDs.enumerated() {
            guard let cellView = views[id] else { continue }
            let frame = NSRect(x: x, y: offsets[index], width: measuredWidth, height: height(at: index))
            if cellView.frame != frame { cellView.frame = frame }
        }
        var y = cellsBottom
        if let addView {
            if !cells.isEmpty { y += DS.Layout.notebookCellSpacing }
            let height = measuredHeight(of: addView, width: measuredWidth)
            addView.frame = NSRect(x: x, y: y, width: measuredWidth, height: height)
            y += height + DS.Layout.notebookCellSpacing
        }
        let totalHeight = max(viewport.height, y)
        let nextSize = NSSize(width: viewport.width, height: totalHeight)
        if contentView.frame.size != nextSize {
            contentView.setFrameSize(nextSize)
            scrollView.reflectScrolledClipView(clipView)
        }
        if anchor != nil {
            let target = max(0, min(anchoredTop(), totalHeight - viewport.height))
            if abs(target - clipView.bounds.minY) > 0.5 {
                clipView.scroll(to: NSPoint(x: 0, y: target))
                scrollView.reflectScrolledClipView(clipView)
            }
        }
        releaseDistantCells()
        if changed { views.values.forEach { $0.refreshHover() } }
        positionToolbar()
        if visibleOnly, !cells.isEmpty {
            DispatchQueue.main.async { [weak self] in self?.layoutCells() }
        } else {
            schedulePrefetch()
        }
    }

    private func schedulePrefetch() {
        guard !prefetchPending else { return }
        prefetchPending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.prefetchPending = false
            self.prefetchNearbyCells()
        }
    }

    private func prefetchNearbyCells() {
        guard !isLayingOut, !ScrollActivityMonitor.shared.isLiveScrolling, measuredWidth > 0,
              let scrollView, !scrollView.isHiddenOrHasHiddenAncestor else { return }
        let visible = scrollView.contentView.bounds
        let margin = visible.height * Self.prefetchedViewports
        guard let range = indices(from: visible.minY - margin, to: visible.maxY + margin) else { return }
        let center = visible.midY
        let missing = range.filter { views[cellIDs[$0]] == nil }
            .sorted { abs(offsets[$0] - center) < abs(offsets[$1] - center) }
        guard !missing.isEmpty else { return }
        isLayingOut = true
        missing.prefix(Self.prefetchBatch).forEach { _ = realize(at: $0) }
        isLayingOut = false
        layoutCells()
    }

    private func releaseDistantCells() {
        guard let scrollView else { return }
        let visible = scrollView.contentView.bounds
        let margin = visible.height * Self.retainedViewports
        let keep = indices(from: visible.minY - margin, to: visible.maxY + margin)
        for (index, id) in cellIDs.enumerated() where keep?.contains(index) != true {
            if let cellView = views[id], !holdsFocus(cellView) { unrealize(id) }
        }
    }

    private func measuredHeight(of view: NSView, width: CGFloat) -> CGFloat {
        view.translatesAutoresizingMaskIntoConstraints = false
        let widthConstraint = view.widthAnchor.constraint(equalToConstant: width)
        widthConstraint.isActive = true
        view.setFrameSize(NSSize(width: width, height: max(1, view.frame.height)))
        view.layoutSubtreeIfNeeded()
        let fittedHeight = view.fittingSize.height
        let height = fittedHeight.isFinite && fittedHeight > 0
            ? min(ceil(fittedHeight), 100_000)
            : max(1, view.frame.height)
        widthConstraint.isActive = false
        view.setFrameSize(NSSize(width: width, height: height))
        view.translatesAutoresizingMaskIntoConstraints = true
        return height
    }

    private func scrollToPendingCell() {
        guard let target = pendingScrollRequest,
              let index = cellIDs.firstIndex(of: target),
              index < offsets.count,
              let scrollView else { return }
        pendingScrollRequest = nil
        let clipView = scrollView.contentView
        func reveal() {
            let visible = clipView.bounds
            let frame = frame(ofCellAt: index)
            var y = visible.minY
            if frame.minY < visible.minY {
                y = frame.minY
            } else if frame.maxY > visible.maxY {
                y = min(frame.minY, frame.maxY - visible.height)
            }
            guard abs(y - visible.minY) > 0.5 else { return }
            clipView.scroll(to: NSPoint(x: 0, y: max(0, y)))
            scrollView.reflectScrolledClipView(clipView)
        }
        reveal()
        layoutCells()
        reveal()
        if AppState.shared.scrollRequest == target {
            AppState.shared.scrollRequest = nil
        }
    }

    private func estimatedHeight(of cell: NotebookCell) -> CGFloat {
        let lineCount = CGFloat(cell.source.reduce(into: 1) { count, character in
            if character == "\n" { count += 1 }
        })
        var height: CGFloat
        if cell.isSourceCollapsed {
            height = EditorTheme.lineHeight + DS.Space.s * 2
        } else if cell.cellType == .markdown && !cell.isEditingMarkdown {
            let charactersPerLine = max(24, Int(max(measuredWidth, 400) / 7.5))
            let wrapped = cell.source.split(separator: "\n", omittingEmptySubsequences: false)
                .reduce(0) { $0 + max(1, ($1.count + charactersPerLine - 1) / charactersPerLine) }
            height = CGFloat(wrapped) * 20 + DS.Space.s * 2
        } else {
            height = lineCount * EditorTheme.lineHeight + DS.Space.s * 2 + DS.Space.xs * 2 + 2
        }
        guard cell.cellType == .code, !cell.outputs.isEmpty else { return max(height, 30) }
        if cell.isOutputCollapsed { return height + DS.Space.s + 20 }
        let monoLine = ceil(monoFontSize * 1.3)
        for output in cell.outputs {
            height += DS.Space.s
            switch output.kind {
            case .stream(_, let text), .executeResult(let text):
                height += CGFloat(text.reduce(into: 1) { if $1 == "\n" { $0 += 1 } }) * monoLine
            case .image(_, let image):
                let size = image?.size ?? NSSize(width: 600, height: 400)
                let width = min(DS.Layout.outputMaxWidth, max(measuredWidth, 400), size.width)
                let scaled = size.width > 0 ? size.height * width / size.width : size.height
                height += min(DS.Layout.outputMaxHeight, scaled) + DS.Bar.strip
            case .plotlyFigure(_, _, _, _, let figureHeight):
                height += CGFloat(figureHeight) + DS.Bar.strip
            case .error(_, _, let traceback, _):
                height += CGFloat(traceback.reduce(into: 2) { if $1 == "\n" { $0 += 1 } }) * monoLine + DS.Space.m * 2
            case .rich:
                height += DS.Layout.richOutputHeight
            case .dataFrame:
                height += 240
            default:
                height += 120
            }
        }
        return height
    }
}

private final class NotebookNativeScrollView: NSScrollView {
    var onViewportChange: ((NSSize) -> Void)?

    override func layout() {
        super.layout()
        guard !isHiddenOrHasHiddenAncestor else { return }
        onViewportChange?(contentView.bounds.size)
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        onViewportChange?(contentView.bounds.size)
    }
}

private final class NotebookDocumentView: NSView {
    override var isFlipped: Bool { true }
}

private struct NotebookAddCellView: View {
    let document: Document
    let notebook: Notebook

    var body: some View {
        HStack(spacing: 10) {
            Button {
                AppState.shared.appendCell(type: .code, to: notebook, in: document)
            } label: {
                Label("Code", systemImage: "plus")
            }
            Button {
                AppState.shared.appendCell(type: .markdown, to: notebook, in: document)
            } label: {
                Label("Markdown", systemImage: "plus")
            }
            Spacer()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.leading, DS.Space.m + DS.Layout.cellGutterWidth + DS.Space.m)
        .padding(.top, DS.Space.xs)
    }
}
