import Foundation

enum QuantaDefaults {
    static var previewDirectory: URL? {
        #if DEBUG
        return ProcessInfo.processInfo.environment["QUANTA_UI_PREVIEW_DIRECTORY"].map {
            URL(fileURLWithPath: $0, isDirectory: true).resolvingSymlinksInPath()
        }
        #else
        return nil
        #endif
    }

    private static let testSuiteName = "quanta.tests"

    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    static let store: UserDefaults = {
        if previewDirectory != nil {
            let name = "quanta.ui-preview.\(ProcessInfo.processInfo.processIdentifier)"
            return UserDefaults(suiteName: name)!
        }
        guard isRunningTests, let suite = UserDefaults(suiteName: testSuiteName) else {
            let defaults = UserDefaults.standard
            migrateLegacySettings(into: defaults,
                                  legacy: defaults.persistentDomain(forName: "nativeviz.Vortex") ?? [:])
            return defaults
        }
        suite.removePersistentDomain(forName: testSuiteName)
        return suite
    }()
    static func migrateLegacySettings(into defaults: UserDefaults, legacy: [String: Any]) {
        let marker = "QuantaLegacySettingsMigrated"
        guard !defaults.bool(forKey: marker) else { return }
        for (key, value) in legacy {
            let renamed: String
            if key.hasPrefix("Vortex") {
                renamed = "Quanta" + key.dropFirst("Vortex".count)
            } else if key == "NSWindow Frame VortexMainWindow" {
                renamed = "NSWindow Frame QuantaMainWindow"
            } else {
                continue
            }
            if defaults.object(forKey: renamed) == nil {
                defaults.set(value, forKey: renamed)
            }
        }
        defaults.set(true, forKey: marker)
    }
}
