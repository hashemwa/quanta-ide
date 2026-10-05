import SwiftUI

struct PythonEnvironmentPanel: View {
    @ObservedObject var manager: PythonEnvironmentManager
    let python: String?
    var version: String? = nil
    let workspace: URL?
    let trusted: Bool
    let kernelBusy: Bool
    let onEnvironmentCreated: (String) -> Void
    let onPackagesChanged: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.monoFontSize) private var monoFontSize
    @State private var query = ""
    @State private var requirements = ""
    @State private var showingOutput = false

    private struct Context: Hashable {
        let python: String?
        let workspace: URL?
        let trusted: Bool
        let kernelBusy: Bool
    }

    private var context: Context {
        Context(python: python, workspace: workspace, trusted: trusted, kernelBusy: kernelBusy)
    }

    private var visiblePackages: [PythonPackage] {
        manager.packages.filter {
            query.isEmpty || $0.name.localizedStandardContains(query) || $0.version.localizedStandardContains(query)
        }
    }

    private var canManage: Bool {
        manager.canManage && trusted && !kernelBusy && manager.python == python
            && manager.workspace == workspace?.standardizedFileURL
    }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader("Python Environment", systemImage: "shippingbox", height: DS.Bar.primary) {
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(manager.isBusy)
            }
            Divider()
            interpreter
            Divider()
            workspaceEnvironment
            Divider()
            installation
            operationStatus
            Divider()
            PanelHeader("Installed Packages", systemImage: "shippingbox") {
                if manager.hasLoadedPackages {
                    Text(manager.packages.count.formatted()).font(.caption).foregroundStyle(.secondary)
                }
            }
            packageList
            FilterBar(text: $query, prompt: "Filter Packages") {
                FilterBarButton("arrow.clockwise", help: "Refresh Installed Packages", busy: manager.operation == .listing) {
                    Task { await manager.refreshPackages() }
                }
                .disabled(!canManage)
            }
        }
        .frame(width: DS.Layout.paletteWidth, height: DS.Layout.outputMaxHeight)
        .interactiveDismissDisabled(manager.isBusy)
        .task(id: context) {
            manager.configure(python: python, workspace: workspace, trusted: trusted, kernelBusy: kernelBusy)
            while manager.isBusy && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard !Task.isCancelled else { return }
            if manager.canManage && !manager.hasLoadedPackages { await manager.refreshPackages() }
        }
        .onDisappear { manager.cancel() }
    }

    private var interpreter: some View {
        VStack(alignment: .leading, spacing: DS.Space.xs) {
            Text(version.flatMap { $0.isEmpty ? nil : "Python \($0)" } ?? "Selected Interpreter")
                .font(.subheadline.weight(.semibold))
            Text(python ?? "Choose a Python interpreter from the Python menu.")
                .font(.system(size: monoFontSize, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .textSelection(.enabled)
                .help(python ?? "No Python interpreter selected")
            if !trusted {
                Label("Trust this workspace to manage Python environments.", systemImage: "lock")
                    .font(.caption).foregroundStyle(.secondary)
            } else if kernelBusy {
                Text("Wait for running code to finish before managing packages.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(DS.Space.l)
    }

    private var workspaceEnvironment: some View {
        HStack(spacing: DS.Space.l) {
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text("Workspace Environment").font(.subheadline.weight(.semibold))
                Text(workspaceDescription).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: DS.Space.s)
            Button("Create .venv") {
                Task {
                    if let interpreter = await manager.createEnvironment() { onEnvironmentCreated(interpreter) }
                }
            }
            .disabled(!canManage || workspace == nil || manager.workspaceEnvironmentExists)
            .help("Create Python Environment in Workspace")
        }
        .padding(DS.Space.l)
    }

    private var workspaceDescription: String {
        guard let workspace else { return "Open a workspace folder to create an environment." }
        if manager.workspaceEnvironmentExists { return "\(workspace.lastPathComponent) already contains a .venv." }
        return "Keep this project’s packages in \(workspace.lastPathComponent)/.venv."
    }

    private var installation: some View {
        VStack(alignment: .leading, spacing: DS.Space.s) {
            Text("Install Packages").font(.subheadline.weight(.semibold))
            HStack(spacing: DS.Space.s) {
                TextField("pandas numpy matplotlib", text: $requirements)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(install)
                    .disabled(!canManage)
                    .accessibilityLabel("Packages to install")
                Button("Install", action: install)
                    .disabled(!canManage || requirements.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .help("Install Packages into Selected Python")
            }
            Text("Separate packages with spaces. Version constraints are supported, such as pandas>=2,<3.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(DS.Space.l)
    }

    @ViewBuilder
    private var operationStatus: some View {
        if manager.operation != nil || manager.errorMessage != nil || manager.statusMessage != nil || !manager.commandOutput.isEmpty {
            VStack(alignment: .leading, spacing: DS.Space.s) {
                if let operation = manager.operation {
                    HStack(spacing: DS.Space.s) {
                        ProgressView().controlSize(.small)
                        Text(operation.title).font(.subheadline)
                        Spacer(minLength: DS.Space.s)
                        Button("Cancel") { manager.cancel() }
                    }
                }
                if let error = manager.errorMessage {
                    Label {
                        Text(error).textSelection(.enabled).lineLimit(4).help(error)
                    } icon: {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(DS.StatusColors.warning)
                    }
                    .font(.caption)
                } else if let status = manager.statusMessage {
                    Text(status).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                if !manager.commandOutput.isEmpty {
                    DisclosureGroup("Output", isExpanded: $showingOutput) {
                        ScrollView {
                            Text(manager.commandOutput)
                                .font(.system(size: monoFontSize, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: DS.Layout.consoleMinHeight)
                    }
                    .font(.caption)
                }
            }
            .padding(.horizontal, DS.Space.l)
            .padding(.bottom, DS.Space.l)
        }
    }

    @ViewBuilder
    private var packageList: some View {
        if manager.hasLoadedPackages && !manager.packages.isEmpty {
            List(visiblePackages) { package in
                HStack(spacing: DS.Space.s) {
                    Text(package.name).font(.system(size: monoFontSize, design: .monospaced))
                    Spacer(minLength: DS.Space.s)
                    Text(package.version).font(.caption).foregroundStyle(.secondary)
                }
                .textSelection(.enabled)
            }
            .listStyle(.inset)
            .overlay {
                if visiblePackages.isEmpty {
                    NavigatorEmptyState("No Matching Packages", systemImage: "magnifyingglass", detail: "Try another package name.") {
                        Button("Clear Filter") { query = "" }
                    }
                }
            }
        } else if manager.operation == .listing {
            Spacer(minLength: 0)
        } else {
            NavigatorEmptyState(manager.hasLoadedPackages ? "No Installed Packages" : "Packages Unavailable",
                                systemImage: "shippingbox", detail: packageListDescription)
        }
    }

    private var packageListDescription: String {
        if manager.hasLoadedPackages { return "Install packages to use them in this Python environment." }
        if !trusted { return "Trust this workspace, then refresh the package list." }
        if python == nil { return "Choose a Python interpreter, then refresh the package list." }
        if kernelBusy { return "The package list will load when running code finishes." }
        return "Refresh to load packages from the selected Python interpreter."
    }

    private func install() {
        guard canManage, !requirements.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let input = requirements
        Task {
            if await manager.installPackages(input) {
                requirements = ""
                onPackagesChanged()
                await manager.refreshPackages()
            }
        }
    }
}
