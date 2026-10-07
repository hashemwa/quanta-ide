import AppKit
import Darwin
import XCTest
@testable import Quanta

@MainActor
final class CrashResilienceTests: XCTestCase {
    func testMalformedDataFrameDimensionsFallBackWithoutLosingSavedOutput() throws {
        let invalid: [(String, Int)] = [
            ("head_count", Int.min), ("head_count", Int.max),
            ("offset", -1), ("offset", Int.max),
            ("total_rows", -1), ("total_cols", -1),
        ]
        for (field, value) in invalid {
            var payload: [String: Any] = [
                "columns": ["value"], "rows": [["42"]],
                "rows_truncated": true, "head_count": 1,
            ]
            payload[field] = value
            XCTAssertNil(DataFramePayload(dict: payload), field)
            let notebook = try Notebook.load(from: JSONSerialization.data(withJSONObject: [
                "nbformat": 4, "nbformat_minor": 5, "metadata": [:],
                "cells": [["cell_type": "code", "source": "frame", "metadata": [:],
                           "outputs": [["output_type": "display_data", "metadata": [:],
                                        "data": [RichOutput.dataframeMIME: payload,
                                                 "text/plain": "Stored table preview"]]]]],
            ] as [String: Any]))
            let output = try XCTUnwrap(notebook.cells.first?.outputs.first)
            guard case .executeResult(let text) = output.kind else {
                return XCTFail("Expected the safe text fallback for \(field)")
            }
            XCTAssertEqual(text, "Stored table preview")
            let restored = try Notebook.load(from: notebook.serializedData())
            let raw = restored.cells.first?.outputs.first?.raw?["data"] as? [String: Any]
            XCTAssertEqual((raw?[RichOutput.dataframeMIME] as? [String: Any])?[field] as? Int, value)
        }
    }

    func testTruncatedTableRejectsNegativeAndStaleRows() throws {
        let payload = try XCTUnwrap(DataFramePayload(dict: [
            "columns": ["value"], "rows": [["first"], ["last"]],
            "index": ["0", "99"], "rows_truncated": true,
            "head_count": 1, "total_rows": 100,
        ]))
        let coordinator = DataFrameNSTable.Coordinator()
        coordinator.payload = payload
        XCTAssertNil(coordinator.dataRow(forTableRow: -1))
        XCTAssertNil(coordinator.dataRow(forTableRow: Int.min))
        XCTAssertNil(coordinator.dataRow(forTableRow: Int.max))
        XCTAssertEqual(coordinator.dataRow(forTableRow: 0), 0)
        XCTAssertNil(coordinator.dataRow(forTableRow: 1))
        XCTAssertEqual(coordinator.dataRow(forTableRow: 2), 1)
        XCTAssertNil(coordinator.dataRow(forTableRow: 3))
        XCTAssertEqual(coordinator.rowValues(payload, dataRow: -1), [])
        XCTAssertEqual(coordinator.rowValues(payload, dataRow: 2), [])
        XCTAssertEqual(coordinator.rowValues(payload, dataRow: 1), ["99", "last"])
        coordinator.payload = DataFramePayload(dict: ["columns": ["value"], "rows": [["only"]]])
        XCTAssertNil(coordinator.dataRow(forTableRow: 2))
        XCTAssertNil(coordinator.tableView(NSTableView(), rowViewForRow: -1))
    }

    func testOriginalDataFrameValuesRejectOverflowingCoordinates() throws {
        let payload = try XCTUnwrap(DataFramePayload(dict: [
            "columns": ["value"], "rows": [["42"]],
            "original_rows": [["42"]], "original_index": ["0"],
        ]))
        XCTAssertNil(payload.originalValue(row: 0, column: Int.min))
        XCTAssertNil(payload.originalValue(row: Int.min, column: 1))
        XCTAssertNil(payload.originalValue(row: Int.max, column: 0))
        XCTAssertNil(payload.originalValue(row: 0, column: Int.max))
        XCTAssertEqual(payload.originalValue(row: 0, column: 1), "42")
    }

    func testKernelFramingDropsOversizedUnterminatedOutputAndResumes() {
        let framer = KernelSession.LineFramer(maximumLineBytes: 128)
        var notices: [String] = []
        for _ in 0..<100 {
            notices += framer.consume(Data(repeating: 65, count: 97)).compactMap {
                if case .stray(let text) = $0 { return text }
                return nil
            }
        }
        XCTAssertEqual(notices.count, 1)
        XCTAssertTrue(notices.first?.contains("skipped") == true)
        let result = framer.consume(Data("\n{\"type\":\"done\",\"status\":\"ok\"}\n".utf8))
        XCTAssertEqual(result.count, 1)
        guard let first = result.first, case .message(let message) = first else {
            return XCTFail("Expected framing to recover")
        }
        XCTAssertEqual(message["type"] as? String, "done")
    }

    func testKernelFramingSkipsOversizedCompleteJSONAndKeepsNextMessage() {
        let framer = KernelSession.LineFramer(maximumLineBytes: 128)
        let oversized = "{\"type\":\"stream\",\"text\":\"" + String(repeating: "x", count: 200) + "\"}\n"
        let result = framer.consume(Data((oversized + "{\"type\":\"ready\"}\n").utf8))
        XCTAssertEqual(result.count, 2)
        guard let first = result.first, let last = result.last,
              case .stray(let notice) = first,
              case .message(let message) = last else { return XCTFail("Expected a notice and the next message") }
        XCTAssertTrue(notice.contains("skipped"))
        XCTAssertEqual(message["type"] as? String, "ready")
    }

    func testKernelFramingPreservesUTF8AcrossSmallChunks() {
        let framer = KernelSession.LineFramer(maximumLineBytes: 128)
        let wire = Data("\n{\"type\":\"result\",\"text\":\"你好 🐍\"}\n".utf8)
        var result: [KernelSession.LineFramer.Item] = []
        for start in stride(from: 0, to: wire.count, by: 3) {
            result += framer.consume(wire.subdata(in: start..<min(start + 3, wire.count)))
        }
        XCTAssertEqual(result.count, 1)
        guard let first = result.first, case .message(let message) = first else {
            return XCTFail("Expected one complete message")
        }
        XCTAssertEqual(message["text"] as? String, "你好 🐍")
    }

    func testStoppingKernelKillsAProcessThatIgnoresTermination() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let script = directory.appendingPathComponent("ignores_termination.py")
        try "import json, os, signal, time\nsignal.signal(signal.SIGTERM, signal.SIG_IGN)\nprint(json.dumps({'type': 'ready', 'pid': os.getpid()}), flush=True)\nwhile True:\n    time.sleep(1)\n".write(to: script, atomically: true, encoding: .utf8)
        let kernel = KernelSession()
        defer { kernel.stop() }
        kernel.start(python: "/usr/bin/python3", scriptURL: script, workingDirectory: directory)
        try await waitUntil { kernel.status == .idle }
        let pid = try XCTUnwrap(kernel.readyInfo?["pid"] as? Int32)
        defer { if Darwin.kill(pid, 0) == 0 { Darwin.kill(pid, SIGKILL) } }
        kernel.stop()
        XCTAssertEqual(kernel.status, .stopped)
        try await waitUntil { Darwin.kill(pid, 0) != 0 && errno == ESRCH }
    }

    func testTerminalStopAndForceStopFinishACommandIgnoringHangup() async throws {
        for force in [false, true] {
            let session = TerminalSession()
            var output = ""
            session.onOutput = { output += String(decoding: $0, as: UTF8.self) }
            session.start(in: FileManager.default.temporaryDirectory, shell: "/bin/sh")
            defer { session.stop(force: true) }
            session.send("stty -echo; trap '' HUP; printf 'QUANTA_STUBBORN_%s\\n' READY; while :; do :; done\n")
            try await waitUntil { output.contains("QUANTA_STUBBORN_READY") }
            session.stop(force: force)
            try await waitUntil { !session.running }
            XCTAssertNotNil(session.exitStatus)
        }
    }

    func testTerminalStopKillsForegroundJobAfterItsShellExits() async throws {
        let session = TerminalSession()
        var output = ""
        var foreground: Int32?
        session.onOutput = {
            output += String(decoding: $0, as: UTF8.self)
            for line in output.split(whereSeparator: \.isNewline) where line.hasPrefix("QUANTA_FOREGROUND_") {
                if let pid = Int32(line.dropFirst("QUANTA_FOREGROUND_".count)) { foreground = pid }
            }
        }
        session.start(in: FileManager.default.temporaryDirectory, shell: "/bin/sh")
        defer { session.stop(force: true) }
        session.send("stty -echo; /bin/sh -c 'trap \"\" HUP; printf \"QUANTA_FOREGROUND_%s\\n\" $$; while :; do :; done'\n")
        try await waitUntil { foreground != nil }
        let pid = try XCTUnwrap(foreground)
        defer { if Darwin.kill(pid, 0) == 0 { Darwin.kill(-pid, SIGKILL) } }
        session.stop()
        try await waitUntil { Darwin.kill(pid, 0) != 0 && errno == ESRCH }
        XCTAssertFalse(session.running)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<250 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Timed out waiting for kernel cleanup")
        throw NSError(domain: "CrashResilienceTests", code: 1)
    }
}
