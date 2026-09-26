import Foundation

struct FileNode: Identifiable, Hashable {
    let url: URL
    let name: String
    let isDirectory: Bool
    var children: [FileNode]?
    var id: URL { url }

    var iconName: String {
        isDirectory ? "folder" : FileNode.iconName(forExtension: url.pathExtension)
    }

    static func iconName(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "py": return "curlybraces"
        case "ipynb": return "text.book.closed"
        case "csv", "tsv", "parquet", "feather": return "tablecells"
        case "json", "yaml", "yml", "toml": return "curlybraces.square"
        case "md", "rst", "txt": return "doc.plaintext"
        case "png", "jpg", "jpeg", "gif", "svg", "pdf": return "photo"
        default: return "doc"
        }
    }
}

struct Workspace {
    let rootURL: URL
    var root: FileNode

    private static let ignored: Set<String> = [
        "__pycache__", "node_modules", "venv", "build", "dist",
    ]

    static func load(url: URL, showsHiddenFiles: Bool = false) -> Workspace {
        Workspace(rootURL: url, root: buildNode(url: url, depth: 0,
                                                showsHiddenFiles: showsHiddenFiles, ancestorPaths: []))
    }

    private static func buildNode(url: URL, depth: Int, showsHiddenFiles: Bool,
                                  ancestorPaths: Set<String>) -> FileNode {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        fm.fileExists(atPath: url.path, isDirectory: &isDir)
        guard isDir.boolValue else {
            return FileNode(url: url, name: url.lastPathComponent, isDirectory: false, children: nil)
        }
        var children: [FileNode] = []
        let canonicalPath = url.resolvingSymlinksInPath().standardizedFileURL.path
        if depth < 12, !ancestorPaths.contains(canonicalPath),
           let items = try? fm.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: showsHiddenFiles ? [] : [.skipsHiddenFiles]) {
            for item in items where !ignored.contains(item.lastPathComponent)
                && !item.lastPathComponent.hasSuffix(".egg-info") {
                children.append(buildNode(url: item, depth: depth + 1,
                                          showsHiddenFiles: showsHiddenFiles,
                                          ancestorPaths: ancestorPaths.union([canonicalPath])))
            }
        }
        children.sort { a, b in
            if a.isDirectory != b.isDirectory { return a.isDirectory }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        return FileNode(url: url, name: url.lastPathComponent, isDirectory: true, children: children)
    }
}
