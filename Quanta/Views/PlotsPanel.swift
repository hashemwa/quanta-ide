import SwiftUI
import UniformTypeIdentifiers

struct PlotsToolbar: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var history: PlotHistory
    @Binding var selection: UUID?
    @Binding var allFiles: Bool

    private var selected: PlotRecord? {
        let records = history.records.filter { allFiles || $0.origin.documentID == app.activeDocumentID }
        return records.first { $0.id == selection } ?? records.last
    }

    var body: some View {
        IconMenu(allFiles ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease",
                 help: "Filter Plots", glass: true) {
            Picker("Show", selection: $allFiles) {
                Text("Active File").tag(false)
                Text("All Files and Console").tag(true)
            }.pickerStyle(.inline)
        }
        IconButton("arrow.up.forward.square", help: "Reveal Plot Source", glass: true) {
            if let selected { app.revealPlotSource(selected) }
        }
        .disabled(selected == nil || !app.openDocuments.contains { $0.id == selected?.origin.documentID })
        if let selected, let image = selected.image {
            IconButton("doc.on.doc", help: "Copy Plot", glass: true) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.writeObjects([image])
            }
            IconButton("macwindow.badge.plus", help: "Open Plot in Window", glass: true) { PlotWindow.open(image: image) }
            IconButton("square.and.arrow.down", help: "Save Plot as PNG…", glass: true) {
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.png]
                panel.nameFieldStringValue = "plot.png"
                if panel.runModal() == .OK, let url = panel.url {
                    do {
                        try PlotImageExport.pngData(image: image, original: Data()).write(to: url, options: .atomic)
                    } catch { app.userNotice = "Could not save plot: \(error.localizedDescription)" }
                }
            }
        }
    }
}

struct PlotsPanel: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject var history: PlotHistory
    @Binding var selection: UUID?
    @Binding var allFiles: Bool

    private var records: [PlotRecord] {
        history.records.filter { allFiles || $0.origin.documentID == app.activeDocumentID }
    }

    private var selected: PlotRecord? {
        records.first { $0.id == selection } ?? records.last
    }

    var body: some View {
        VStack(spacing: 0) {
            if records.isEmpty {
                ContentUnavailableView("No Plots", systemImage: "chart.xyaxis.line",
                                       description: Text("Run code that produces a figure, or choose All Files and Console."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    List(records, selection: $selection) { record in
                        VStack(alignment: .leading, spacing: DS.Space.xxs) {
                            if let image = record.image {
                                Image(nsImage: image).resizable().scaledToFit()
                                    .frame(maxWidth: .infinity)
                                    .frame(height: DS.Layout.plotThumbnailHeight)
                            } else {
                                Image(systemName: "chart.xyaxis.line")
                                    .frame(maxWidth: .infinity)
                                    .frame(height: DS.Layout.plotThumbnailHeight)
                            }
                            Text(record.origin.label).font(.caption).lineLimit(2)
                        }
                        .tag(record.id)
                        .help(record.origin.label)
                        .accessibilityLabel(record.origin.label)
                    }
                    .listStyle(.inset)
                    .scrollContentBackground(.hidden)
                    .listRowSeparator(.hidden)
                    .frame(width: DS.Layout.plotListWidth)
                    Divider()
                    if let selected {
                        VStack(spacing: DS.Space.s) {
                            Text(selected.origin.label).font(.caption).foregroundStyle(.secondary)
                            if let image = selected.image, case .image = selected.output.kind {
                                Image(nsImage: image).resizable().scaledToFit()
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            } else {
                                ScrollView { preview(selected) }
                            }
                        }
                        .padding(DS.Space.m)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .id(selected.previewID)
                    }
                }
            }
        }
        .onAppear { synchronize() }
        .onChange(of: app.activeDocumentID) { _, _ in synchronize() }
        .onChange(of: allFiles) { _, _ in selection = records.last?.id }
        .onChange(of: records.map(\.id)) { old, _ in
            let wasLatest = selection == nil || selection == old.last
            if wasLatest || !records.contains(where: { $0.id == selection }) { selection = records.last?.id }
        }
    }

    private func synchronize() {
        history.importNotebook(app.activeDocument)
        selection = records.last?.id
    }

    @ViewBuilder
    private func preview(_ record: PlotRecord) -> some View {
        switch record.output.kind {
        case .plotlyFigure(let html, let jsPath, let data, let image, let height):
            PlotlyFigureView(html: html, jsPath: jsPath, image: image, imageData: data,
                             height: height, cacheKey: record.previewID)
        default:
            OutputItemView(output: record.output)
        }
    }
}
