import AppKit
import XCTest
@testable import Quanta

final class GitPathspecTests: XCTestCase {
    func testPathspecsAreEscapedSoWildcardsMatchOnlyTheNamedFile() {
        let paths = ["plot_*.py", ":colon.py", "Chapter [1].ipynb", "plain.py"]
        XCTAssertEqual(GitClient.literalPathspecs(paths),
                       [":(literal)plot_*.py", ":(literal):colon.py",
                        ":(literal)Chapter [1].ipynb", ":(literal)plain.py"])
    }

    func testEmptyPathListStaysEmpty() {
        XCTAssertEqual(GitClient.literalPathspecs([]), [])
    }
}

final class NotebookTests: XCTestCase {
    private func load(_ json: [String: Any]) throws -> Notebook {
        try Notebook.load(from: JSONSerialization.data(withJSONObject: json))
    }

    func testRoundTripPreservesSourceAndOutputs() throws {
        let json: [String: Any] = [
            "nbformat": 4, "nbformat_minor": 5,
            "metadata": ["kernelspec": ["name": "python3", "display_name": "Python 3", "language": "python"]],
            "cells": [
                ["cell_type": "markdown", "id": "md1", "metadata": [:] as [String: Any],
                 "source": ["# Title\n", "text"]],
                ["cell_type": "code", "id": "c1", "metadata": [:] as [String: Any],
                 "execution_count": 3,
                 "source": ["print('hi')\n", "1 + 1"],
                 "outputs": [
                    ["output_type": "stream", "name": "stdout", "text": ["hi\n"]],
                    ["output_type": "execute_result", "execution_count": 3,
                     "data": ["text/plain": ["2"]], "metadata": [:] as [String: Any]],
                 ]],
            ],
        ]
        let notebook = try load(json)
        XCTAssertEqual(notebook.cells.count, 2)
        XCTAssertEqual(notebook.cells[0].cellType, .markdown)
        XCTAssertEqual(notebook.cells[0].source, "# Title\ntext")
        XCTAssertEqual(notebook.cells[1].executionCount, 3)
        XCTAssertEqual(notebook.cells[1].outputs.count, 2)

        let reloaded = try Notebook.load(from: notebook.serializedData())
        XCTAssertEqual(reloaded.cells.count, 2)
        XCTAssertEqual(reloaded.cells[0].source, "# Title\ntext")
        XCTAssertEqual(reloaded.cells[1].source, "print('hi')\n1 + 1")
        XCTAssertEqual(reloaded.cells[1].nbID, "c1")
        XCTAssertEqual(reloaded.cells[1].outputs.count, 2)
    }

    func testUnrenderedRichOutputSurvivesSave() throws {
        let json: [String: Any] = [
            "nbformat": 4, "nbformat_minor": 5, "metadata": [:] as [String: Any],
            "cells": [
                ["cell_type": "code", "id": "c1", "metadata": [:] as [String: Any],
                 "execution_count": 1, "source": ["df"],
                 "outputs": [
                    ["output_type": "execute_result", "execution_count": 1,
                     "data": ["text/html": ["<table><tr><td>1</td></tr></table>"],
                              "text/plain": ["   a\n0  1"]],
                     "metadata": [:] as [String: Any]],
                 ]],
            ],
        ]
        let notebook = try load(json)
        let saved = try JSONSerialization.jsonObject(with: notebook.serializedData()) as? [String: Any]
        let cells = saved?["cells"] as? [[String: Any]]
        let outputs = cells?.first?["outputs"] as? [[String: Any]]
        let data = outputs?.first?["data"] as? [String: Any]
        XCTAssertNotNil(data?["text/html"], "rich mime types must round-trip verbatim")
        XCTAssertNotNil(data?["text/plain"])
    }

    func testMarkdownAttachmentsSurviveSave() throws {
        let json: [String: Any] = [
            "nbformat": 4, "nbformat_minor": 5, "metadata": [:] as [String: Any],
            "cells": [
                ["cell_type": "markdown", "id": "m1", "metadata": [:] as [String: Any],
                 "source": ["![img](attachment:pic.png)"],
                 "attachments": ["pic.png": ["image/png": "aGVsbG8="]]],
            ],
        ]
        let notebook = try load(json)
        let saved = try JSONSerialization.jsonObject(with: notebook.serializedData()) as? [String: Any]
        let cells = saved?["cells"] as? [[String: Any]]
        XCTAssertNotNil(cells?.first?["attachments"])
        let data = Notebook.attachmentData(notebook.cells[0].extraKeys["attachments"])
        XCTAssertEqual(data["pic.png"], Data(base64Encoded: "aGVsbG8="))
    }

    func testAttachmentsAreDroppedWhenAMarkdownCellBecomesCode() throws {
        let json: [String: Any] = [
            "nbformat": 4, "nbformat_minor": 5, "metadata": [:] as [String: Any],
            "cells": [
                ["cell_type": "markdown", "id": "m1", "metadata": [:] as [String: Any],
                 "source": ["![img](attachment:pic.png)"],
                 "attachments": ["pic.png": ["image/png": "aGVsbG8="]]],
            ],
        ]
        let notebook = try load(json)
        notebook.cells[0].cellType = .code
        let saved = try JSONSerialization.jsonObject(with: notebook.serializedData()) as? [String: Any]
        let cells = saved?["cells"] as? [[String: Any]]
        XCTAssertEqual(cells?.first?["cell_type"] as? String, "code")
        XCTAssertNil(cells?.first?["attachments"])
    }

    func testSourceSplitsOnEveryLineBreakPythonRecognises() throws {
        let exotic = "a\u{0C}b\u{2028}c\r\nd\re"
        let json: [String: Any] = [
            "nbformat": 4, "nbformat_minor": 5, "metadata": [:] as [String: Any],
            "cells": [
                ["cell_type": "code", "id": "c1", "metadata": [:] as [String: Any],
                 "execution_count": NSNull(), "outputs": [] as [Any],
                 "source": ["a\u{0C}", "b\u{2028}", "c\r\n", "d\r", "e"]],
            ],
        ]
        let notebook = try load(json)
        XCTAssertEqual(notebook.cells[0].source, exotic)
        let saved = try JSONSerialization.jsonObject(with: notebook.serializedData()) as? [String: Any]
        let cells = saved?["cells"] as? [[String: Any]]
        XCTAssertEqual(cells?.first?["source"] as? [String],
                       ["a\u{0C}", "b\u{2028}", "c\r\n", "d\r", "e"])
    }

    func testRejectsNonNotebookJSON() throws {
        XCTAssertThrowsError(try load(["hello": "world"]))
        XCTAssertThrowsError(try load(["nbformat": 3, "worksheets": [] as [Any]]))
    }
}

final class PythonHighlighterTests: XCTestCase {
    private func color(_ storage: NSTextStorage, at index: Int) -> NSColor? {
        storage.attribute(.foregroundColor, at: index, effectiveRange: nil) as? NSColor
    }

    func testTokenColors() {
        let source = "def greet(name):\n    return f'hi {name}'  # comment\nx = 42\n"
        let storage = NSTextStorage(string: source)
        PythonHighlighter.highlight(storage)
        XCTAssertEqual(color(storage, at: 0), EditorTheme.keyword)
        XCTAssertEqual(color(storage, at: 4), EditorTheme.defName)
        XCTAssertEqual(color(storage, at: 28), EditorTheme.string)
        XCTAssertEqual(color(storage, at: 42), EditorTheme.comment)
        XCTAssertEqual(color(storage, at: 56), EditorTheme.number)
    }

    func testUnterminatedTripleQuoteDoesNotCrash() {
        let storage = NSTextStorage(string: "s = '''abc\ndef x")
        PythonHighlighter.highlight(storage)
        XCTAssertEqual(color(storage, at: 4), EditorTheme.string)
    }

    func testEmptyDocument() {
        let storage = NSTextStorage(string: "")
        PythonHighlighter.highlight(storage)
        XCTAssertEqual(storage.length, 0)
    }
}

final class DataFramePayloadTests: XCTestCase {
    func testParsesKernelPayload() throws {
        let dict: [String: Any] = [
            "name": "df",
            "columns": ["a", "b"],
            "dtypes": ["int64", "object"],
            "index": ["0", "1"],
            "rows": [["1", "x"], ["2", "y"]],
            "offset": 0, "total_rows": 2, "total_cols": 2,
            "text": "preview",
        ]
        let payload = try XCTUnwrap(DataFramePayload(dict: dict))
        XCTAssertEqual(payload.rows.count, 2)
        XCTAssertEqual(payload.columns, ["a", "b"])
        XCTAssertTrue(payload.isNumericColumn(0))
        XCTAssertFalse(payload.isNumericColumn(1))
    }

    func testRejectsMalformedPayload() {
        XCTAssertNil(DataFramePayload(dict: ["name": "df"]))
    }
}

final class NotebookExporterTests: XCTestCase {
    private func sampleNotebook() -> Notebook {
        Notebook(cells: [
            NotebookCell(type: .markdown, source: "# Title\nSome **bold** text"),
            NotebookCell(type: .code, source: "x = 1\nprint(x)",
                         outputs: [CellOutput(kind: .stream(name: "stdout", text: "1\n"))],
                         executionCount: 3),
        ], metadata: [:])
    }

    func testPythonScriptExport() {
        let script = NotebookExporter.pythonScript(from: sampleNotebook())
        XCTAssertTrue(script.contains("# %% [markdown]\n# # Title\n# Some **bold** text"))
        XCTAssertTrue(script.contains("# %%\nx = 1\nprint(x)"))
    }

    func testHTMLExportContainsCellsAndOutputs() {
        let html = NotebookExporter.html(from: sampleNotebook(), title: "t.ipynb")
        XCTAssertTrue(html.contains("<h1>Title</h1>"))
        XCTAssertTrue(html.contains("<b>bold</b>"))
        XCTAssertTrue(html.contains("<span class=\"syntax-builtin\">print</span>(x)"))
        XCTAssertTrue(html.contains("<pre class=\"out\">1"))
        XCTAssertTrue(html.contains("[3]"))
    }

    func testMarkdownSubset() {
        let html = NotebookExporter.markdownToHTML("## Head\n- one\n- two\n\n`code` here")
        XCTAssertTrue(html.contains("<h2>Head</h2>"))
        XCTAssertTrue(html.contains("<li>one</li>"))
        XCTAssertTrue(html.contains("<code>code</code>"))
    }
}

final class CellOperationTests: XCTestCase {
    func testCellSerializationRoundTripsThroughClipboardPath() throws {
        let notebook = Notebook(cells: [NotebookCell(type: .code, source: "a = 1")], metadata: [:])
        let cell = notebook.cells[0]
        cell.isSourceCollapsed = true
        var dict = notebook.serializeCell(cell)
        dict["id"] = NotebookCell.makeNBID()
        let restored = Notebook.parseCell(dict)
        XCTAssertEqual(restored.source, "a = 1")
        XCTAssertEqual(restored.cellType, .code)
        XCTAssertTrue(restored.isSourceCollapsed)
        XCTAssertNotEqual(restored.nbID, cell.nbID)
    }

    func testCollapseStateSurvivesSave() throws {
        let notebook = Notebook(cells: [NotebookCell(type: .code, source: "x")], metadata: [:])
        notebook.cells[0].isOutputCollapsed = true
        let data = try notebook.serializedData()
        let reloaded = try Notebook.load(from: data)
        XCTAssertTrue(reloaded.cells[0].isOutputCollapsed)
        XCTAssertFalse(reloaded.cells[0].isSourceCollapsed)
    }

    func testDataFrameTSV() {
        let payload = DataFramePayload(dict: [
            "columns": ["a", "b"], "dtypes": ["int64", "object"],
            "index": ["0", "1"], "rows": [["1", "x"], ["2", "y"]],
            "offset": 0, "total_rows": 2, "total_cols": 2, "text": "df",
        ])
        XCTAssertEqual(payload?.tsv, "index\ta\tb\n0\t1\tx\n1\t2\ty")
    }

    func testDurationLabel() {
        XCTAssertEqual(NotebookCellAppKitView.durationLabel(0.03), "<0.1s")
        XCTAssertEqual(NotebookCellAppKitView.durationLabel(2.34), "2.3s")
        XCTAssertEqual(NotebookCellAppKitView.durationLabel(75), "1m 15s")
    }
}

final class ReviewRegressionTests: XCTestCase {
    func testJSONTreeDistinguishesIntsFromBools() {
        let parsed = try! JSONSerialization.jsonObject(with: Data(#"{"a":1,"b":0,"c":true,"d":false}"#.utf8)) as! [String: Any]
        XCTAssertEqual(JSONNodeView.scalarText(parsed["a"]!), "1")
        XCTAssertEqual(JSONNodeView.scalarText(parsed["b"]!), "0")
        XCTAssertEqual(JSONNodeView.scalarText(parsed["c"]!), "True")
        XCTAssertEqual(JSONNodeView.scalarText(parsed["d"]!), "False")
    }

    func testTruncatedTSVMarksTheGap() {
        let payload = DataFramePayload(dict: [
            "columns": ["a"], "dtypes": ["int64"], "index": ["0", "1", "98", "99"],
            "rows": [["1"], ["2"], ["98"], ["99"]], "offset": 0, "total_rows": 100,
            "total_cols": 1, "rows_truncated": true, "head_count": 2, "text": "df",
        ])!
        let lines = payload.tsv.components(separatedBy: "\n")
        XCTAssertEqual(lines[3], "…\t…")
        XCTAssertEqual(lines.count, 6)
    }

    func testMarkdownExportHandlesDeepHeadings() {
        let html = NotebookExporter.markdownToHTML("#### Four\n###### Six\n####### Seven")
        XCTAssertTrue(html.contains("<h4>Four</h4>"))
        XCTAssertTrue(html.contains("<h6>Six</h6>"))
        XCTAssertTrue(html.contains("<p>####### Seven</p>"))
    }

    func testNotebookFingerprintTracksContentNotIdentity() {
        let a = Notebook(cells: [NotebookCell(type: .code, source: "x = 1")], metadata: [:])
        let b = Notebook(cells: [NotebookCell(type: .code, source: "x = 1")], metadata: [:])
        XCTAssertEqual(a.contentFingerprint, b.contentFingerprint)
        b.cells[0].source = "x = 2"
        XCTAssertNotEqual(a.contentFingerprint, b.contentFingerprint)
    }

    func testCollapsedFlagsAreOmittedWhenFalse() throws {
        let notebook = Notebook(cells: [NotebookCell(type: .code, source: "x")], metadata: [:])
        let dict = notebook.serializeCell(notebook.cells[0])
        let metadata = try XCTUnwrap(dict["metadata"] as? [String: Any])
        XCTAssertNil(metadata["jupyter"])
    }

    func testEditedRangeHighlightOnlyTouchesScope() {
        let storage = NSTextStorage(string: "x = 1\n# comment\ny = 2")
        PythonHighlighter.highlight(storage)
        PythonHighlighter.highlight(storage, editedRange: NSRange(location: 17, length: 1))
        let commentColor = storage.attribute(.foregroundColor, at: 6, effectiveRange: nil) as? NSColor
        XCTAssertEqual(commentColor, EditorTheme.comment)
    }
}

final class MarkdownMathTests: XCTestCase {
    func testInlineMathSplitting() {
        XCTAssertEqual(MarkdownView.splitInlineMath("a $x^2$ b"),
                       [.text("a "), .math("x^2"), .text(" b")])
        XCTAssertEqual(MarkdownView.splitInlineMath("$e^{i\\pi}$"),
                       [.math("e^{i\\pi}")])
        XCTAssertEqual(MarkdownView.splitInlineMath("costs \\$5 and \\$6"),
                       [.text("costs $5 and $6")])
        XCTAssertEqual(MarkdownView.splitInlineMath("unclosed $ dollar"),
                       [.text("unclosed $ dollar")])
        XCTAssertEqual(MarkdownView.splitInlineMath("plain text"),
                       [.text("plain text")])
    }

    func testDisplayMathBlockParsing() {
        XCTAssertEqual(MarkdownView.parse("$$E = mc^2$$"), [.math("E = mc^2")])
        XCTAssertEqual(
            MarkdownView.parse("intro\n\n$$\n\\frac{a}{b}\n$$\n\nafter"),
            [.paragraph("intro"), .math("\\frac{a}{b}"), .paragraph("after")])
        XCTAssertEqual(MarkdownView.parse("```\n$$not math$$\n```"),
                       [.code("$$not math$$")])
    }

    func testStandaloneMarkdownImageParses() {
        XCTAssertEqual(
            MarkdownView.parse("intro\n\n![plot](attachment:fig.png)\n\nafter"),
            [.paragraph("intro"), .image(alt: "plot", url: "attachment:fig.png"), .paragraph("after")])
        XCTAssertEqual(
            MarkdownView.parse("![x](y.png \"title\")"),
            [.image(alt: "x", url: "y.png")])
        XCTAssertEqual(
            MarkdownView.parse("```\n![not](an.png)\n```"),
            [.code("![not](an.png)")])
    }

    func testInlineImageSplitting() {
        XCTAssertEqual(
            MarkdownView.splitInlineMath("a ![x](y.png) b"),
            [.text("a "), .image(alt: "x", url: "y.png"), .text(" b")])
        XCTAssertEqual(
            MarkdownView.splitInlineMath("see $x$ and ![y](z.png)"),
            [.text("see "), .math("x"), .text(" and "), .image(alt: "y", url: "z.png")])
    }

    func testImageDataFromAttachmentAndDataURI() {
        let png = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
        let attachments = ["fig.png": png]
        XCTAssertEqual(MarkdownView.imageData(url: "attachment:fig.png",
                                              attachments: attachments, baseDirectory: nil), png)
        XCTAssertEqual(MarkdownView.imageData(url: "attachment:./fig.png",
                                              attachments: attachments, baseDirectory: nil), png)
        let uri = "data:image/png;base64," + png.base64EncodedString()
        XCTAssertEqual(MarkdownView.imageData(url: uri, attachments: [:], baseDirectory: nil), png)
        XCTAssertNil(MarkdownView.imageData(url: "https://example.com/x.png",
                                            attachments: [:], baseDirectory: nil))
    }

    func testHTMLExportEmbedsMarkdownAttachments() {
        let png = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
        let cell = NotebookCell(type: .markdown, source: "See ![plot](attachment:fig.png)")
        cell.extraKeys["attachments"] = ["fig.png": ["image/png": png.base64EncodedString()]]
        let html = NotebookExporter.html(from: Notebook(cells: [cell], metadata: [:]), title: "t")
        XCTAssertTrue(html.contains("<img alt=\"plot\" src=\"data:image/png;base64,"))
        XCTAssertTrue(html.contains(png.base64EncodedString()))
        XCTAssertEqual(NotebookExporter.markdownToHTML("![missing](attachment:gone.png)"),
                       "missing\n")
    }

    func testImageAltTextCannotInjectHTMLAttributes() {
        let png = Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
        let cell = NotebookCell(type: .markdown,
                                source: "![\" onload=\"alert(1)](attachment:fig.png)")
        cell.extraKeys["attachments"] = ["fig.png": ["image/png": png.base64EncodedString()]]
        let html = NotebookExporter.html(from: Notebook(cells: [cell], metadata: [:]), title: "t")
        XCTAssertFalse(html.contains("onload=\"alert(1)\""))
        XCTAssertTrue(html.contains("&quot; onload=&quot;alert(1)"))
    }
}

final class PythonLocatorTests: XCTestCase {
    private var home: URL!
    private var workspace: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("quanta-tests-\(UUID().uuidString)")
        home = base.appendingPathComponent("home")
        workspace = base.appendingPathComponent("project")
        try makeFakePython(at: home.appendingPathComponent("miniforge3"))
        try makeFakePython(at: home.appendingPathComponent("miniforge3/envs/ml"))
        try makeFakePython(at: workspace.appendingPathComponent(".venv"))
        let registry = home.appendingPathComponent(".conda")
        try FileManager.default.createDirectory(at: registry, withIntermediateDirectories: true)
        let entries = [
            home.appendingPathComponent("miniforge3").path,
            home.appendingPathComponent("miniforge3/envs/ml").path,
        ]
        try entries.joined(separator: "\n")
            .write(to: registry.appendingPathComponent("environments.txt"),
                   atomically: true, encoding: .utf8)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home.deletingLastPathComponent())
    }

    private func makeFakePython(at prefix: URL) throws {
        let bin = prefix.appendingPathComponent("bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: bin.appendingPathComponent("python3").path,
            contents: Data("#!/bin/sh\n".utf8),
            attributes: [.posixPermissions: 0o755])
    }

    func testDiscoversWorkspaceAndCondaEnvironments() {
        let envs = PythonLocator.discover(workspace: workspace, home: home)
        XCTAssertEqual(envs.first?.kind, .workspace)
        XCTAssertEqual(envs.first?.name, ".venv")
        let conda = envs.filter { $0.kind == .conda }
        XCTAssertEqual(conda.map(\.name), ["base (miniforge3)", "ml"])
    }

    func testWorkspaceEnvironmentWinsAutoPick() {
        let envs = PythonLocator.discover(workspace: workspace, home: home)
        XCTAssertEqual(PythonLocator.preferred(from: envs)?.kind, .workspace)
    }

    func testCondaBaseWinsWithoutWorkspaceEnv() {
        let stored = QuantaDefaults.store.string(forKey: PythonLocator.defaultsKey)
        QuantaDefaults.store.removeObject(forKey: PythonLocator.defaultsKey)
        defer {
            if let stored { QuantaDefaults.store.set(stored, forKey: PythonLocator.defaultsKey) }
        }
        let envs = PythonLocator.discover(workspace: nil, home: home)
        let preferred = PythonLocator.preferred(from: envs)
        XCTAssertEqual(preferred?.kind, .conda)
        XCTAssertEqual(preferred?.name, "base (miniforge3)")
    }
}

final class DataFrameClipboardTests: XCTestCase {
    private let header = ["", "name", "score"]
    private let rows = [["0", "ann", "1.5"], ["1", "bob|z", "NaN"]]

    func testTSVWithAndWithoutHeader() {
        XCTAssertEqual(DataFrameClipboard.tsv(rows: rows), "0\tann\t1.5\n1\tbob|z\tNaN")
        XCTAssertEqual(DataFrameClipboard.tsv(header: header, rows: rows),
                       "\tname\tscore\n0\tann\t1.5\n1\tbob|z\tNaN")
    }

    func testMarkdownEscapesPipesAndAlignsNumericColumns() {
        let md = DataFrameClipboard.markdown(header: header, rows: rows,
                                             rightAligned: [true, false, true])
        XCTAssertEqual(md.components(separatedBy: "\n"), [
            "|  | name | score |",
            "| ---: | --- | ---: |",
            "| 0 | ann | 1.5 |",
            "| 1 | bob\\|z | NaN |",
        ])
    }

    func testMarkdownPadsShortRows() {
        let md = DataFrameClipboard.markdown(header: ["a", "b"], rows: [["1"]])
        XCTAssertTrue(md.hasSuffix("| 1 |  |"))
    }

    func testPythonListLiterals() {
        XCTAssertEqual(DataFrameClipboard.pythonList(["1", "2.5", "NaN", ""], bare: true),
                       "[1, 2.5, float('nan'), None]")
        XCTAssertEqual(DataFrameClipboard.pythonList(["it's", "back\\slash"], bare: false),
                       "['it\\'s', 'back\\\\slash']")
    }

    func testRowHeightTracksZoomAndKeepsDefault() {
        XCTAssertEqual(DataFrameTextStyle.rowHeight(
            forCellSize: DataFrameTextStyle.cellSize(forMonoSize: 12)), 20)
        XCTAssertGreaterThan(DataFrameTextStyle.rowHeight(forCellSize: 16),
                             DataFrameTextStyle.rowHeight(forCellSize: 11))
        XCTAssertEqual(DataFrameNSTable.inlineHeight(rowCount: 5, monoSize: 12), 5 * 22 + 32)
    }
}

final class AppStateLogicTests: XCTestCase {
    func testDedentLiftsBlockOutOfFunctionBody() {
        let code = "    total = 0\n    for row in rows:\n        total += row\n"
        XCTAssertEqual(AppState.dedent(code), "total = 0\nfor row in rows:\n    total += row")
    }

    func testDedentNormalisesTabsToColumns() {
        let code = "\tx = 1\n\t\ty = 2"
        XCTAssertEqual(AppState.dedent(code), "x = 1\n    y = 2")
    }

    func testDedentLeavesUnindentedCodeAndDropsTrailingBlankLines() {
        XCTAssertEqual(AppState.dedent("x = 1\n\n   \n"), "x = 1")
        XCTAssertEqual(AppState.dedent("print(1)"), "print(1)")
    }

    func testDedentIgnoresBlankLinesWhenMeasuringIndent() {
        XCTAssertEqual(AppState.dedent("  a = 1\n\n  b = 2"), "a = 1\n\nb = 2")
    }

    func testSelectTabWrapsBothWays() {
        let app = AppState()
        let first = Document(script: nil, text: "")
        let second = Document(script: nil, text: "")
        let third = Document(script: nil, text: "")
        app.openDocuments = [first, second, third]
        app.activeDocumentID = third.id
        app.selectTab(offset: 1)
        XCTAssertEqual(app.activeDocumentID, first.id)
        app.selectTab(offset: -1)
        XCTAssertEqual(app.activeDocumentID, third.id)
        app.selectTab(offset: -2)
        XCTAssertEqual(app.activeDocumentID, first.id)
    }

    func testSelectTabWithNoDocumentsDoesNothing() {
        let app = AppState()
        app.openDocuments = []
        app.activeDocumentID = nil
        app.selectTab(offset: 1)
        XCTAssertNil(app.activeDocumentID)
    }

    func testEnvironmentNameFallsBackToTheEnvironmentDirectory() {
        let app = AppState()
        app.environments = []
        app.pythonPath = "/Users/x/miniforge3/envs/msds/bin/python3"
        XCTAssertEqual(app.environmentName, "msds")
        app.pythonPath = "/usr/bin/python3"
        XCTAssertEqual(app.environmentName, "python3")
        app.pythonPath = "/opt/homebrew/bin/python3.12"
        XCTAssertEqual(app.environmentName, "python3.12")
        app.pythonPath = nil
        XCTAssertEqual(app.environmentName, "No interpreter")
    }

    func testDisplayRowCountCountsTheEllipsisRowOnly() {
        let compact = DataFramePayload(dict: [
            "columns": ["a"], "rows": [["1"], ["2"]], "total_rows": 2,
        ])
        XCTAssertEqual(compact?.displayRowCount, 2)
        let truncated = DataFramePayload(dict: [
            "columns": ["a"], "rows": [["1"], ["2"]], "total_rows": 900,
            "rows_truncated": true, "head_count": 1,
        ])
        XCTAssertEqual(truncated?.displayRowCount, 3)
    }
}

final class JupyterJSONTests: XCTestCase {
    func testMatchesJupyterFormatting() throws {
        let object: [String: Any] = [
            "cells": [
                ["cell_type": "code", "execution_count": NSNull(), "id": "ab12",
                 "metadata": [:] as [String: Any], "outputs": [] as [Any],
                 "source": ["x = 1\n", "print(\"hi\\t\")"]],
                ["cell_type": "markdown", "id": "cd34",
                 "metadata": ["jupyter": ["source_hidden": true]], "source": [] as [Any]],
            ],
            "metadata": [
                "kernelspec": ["display_name": "Python 3", "language": "python", "name": "python3"],
                "language_info": ["name": "python", "version": "3.11.0"],
                "flt": 1.0, "big": 1e16, "small": 0.00001, "neg": -2.5, "half": 0.5,
                "uni": "héllo ✓ 😀", "ctrl": "a\u{01}b",
                "edge_big": 9007199254740994.0, "edge_mid": 9.5e15,
                "esc": "q\"b\\s/n\nr\rt\tb\u{08}f\u{0C}",
            ],
            "nbformat": 4,
            "nbformat_minor": 5,
        ]
        let expected = #"""
        {
         "cells": [
          {
           "cell_type": "code",
           "execution_count": null,
           "id": "ab12",
           "metadata": {},
           "outputs": [],
           "source": [
            "x = 1\n",
            "print(\"hi\\t\")"
           ]
          },
          {
           "cell_type": "markdown",
           "id": "cd34",
           "metadata": {
            "jupyter": {
             "source_hidden": true
            }
           },
           "source": []
          }
         ],
         "metadata": {
          "big": 1e+16,
          "ctrl": "a\u0001b",
          "edge_big": 9007199254740994.0,
          "edge_mid": 9500000000000000.0,
          "esc": "q\"b\\s/n\nr\rt\tb\bf\f",
          "flt": 1.0,
          "half": 0.5,
          "kernelspec": {
           "display_name": "Python 3",
           "language": "python",
           "name": "python3"
          },
          "language_info": {
           "name": "python",
           "version": "3.11.0"
          },
          "neg": -2.5,
          "small": 1e-05,
          "uni": "héllo ✓ 😀"
         },
         "nbformat": 4,
         "nbformat_minor": 5
        }
        """# + "\n"
        XCTAssertEqual(String(decoding: try JupyterJSON.data(object), as: UTF8.self), expected)
    }

    func testJupyterNotebookRoundTripsByteForByte() throws {
        let original = #"""
        {
         "cells": [
          {
           "cell_type": "markdown",
           "id": "m1",
           "metadata": {},
           "source": [
            "# Title\n",
            "\n",
            "Some *text* with $x^2$."
           ]
          },
          {
           "cell_type": "code",
           "execution_count": 2,
           "id": "c1",
           "metadata": {
            "tags": [
             "demo"
            ]
           },
           "outputs": [
            {
             "name": "stdout",
             "output_type": "stream",
             "text": [
              "hi\n",
              "there\n"
             ]
            },
            {
             "data": {
              "text/plain": [
               "   a  b\n",
               "0  1  2"
              ]
             },
             "execution_count": 2,
             "metadata": {},
             "output_type": "execute_result"
            },
            {
             "data": {
              "image/png": "iVBORw0KGgo=\n",
              "text/plain": [
               "<Figure size 640x480 with 1 Axes>"
              ]
             },
             "metadata": {
              "needs_background": "light"
             },
             "output_type": "display_data"
            }
           ],
           "source": [
            "import numpy as np\n",
            "np.arange(3) * 2.5"
           ]
          },
          {
           "cell_type": "raw",
           "id": "r1",
           "metadata": {},
           "source": [
            "raw é text"
           ]
          }
         ],
         "metadata": {
          "kernelspec": {
           "display_name": "Python 3 (ipykernel)",
           "language": "python",
           "name": "python3"
          },
          "language_info": {
           "codemirror_mode": {
            "name": "ipython",
            "version": 3
           },
           "file_extension": ".py",
           "mimetype": "text/x-python",
           "name": "python",
           "nbconvert_exporter": "python",
           "pygments_lexer": "ipython3",
           "version": "3.11.5"
          }
         },
         "nbformat": 4,
         "nbformat_minor": 5
        }
        """# + "\n"
        let notebook = try Notebook.load(from: Data(original.utf8))
        XCTAssertEqual(notebook.cells.count, 3)
        XCTAssertEqual(String(decoding: try notebook.serializedData(), as: UTF8.self), original)
    }

    func testEmptyNotebookUsesOneSpaceIndentAndTrailingNewline() throws {
        let notebook = Notebook(cells: [NotebookCell(type: .code, source: "")], metadata: [:])
        let text = String(decoding: try notebook.serializedData(), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("{\n \"cells\": [\n  {\n   \"cell_type\": \"code\","))
        XCTAssertTrue(text.hasSuffix(" \"nbformat\": 4,\n \"nbformat_minor\": 5\n}\n"))
        XCTAssertFalse(text.contains("\" : "))
    }
}

final class GitStatusParserTests: XCTestCase {
    private func data(_ records: [String]) -> Data {
        Data((records.joined(separator: "\0") + "\0").utf8)
    }

    func testParsesHeadersAndEntries() {
        let result = GitStatusParser.parse(data([
            "# branch.oid 0123abcd",
            "# branch.head main",
            "# branch.upstream origin/main",
            "# branch.ab +2 -1",
            "1 .M N... 100644 100644 100644 aaaa bbbb notebooks/a b.ipynb",
            "1 A. N... 000000 100644 100644 0000 cccc new.py",
            "1 MM N... 100644 100644 100644 aaaa dddd both.py",
            "2 R. N... 100644 100644 100644 aaaa eeee R100 renamed.py",
            "old.py",
            "u UU N... 100644 100644 100644 100644 a b c conflict.py",
            "? untracked file.txt",
            "! ignored.pyc",
        ]))
        XCTAssertEqual(result.header.branch, "main")
        XCTAssertEqual(result.header.oid, "0123abcd")
        XCTAssertEqual(result.header.upstream, "origin/main")
        XCTAssertEqual(result.header.ahead, 2)
        XCTAssertEqual(result.header.behind, 1)
        XCTAssertEqual(result.entries.count, 6)
        XCTAssertEqual(result.entries[0], GitStatusParser.Entry(
            staged: nil, unstaged: .modified, isConflicted: false,
            path: "notebooks/a b.ipynb", originalPath: nil))
        XCTAssertEqual(result.entries[1].staged, .added)
        XCTAssertNil(result.entries[1].unstaged)
        XCTAssertEqual(result.entries[2].staged, .modified)
        XCTAssertEqual(result.entries[2].unstaged, .modified)
        XCTAssertEqual(result.entries[3], GitStatusParser.Entry(
            staged: .renamed, unstaged: nil, isConflicted: false,
            path: "renamed.py", originalPath: "old.py"))
        XCTAssertTrue(result.entries[4].isConflicted)
        XCTAssertEqual(result.entries[4].path, "conflict.py")
        XCTAssertEqual(result.entries[5], GitStatusParser.Entry(
            staged: nil, unstaged: .untracked, isConflicted: false,
            path: "untracked file.txt", originalPath: nil))
    }

    func testDetachedAndInitialHeaders() {
        let result = GitStatusParser.parse(data(["# branch.oid (initial)", "# branch.head (detached)"]))
        XCTAssertEqual(result.header.oid, "(initial)")
        XCTAssertEqual(result.header.branch, "(detached)")
        XCTAssertTrue(result.entries.isEmpty)
    }
}

final class NotebookSemanticsTests: XCTestCase {
    private func notebookData(source: String, executionCount: Int?, outputs: [CellOutput],
                              metadata: [String: Any] = [:]) throws -> Data {
        let notebook = Notebook(cells: [
            NotebookCell(type: .markdown, source: "# Title"),
            NotebookCell(type: .code, source: source, outputs: outputs,
                         executionCount: executionCount, nbID: "c1"),
        ], metadata: metadata)
        return try notebook.serializedData()
    }

    func testOutputsExecutionCountsAndMetadataDoNotCount() throws {
        let clean = try notebookData(source: "x = 1", executionCount: nil, outputs: [])
        let executed = try notebookData(
            source: "x = 1", executionCount: 7,
            outputs: [CellOutput(kind: .stream(name: "stdout", text: "1\n"))],
            metadata: ["language_info": ["name": "python", "version": "3.12.1"]])
        XCTAssertTrue(NotebookSemantics.sameUserContent(clean, executed))
        XCTAssertNotEqual(clean, executed)
    }

    func testSourceEditsCount() throws {
        let before = try notebookData(source: "x = 1", executionCount: 1, outputs: [])
        let after = try notebookData(source: "x = 2", executionCount: 1, outputs: [])
        XCTAssertFalse(NotebookSemantics.sameUserContent(before, after))
    }

    func testUnparseableContentCountsAsChanged() throws {
        let valid = try notebookData(source: "x = 1", executionCount: nil, outputs: [])
        XCTAssertFalse(NotebookSemantics.sameUserContent(valid, Data("{".utf8)))
        XCTAssertFalse(NotebookSemantics.sameUserContent(valid, Data()))
    }

    func testFlattenedNotebookListsCellSourcesOnly() throws {
        let data = try notebookData(
            source: "x = 1\nprint(x)", executionCount: 3,
            outputs: [CellOutput(kind: .executeResult(text: "1"))])
        XCTAssertEqual(NotebookSemantics.flattened(data),
                       "# %% [markdown]\n# Title\n\n# %%\nx = 1\nprint(x)\n")
    }
}

final class LineDiffTests: XCTestCase {
    func testLinesDropTheTrailingNewlineOnly() {
        XCTAssertEqual(LineDiff.lines(""), [])
        XCTAssertEqual(LineDiff.lines("a"), ["a"])
        XCTAssertEqual(LineDiff.lines("a\nb\n"), ["a", "b"])
        XCTAssertEqual(LineDiff.lines("a\n\n"), ["a", ""])
    }

    func testAlignedRowsCarryBothLineNumbers() {
        let rows = LineDiff.align(old: ["a", "b", "c", "d"], new: ["a", "x", "c", "d", "e"])
        XCTAssertEqual(rows.map(\.kind), [.context, .removed, .added, .context, .context, .added])
        XCTAssertEqual(rows.map(\.text), ["a", "b", "x", "c", "d", "e"])
        XCTAssertEqual(rows.map(\.oldLine), [1, 2, nil, 3, 4, nil])
        XCTAssertEqual(rows.map(\.newLine), [1, nil, 2, 3, 4, 5])
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count)
    }

    func testCompareCountsAdditionsAndDeletions() {
        let diff = DiffDocument.compare(oldText: "a\nb\n", newText: "a\nc\nd\n",
                                        oldLabel: "Index", newLabel: "Working Tree",
                                        isNotebook: false)
        XCTAssertEqual(diff.additions, 2)
        XCTAssertEqual(diff.deletions, 1)
        XCTAssertTrue(diff.hasChanges)
        XCTAssertFalse(DiffDocument.compare(oldText: "same\n", newText: "same\n",
                                            oldLabel: "a", newLabel: "b",
                                            isNotebook: false).hasChanges)
    }

    func testDisplayRowsCollapseUnchangedRunsAndExpandOnRequest() {
        let old = (1...20).map { "l\($0)" }
        var new = old
        new[9] = "changed"
        let diff = DiffDocument.compare(oldText: old.joined(separator: "\n"),
                                        newText: new.joined(separator: "\n"),
                                        oldLabel: "a", newLabel: "b", isNotebook: false)
        let collapsed = diff.displayRows(context: 3, expanded: [])
        XCTAssertEqual(collapsed.map(\.kind), [
            .gap, .context, .context, .context, .removed, .added,
            .context, .context, .context, .gap,
        ])
        XCTAssertEqual(collapsed.first?.hiddenCount, 6)
        XCTAssertEqual(collapsed.last?.hiddenCount, 7)
        XCTAssertEqual(collapsed.first?.runStart, 0)
        let expanded = diff.displayRows(context: 3, expanded: [0])
        XCTAssertEqual(expanded.count, 9 + 2 + 3 + 1)
        XCTAssertEqual(expanded.first?.text, "l1")
        XCTAssertTrue(diff.displayRows(context: 3, expanded: [0, 11]).allSatisfy { $0.kind != .gap })
    }

    func testTrailingNewlineOnlyChangeIsVisible() {
        let diff = DiffDocument.compare(oldText: "a\nb\n", newText: "a\nb", oldLabel: "a",
                                        newLabel: "b", isNotebook: false)
        XCTAssertTrue(diff.hasChanges)
        XCTAssertEqual(diff.additions, 1)
        XCTAssertEqual(diff.deletions, 1)
        XCTAssertEqual(diff.rows.last?.text, "b" + LineDiff.missingNewlineMarker)
    }

    func testHugeRewriteFallsBackToWholeReplacement() {
        let old = (1...5000).map { "old \($0)" }
        let new = (1...5000).map { "new \($0)" }
        let rows = LineDiff.align(old: old, new: new)
        XCTAssertEqual(rows.filter { $0.kind == .removed }.count, 5000)
        XCTAssertEqual(rows.filter { $0.kind == .added }.count, 5000)
    }

    func testBinaryDetection() {
        XCTAssertTrue(DiffDocument.isBinaryData(Data([0x50, 0x4B, 0x00, 0x01])))
        XCTAssertFalse(DiffDocument.isBinaryData(Data("plain text\n".utf8)))
        XCTAssertEqual(DiffDocument.text(from: Data()), "")
        XCTAssertNil(DiffDocument.text(from: Data([0x00])))
    }
}

final class GitSnapshotIntegrationTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        try XCTSkipIf(GitClient.executable == nil, "git is not installed")
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quanta-git-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        setenv("GIT_CONFIG_GLOBAL", "/dev/null", 1)
        setenv("GIT_CONFIG_NOSYSTEM", "1", 1)
        try run(["init", "-q", "-b", "main"])
        try run(["config", "user.email", "tests@example.com"])
        try run(["config", "user.name", "Quanta Tests"])
    }

    override func tearDownWithError() throws {
        unsetenv("GIT_CONFIG_GLOBAL")
        unsetenv("GIT_CONFIG_NOSYSTEM")
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func run(_ arguments: [String]) throws {
        let result = GitClient.run(["-c", "commit.gpgsign=false"] + arguments, in: root)
        guard result.succeeded else { throw QuantaError(result.failureMessage) }
    }

    private func writeNotebook(source: String, executionCount: Int?, outputs: [CellOutput]) throws {
        let notebook = Notebook(cells: [
            NotebookCell(type: .code, source: source, outputs: outputs,
                         executionCount: executionCount, nbID: "c1"),
        ], metadata: [:])
        try notebook.serializedData().write(to: root.appendingPathComponent("a.ipynb"))
    }

    func testGitScopesSeparateIndexAndWorkingTreeAndNeverHideConflicts() {
        XCTAssertTrue(GitChangeScope.all.includes(.staged))
        XCTAssertTrue(GitChangeScope.all.includes(.unstaged))
        XCTAssertTrue(GitChangeScope.staged.includes(.staged))
        XCTAssertFalse(GitChangeScope.staged.includes(.unstaged))
        XCTAssertFalse(GitChangeScope.unstaged.includes(.staged))
        XCTAssertTrue(GitChangeScope.unstaged.includes(.unstaged))
        for scope in GitChangeScope.allCases { XCTAssertTrue(scope.includes(.conflicted)) }
    }

    func testRemoteDiscoveryDoesNotGuessBetweenMultiplePublishTargets() throws {
        let local = try XCTUnwrap(GitSnapshot.load(workspace: root, hideOutputOnlyNotebooks: true)).get()
        XCTAssertTrue(local.remotes.isEmpty)
        XCTAssertNil(local.publishRemote)

        try run(["remote", "add", "team", root.appendingPathComponent("team.git").path])
        let single = try XCTUnwrap(GitSnapshot.load(workspace: root, hideOutputOnlyNotebooks: true)).get()
        XCTAssertEqual(single.remotes, ["team"])
        XCTAssertEqual(single.publishRemote, "team")

        try run(["remote", "add", "backup", root.appendingPathComponent("backup.git").path])
        let multiple = try XCTUnwrap(GitSnapshot.load(workspace: root, hideOutputOnlyNotebooks: true)).get()
        XCTAssertNil(multiple.publishRemote)

        try run(["remote", "add", "origin", root.appendingPathComponent("origin.git").path])
        let origin = try XCTUnwrap(GitSnapshot.load(workspace: root, hideOutputOnlyNotebooks: true)).get()
        XCTAssertEqual(origin.publishRemote, "origin")
    }

    @MainActor
    func testUnstageBeforeFirstCommitPreservesLaterWorkingTreeEdits() throws {
        let file = root.appendingPathComponent("draft.py")
        try "staged = 1\n".write(to: file, atomically: true, encoding: .utf8)
        try run(["add", "--", "draft.py"])
        try "working = 2\n".write(to: file, atomically: true, encoding: .utf8)

        let state = SourceControlState()
        let loaded = expectation(description: "Repository loaded")
        state.onSnapshot = { loaded.fulfill() }
        state.setWorkspace(root)
        wait(for: [loaded], timeout: 10)
        state.onSnapshot = nil
        XCTAssertFalse(state.canPush)
        XCTAssertFalse(state.canPull)

        let unstaged = expectation(description: "Initial commit changes unstaged")
        state.unstage(paths: ["draft.py"]) { succeeded in
            XCTAssertTrue(succeeded)
            unstaged.fulfill()
        }
        wait(for: [unstaged], timeout: 10)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "working = 2\n")
        let snapshot = try XCTUnwrap(GitSnapshot.load(workspace: root, hideOutputOnlyNotebooks: true)).get()
        XCTAssertTrue(snapshot.staged.isEmpty)
        XCTAssertEqual(snapshot.unstaged.map(\.path), ["draft.py"])
    }

    @MainActor
    func testOperationFailureRemainsVisibleUntilDismissed() throws {
        let state = SourceControlState()
        let loaded = expectation(description: "Repository loaded")
        state.onSnapshot = { loaded.fulfill() }
        state.setWorkspace(root)
        wait(for: [loaded], timeout: 10)
        state.onSnapshot = nil

        let failed = expectation(description: "Git failure reported")
        state.stage(paths: ["missing.py"]) { succeeded in
            XCTAssertFalse(succeeded)
            failed.fulfill()
        }
        wait(for: [failed], timeout: 10)
        XCTAssertTrue(state.operationError?.contains("Stage failed") ?? false)
        XCTAssertFalse(state.isBusy)
        state.dismissError()
        XCTAssertNil(state.operationError)
    }

    func testOutputOnlyNotebookChangesAreHiddenUntilSourceChanges() throws {
        try writeNotebook(source: "x = 1", executionCount: nil, outputs: [])
        try "print('hi')\n".write(to: root.appendingPathComponent("s.py"), atomically: true, encoding: .utf8)
        try run(["add", "-A"])
        try run(["commit", "-q", "-m", "init"])

        let clean = try XCTUnwrap(GitSnapshot.load(workspace: root, hideOutputOnlyNotebooks: true)).get()
        XCTAssertTrue(clean.isClean)
        XCTAssertEqual(clean.branch, "main")
        XCTAssertTrue(clean.hasCommits)
        XCTAssertEqual(clean.branches, ["main"])

        try writeNotebook(source: "x = 1", executionCount: 4,
                          outputs: [CellOutput(kind: .stream(name: "stdout", text: "ran\n"))])
        let executed = try XCTUnwrap(GitSnapshot.load(workspace: root, hideOutputOnlyNotebooks: true)).get()
        XCTAssertTrue(executed.unstaged.isEmpty)
        XCTAssertEqual(executed.hiddenNotebooks.map(\.path), ["a.ipynb"])
        XCTAssertNil(executed.statusByPath[root.appendingPathComponent("a.ipynb").path])

        let shown = try XCTUnwrap(GitSnapshot.load(workspace: root, hideOutputOnlyNotebooks: false)).get()
        XCTAssertEqual(shown.unstaged.map(\.path), ["a.ipynb"])
        XCTAssertTrue(shown.hiddenNotebooks.isEmpty)

        try writeNotebook(source: "x = 2", executionCount: 4,
                          outputs: [CellOutput(kind: .stream(name: "stdout", text: "ran\n"))])
        try "print('changed')\n".write(to: root.appendingPathComponent("s.py"), atomically: true, encoding: .utf8)
        try Data("data".utf8).write(to: root.appendingPathComponent("new.csv"))
        let edited = try XCTUnwrap(GitSnapshot.load(workspace: root, hideOutputOnlyNotebooks: true)).get()
        XCTAssertEqual(edited.unstaged.map(\.path), ["a.ipynb", "new.csv", "s.py"])
        XCTAssertEqual(edited.unstaged.map(\.status), [.modified, .untracked, .modified])
        XCTAssertTrue(edited.hiddenNotebooks.isEmpty)
        XCTAssertEqual(edited.statusByPath[root.appendingPathComponent("s.py").path], .modified)

        let diff = try DiffSource.load(DiffSource(change: edited.unstaged[0]), root: edited.root).get()
        XCTAssertTrue(diff.isNotebook)
        XCTAssertEqual(diff.additions, 1)
        XCTAssertEqual(diff.deletions, 1)
        XCTAssertEqual(diff.rows.filter { $0.kind == .removed }.map(\.text), ["x = 1"])
        XCTAssertEqual(diff.rows.filter { $0.kind == .added }.map(\.text), ["x = 2"])

        try run(["add", "-A", "--", "s.py"])
        let staged = try XCTUnwrap(GitSnapshot.load(workspace: root, hideOutputOnlyNotebooks: true)).get()
        XCTAssertEqual(staged.staged.map(\.path), ["s.py"])
        XCTAssertEqual(staged.unstaged.map(\.path), ["a.ipynb", "new.csv"])
        XCTAssertEqual(staged.repositoryPath(for: root.appendingPathComponent("s.py")), "s.py")
        XCTAssertEqual(staged.repositoryPath(for: root.appendingPathComponent("sub/x.py")), "sub/x.py")
        let realRoot = URL(fileURLWithPath: staged.root.path, isDirectory: true)
        if realRoot.path != root.path {
            XCTAssertEqual(staged.repositoryPath(for: realRoot.appendingPathComponent("s.py")), "s.py")
        }
        XCTAssertNil(staged.repositoryPath(for: URL(fileURLWithPath: "/usr/bin/true")))
    }
}
