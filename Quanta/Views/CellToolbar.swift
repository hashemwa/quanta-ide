import AppKit
import SwiftUI

struct CellToolbar: View {
    let document: Document
    @ObservedObject var notebook: Notebook
    @ObservedObject private var selection = AppState.shared.selection

    private var cell: NotebookCell? {
        guard selection.selectedCellIDs.count <= 1, let id = selection.selectedCellID else { return nil }
        return notebook.cells.first { $0.id == id }
    }

    var body: some View {
        FloatingToolbar(visible: cell != nil) {
            if let cell {
                CellToolbarActions(cell: cell, notebook: notebook, document: document)
            }
        }
        .fixedSize()
    }
}

private struct CellToolbarActions: View {
    @ObservedObject var cell: NotebookCell
    @ObservedObject var notebook: Notebook
    let document: Document
    private var app: AppState { AppState.shared }

    private var isFirst: Bool { notebook.cells.first?.id == cell.id }
    private var isLast: Bool { notebook.cells.last?.id == cell.id }
    private var isCode: Bool { cell.cellType == .code }

    var body: some View {
        IconButton("arrow.up", help: "Move Cell Up (⌥⌘[)") {
            app.moveCell(cell, direction: -1, in: notebook, document: document)
        }
        .disabled(isFirst)
        IconButton("arrow.down", help: "Move Cell Down (⌥⌘])") {
            app.moveCell(cell, direction: 1, in: notebook, document: document)
        }
        .disabled(isLast)
        ToolbarDivider()
        IconButton(isCode ? "text.alignleft" : "chevron.left.forwardslash.chevron.right",
                   help: isCode ? "Convert to Markdown (M)" : "Convert to Code (Y)") {
            app.convertCell(cell, to: isCode ? .markdown : .code, in: document)
        }
        IconButton(cell.isSourceCollapsed ? "rectangle.expand.vertical" : "rectangle.compress.vertical",
                   help: cell.isSourceCollapsed ? "Expand Source" : "Collapse Source") {
            app.setSourceCollapsed(!cell.isSourceCollapsed, for: cell, in: document)
        }
        if isCode {
            IconButton("eraser", help: "Clear Output") { app.clearOutput(for: cell, in: document) }
                .disabled(cell.outputs.isEmpty)
        }
        ToolbarDivider()
        IconButton("trash", help: "Delete Cell (D D)") {
            app.deleteCell(cell, in: notebook, document: document)
        }
        IconMenu("ellipsis", help: "More Cell Actions") {
            if isCode {
                Button("Run Cell") { app.runCell(cell, in: document, advance: false) }
                Button("Run Cells Above") { app.runCells(above: cell, in: document) }
                Button("Run Cells Below") { app.runCells(below: cell, in: document) }
                Divider()
            }
            CellInsertionActions(cell: cell, notebook: notebook, document: document)
            Divider()
            Button("Duplicate Cell") { app.duplicateCell(cell, in: notebook, document: document) }
            Button("Copy Cell") { app.copyCell(cell, in: notebook) }
            Button("Cut Cell") {
                app.copyCell(cell, in: notebook)
                app.deleteCell(cell, in: notebook, document: document)
            }
            Button("Paste Cell Below") { app.pasteCell(after: cell, in: notebook, document: document) }
            if isCode {
                Divider()
                Button(cell.isOutputCollapsed ? "Show Output" : "Hide Output") {
                    app.setOutputCollapsed(!cell.isOutputCollapsed, for: cell, in: document)
                }
                Button("Undo Clear Output") { app.undoClearedOutput(in: document) }
                    .disabled(document.clearedOutputs.isEmpty)
            }
        }
    }
}

final class CellToolbarHostingView: NSHostingView<CellToolbar> {
    var passesClicksThrough = true
    var onSizeChange: (() -> Void)?

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        DispatchQueue.main.async { [weak self] in self?.onSizeChange?() }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        passesClicksThrough ? nil : super.hitTest(point)
    }
}
