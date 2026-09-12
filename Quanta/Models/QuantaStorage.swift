import Foundation

enum QuantaStorage {
    static func draftsDirectory(applicationSupport: URL) -> URL {
        let manager = FileManager.default
        let current = applicationSupport.appendingPathComponent("Quanta/Drafts", isDirectory: true)
        let legacy = applicationSupport.appendingPathComponent("Vortex/Drafts", isDirectory: true)
        if !manager.fileExists(atPath: current.path), manager.fileExists(atPath: legacy.path) {
            let staging = current.deletingLastPathComponent()
                .appendingPathComponent("Drafts-migration-\(UUID().uuidString)", isDirectory: true)
            do {
                try manager.createDirectory(at: current.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
                try manager.copyItem(at: legacy, to: staging)
                try manager.moveItem(at: staging, to: current)
            } catch {
                try? manager.removeItem(at: staging)
                return legacy
            }
        }
        try? manager.createDirectory(at: current, withIntermediateDirectories: true)
        return current
    }
}
