import Foundation

enum WorkspaceTrust {
    static let workspacesKey = "QuantaTrustedWorkspaces"
    static let interpretersKey = "QuantaTrustedInterpreters"

    static func path(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func contains(_ url: URL, defaults: UserDefaults = QuantaDefaults.store) -> Bool {
        (defaults.stringArray(forKey: workspacesKey) ?? []).contains(path(url))
    }

    static func grant(_ url: URL, defaults: UserDefaults = QuantaDefaults.store) {
        var paths = Set(defaults.stringArray(forKey: workspacesKey) ?? [])
        paths.insert(path(url))
        defaults.set(paths.sorted(), forKey: workspacesKey)
    }

    static func allows(_ environment: PythonEnvironment, workspace: URL?,
                       defaults: UserDefaults = QuantaDefaults.store) -> Bool {
        if let workspace, !contains(workspace, defaults: defaults) { return false }
        if environment.kind != .custom { return true }
        let executable = URL(fileURLWithPath: environment.executable)
        let trusted = defaults.stringArray(forKey: interpretersKey) ?? []
        return trusted.contains(path(executable))
    }

    static func grantInterpreter(_ executable: String, defaults: UserDefaults = QuantaDefaults.store) {
        var paths = Set(defaults.stringArray(forKey: interpretersKey) ?? [])
        paths.insert(path(URL(fileURLWithPath: executable)))
        defaults.set(paths.sorted(), forKey: interpretersKey)
    }
}

struct KernelTransition {
    let workspace: URL?
    let python: String
    let rememberInterpreter: Bool
}

extension AppState {
    var isWorkspaceTrusted: Bool {
        workspace.map { WorkspaceTrust.contains($0.rootURL) } ?? true
    }

    func requestWorkspaceTrust() {
        workspaceTrustRequest = workspace?.rootURL
    }

    func trustWorkspace(_ url: URL) {
        guard workspace?.rootURL == url else { return }
        WorkspaceTrust.grant(url)
        workspaceTrustRequest = nil
        refreshEnvironments()
        synchronizeWorkspaceKernel()
    }

    func allowExecution() -> Bool {
        guard isWorkspaceTrusted else {
            requestWorkspaceTrust()
            return false
        }
        return kernelTransition == nil
    }

    func synchronizeWorkspaceKernel() {
        guard isWorkspaceTrusted else { return }
        let allowed = environments.filter { WorkspaceTrust.allows($0, workspace: workspace?.rootURL) }
        guard let python = allowed.first(where: { $0.kind == .workspace })?.executable
            ?? pythonPath.flatMap({ path in allowed.first { $0.executable == path }?.executable })
            ?? PythonLocator.preferred(from: allowed)?.executable else { return }
        if kernel.isRunning {
            let directory = workspace?.rootURL ?? FileManager.default.homeDirectoryForCurrentUser
            if kernel.workingDirectory.map(WorkspaceTrust.path) != WorkspaceTrust.path(directory)
                || kernel.executable != python {
                kernelTransition = KernelTransition(workspace: workspace?.rootURL, python: python,
                                                    rememberInterpreter: false)
            }
        } else {
            pythonPath = python
            startKernelIfNeeded()
        }
    }

    func applyKernelTransition(_ transition: KernelTransition) {
        guard transition.workspace == workspace?.rootURL, isWorkspaceTrusted else { return }
        kernelTransition = nil
        guard FileManager.default.isExecutableFile(atPath: transition.python) else {
            userNotice = "The selected Python interpreter is no longer executable. The current session was kept."
            return
        }
        if transition.rememberInterpreter {
            WorkspaceTrust.grantInterpreter(transition.python)
            QuantaDefaults.store.set(transition.python, forKey: PythonLocator.defaultsKey)
        }
        cancelPendingRunAll()
        pythonPath = transition.python
        restartKernel(confirm: false)
    }

    func keepKernelSession() {
        kernelTransition = nil
        appendConsole(.system, "Keeping the current Python session in \(kernel.workingDirectory?.path ?? "an unknown directory").")
    }

    var executionDirectoryLabel: String {
        guard kernel.isRunning else { return "No running session" }
        return kernel.workingDirectory?.path ?? "Unavailable"
    }

    var kernelUsesDifferentDirectory: Bool {
        guard kernel.isRunning, let workspace else { return false }
        return kernel.workingDirectory.map(WorkspaceTrust.path) != WorkspaceTrust.path(workspace.rootURL)
    }
}
