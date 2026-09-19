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

struct NotebookNavigator: View {
    let document: Document
    @StateObject private var activity: NotebookActivity
    @State private var showOutline = false
    @State private var query = ""
    private var app: AppState { AppState.shared }
    @ObservedObject private var selection = AppState.shared.selection

    init(document: Document, notebook: Notebook) {
        self.document = document
        _activity = StateObject(wrappedValue: NotebookActivity(notebook))
    }

    private var cells: [NotebookCell] { activity.notebook.cells }
    private var code: [NotebookCell] { cells.filter { $0.cellType == .code } }
    private var running: NotebookCell? { code.first(where: \.isRunning) }
    private var queued: Int { code.filter(\.isQueued).count }
    private var selectedCell: NotebookCell? { cells.first { $0.id == selection.selectedCellID } }

    var body: some View {
        PanelBar {
            Button { showOutline.toggle() } label: { Label("Outline", systemImage: "list.bullet.indent") }
                .buttonStyle(.borderless)
                .help("Navigate notebook headings and cells")
                .popover(isPresented: $showOutline, arrowEdge: .bottom) { outline }
            Spacer(minLength: DS.Space.s)
            if let running {
                Button {
                    app.activeDocumentID = document.id
                    app.selectedCellID = running.id
                    app.scrollRequest = running.id
                } label: {
                    Label("Running cell \((cells.firstIndex { $0.id == running.id } ?? 0) + 1)", systemImage: "play.circle")
                }
                .buttonStyle(.borderless)
                .help("Jump to the running cell")
                if queued > 0 {
                    ProgressView(value: Double(code.count - queued - 1), total: Double(max(1, code.count)))
                        .frame(width: DS.Layout.executionProgressWidth)
                        .help("\(code.count - queued - 1) of \(code.count) code cells finished")
                    Text("\(queued) queued").foregroundStyle(.secondary)
                }
            } else {
                Text("\(cells.count) cells").foregroundStyle(.secondary)
                let stale = code.filter(\.hasStaleOutput).count
                if stale > 0 { Text("\(stale) stale").foregroundStyle(.orange).help("Cell source changed since its output was produced") }
            }
            Divider().frame(height: DS.Layout.tabDividerHeight)
            IconMenu("plus", help: "Insert Cell") {
                Button("Code Below") {
                    if let cell = selectedCell { app.insertCell(type: .code, nextTo: cell, offset: 1, in: activity.notebook, document: document) }
                }
                Button("Markdown Below") {
                    if let cell = selectedCell { app.insertCell(type: .markdown, nextTo: cell, offset: 1, in: activity.notebook, document: document) }
                }
            }
            .disabled(selectedCell == nil)
            IconButton("chevron.up", help: "Move Selected Cell Up") {
                if let cell = selectedCell { app.moveCell(cell, direction: -1, in: activity.notebook, document: document) }
            }
            .disabled(selectedCell == nil || selectedCell?.id == cells.first?.id)
            IconButton("chevron.down", help: "Move Selected Cell Down") {
                if let cell = selectedCell { app.moveCell(cell, direction: 1, in: activity.notebook, document: document) }
            }
            .disabled(selectedCell == nil || selectedCell?.id == cells.last?.id)
            IconMenu("ellipsis", help: "Selected Cell Actions") {
                if let cell = selectedCell {
                    Button("Run Cell") { app.runCell(cell, in: document, advance: false) }
                    Button(cell.isSourceCollapsed ? "Expand Source" : "Collapse Source") {
                        app.setSourceCollapsed(!cell.isSourceCollapsed, for: cell, in: document)
                    }
                    Button("Duplicate Cell") { app.duplicateCell(cell, in: activity.notebook, document: document) }
                    Divider()
                    Button("Delete Cell", role: .destructive) { app.deleteCell(cell, in: activity.notebook, document: document) }
                }
            }
            .disabled(selectedCell == nil)
        }
        .font(.caption)
    }

    private var outline: some View {
        VStack(spacing: 0) {
            TextField("Filter headings and cells", text: $query).textFieldStyle(.roundedBorder).padding(DS.Space.m)
            List {
                ForEach(Array(cells.enumerated()), id: \.element.id) { index, cell in
                    let title = label(cell, index: index)
                    if query.isEmpty || title.localizedStandardContains(query) {
                        Button {
                            app.activeDocumentID = document.id
                            app.selectedCellID = cell.id
                            app.scrollRequest = cell.id
                            showOutline = false
                        } label: {
                            HStack {
                                Image(systemName: cell.cellType == .markdown ? "text.alignleft" : "curlybraces")
                                Text(title).lineLimit(2)
                                Spacer()
                                if cell.isRunning { Image(systemName: "play.fill") }
                                else if cell.hasStaleOutput { Image(systemName: "clock.badge.exclamationmark").foregroundStyle(.orange) }
                            }
                        }.buttonStyle(.plain)
                    }
                }
            }.listStyle(.plain)
        }.frame(width: DS.Layout.inspectionWidth, height: DS.Layout.inspectionHeight)
    }

    private func label(_ cell: NotebookCell, index: Int) -> String {
        let first = cell.source.components(separatedBy: .newlines).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? "Empty cell"
        return "\(index + 1) · \(first.trimmingCharacters(in: CharacterSet(charactersIn: "# ")))"
    }
}

private struct OutputCellKey: EnvironmentKey { static let defaultValue: UUID? = nil }
extension EnvironmentValues {
    var outputCellID: UUID? {
        get { self[OutputCellKey.self] }
        set { self[OutputCellKey.self] = newValue }
    }
}
