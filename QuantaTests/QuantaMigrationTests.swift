import XCTest
@testable import Quanta

final class QuantaMigrationTests: XCTestCase {
    func testSettingsMigrateWithoutOverwritingAndOnlyOnce() throws {
        let name = "quanta.migration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(false, forKey: "QuantaShowConsole")
        let legacy: [String: Any] = [
            "VortexShowConsole": true,
            "VortexPythonPath": "/example/bin/python3",
            "VortexRecentFiles": ["/example/notebook.ipynb"],
            "NSWindow Frame VortexMainWindow": "10 20 800 600",
            "Unrelated": "ignored",
        ]
        QuantaDefaults.migrateLegacySettings(into: defaults, legacy: legacy)
        XCTAssertFalse(defaults.bool(forKey: "QuantaShowConsole"))
        XCTAssertEqual(defaults.string(forKey: "QuantaPythonPath"), "/example/bin/python3")
        XCTAssertEqual(defaults.stringArray(forKey: "QuantaRecentFiles"), ["/example/notebook.ipynb"])
        XCTAssertEqual(defaults.string(forKey: "NSWindow Frame QuantaMainWindow"), "10 20 800 600")
        XCTAssertNil(defaults.object(forKey: "Unrelated"))
        defaults.removeObject(forKey: "QuantaPythonPath")
        QuantaDefaults.migrateLegacySettings(into: defaults, legacy: legacy)
        XCTAssertNil(defaults.object(forKey: "QuantaPythonPath"))
    }

    func testDraftMigrationPreservesOriginalsAndNewerQuantaDrafts() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("quanta-migration-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: root) }
        let legacy = root.appendingPathComponent("Vortex/Drafts")
        try manager.createDirectory(at: legacy, withIntermediateDirectories: true)
        let old = legacy.appendingPathComponent("example.py")
        try Data("original".utf8).write(to: old)
        let current = QuantaStorage.draftsDirectory(applicationSupport: root)
        XCTAssertEqual(current, root.appendingPathComponent("Quanta/Drafts", isDirectory: true))
        let copied = current.appendingPathComponent("example.py")
        XCTAssertEqual(try Data(contentsOf: copied), Data("original".utf8))
        XCTAssertEqual(try Data(contentsOf: old), Data("original".utf8))
        try Data("newer".utf8).write(to: copied)
        _ = QuantaStorage.draftsDirectory(applicationSupport: root)
        XCTAssertEqual(try Data(contentsOf: copied), Data("newer".utf8))
    }

    func testDraftMigrationFallsBackIfDestinationCannotBeCreated() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("quanta-migration-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: root) }
        let legacy = root.appendingPathComponent("Vortex/Drafts", isDirectory: true)
        try manager.createDirectory(at: legacy, withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("Quanta"))
        XCTAssertEqual(QuantaStorage.draftsDirectory(applicationSupport: root), legacy)
    }
}
