import AppKit
import Combine
import SwiftUI

struct NotebookScrollView: NSViewRepresentable {
    let document: Document
    let notebook: Notebook
    let scrollRequest: UUID?
    @Environment(\.monoFontSize) private var monoFontSize

    func makeCoordinator() -> Coordinator {
        Coordinator(document: document, notebook: notebook, monoFontSize: monoFontSize)
    }

    static func spacing(after type: CellType?) -> CGFloat {
        type == .markdown ? DS.Layout.notebookProseSpacing : DS.Layout.notebookCellSpacing
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.makeScrollView()
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(document: document, notebook: notebook,
                                   monoFontSize: monoFontSize, scrollRequest: scrollRequest)
    }

    final class Coordinator {
        private var document: Document
        private var notebook: Notebook
        private var monoFontSize: CGFloat
        private var cellIDs: [UUID]
        private var cellViews: [NotebookCellAppKitView] = []
        private var cellHeights: [UUID: CGFloat] = [:]
        private var dirtyCellIDs: Set<UUID> = []
        private var measuredWidth: CGFloat = 0
        private var measuredViewportWidth: CGFloat = 0
        private var layoutPending = false
        private var needsRebuild = true
        private var handledScrollRequest: UUID?
        private var pendingScrollRequest: UUID?
        private var scrollCancellable: AnyCancellable?
        private weak var scrollView: NotebookNativeScrollView?
        private weak var contentView: NotebookDocumentView?
        private var addView: NSHostingView<AnyView>?

        init(document: Document, notebook: Notebook, monoFontSize: CGFloat) {
            self.document = document
            self.notebook = notebook
            self.monoFontSize = monoFontSize
            cellIDs = notebook.cells.map(\.id)
            scrollCancellable = ScrollActivityMonitor.shared.$isLiveScrolling
                .receive(on: DispatchQueue.main)
                .sink { [weak self] active in
                    if !active, self?.dirtyCellIDs.isEmpty == false { self?.scheduleLayout() }
                }
        }

        func makeScrollView() -> NSScrollView {
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
            NotebookScrolling.register(scrollView: scrollView)
            DispatchQueue.main.async { [weak self] in
                guard let self, let scrollView = self.scrollView else { return }
                self.updateViewport(scrollView.contentView.bounds.size)
            }
            return scrollView
        }

        func update(document: Document, notebook: Notebook, monoFontSize: CGFloat,
                    scrollRequest: UUID?) {
            let nextIDs = notebook.cells.map(\.id)
            if self.document !== document || self.notebook !== notebook || cellIDs != nextIDs {
                needsRebuild = true
            } else if self.monoFontSize != monoFontSize {
                for cellView in cellViews {
                    if let cell = notebook.cells.first(where: { $0.id == cellView.cellID }) {
                        cellView.configure(cell: cell, document: document, notebook: notebook,
                                           monoFontSize: monoFontSize)
                        dirtyCellIDs.insert(cell.id)
                    }
                }
            }
            self.document = document
            self.notebook = notebook
            self.monoFontSize = monoFontSize
            cellIDs = nextIDs
            if scrollRequest == nil {
                handledScrollRequest = nil
            } else if scrollRequest != handledScrollRequest {
                handledScrollRequest = scrollRequest
                pendingScrollRequest = scrollRequest
            }
            if let scrollView { updateViewport(scrollView.contentView.bounds.size) }
        }

        private func updateViewport(_ size: NSSize) {
            guard size.width > DS.Layout.cellGutterWidth + DS.Space.xl else { return }
            let width = min(DS.Layout.notebookReadingWidth,
                            size.width - DS.Layout.notebookSidePadding * 2)
            if needsRebuild { rebuild(width: width) }
            if abs(width - measuredWidth) > 0.5 {
                measuredWidth = width
                measuredViewportWidth = size.width
                dirtyCellIDs = Set(cellIDs)
                layoutCells()
            } else if abs(size.width - measuredViewportWidth) > 0.5 {
                measuredViewportWidth = size.width
                layoutCells()
            } else if let contentView, contentView.frame.height < size.height {
                contentView.setFrameSize(NSSize(width: size.width, height: size.height))
            }
            scrollToPendingCell()
        }

        private func rebuild(width: CGFloat) {
            guard let contentView else { return }
            let origin = scrollView?.contentView.bounds.origin ?? .zero
            for cellView in cellViews {
                cellView.onSizeChange = nil
                cellView.resetForReuse()
                cellView.removeFromSuperview()
            }
            addView?.removeFromSuperview()
            cellViews.removeAll(keepingCapacity: true)
            cellHeights.removeAll(keepingCapacity: true)
            dirtyCellIDs = Set(cellIDs)
            for cell in notebook.cells {
                let initialHeight = max(120, cell.editorHeight + DS.Space.l)
                let cellView = NotebookCellAppKitView(frame: NSRect(x: 0, y: 0,
                                                                  width: width, height: initialHeight))
                cellView.translatesAutoresizingMaskIntoConstraints = false
                cellView.configure(cell: cell, document: document, notebook: notebook,
                                   monoFontSize: monoFontSize)
                contentView.addSubview(cellView)
                cellView.onSizeChange = { [weak self, weak cellView] in
                    guard let self, let cellID = cellView?.cellID else { return }
                    self.dirtyCellIDs.insert(cellID)
                    self.scheduleLayout()
                }
                cellViews.append(cellView)
            }
            let addView = NSHostingView(rootView: AnyView(
                NotebookAddCellView(document: document, notebook: notebook)
                    .environment(\.monoFontSize, monoFontSize)
            ))
            addView.sizingOptions = [.intrinsicContentSize]
            addView.translatesAutoresizingMaskIntoConstraints = false
            addView.frame = NSRect(x: 0, y: 0, width: width, height: 40)
            contentView.addSubview(addView)
            self.addView = addView
            needsRebuild = false
            measuredWidth = 0
            measuredViewportWidth = 0
            scrollView?.contentView.scroll(to: origin)
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

        private func layoutCells() {
            guard let scrollView, let contentView, measuredWidth > 0 else { return }
            let clipView = scrollView.contentView
            let oldOrigin = clipView.bounds.minY
            let anchor = cellHeights.isEmpty ? nil
                : cellViews.firstIndex { $0.frame.maxY > oldOrigin }
            let anchorOffset = anchor.map { oldOrigin - cellViews[$0].frame.minY } ?? 0
            let x = max(0, (clipView.bounds.width - measuredWidth) / 2)
            var y = DS.Layout.notebookTopPadding
            var changed = false
            for (index, cellView) in cellViews.enumerated() {
                if index > 0 { y += NotebookScrollView.spacing(after: cellViews[index - 1].cellType) }
                let cellID = cellIDs[index]
                let height: CGFloat
                if dirtyCellIDs.contains(cellID) || cellHeights[cellID] == nil {
                    height = measuredHeight(of: cellView, width: measuredWidth)
                    if abs(height - (cellHeights[cellID] ?? 0)) > 0.5 { changed = true }
                    cellHeights[cellID] = height
                } else {
                    height = cellHeights[cellID] ?? 1
                }
                cellView.frame = NSRect(x: x, y: y, width: measuredWidth, height: height)
                y += height
            }
            dirtyCellIDs.removeAll()
            if let addView {
                if !cellViews.isEmpty { y += DS.Layout.notebookCellSpacing }
                let height = measuredHeight(of: addView, width: measuredWidth)
                addView.frame = NSRect(x: x, y: y, width: measuredWidth, height: height)
                y += height + DS.Layout.notebookCellSpacing
            }
            let viewport = clipView.bounds.size
            let totalHeight = max(viewport.height, y)
            let nextSize = NSSize(width: viewport.width, height: totalHeight)
            if contentView.frame.size != nextSize {
                contentView.setFrameSize(nextSize)
                scrollView.reflectScrolledClipView(clipView)
            } else if changed {
                contentView.needsDisplay = true
            }
            if let anchor, changed {
                let target = cellViews[anchor].frame.minY + anchorOffset
                let clamped = max(0, min(target, totalHeight - viewport.height))
                if abs(clamped - clipView.bounds.minY) > 0.5 {
                    clipView.scroll(to: NSPoint(x: 0, y: clamped))
                    scrollView.reflectScrolledClipView(clipView)
                }
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
                  index < cellViews.count,
                  let scrollView else { return }
            pendingScrollRequest = nil
            let clipView = scrollView.contentView
            let visible = clipView.bounds
            let frame = cellViews[index].frame
            var y = visible.minY
            if frame.minY < visible.minY {
                y = frame.minY
            } else if frame.maxY > visible.maxY {
                y = frame.maxY - visible.height
            }
            clipView.scroll(to: NSPoint(x: 0, y: max(0, y)))
            scrollView.reflectScrolledClipView(clipView)
            if AppState.shared.scrollRequest == target {
                AppState.shared.scrollRequest = nil
            }
        }
    }
}

private final class NotebookNativeScrollView: NSScrollView {
    var onViewportChange: ((NSSize) -> Void)?

    override func layout() {
        super.layout()
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
