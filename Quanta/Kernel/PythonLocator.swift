import Foundation

struct PythonEnvironment: Identifiable, Hashable {
    enum Kind: Int {
        case workspace, conda, pyenv, homebrew, system, custom
    }

    let executable: String
    let kind: Kind
    let name: String
    var id: String { executable }
}

enum PythonLocator {
    static let defaultsKey = "QuantaPythonPath"

    static func discover(workspace: URL?,
                         home: URL = FileManager.default.homeDirectoryForCurrentUser)
        -> [PythonEnvironment] {
        let fm = FileManager.default
        var environments: [PythonEnvironment] = []
        var seen = Set<String>()

        func add(_ executable: String, _ kind: PythonEnvironment.Kind, _ name: String) {
            guard !seen.contains(executable), fm.isExecutableFile(atPath: executable) else { return }
            seen.insert(executable)
            environments.append(PythonEnvironment(executable: executable, kind: kind, name: name))
        }

        func addPrefix(_ dir: URL, kind: PythonEnvironment.Kind, name: String) {
            for candidate in ["bin/python3", "bin/python"] {
                let exe = dir.appendingPathComponent(candidate).path
                if fm.isExecutableFile(atPath: exe) {
                    add(exe, kind, name)
                    return
                }
            }
        }

        if let ws = workspace {
            for venv in [".venv", "venv", "env"] {
                addPrefix(ws.appendingPathComponent(venv), kind: .workspace, name: venv)
            }
        }

        let registry = home.appendingPathComponent(".conda/environments.txt")
        if let text = try? String(contentsOf: registry, encoding: .utf8) {
            for line in text.split(separator: "\n") {
                let path = line.trimmingCharacters(in: .whitespaces)
                guard !path.isEmpty else { continue }
                let url = URL(fileURLWithPath: path)
                let isNamedEnv = url.deletingLastPathComponent().lastPathComponent == "envs"
                addPrefix(url, kind: .conda,
                          name: isNamedEnv ? url.lastPathComponent : "base (\(url.lastPathComponent))")
            }
        }

        for root in ["miniforge3", "miniconda3", "anaconda3", "mambaforge", "micromamba"] {
            let rootURL = home.appendingPathComponent(root)
            addPrefix(rootURL, kind: .conda, name: "base (\(root))")
            let envsDir = rootURL.appendingPathComponent("envs")
            if let names = try? fm.contentsOfDirectory(atPath: envsDir.path) {
                for name in names.sorted() {
                    addPrefix(envsDir.appendingPathComponent(name), kind: .conda, name: name)
                }
            }
        }

        let pyenvVersions = home.appendingPathComponent(".pyenv/versions")
        if let names = try? fm.contentsOfDirectory(atPath: pyenvVersions.path) {
            for name in names.sorted() {
                addPrefix(pyenvVersions.appendingPathComponent(name), kind: .pyenv, name: name)
            }
        }

        add("/opt/homebrew/bin/python3", .homebrew, "Homebrew")
        add("/usr/local/bin/python3", .homebrew, "Homebrew (Intel)")
        add("/usr/bin/python3", .system, "System")

        if let stored = QuantaDefaults.store.string(forKey: defaultsKey) {
            add(stored, .custom, URL(fileURLWithPath: stored).lastPathComponent)
        }
        return environments
    }

    static func preferred(from environments: [PythonEnvironment]) -> PythonEnvironment? {
        if let ws = environments.first(where: { $0.kind == .workspace }) { return ws }
        if let stored = QuantaDefaults.store.string(forKey: defaultsKey),
           let env = environments.first(where: { $0.executable == stored }) {
            return env
        }
        if let base = environments.first(where: { $0.kind == .conda && $0.name.hasPrefix("base") }) {
            return base
        }
        return environments.first
    }

    static func probeVersion(_ executable: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = ["--version"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do { try proc.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0,
              let text = String(data: data, encoding: .utf8) else { return nil }
        return text.split(separator: " ").last
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}
