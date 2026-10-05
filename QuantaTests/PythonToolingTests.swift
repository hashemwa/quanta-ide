import Foundation
import XCTest
@testable import Quanta

@MainActor
final class PythonToolingTests: XCTestCase {
    private var helperURL: URL {
        get throws {
            try XCTUnwrap(Bundle.main.url(forResource: "quanta_analysis", withExtension: "py")
                ?? Bundle.main.url(forResource: "quanta_analysis", withExtension: "py", subdirectory: "Resources"))
        }
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("quanta-tooling-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    private func helper(_ body: String, mockedRuff: String? = nil) throws -> URL {
        let directory = try temporaryDirectory()
        let url = directory.appendingPathComponent("helper.py")
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        let path = String(decoding: try encoder.encode(helperURL.path), as: UTF8.self)
        let setup: String
        if let mockedRuff {
            setup = """
            def run_ruff(arguments, source):
            \(mockedRuff.split(separator: "\n", omittingEmptySubsequences: false).map { "    " + $0 }.joined(separator: "\n"))
            namespace['analyze'].__globals__['run_ruff'] = run_ruff
            namespace['analyze'].__globals__['importlib'].util.find_spec = lambda name: object()
            """
        } else {
            setup = "namespace['analyze'].__globals__['importlib'].util.find_spec = lambda name: None"
        }
        try """
        import json
        import runpy
        import sys
        namespace = runpy.run_path(\(path))
        \(setup)
        \(body)
        """.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func analyze(_ sources: [PythonSourceInput], helper: URL? = nil, workingDirectory: URL? = nil,
                         timeout: TimeInterval = 5, outputLimit: Int = 8 * 1_024 * 1_024,
                         isNotebook: Bool = false) async throws -> PythonAnalysisResult {
        let tooling = try PythonTooling(helperURL: helper ?? helperURL, timeout: timeout, outputLimit: outputLimit)
        defer { tooling.cancel() }
        return try await withCheckedThrowingContinuation { continuation in
            tooling.analyze(sources: sources, python: "/usr/bin/python3", workingDirectory: workingDirectory,
                            isNotebook: isNotebook) {
                continuation.resume(with: $0)
            }
        }
    }

    func testSyntaxErrorsMapToTheirCellWithoutExecutingCode() async throws {
        let directory = try temporaryDirectory()
        let marker = directory.appendingPathComponent("must-not-exist")
        let first = PythonSourceInput(id: UUID(), source: "from pathlib import Path\nPath('must-not-exist').touch()\n")
        let second = PythonSourceInput(id: UUID(), source: "result = (\n")
        let result = try await analyze([first, second], helper: helper("namespace['main']()"), workingDirectory: directory)
        XCTAssertEqual(result.toolName, "Python syntax")
        XCTAssertEqual(result.diagnostics.count, 1)
        XCTAssertEqual(result.diagnostics.first?.sourceID, second.id)
        XCTAssertEqual(result.diagnostics.first?.severity, .error)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testSyntaxChecksDoNotMergeIncompleteCells() async throws {
        let sources = [PythonSourceInput(id: UUID(), source: "values = ["),
                       PythonSourceInput(id: UUID(), source: "1, 2, 3]")]
        let result = try await analyze(sources, helper: helper("namespace['main']()"))
        XCTAssertEqual(Set(result.diagnostics.map(\.sourceID)), Set(sources.map(\.id)))
        XCTAssertEqual(result.diagnostics.count, 2)
    }

    func testSyntaxChecksCarryFutureFlagsAndAllowTopLevelAwait() async throws {
        let sources = [PythonSourceInput(id: UUID(), source: "from __future__ import barry_as_FLUFL"),
                       PythonSourceInput(id: UUID(), source: "different = 1 <> 2\nawait fetch()\n")]
        let result = try await analyze(sources, helper: helper("namespace['main']()"))
        XCTAssertTrue(result.diagnostics.isEmpty)
    }

    func testSyntaxChecksCatchReturnOutsideFunction() async throws {
        let result = try await analyze([PythonSourceInput(id: UUID(), source: "return 42")],
                                       helper: helper("namespace['main']()"))
        XCTAssertEqual(result.diagnostics.first?.code, "SyntaxError")
        XCTAssertTrue(result.diagnostics.first?.message.contains("outside function") == true)
    }

    func testInlineMagicMultilineStringsAndModuloContinuations() async throws {
        let source = "%matplotlib inline\ntext = '''start\n%time should remain a string\n'''\nvalue = (10\n%len(text))\n"
        let result = try await analyze([PythonSourceInput(id: UUID(), source: source)],
                                       helper: helper("namespace['main']()"))
        XCTAssertTrue(result.diagnostics.isEmpty)
    }

    func testUnsupportedMagicsHaveAnExplicitLimitationAndKeepOtherCellsChecked() async throws {
        let first = PythonSourceInput(id: UUID(), source: "%%bash\necho hello\n")
        let second = PythonSourceInput(id: UUID(), source: "if True\n    pass\n")
        let result = try await analyze([first, second], helper: helper("namespace['main']()"))
        XCTAssertTrue(result.diagnostics.contains { $0.sourceID == first.id && $0.code == "IPYTHON" })
        XCTAssertTrue(result.diagnostics.contains { $0.sourceID == second.id && $0.code == "SyntaxError" })
        XCTAssertTrue(result.notice?.contains("cell-magic bodies are not checked") == true)
    }

    func testAnalysisIgnoresWorkspaceModulesThatShadowTheStandardLibrary() async throws {
        let directory = try temporaryDirectory()
        try "raise RuntimeError('workspace module was imported')".write(
            to: directory.appendingPathComponent("json.py"), atomically: true, encoding: .utf8)
        let result = try await analyze([PythonSourceInput(id: UUID(), source: "value = 1")],
                                       workingDirectory: directory)
        XCTAssertTrue(result.diagnostics.isEmpty)
    }

    func testRuffReceivesNotebookCellsAndUsesProjectConfiguration() async throws {
        let directory = try temporaryDirectory()
        let config = directory.appendingPathComponent("ruff.toml")
        try "line-length = 100\n".write(to: config, atomically: true, encoding: .utf8)
        let first = PythonSourceInput(id: UUID(), source: "data = [1, 2]\n")
        let second = PythonSourceInput(id: UUID(), source: "print(data, missing)\n")
        let fixture = try helper("namespace['main']()", mockedRuff: """
        assert '--no-fix' in arguments and '--no-fix-only' in arguments and '--no-cache' in arguments
        assert '--config' in arguments and arguments[-1] == '-'
        document = json.loads(source)
        assert document['cells'][0]['source'] == 'data = [1, 2]\\n'
        assert document['cells'][1]['source'] == 'print(data, missing)\\n'
        return 1, json.dumps([{'cell': 2, 'code': 'F821', 'message': 'Undefined name `missing`',
                              'location': {'row': 1, 'column': 13}, 'end_location': {'row': 1, 'column': 20}}]), ''
        """)
        let result = try await analyze([first, second], helper: fixture, workingDirectory: directory)
        XCTAssertEqual(result.toolName, "Ruff + Python syntax")
        XCTAssertEqual(result.diagnostics.count, 1)
        XCTAssertEqual(result.diagnostics.first?.sourceID, second.id)
        XCTAssertEqual(result.diagnostics.first?.column, 13)
        XCTAssertEqual(result.diagnostics.first?.severity, .error)
    }

    func testRuffDiagnosticsUseSwiftCharacterColumnsAfterEmojiAndCombiningMarks() async throws {
        let source = "text = '👩🏽‍💻é'; missing\n"
        let scalarColumn = source.unicodeScalars.distance(from: source.unicodeScalars.startIndex,
                                                        to: source.range(of: "missing")!.lowerBound) + 1
        let fixture = try helper("namespace['main']()", mockedRuff: """
        return 1, json.dumps([{'code': 'F821', 'message': 'Undefined name `missing`',
                              'location': {'row': 1, 'column': \(scalarColumn)},
                              'end_location': {'row': 1, 'column': \(scalarColumn + 7)}}]), ''
        """)
        let result = try await analyze([PythonSourceInput(id: UUID(), source: source)], helper: fixture)
        let column = source.distance(from: source.startIndex, to: source.range(of: "missing")!.lowerBound) + 1
        XCTAssertEqual(result.diagnostics.first?.column, column)
        XCTAssertEqual(result.diagnostics.first?.endColumn, column + 7)
    }

    func testRuffReceivesSingleCellNotebooksAsNotebooks() async throws {
        let fixture = try helper("namespace['main']()", mockedRuff: """
        assert arguments[arguments.index('--stdin-filename') + 1] == '__quanta__.ipynb'
        document = json.loads(source)
        assert len(document['cells']) == 1 and document['cells'][0]['source'] == 'display(1)'
        return 0, '[]', ''
        """)
        let result = try await analyze([PythonSourceInput(id: UUID(), source: "display(1)")],
                                       helper: fixture, isNotebook: true)
        XCTAssertEqual(result.toolName, "Ruff + Python syntax")
        XCTAssertTrue(result.diagnostics.isEmpty)
    }

    func testRuffAllowsTopLevelAwaitSupportedByTheRunner() async throws {
        let fixture = try helper("namespace['main']()", mockedRuff: """
        return 1, json.dumps([
            {'code': 'F704', 'message': 'await outside function',
             'location': {'row': 1, 'column': 1}, 'end_location': {'row': 1, 'column': 14}},
            {'code': 'PLE1142', 'message': 'await outside async function',
             'location': {'row': 1, 'column': 1}, 'end_location': {'row': 1, 'column': 14}},
            {'code': 'F821', 'message': 'Undefined name `fetch`',
             'location': {'row': 1, 'column': 7}, 'end_location': {'row': 1, 'column': 12}}
        ]), ''
        """)
        let result = try await analyze([PythonSourceInput(id: UUID(), source: "await fetch()")], helper: fixture)
        XCTAssertEqual(result.diagnostics.map(\.code), ["F821"])
    }

    func testRuffAdaptsPersistentFutureGrammarAndPreservesStringContents() async throws {
        let fixture = try helper("namespace['main']()", mockedRuff: """
        document = json.loads(source)
        assert document['cells'][1]['source'] == "different = 1 != 2\\ntext = '<>'"
        return 0, '[]', ''
        """)
        let result = try await analyze([
            PythonSourceInput(id: UUID(), source: "from __future__ import barry_as_FLUFL"),
            PythonSourceInput(id: UUID(), source: "different = 1 <> 2\ntext = '<>'"),
        ], helper: fixture)
        XCTAssertEqual(result.toolName, "Ruff + Python syntax")
        XCTAssertTrue(result.diagnostics.isEmpty)
    }

    func testPythonSyntaxResultsRemainAuthoritativeWhenRuffCannotParseASource() async throws {
        let fixture = try helper("namespace['main']()", mockedRuff: """
        return 1, json.dumps([
            {'cell': 1, 'code': 'invalid-syntax', 'message': 'Unsupported parser syntax',
             'location': {'row': 1, 'column': 1}, 'end_location': {'row': 1, 'column': 2}},
            {'cell': 2, 'code': 'invalid-syntax', 'message': 'Expected colon',
             'location': {'row': 1, 'column': 1}, 'end_location': {'row': 1, 'column': 2}},
            {'cell': 3, 'code': 'F821', 'message': 'Undefined name `missing`',
             'location': {'row': 1, 'column': 7}, 'end_location': {'row': 1, 'column': 14}}
        ]), ''
        """)
        let sources = [PythonSourceInput(id: UUID(), source: "value = 1"),
                       PythonSourceInput(id: UUID(), source: "if True\n    pass"),
                       PythonSourceInput(id: UUID(), source: "print(missing)")]
        let result = try await analyze(sources, helper: fixture)
        XCTAssertEqual(result.diagnostics.map(\.code), ["SyntaxError", "F821"])
        XCTAssertEqual(result.diagnostics.map(\.sourceID), [sources[1].id, sources[2].id])
        XCTAssertTrue(result.notice?.contains("could not be checked by Ruff") == true)
    }

    func testRuffKnowsQuantaDisplayFunctions() async throws {
        let fixture = try helper("namespace['main']()", mockedRuff: """
        return 1, json.dumps([
            {'code': 'F821', 'message': 'Undefined name `display`',
             'location': {'row': 1, 'column': 1}, 'end_location': {'row': 1, 'column': 8}},
            {'code': 'F821', 'message': 'Undefined name `clear_output`',
             'location': {'row': 2, 'column': 1}, 'end_location': {'row': 2, 'column': 13}}
        ]), ''
        """)
        let result = try await analyze([PythonSourceInput(id: UUID(), source: "display(1)\nclear_output()\n")], helper: fixture)
        XCTAssertEqual(result.toolName, "Ruff + Python syntax")
        XCTAssertTrue(result.diagnostics.isEmpty)
    }

    func testRuffFailureKeepsPythonSyntaxResults() async throws {
        let fixture = try helper("namespace['main']()", mockedRuff: "return 2, '', 'Invalid Ruff configuration'")
        let result = try await analyze([PythonSourceInput(id: UUID(), source: "value =\n")], helper: fixture)
        XCTAssertEqual(result.toolName, "Python syntax")
        XCTAssertEqual(result.diagnostics.first?.code, "SyntaxError")
        XCTAssertTrue(result.notice?.contains("Invalid Ruff configuration") == true)
    }

    func testFormattingReturnsRuffOutputAndExplainsMissingFormatter() async throws {
        let fixture = try helper("namespace['main']()", mockedRuff: """
        assert arguments[0] == 'format' and arguments[-1] == '-'
        assert source == 'value=1'
        return 0, 'value = 1\\n', ''
        """)
        let tooling = PythonTooling(helperURL: fixture)
        defer { tooling.cancel() }
        let formatted: String = try await withCheckedThrowingContinuation { continuation in
            tooling.format(source: "value=1", python: "/usr/bin/python3", workingDirectory: nil) {
                continuation.resume(with: $0)
            }
        }
        XCTAssertEqual(formatted, "value = 1\n")
        let missing = PythonTooling(helperURL: try helper("namespace['main']()"))
        defer { missing.cancel() }
        do {
            let _: String = try await withCheckedThrowingContinuation { continuation in
                missing.format(source: "value=1", python: "/usr/bin/python3", workingDirectory: nil) {
                    continuation.resume(with: $0)
                }
            }
            XCTFail("Formatting should explain that Ruff is unavailable")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Python Environment"))
        }
    }

    func testNotebookFormattingPreservesMagicCommands() async throws {
        let fixture = try helper("namespace['main']()", mockedRuff: """
        assert arguments[0] == 'format'
        assert arguments[arguments.index('--stdin-filename') + 1] == '__quanta__.ipynb'
        document = json.loads(source)
        assert document['cells'][0]['source'] == '%matplotlib inline\\nvalue=1'
        document['cells'][0]['source'] = ['%matplotlib inline\\n', 'value = 1']
        return 0, json.dumps(document), ''
        """)
        let tooling = PythonTooling(helperURL: fixture)
        defer { tooling.cancel() }
        let formatted: String = try await withCheckedThrowingContinuation { continuation in
            tooling.format(source: "%matplotlib inline\nvalue=1", python: "/usr/bin/python3",
                           workingDirectory: nil, isNotebook: true) {
                continuation.resume(with: $0)
            }
        }
        XCTAssertEqual(formatted, "%matplotlib inline\nvalue = 1")
    }

    func testOutputLimitAndTimeoutProduceUsefulErrors() async throws {
        let loud = try helper("sys.stdout.write('x' * 10000)")
        do {
            _ = try await analyze([], helper: loud, outputLimit: 100)
            XCTFail("Excessive output should be rejected")
        } catch {
            guard case PythonToolingError.outputLimit = error else { return XCTFail("\(error)") }
        }
        let slow = try helper("import time\ntime.sleep(5)")
        do {
            _ = try await analyze([], helper: slow, timeout: 0.2)
            XCTFail("Unresponsive analysis should time out")
        } catch {
            guard case PythonToolingError.timedOut = error else { return XCTFail("\(error)") }
        }
    }

    func testConcurrentDocumentChecksKeepTheirResponsesIndependent() async throws {
        let fixture = try helper("namespace['main']()")
        let sources = (0..<4).map { _ in PythonSourceInput(id: UUID(), source: "value = (\n") }
        async let first = analyze([sources[0]], helper: fixture)
        async let second = analyze([sources[1]], helper: fixture)
        async let third = analyze([sources[2]], helper: fixture)
        async let fourth = analyze([sources[3]], helper: fixture)
        let results = try await [first, second, third, fourth]
        for (source, result) in zip(sources, results) {
            XCTAssertEqual(result.diagnostics.count, 1)
            XCTAssertEqual(result.diagnostics.first?.sourceID, source.id)
        }
    }

    func testNewRequestsSuppressCancelledCallbacks() async throws {
        let fixture = try helper("import time\ntime.sleep(0.2)\nnamespace['main']()")
        let tooling = PythonTooling(helperURL: fixture)
        defer { tooling.cancel() }
        let stale = expectation(description: "Cancelled request")
        stale.isInverted = true
        let latest = expectation(description: "Latest request")
        tooling.analyze(sources: [PythonSourceInput(id: UUID(), source: "bad =")],
                        python: "/usr/bin/python3", workingDirectory: nil) { _ in stale.fulfill() }
        tooling.analyze(sources: [PythonSourceInput(id: UUID(), source: "valid = 1")],
                        python: "/usr/bin/python3", workingDirectory: nil) { result in
            XCTAssertTrue((try? result.get().diagnostics.isEmpty) == true)
            latest.fulfill()
        }
        await fulfillment(of: [latest, stale], timeout: 1)
    }
}
