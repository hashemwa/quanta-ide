import AppKit
import Combine

struct PlotOrigin {
    let runID = UUID()
    let documentID: UUID?
    let name: String
    let cellID: UUID?
    let cellNumber: Int?
    let run: Int?

    var label: String {
        [name, cellNumber.map { "Cell \($0)" }, run.map { "Run \($0)" } ?? "Saved output"]
            .compactMap { $0 }.joined(separator: " · ")
    }
}

struct PlotRecord: Identifiable {
    var id: UUID { output.id }
    var output: CellOutput
    let origin: PlotOrigin
    let previewID = UUID()

    var image: NSImage? {
        switch output.kind {
        case .image(_, let image), .plotlyFigure(_, _, _, let image, _): return image
        default: return nil
        }
    }
}

final class PlotHistory: ObservableObject {
    @Published private(set) var records: [PlotRecord] = []
    private var runCounts: [UUID: Int] = [:]
    private var consoleRuns = 0
    let limit: Int

    init(limit: Int = 200) { self.limit = max(1, limit) }

    func beginRun(document: Document?, cell: NotebookCell? = nil) -> PlotOrigin {
        let run: Int
        if let document {
            runCounts[document.id, default: 0] += 1
            run = runCounts[document.id]!
        } else {
            consoleRuns += 1
            run = consoleRuns
        }
        return PlotOrigin(documentID: document?.id, name: document?.displayName ?? "Console",
                          cellID: cell?.id,
                          cellNumber: cell.flatMap { cell in document?.notebook?.cells.firstIndex { $0.id == cell.id }.map { $0 + 1 } },
                          run: run)
    }

    func record(_ output: CellOutput, origin: PlotOrigin) {
        switch output.kind {
        case .image, .plotlyFigure: break
        case .rich(let bundle) where bundle["image/svg+xml"] != nil: break
        default: return
        }
        if let index = records.firstIndex(where: { $0.id == output.id }) {
            records[index].output = output
        } else {
            records.append(PlotRecord(output: output, origin: origin))
            if records.count > limit { records.removeFirst(records.count - limit) }
        }
    }

    func consume(_ message: [String: Any], origin: PlotOrigin) {
        if message["type"] as? String == "rich", let bundle = message["mime_bundle"] as? [String: Any] {
            record(CellOutput(kind: RichOutput.kind(bundle), raw: RichOutput.raw(bundle)), origin: origin)
            return
        }
        if message["type"] as? String == "display", message["mime"] as? String == "image/png",
           let encoded = message["data"] as? String,
           let data = Data(base64Encoded: encoded, options: .ignoreUnknownCharacters) {
            record(CellOutput(kind: .image(data: data, image: NSImage(data: data))), origin: origin)
        } else if message["type"] as? String == "plotlyhtml",
                  let html = message["html"] as? String, let jsPath = message["js_path"] as? String {
            let height = (message["height"] as? NSNumber)?.doubleValue ?? 450
            if (message["has_png"] as? Bool ?? true), let last = records.last,
               last.origin.runID == origin.runID, case .image(let data, let image) = last.output.kind {
                var output = last.output
                output.kind = .plotlyFigure(html: html, jsPath: jsPath, data: data, image: image, height: height)
                record(output, origin: origin)
            } else {
                record(CellOutput(kind: .plotlyFigure(html: html, jsPath: jsPath, data: Data(), image: nil, height: height)), origin: origin)
            }
        }
    }

    func importNotebook(_ document: Document?) {
        guard let document, let notebook = document.notebook else { return }
        for (index, cell) in notebook.cells.enumerated() {
            let origin = PlotOrigin(documentID: document.id, name: document.displayName,
                                    cellID: cell.id, cellNumber: index + 1, run: nil)
            for output in cell.outputs where !records.contains(where: { $0.id == output.id }) {
                record(output, origin: origin)
            }
        }
    }
}

extension AppState {
    func showPlots() {
        plots.importNotebook(activeDocument)
        bottomPane = .plots
        consoleHeight = max(consoleHeight, DS.Layout.plotsDefaultHeight)
        setConsoleVisible(true)
    }

    func revealPlotSource(_ record: PlotRecord) {
        guard let document = openDocuments.first(where: { $0.id == record.origin.documentID }) else { return }
        activeDocumentID = document.id
        if let cellID = record.origin.cellID,
           document.notebook?.cells.contains(where: { $0.id == cellID }) == true {
            selectedCellID = cellID
            scrollRequest = cellID
        } else if document.kind == .script {
            focusEditor(document.id)
        }
    }
}
