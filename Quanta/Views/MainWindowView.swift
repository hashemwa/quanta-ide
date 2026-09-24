import AppKit
import SwiftUI

struct MainWindowView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var columnVisibility: NavigationSplitViewVisibility =
        QuantaDefaults.previewHidesNavigator ? .detailOnly : .all

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
        .environment(\.monoFontSize, app.editorFontSize - 1)
        .modifier(WindowTitle())
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
            Text("Trusting \((url.path as NSString).abbreviatingWithTildeInPath) allows Quanta to probe and launch its Python environments and run code. Only trust folders whose contents and source you trust.")
        }
        .alert("Change Python session?", isPresented: Binding(
            get: { app.kernelTransition != nil },
            set: { if !$0 { app.kernelTransition = nil } }
        ), presenting: app.kernelTransition) { transition in
            Button("Restart in Workspace", role: .destructive) { app.applyKernelTransition(transition) }
            Button("Keep Current Session", role: .cancel) { app.keepKernelSession() }
        } message: { transition in
            Text(transitionMessage(transition))
        }
        .onChange(of: colorScheme) { _, _ in app.pushAppearance() }
        .onChange(of: app.sidebarRevealRequest) { _, _ in
            if columnVisibility == .detailOnly {
                withAnimation(reduceMotion ? nil : DS.Motion.quick) { columnVisibility = .all }
            }
        }
    }

    private func transitionMessage(_ transition: KernelTransition) -> String {
        let python = (transition.python as NSString).abbreviatingWithTildeInPath
        let directory = transition.workspace?.path ?? FileManager.default.homeDirectoryForCurrentUser.path
        return "Restarting clears all Python variables and stops current work.\n\n"
            + "Interpreter: \(python)\nDirectory: \((directory as NSString).abbreviatingWithTildeInPath)\n\n"
            + "The current session uses: \(app.executionDirectoryLabel)"
    }

    @ToolbarContentBuilder
    private var navigatorToolbar: some ToolbarContent {
        ToolbarItem(placement: .automatic) { NavigatorToggle(columnVisibility: $columnVisibility) }
    }

    @ToolbarContentBuilder
    private var inspectorToolbar: some ToolbarContent {
        ToolbarSpacer(.flexible)
        ToolbarItem(placement: .primaryAction) {
            Button { app.toggleVariables() } label: {
                Label("Variables", systemImage: "sidebar.trailing")
            }
            .help(app.showVariables ? "Hide Variables (⌥⌘0)" : "Show Variables (⌥⌘0)")
        }
    }
}

private struct WindowTitle: ViewModifier {
    @EnvironmentObject private var app: AppState
    @ObservedObject private var git = AppState.shared.git

    func body(content: Content) -> some View {
        content
            .navigationTitle(title)
            .navigationSubtitle(subtitle)
    }

    private var title: String {
        app.workspace?.rootURL.lastPathComponent
            ?? app.activeDocument?.displayName
            ?? "Quanta"
    }

    private var subtitle: String {
        guard app.workspace != nil else { return "" }
        return git.snapshot?.headDescription ?? ""
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
        ExecutionStopButton(app: app, title: "Stop")
            .help("Interrupt Execution (⌘.)")
    }
}

struct ExecutionStopButton: View {
    @ObservedObject var app: AppState
    var title = "Interrupt Execution"

    var body: some View {
        if let session = app.activeDocument?.dataSession {
            DataQueryStopButton(session: session, title: title)
        } else {
            Button { app.interruptKernel() } label: {
                Label(title, systemImage: "stop.fill")
            }
            .disabled(app.kernelStatus != .busy)
        }
    }
}

private struct DataQueryStopButton: View {
    @ObservedObject var session: DataSession
    let title: String

    var body: some View {
        Button { session.stop() } label: {
            Label(title, systemImage: "stop.fill")
        }
        .disabled(!session.isLoading)
    }
}

struct HistoryControls: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        Button { app.navigateHistory(-1) } label: {
            Label("Back", systemImage: "chevron.left")
        }
        .help("Go Back (⌘[)")
        .disabled(!app.canNavigateBack)
        Button { app.navigateHistory(1) } label: {
            Label("Forward", systemImage: "chevron.right")
        }
        .help("Go Forward (⌘])")
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
        ToolbarItemGroup(placement: .navigation) { HistoryControls() }
        ToolbarSpacer(.flexible)
        ToolbarItem(placement: .primaryAction) { KernelStatusMenu() }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItemGroup(placement: .primaryAction) { RunControls() }
        ToolbarSpacer(.fixed, placement: .primaryAction)
        ToolbarItemGroup(placement: .primaryAction) {
            splitButton
            consoleButton
        }
    }

    private var splitButton: some View {
        Button {
            app.toggleSplitEditor()
        } label: {
            Label("Split Editor", systemImage: "rectangle.split.2x1")
        }
        .help(app.splitDocumentID == nil ? "Split Editor (⌘\\)" : "Close Split Editor (⌘\\)")
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
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Bottom Panel Height")
            .accessibilityValue("\(Int(height)) points")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: height = min(height + DS.Layout.panelResizeStep, range.upperBound)
                case .decrement: height = max(height - DS.Layout.panelResizeStep, range.lowerBound)
                @unknown default: break
                }
            }
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
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Editor Split")
            .accessibilityValue("\(Int((fraction * 100).rounded())) percent")
            .accessibilityAdjustableAction { direction in
                let range = DS.Layout.splitFractionRange
                switch direction {
                case .increment: fraction = min(fraction + DS.Layout.splitResizeStep, range.upperBound)
                case .decrement: fraction = max(fraction - DS.Layout.splitResizeStep, range.lowerBound)
                @unknown default: break
                }
            }
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                Text(displayTitle)
                    .font(.callout)
                    .lineLimit(1)
                    .fixedSize()
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
        .help(tooltip)
        .accessibilityLabel("Interpreter: \(environmentTitle)")
        .accessibilityValue(app.kernelStatus.label)
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
                .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
        case .starting:
            Image(systemName: "memorychip")
                .foregroundStyle(.orange)
                .symbolEffect(.pulse, options: .repeating, isActive: !reduceMotion)
        case .dead:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        case .stopped:
            Image(systemName: "memorychip")
                .foregroundStyle(.tertiary)
        }
    }

    private var environmentTitle: String {
        if !app.isWorkspaceTrusted { return "Restricted Workspace" }
        let name = app.environmentName
        let version = app.kernelPythonVersion
            ?? app.pythonPath.flatMap { app.environmentVersions[$0] }
        if let version, !version.isEmpty {
            return "\(name) — Python \(version)" + directorySuffix
        }
        return name + directorySuffix
    }

    private var title: String {
        guard app.isWorkspaceTrusted else { return environmentTitle }
        switch app.kernelStatus {
        case .idle, .busy: return environmentTitle
        case .starting: return "\(environmentTitle) · Starting"
        case .dead: return "\(environmentTitle) · Crashed"
        case .stopped: return "\(environmentTitle) · Off"
        }
    }

    private var displayTitle: String {
        let limit = DS.Layout.kernelTitleLimit
        guard title.count > limit else { return title }
        let half = (limit - 1) / 2
        return String(title.prefix(half)) + "…" + String(title.suffix(half))
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
