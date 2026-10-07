import AppKit
import Combine
import SwiftUI
import WebKit
import XCTest
@testable import Quanta

@MainActor
final class InteractionPolishTests: XCTestCase {
    func testEnhancedOutputPreferenceDefaultsOnPersistsAndIgnoresRepeatedChoices() {
        let defaults = UserDefaults(suiteName: "quanta.output-tests.\(UUID().uuidString)")!
        let state = OutputPresentation(defaults: defaults)
        XCTAssertTrue(state.usesEnhancedDataOutputs)
        var changes = 0
        let subscription = state.objectWillChange.sink { changes += 1 }
        state.setEnhancedDataOutputs(false)
        state.setEnhancedDataOutputs(false)
        XCTAssertEqual(changes, 1)
        XCTAssertFalse(OutputPresentation(defaults: defaults).usesEnhancedDataOutputs)
        state.setEnhancedDataOutputs(true)
        XCTAssertTrue(OutputPresentation(defaults: defaults).usesEnhancedDataOutputs)
        withExtendedLifetime(subscription) {}
    }

    func testOutputModeSwitchesNativePresentationAndExportsWithoutChangingSavedData() throws {
        let presentation = AppState.shared.outputPresentation
        let previous = presentation.usesEnhancedDataOutputs
        defer { presentation.setEnhancedDataOutputs(previous) }
        presentation.setEnhancedDataOutputs(true)
        let array = try XCTUnwrap(NDArrayPayload(dict: ["shape": [4], "dtype": "float64", "stats": ["mean": 2.5],
                                                       "series": [1, 4, 2, 3], "text": "array([1., 4., 2., 3.])"]))
        let cell = NotebookCell(type: .code, source: "values", outputs: [CellOutput(kind: .ndarray(array))])
        let notebook = Notebook(cells: [cell], metadata: [:])
        let saved = try notebook.serializedData()
        let layout = LayoutTestSupport()
        let hosting = host(AnyView(OutputListView(cell: cell)
            .environment(\.viewLayoutObserver) { layout.frames[$0] = $1 }
            .frame(width: 760, height: 260, alignment: .topLeading)
            .background(Color(nsColor: .textBackgroundColor))), width: 760, height: 260)
        let enhanced = try imageData(hosting)
        let initialFrames = layout.frames
        presentation.setEnhancedDataOutputs(false)
        settle(hosting)
        let plain = try imageData(hosting)
        XCTAssertNotEqual(plain, enhanced)
        XCTAssertEqual(try notebook.serializedData(), saved)
        let html = NotebookExporter.html(from: notebook, title: "Mode audit", enhancedDataOutputs: false)
        XCTAssertTrue(html.contains("array([1., 4., 2., 3.])"))
        XCTAssertFalse(html.contains("<div class=\"rich-output output-card\">"))
        XCTAssertFalse(html.contains("alt=\"Array sparkline\""))
        presentation.setEnhancedDataOutputs(true)
        layout.frames.removeAll()
        settle(hosting)
        let restored = try imageData(hosting)
        XCTAssertNotEqual(restored, plain)
        XCTAssertEqual(layout.frames, initialFrames)
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/interaction-polish", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try enhanced.write(to: directory.appendingPathComponent("enhanced.png"))
        try plain.write(to: directory.appendingPathComponent("plain.png"))
        try restored.write(to: directory.appendingPathComponent("restored.png"))
    }

    func testPlainDataFallbackRetainsOtherRichOutputKinds() throws {
        let json = CellOutput(kind: .jsonTree(JSONTreePayload(value: ["<name>": [1, 2]], summary: "dict", text: "")))
        XCTAssertTrue(try XCTUnwrap(json.enhancedDataText).contains("<name>"))
        let bundle = ["text/latex": "$x^2$", "text/plain": "x^2"]
        let math = CellOutput(kind: RichOutput.kind(bundle), raw: RichOutput.raw(bundle))
        XCTAssertNil(math.enhancedDataText)
        let cell = NotebookCell(type: .code, outputs: [json, math])
        let html = NotebookExporter.html(from: Notebook(cells: [cell], metadata: [:]), title: "Fallback", enhancedDataOutputs: false)
        XCTAssertTrue(html.contains("&lt;name&gt;"))
        XCTAssertTrue(html.contains("<math"))
    }

    func testMarkdownRichOutputsResolveNotebookRelativeImagesInPreviewAndExport() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = NSImage(size: NSSize(width: 32, height: 32))
        image.lockFocus()
        NSColor.green.setFill()
        NSRect(x: 0, y: 0, width: 32, height: 32).fill()
        image.unlockFocus()
        let bitmap = try XCTUnwrap(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let bytes = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try bytes.write(to: directory.appendingPathComponent("result.png"))
        let bundle = ["text/markdown": "![Saved result](result.png)"]
        let cell = NotebookCell(type: .code, outputs: [CellOutput(kind: RichOutput.kind(bundle), raw: RichOutput.raw(bundle))])
        let notebook = Notebook(cells: [cell], metadata: [:])
        let document = Document(notebook: notebook, url: directory.appendingPathComponent("example.ipynb"))
        let canvas = NotebookCanvas(document: document, notebook: notebook, monoFontSize: 12)
        let view = canvas.view
        let window = makeWindow(view, width: 900, height: 600)
        defer { window.close() }
        settle(view)
        let snapshot = try LayoutTestSupport.snapshot(of: view)
        let hasGreenImage = (0..<snapshot.pixelsHigh).contains { y in
            (0..<snapshot.pixelsWide).contains { x in
                guard let color = snapshot.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
                return color.greenComponent > 0.8 && color.redComponent < 0.2 && color.blueComponent < 0.2
            }
        }
        XCTAssertTrue(hasGreenImage)
        let html = NotebookExporter.html(from: notebook, title: "Relative image", baseDirectory: directory)
        XCTAssertTrue(html.contains("src=\"data:image/png;base64,\(bytes.base64EncodedString())\""))
        XCTAssertTrue(html.contains("alt=\"Saved result\""))
    }

    func testRepeatedCellClicksDoNotPublishUnchangedSelectionOrDocumentState() {
        let app = AppState()
        let cell = NotebookCell(type: .code, source: "value = 1")
        let notebook = Notebook(cells: [cell], metadata: [:])
        app.selectCell(cell, in: notebook)
        var changes = 0
        let selection = app.selection.objectWillChange.sink { changes += 1 }
        let state = app.objectWillChange.sink { changes += 1 }
        for _ in 0..<20 {
            app.activateDocument(nil)
            app.selectCell(cell, in: notebook)
        }
        XCTAssertEqual(changes, 0)
        XCTAssertEqual(app.selection.selectedCellIDs, [cell.id])
        withExtendedLifetime((selection, state)) {}
    }

    func testTypingAndStatusChangesKeepEditorsAndDoNotMeasureUnchangedHeight() throws {
        let cell = NotebookCell(type: .code, source: "value = 1")
        let notebook = Notebook(cells: [cell], metadata: [:])
        let document = Document(notebook: notebook, url: nil)
        let canvas = NotebookCanvas(document: document, notebook: notebook, monoFontSize: 12)
        let scroll = try XCTUnwrap(canvas.view as? NSScrollView)
        let window = makeWindow(scroll, width: 900, height: 600)
        defer { window.close() }
        settle(scroll)
        let cellView = try XCTUnwrap(descendants(scroll).compactMap { $0 as? NotebookCellAppKitView }.first)
        let editor = try XCTUnwrap(EditorRegistry.shared.view(for: cell.id))
        let frame = cellView.frame
        var measurements = 0
        let callback = cellView.onSizeChange
        cellView.onSizeChange = { measurements += 1; callback?() }
        cell.isQueued = true
        cell.isRunning = true
        cell.executionCount = 1
        settle(scroll)
        XCTAssertEqual(measurements, 0)
        editor.insertText("x", replacementRange: NSRange(location: 0, length: 0))
        settle(scroll)
        XCTAssertEqual(measurements, 0)
        XCTAssertTrue(EditorRegistry.shared.view(for: cell.id) === editor)
        XCTAssertEqual(cellView.frame, frame)
        editor.insertText(String(repeating: "\nnext = 2", count: 6), replacementRange: NSRange(location: editor.string.utf16.count, length: 0))
        settle(scroll)
        XCTAssertGreaterThan(measurements, 0)
        XCTAssertGreaterThan(cellView.frame.height, frame.height)
    }

    func testUnicodeEquivalentNotebookEditsPreserveSavedSourceAndMarkOldOutputStale() throws {
        let composed = "value = 'café'\nprint(1)"
        let decomposed = "value = 'cafe\u{301}'\nprint(1)"
        let cell = NotebookCell(type: .code, source: composed, outputs: [CellOutput(kind: .executeResult(text: "old result"))])
        cell.lastExecutedSource = composed
        let notebook = Notebook(cells: [cell], metadata: [:])
        let document = Document(notebook: notebook, url: nil)
        let canvas = NotebookCanvas(document: document, notebook: notebook, monoFontSize: 12)
        let view = canvas.view
        let window = makeWindow(view, width: 900, height: 600)
        defer { window.close() }
        settle(view)
        let editor = try XCTUnwrap(EditorRegistry.shared.view(for: cell.id))
        let revision = cell.layoutRevision
        XCTAssertFalse(cell.hasStaleOutput)
        editor.insertText(decomposed, replacementRange: NSRange(location: 0, length: composed.utf16.count))
        settle(view)
        XCTAssertTrue(cell.source.utf16.elementsEqual(decomposed.utf16))
        XCTAssertTrue(cell.hasStaleOutput)
        XCTAssertGreaterThan(cell.layoutRevision, revision)
        let saved = try Notebook.load(from: notebook.serializedData())
        XCTAssertTrue(saved.cells[0].source.utf16.elementsEqual(decomposed.utf16))
        cell.source = composed
        settle(view)
        XCTAssertTrue(editor.string.utf16.elementsEqual(composed.utf16))
        XCTAssertFalse(cell.hasStaleOutput)
    }

    func testSidebarFileListAndFooterNeverOverlapAfterPaneSwitches() throws {
        let app = AppState()
        let root = URL(fileURLWithPath: "/tmp/quanta-panel-audit", isDirectory: true)
        let names = ["A1.npy", "A2.npy", "A3.npy", "HW02-STUDENT.ipynb", "HW02-STUDENT.marimo.py"]
        let children = names.map { FileNode(url: root.appendingPathComponent($0), name: $0, isDirectory: false, children: nil) }
        app.workspace = Workspace(rootURL: root, root: FileNode(url: root, name: root.lastPathComponent, isDirectory: true, children: children))
        app.sidebarPane = .files
        for dark in [false, true] {
            for width in [280.0, 440.0] {
                let hosting = host(AnyView(SidebarView().environmentObject(app)
                    .preferredColorScheme(dark ? .dark : .light)
                    .frame(width: width, height: 650)
                    .background(Color(nsColor: .windowBackgroundColor))), width: width, height: 650)
                hosting.window?.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                settle(hosting)
                try assertSidebarLayout(hosting)
                for _ in 0..<3 {
                    app.sidebarPane = .search
                    settle(hosting)
                    let search = try XCTUnwrap(descendants(hosting).compactMap { $0 as? NSSearchField }.first {
                        $0.placeholderString == "Search in files"
                    })
                    XCTAssertTrue(try XCTUnwrap(hosting.window).makeFirstResponder(search))
                    app.sidebarPane = .files
                    settle(hosting)
                    XCTAssertNil(search.window)
                    try assertSidebarLayout(hosting)
                }
                try capture(hosting, name: "sidebar-\(dark ? "dark" : "light")-\(Int(width))")
                hosting.window?.close()
            }
        }
    }

    func testInspectorReopeningRestoresFilterAndSelection() throws {
        let app = AppState.shared
        let store = app.variableStore
        let state = app.variablesPanelState
        let previous = (store.items, state.query, state.typeFilter, state.sortByType, state.selected)
        defer {
            store.items = previous.0
            state.query = previous.1
            state.typeFilter = previous.2
            state.sortByType = previous.3
            state.selected = previous.4
        }
        store.items = [
            try XCTUnwrap(VariableInfo(dict: ["name": "array_values", "type": "ndarray", "summary": "3 values"])),
            try XCTUnwrap(VariableInfo(dict: ["name": "count", "type": "int", "summary": "3"])),
        ]
        state.query = ""
        state.typeFilter = "All Types"
        let first = host(AnyView(VariablesPanel()), width: 280, height: 600)
        let filter = try XCTUnwrap(descendants(first).compactMap { $0 as? NSSearchField }.first)
        filter.stringValue = "array"
        filter.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: filter))
        state.selected = "array_values"
        state.typeFilter = "ndarray"
        state.sortByType = true
        settle(first)
        first.window?.close()
        let reopened = host(AnyView(VariablesPanel()), width: 280, height: 600)
        let restored = try XCTUnwrap(descendants(reopened).compactMap { $0 as? NSSearchField }.first)
        XCTAssertEqual(restored.stringValue, "array")
        XCTAssertEqual(state.selected, "array_values")
        XCTAssertEqual(state.typeFilter, "ndarray")
        XCTAssertTrue(state.sortByType)
        let list = try XCTUnwrap(descendants(reopened).compactMap { $0 as? NSTableView }.first)
        XCTAssertEqual(list.selectedRow, 0)
        reopened.window?.setContentSize(NSSize(width: 440, height: 600))
        settle(reopened)
        XCTAssertEqual(list.selectedRow, 0)
        state.query = ""
        state.typeFilter = "All Types"
        state.sortByType = false
        state.selected = "count"
        settle(reopened)
        XCTAssertEqual(list.selectedRow, 1)
        list.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        settle(reopened)
        XCTAssertEqual(state.selected, "array_values")
    }

    func testBottomPanelReopeningRestoresTerminalWithoutKeepingAHiddenPanel() throws {
        let app = AppState()
        app.bottomPane = .console
        app.setConsoleVisible(true, animated: false)
        let hosting = host(AnyView(DetailSplitView().environmentObject(app)), width: 1050, height: 760)
        let browser = app.terminal.webView()
        XCTAssertNil(app.terminal.error)
        XCTAssertTrue(browser.isDescendant(of: hosting))
        let original = browser.frame.size
        XCTAssertGreaterThan(original.height, 0)
        for _ in 0..<5 {
            app.setConsoleVisible(false, animated: false)
            settle(hosting)
            XCTAssertFalse(browser.isDescendant(of: hosting))
            app.setConsoleVisible(true, animated: false)
            settle(hosting)
            XCTAssertTrue(browser.isDescendant(of: hosting))
            XCTAssertEqual(browser.frame.size, original)
        }
    }

    func testEquationRemainsVisibleWhileItsNewFontImageIsPending() throws {
        let state = NotebookMathRenderState()
        var completions: [(AppState.LatexResult) -> Void] = []
        for size in [13.0, 16.0] {
            state.load(NotebookMathRequest(expressions: ["x"], display: false, fontSize: size, color: "#000000")) {
                _, _, _, _, completion in completions.append(completion)
            }
            if size == 13 { completions[0](.image(NSImage(size: NSSize(width: 10, height: 10)), depth: 0)) }
        }
        guard case .image(let previous, _) = state.results["x"] else { return XCTFail("Equation flashed empty") }
        XCTAssertEqual(previous.size.width, 10)
        completions[1](.image(NSImage(size: NSSize(width: 20, height: 12)), depth: 0))
        guard case .image(let updated, _) = state.results["x"] else { return XCTFail("Equation did not update") }
        XCTAssertEqual(updated.size.width, 20)
    }

    func testRepeatedHeatmapReadsReuseItsImageAndSeparateNewPayloads() throws {
        let payload = try XCTUnwrap(NDArrayPayload(dict: ["shape": [2, 2], "dtype": "float64", "grid": [[0.0, 0.5], [1.0, 0.2]]]))
        let image = try XCTUnwrap(NDArrayView.cachedHeatmapImage(payload))
        for _ in 0..<30 { XCTAssertTrue(NDArrayView.cachedHeatmapImage(payload) === image) }
        let other = try XCTUnwrap(NDArrayPayload(dict: ["shape": [2, 2], "dtype": "float64", "grid": [[1.0, 0.5], [0.0, 0.2]]]))
        XCTAssertFalse(NDArrayView.cachedHeatmapImage(other) === image)
    }

    func testLargeModelCardsStayCompactWhileExportsRetainSavedParameters() throws {
        let fields = Dictionary(uniqueKeysWithValues: (0..<2000).map { (String(format: "parameter_%04d", $0), "value_\($0)") })
        let payload = try XCTUnwrap(ObjectCardPayload(dict: ["title": "Pipeline", "subtitle": "sklearn.pipeline", "fields": fields,
                                                           "badges": ["classes_"], "text": "Pipeline(steps=[...])"]))
        for width in [280.0, 760.0] {
            let hosting = host(AnyView(ObjectCardView(payload: payload)
                .frame(width: width).fixedSize(horizontal: false, vertical: true)
                .background(Color(nsColor: .textBackgroundColor))), width: width, height: 600)
            XCTAssertLessThan(hosting.fittingSize.height, 450)
            XCTAssertEqual(hosting.fittingSize.width, width, accuracy: 0.5)
        }
        let cell = NotebookCell(type: .code, outputs: [CellOutput(kind: .objectCard(payload))])
        let html = NotebookExporter.html(from: Notebook(cells: [cell], metadata: [:]), title: "Model parameters")
        XCTAssertTrue(html.contains("parameter_1999"))
        XCTAssertTrue(html.contains("value_1999"))
    }

    private func host(_ content: AnyView, width: CGFloat, height: CGFloat) -> NSHostingView<AnyView> {
        let hosting = NSHostingView(rootView: content)
        let window = makeWindow(hosting, width: width, height: height)
        addTeardownBlock { window.close() }
        settle(hosting)
        return hosting
    }

    private func makeWindow(_ view: NSView, width: CGFloat, height: CGFloat) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = view
        return window
    }

    private func settle(_ view: NSView) {
        for _ in 0..<5 {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            view.layoutSubtreeIfNeeded()
        }
    }

    private func descendants(_ view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap(descendants)
    }

    private func assertSidebarLayout(_ hosting: NSView, file: StaticString = #filePath, line: UInt = #line) throws {
        let outline = try XCTUnwrap(descendants(hosting).compactMap { $0 as? NSOutlineView }.first, file: file, line: line)
        let scroll = try XCTUnwrap(outline.enclosingScrollView, file: file, line: line)
        let filter = try XCTUnwrap(descendants(hosting).compactMap { $0 as? NSSearchField }.first {
            $0.placeholderString == "Filter"
        }, file: file, line: line)
        let listFrame = topFrame(scroll, in: hosting)
        let filterFrame = topFrame(filter, in: hosting)
        XCTAssertGreaterThanOrEqual(listFrame.minY, DS.Bar.primary - 0.5, file: file, line: line)
        XCTAssertLessThanOrEqual(listFrame.maxY, filterFrame.minY, file: file, line: line)
        XCTAssertGreaterThan(filterFrame.minY, hosting.bounds.height - DS.Bar.footer - 1, file: file, line: line)
        XCTAssertLessThanOrEqual(filterFrame.maxY, hosting.bounds.height, file: file, line: line)
        XCTAssertGreaterThan(listFrame.height, hosting.bounds.height * 0.7, file: file, line: line)
    }

    private func topFrame(_ view: NSView, in hosting: NSView) -> CGRect {
        var frame = hosting.convert(view.bounds, from: view)
        if !hosting.isFlipped { frame.origin.y = hosting.bounds.height - frame.maxY }
        return frame
    }

    private func capture(_ view: NSView, name: String) throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/panel-repair", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try imageData(view).write(to: directory.appendingPathComponent("\(name).png"))
    }

    private func imageData(_ view: NSView) throws -> Data {
        try XCTUnwrap(try LayoutTestSupport.snapshot(of: view).representation(using: .png, properties: [:]))
    }
}
