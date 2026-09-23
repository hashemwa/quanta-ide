import Combine
import SwiftUI

final class NotebookActivity: ObservableObject {
    let notebook: Notebook
    private var cellsSubscription: AnyCancellable?
    private var contentSubscription: AnyCancellable?
    init(_ notebook: Notebook) {
        self.notebook = notebook
        cellsSubscription = notebook.$cells.sink { [weak self] cells in
            guard let self else { return }
            self.contentSubscription = Publishers.MergeMany(cells.map(\.objectWillChange))
                .debounce(for: .milliseconds(50), scheduler: DispatchQueue.main)
                .sink { [weak self] _ in self?.objectWillChange.send() }
            DispatchQueue.main.async { [weak self] in self?.objectWillChange.send() }
        }
    }
}

struct NotebookOutlineEntry: Identifiable, Equatable {
    enum Kind: Equatable {
        case heading
        case cell(CellType)
    }

    let id: String
    let cellID: UUID
    let title: String
    let kind: Kind
    let depth: Int

    static func entries(for cells: [NotebookCell]) -> [NotebookOutlineEntry] {
        let headings = cells.map { $0.cellType == .markdown ? Self.headings(in: $0.source) : [] }
        let topLevel = headings.joined().map(\.level).min() ?? 1
        var result: [NotebookOutlineEntry] = []
        var sectionDepth = 0
        for (index, cell) in cells.enumerated() {
            guard !headings[index].isEmpty else {
                result.append(NotebookOutlineEntry(id: cell.id.uuidString, cellID: cell.id,
                                                   title: summary(of: cell, index: index),
                                                   kind: .cell(cell.cellType), depth: sectionDepth))
                continue
            }
            for (offset, heading) in headings[index].enumerated() {
                let depth = heading.level - topLevel
                result.append(NotebookOutlineEntry(id: "\(cell.id.uuidString)-\(offset)", cellID: cell.id,
                                                   title: heading.text, kind: .heading, depth: depth))
                sectionDepth = depth + 1
            }
        }
        return result
    }

    private static func headings(in source: String) -> [(level: Int, text: String)] {
        MarkdownView.cachedParse(source).compactMap { block in
            switch block {
            case .heading(let level, let text):
                return (level, plain(text))
            case .html(let level?, _, let text):
                return (level, plain(text))
            default:
                return nil
            }
        }
    }

    private static func plain(_ markdown: String) -> String {
        String(MarkdownView.inlineAttributed(markdown).characters).trimmingCharacters(in: .whitespaces)
    }

    private static func summary(of cell: NotebookCell, index: Int) -> String {
        let first = cell.source.components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? "Empty cell"
        let line = cell.cellType == .markdown ? plain(first) : first.trimmingCharacters(in: .whitespaces)
        return "\(index + 1) · \(line)"
    }
}

struct NotebookOutlinePane: View {
    let document: Document?

    var body: some View {
        if let document, let notebook = document.notebook {
            NotebookOutlineList(document: document, notebook: notebook)
                .id(document.id)
        } else {
            NavigatorEmptyState("No Outline", systemImage: "list.bullet.indent",
                                detail: "Open a notebook to see its headings and cells.")
        }
    }
}

private struct NotebookOutlineList: View {
    let document: Document
    @StateObject private var activity: NotebookActivity
    @ObservedObject private var selection = AppState.shared.selection
    @State private var selectedEntry: String?
    @State private var filter = ""

    init(document: Document, notebook: Notebook) {
        self.document = document
        _activity = StateObject(wrappedValue: NotebookActivity(notebook))
    }

    var body: some View {
        let cells = activity.notebook.cells
        let entries = NotebookOutlineEntry.entries(for: cells)
        let visible = filter.isEmpty ? entries : entries.filter { $0.title.localizedStandardContains(filter) }
        VStack(spacing: 0) {
            List(visible, selection: $selectedEntry) { entry in
                NotebookOutlineRow(entry: entry, cell: cells.first { $0.id == entry.cellID })
                    .tag(entry.id)
            }
            .listStyle(.sidebar)
            .environment(\.defaultMinListRowHeight, DS.Layout.listRowMinHeight)
            .overlay {
                if visible.isEmpty {
                    if filter.isEmpty {
                        NavigatorEmptyState("Empty Notebook", systemImage: "list.bullet.indent",
                                            detail: "Add a cell to start this notebook.")
                    } else {
                        NavigatorEmptyState("No Results", systemImage: "magnifyingglass",
                                            detail: "No heading or cell matches “\(filter)”.")
                    }
                }
            }
            FilterBar(text: $filter)
        }
        .onAppear { mirrorSelection(in: entries) }
        .onChange(of: selection.selectedCellID) { _, _ in mirrorSelection(in: entries) }
        .onChange(of: selectedEntry) { _, id in reveal(entries.first { $0.id == id }) }
    }

    private func mirrorSelection(in entries: [NotebookOutlineEntry]) {
        guard let cellID = selection.selectedCellID,
              let entry = entries.first(where: { $0.cellID == cellID }),
              selectedEntry.flatMap({ id in entries.first { $0.id == id }?.cellID }) != cellID else { return }
        selectedEntry = entry.id
    }

    private func reveal(_ entry: NotebookOutlineEntry?) {
        guard let entry, selection.selectedCellID != entry.cellID || AppState.shared.activeDocumentID != document.id
        else { return }
        let app = AppState.shared
        app.activeDocumentID = document.id
        app.selectedCellID = entry.cellID
        app.scrollRequest = entry.cellID
    }
}

private struct NotebookOutlineRow: View {
    let entry: NotebookOutlineEntry
    let cell: NotebookCell?

    var body: some View {
        HStack(spacing: DS.Space.s) {
            switch entry.kind {
            case .heading:
                Text(entry.title)
                    .font(.callout.weight(.semibold))
            case .cell(let type):
                Image(systemName: type == .markdown ? "text.alignleft" : "curlybraces")
                    .foregroundStyle(.secondary)
                    .frame(width: DS.Layout.iconSlot)
                    .accessibilityHidden(true)
                Text(entry.title)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if cell?.isRunning == true {
                ProgressView()
                    .controlSize(.mini)
                    .accessibilityLabel("Running")
            } else if cell?.hasStaleOutput == true {
                Image(systemName: "clock.badge.exclamationmark")
                    .foregroundStyle(.orange)
                    .help("Output is stale: the source changed after the last run")
                    .accessibilityLabel("Output is stale")
            }
        }
        .lineLimit(1)
        .padding(.leading, CGFloat(entry.depth) * DS.Space.l)
        .accessibilityElement(children: .combine)
    }
}

private struct OutputCellKey: EnvironmentKey { static let defaultValue: UUID? = nil }
extension EnvironmentValues {
    var outputCellID: UUID? {
        get { self[OutputCellKey.self] }
        set { self[OutputCellKey.self] = newValue }
    }
}

struct CellInsertionActions: View {
    let cell: NotebookCell
    let notebook: Notebook
    let document: Document

    var body: some View {
        Section("Above This Cell") {
            Button("Code Cell Above") { insert(.code, offset: 0) }
            Button("Markdown Cell Above") { insert(.markdown, offset: 0) }
        }
        Section("Below This Cell") {
            Button("Code Cell Below") { insert(.code, offset: 1) }
            Button("Markdown Cell Below") { insert(.markdown, offset: 1) }
        }
    }

    private func insert(_ type: CellType, offset: Int) {
        AppState.shared.insertCell(type: type, nextTo: cell, offset: offset,
                                   in: notebook, document: document, editing: true)
    }
}
