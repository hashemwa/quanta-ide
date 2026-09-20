import AppKit
import SwiftUI

struct MainWindowView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .toolbar(removing: .sidebarToggle)
                .toolbar { navigatorToolbar }
                .navigationSplitViewColumnWidth(min: DS.Layout.sidebarMin,
                                                ideal: DS.Layout.sidebarIdeal,
                                                max: DS.Layout.sidebarMax)
        } detail: {
            DetailSplitView()
                .navigationSplitViewColumnWidth(min: DS.Layout.editorPaneMin,
                                                ideal: DS.Layout.editorColumnIdeal)
        }
        .inspector(isPresented: Binding(get: { app.showVariables },
                                        set: { app.setVariablesVisible($0) })) {
            Group {
                if let session = app.activeDocument?.dataSession { DataColumnInspector(session: session) }
                else { VariablesPanel() }
            }
                .toolbar { inspectorToolbar }
                .inspectorColumnWidth(min: DS.Layout.inspectorMin,
                                      ideal: DS.Layout.inspectorIdeal,
                                      max: DS.Layout.inspectorMax)
        }
        .modifier(LanguageNavigationPresentation(service: app.language))
        .navigationTitle(windowTitle)
        .navigationSubtitle(windowSubtitle)
        .sheet(item: $app.paletteMode) { mode in
            CommandPalette(mode: mode).environmentObject(app)
        }
        .onAppear { app.bootstrap() }
        .alert("Trust this workspace?", isPresented: Binding(
            get: { app.workspaceTrustRequest != nil },
            set: { if !$0 { app.workspaceTrustRequest = nil } }
        ), presenting: app.workspaceTrustRequest) { url in
            Button("Trust and Enable Python") { app.trustWorkspace(url) }
            Button("Browse Without Running", role: .cancel) { app.workspaceTrustRequest = nil }
        } message: { url in
            Text("Trusting \(url.path) allows Quanta to probe and launch its Python environments and run code. Only trust folders whose contents and source you trust.")
        }
        .alert("Change Python session?", isPresented: Binding(
            get: { app.kernelTransition != nil },
            set: { if !$0 { app.kernelTransition = nil } }
        ), presenting: app.kernelTransition) { transition in
            Button("Restart in Workspace", role: .destructive) { app.applyKernelTransition(transition) }
            Button("Keep Current Session", role: .cancel) { app.keepKernelSession() }
        } message: { transition in
            Text("Restarting clears all Python variables and stops current work.\n\nInterpreter: \(transition.python)\nDirectory: \(transition.workspace?.path ?? FileManager.default.homeDirectoryForCurrentUser.path)\n\nThe current session uses: \(app.executionDirectoryLabel)")
        }
        .onChange(of: colorScheme) { _, _ in app.pushAppearance() }
        .onChange(of: app.sidebarRevealRequest) { _, _ in
            if columnVisibility == .detailOnly {
                withAnimation(reduceMotion ? nil : DS.Motion.quick) { columnVisibility = .all }
            }
        }
    }

    private var windowTitle: String {
        app.activeDocument?.displayName
            ?? app.workspace?.rootURL.lastPathComponent
            ?? "Quanta"
    }

    private var windowSubtitle: String {
        guard app.activeDocument != nil, let root = app.workspace?.rootURL else { return "" }
        return root.lastPathComponent
    }

    @ToolbarContentBuilder
    private var navigatorToolbar: some ToolbarContent {
        ToolbarItem(placement: .automatic) { NavigatorToggle(columnVisibility: $columnVisibility) }
        if #available(macOS 26.0, *) { ToolbarSpacer(.flexible) }
        ToolbarItemGroup(placement: .primaryAction) { RunControls() }
    }

    @ToolbarContentBuilder
    private var inspectorToolbar: some ToolbarContent {
        if #available(macOS 26.0, *) { ToolbarSpacer(.flexible) }
        ToolbarItem(placement: .primaryAction) {
            Button { app.toggleVariables() } label: {
                Label("Variables", systemImage: "sidebar.trailing")
            }
            .help(app.showVariables ? "Hide Variables (⌥⌘0)" : "Show Variables (⌥⌘0)")
        }
    }
}

struct NavigatorToggle: View {
    @Binding var columnVisibility: NavigationSplitViewVisibility
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button {
            withAnimation(reduceMotion ? nil : DS.Motion.quick) {
                columnVisibility = columnVisibility == .detailOnly ? .all : .detailOnly
            }
        } label: {
            Label("Navigator", systemImage: "sidebar.leading")
        }
        .help(columnVisibility == .detailOnly ? "Show Navigator (⌃⌘S)" : "Hide Navigator (⌃⌘S)")
    }
}

struct RunControls: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        Button { app.runActiveDocument() } label: {
            Label(app.runCommandTitle, systemImage: app.runCommandIcon)
        }
        .help(app.runCommandHelp)
        .disabled(app.activeDocument == nil)
        Button { app.interruptKernel() } label: {
            Label("Stop", systemImage: "stop.fill")
        }
        .help("Interrupt execution (⌘.)")
        .disabled(app.kernelStatus != .busy)
    }
}

struct HistoryControls: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        Button { app.navigateHistory(-1) } label: {
            Label("Back", systemImage: "chevron.left")
        }
        .help("Go Back")
        .disabled(!app.canNavigateBack)
        Button { app.navigateHistory(1) } label: {
            Label("Forward", systemImage: "chevron.right")
        }
        .help("Go Forward")
        .disabled(!app.canNavigateForward)
    }
}

struct DetailSplitView: View {
    @EnvironmentObject var app: AppState
    @State private var draggedConsoleHeight: CGFloat?

    var body: some View {
        editor
            .toolbar { editorToolbar }
    }

    private var editor: some View {
        VStack(spacing: 0) {
            EditorAreaView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .layoutPriority(1)
            if app.showConsole {
                PanelResizeHandle(height: $app.consoleHeight,
                                  range: DS.Layout.consoleMinHeight...480,
                                  defaultHeight: DS.Layout.consoleDefaultHeight)
                BottomPanel()
                    .frame(height: min(max(draggedConsoleHeight ?? app.consoleHeight,
                                           DS.Layout.consoleMinHeight), 480))
                    .transition(.move(edge: .bottom))
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
        .clipped()
        .onPreferenceChange(PanelDragHeight.self) { next in
            if draggedConsoleHeight != next { draggedConsoleHeight = next }
        }
    }

    @ToolbarContentBuilder
    private var editorToolbar: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarItemGroup(placement: .navigation) { HistoryControls() }
            ToolbarSpacer(.fixed)
            ToolbarItem(placement: .principal) { KernelStatusMenu() }
            ToolbarSpacer(.flexible)
            ToolbarItemGroup(placement: .primaryAction) {
                splitButton
                consoleButton
            }
        } else {
            ToolbarItemGroup {
                HistoryControls()
                KernelStatusMenu()
                splitButton
                consoleButton
            }
        }
    }

    private var splitButton: some View {
        Button {
            app.toggleSplitEditor()
        } label: {
            Label("Split Editor", systemImage: "rectangle.split.2x1")
        }
        .help(app.splitDocumentID == nil ? "Split Editor" : "Close Split Editor")
        .disabled(app.activeDocument == nil)
    }

    private var consoleButton: some View {
        Button { app.toggleConsole() } label: {
            Label("Bottom Panel", systemImage: "terminal")
        }
        .help(consoleHelp)
    }

    private var consoleHelp: String {
        if app.consoleRevealPending && !app.showConsole { return "Show Console — new output (⇧⌘Y)" }
        return app.showConsole ? "Hide Bottom Panel (⇧⌘Y)" : "Show Bottom Panel (⇧⌘Y)"
    }
}

struct PanelResizeHandle: View {
    @Binding var height: CGFloat
    let range: ClosedRange<CGFloat>
    let defaultHeight: CGFloat
    @State private var dragStart: CGFloat?
    @State private var live: CGFloat?

    var body: some View {
        Divider()
            .overlay {
                Color.clear
                    .frame(height: 8)
                    .contentShape(Rectangle())
                    .pointerStyle(.rowResize)
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in
                                if dragStart == nil { dragStart = height }
                                let proposed = (dragStart ?? height) - value.translation.height
                                live = min(max(proposed, range.lowerBound), range.upperBound)
                            }
                            .onEnded { _ in
                                if let live { height = live }
                                dragStart = nil
                                live = nil
                            }
                    )
                    .onTapGesture(count: 2) { height = defaultHeight }
            }
            .zIndex(1)
            .preference(key: PanelDragHeight.self, value: live)
    }
}

struct ColumnResizeHandle: View {
    @Binding var fraction: CGFloat
    @State private var dragStart: CGFloat?
    @State private var startTotal: CGFloat?

    var body: some View {
        Divider()
            .overlay {
                Color.clear
                    .frame(width: 8)
                    .contentShape(Rectangle())
                    .pointerStyle(.columnResize)
                    .gesture(
                        DragGesture(minimumDistance: 1, coordinateSpace: .named("editorSplit"))
                            .onChanged { value in
                                if dragStart == nil {
                                    dragStart = fraction
                                    let start = max(fraction, 0.001)
                                    startTotal = value.startLocation.x / start
                                }
                                guard let origin = dragStart, let total = startTotal,
                                      total.isFinite, total > 1 else { return }
                                let minPane = min(DS.Layout.editorPaneMin, total / 2)
                                let minFraction = minPane / total
                                let proposed = origin + value.translation.width / total
                                guard proposed.isFinite else { return }
                                fraction = min(max(proposed, minFraction), 1 - minFraction)
                            }
                            .onEnded { _ in
                                dragStart = nil
                                startTotal = nil
                            }
                    )
                    .onTapGesture(count: 2) { fraction = 0.5 }
            }
            .zIndex(1)
    }
}

struct PanelDragHeight: PreferenceKey {
    static let defaultValue: CGFloat? = nil
    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        value = nextValue() ?? value
    }
}

struct KernelStatusMenu: View {
    @EnvironmentObject var app: AppState

    private static let sections: [(PythonEnvironment.Kind, String)] = [
        (.workspace, "This Workspace"),
        (.conda, "Conda"),
        (.pyenv, "pyenv"),
        (.homebrew, "Homebrew"),
        (.system, "System"),
        (.custom, "Custom"),
    ]

    var body: some View {
        Menu {
            if !app.isWorkspaceTrusted {
                Text("Restricted Workspace")
                Button("Trust Workspace…") { app.requestWorkspaceTrust() }
                Divider()
            }
            if app.kernel.isRunning {
                Text("Interpreter: \(app.kernel.executable ?? "Unknown")")
                Text("Directory: \(app.executionDirectoryLabel)")
                Divider()
            }
            ForEach(Self.sections, id: \.0) { kind, title in
                let envs = app.environments.filter { $0.kind == kind }
                if !envs.isEmpty {
                    Section(title) {
                        ForEach(envs) { env in
                            Button {
                                app.selectPython(env.executable)
                            } label: {
                                if env.executable == app.pythonPath {
                                    Label(rowTitle(env), systemImage: "checkmark")
                                } else {
                                    Text(rowTitle(env))
                                }
                            }
                            .help(env.executable)
                        }
                    }
                }
            }
            Divider()
            if let version = app.kernelPythonVersion {
                Text("Running Python \(version)")
            }
            Button("Rescan Environments") { app.refreshEnvironments() }
            Button("Choose Interpreter…") { app.choosePythonManually() }
            Divider()
            Button("Restart Kernel") { app.restartKernel() }
            Button("Interrupt Execution") { app.interruptKernel() }
        } label: {
            HStack(spacing: DS.Space.s) {
                indicator
                    .font(.system(size: DS.Layout.kernelGlyph, weight: .semibold))
                    .frame(width: DS.Layout.statusSlot, height: DS.Layout.statusSlot)
                Text(title)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let progress = app.runQueueProgress {
                    Text("\(progress.completed)/\(progress.total)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, DS.Space.bar)
            .contentShape(Rectangle())
        }
        .menuIndicator(.hidden)
        .frame(minWidth: DS.Layout.kernelLabelMinWidth,
               idealWidth: DS.Layout.kernelLabelWidth,
               maxWidth: DS.Layout.kernelLabelWidth)
        .modifier(KernelMenuSizing())
        .help(tooltip)
        .accessibilityLabel("Interpreter: \(title)")
    }

    @ViewBuilder
    private var indicator: some View {
        switch app.kernelStatus {
        case .idle:
            Image(systemName: "memorychip")
                .foregroundStyle(.secondary)
        case .busy:
            Image(systemName: "memorychip")
                .foregroundStyle(.yellow)
                .symbolEffect(.pulse, options: .repeating)
        case .starting:
            Image(systemName: "memorychip")
                .foregroundStyle(.orange)
                .symbolEffect(.pulse, options: .repeating)
        case .dead:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        case .stopped:
            Image(systemName: "memorychip")
                .foregroundStyle(.tertiary)
        }
    }

    private var title: String {
        if !app.isWorkspaceTrusted { return "Restricted Workspace" }
        let name = app.environmentName
        let version = app.kernelPythonVersion
            ?? app.pythonPath.flatMap { app.environmentVersions[$0] }
        let base: String
        if let version, !version.isEmpty {
            base = "\(name) — Python \(version)" + directorySuffix
        } else {
            base = name + directorySuffix
        }
        switch app.kernelStatus {
        case .idle: return base
        case .busy: return "\(base) · Running"
        case .starting: return "\(base) · Starting"
        case .dead: return "\(base) · Crashed"
        case .stopped: return "\(base) · Off"
        }
    }

    private var tooltip: String {
        var parts: [String] = []
        if let version = app.kernelPythonVersion { parts.append("Python \(version)") }
        parts.append(app.kernelStatus.label)
        parts.append("Directory: \(app.executionDirectoryLabel)")
        if let path = app.pythonPath {
            parts.append((path as NSString).abbreviatingWithTildeInPath)
        }
        return parts.joined(separator: " · ")
    }

    private var directorySuffix: String {
        guard app.kernelUsesDifferentDirectory else { return "" }
        return " · Session: \(app.kernel.workingDirectory?.lastPathComponent ?? "Unknown")"
    }

    private func rowTitle(_ env: PythonEnvironment) -> String {
        if let version = app.environmentVersions[env.executable], !version.isEmpty {
            return "\(env.name) — Python \(version)"
        }
        return env.name
    }
}

private struct KernelMenuSizing: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.buttonSizing(.flexible)
        } else {
            content
        }
    }
}
