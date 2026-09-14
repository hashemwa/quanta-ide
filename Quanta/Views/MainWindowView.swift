import SwiftUI

struct MainWindowView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.colorScheme) private var colorScheme
    @State private var columnVisibility: NavigationSplitViewVisibility = .automatic

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: DS.Layout.sidebarMin, ideal: DS.Layout.sidebarIdeal, max: DS.Layout.sidebarMax)
        } detail: {
            DetailSplitView()
        }
        .inspector(isPresented: Binding(get: { app.showVariables },
                                        set: { app.setVariablesVisible($0) })) {
            VariablesPanel()
                .inspectorColumnWidth(min: DS.Layout.inspectorMin,
                                      ideal: DS.Layout.inspectorIdeal,
                                      max: DS.Layout.inspectorMax)
                .toolbar { inspectorToolbar }
        }
        .navigationTitle(windowTitle)
        .navigationSubtitle(windowSubtitle)
        .onAppear { app.bootstrap() }
        .onChange(of: colorScheme) { _, _ in app.pushAppearance() }
        .onChange(of: app.sidebarRevealRequest) { _, _ in
            if columnVisibility == .detailOnly { columnVisibility = .all }
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
    private var inspectorToolbar: some ToolbarContent {
        ToolbarItem {
            Button {
                app.toggleVariables()
            } label: {
                Label("Variables", systemImage: "sidebar.trailing")
                    .foregroundStyle(app.showVariables ? AnyShapeStyle(Color.accentColor)
                                                       : AnyShapeStyle(.primary))
            }
            .help(app.showVariables ? "Hide Variables (⌥⌘0)" : "Show Variables (⌥⌘0)")
        }
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
        GeometryReader { geo in
            let maxConsole = max(DS.Layout.consoleMinHeight, min(480, geo.size.height * 0.45))
            VStack(spacing: 0) {
                EditorAreaView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if app.showConsole {
                    PanelResizeHandle(height: $app.consoleHeight,
                                      range: DS.Layout.consoleMinHeight...maxConsole,
                                      defaultHeight: DS.Layout.consoleDefaultHeight)
                    ConsoleView()
                        .frame(height: min(max(draggedConsoleHeight ?? app.consoleHeight,
                                               DS.Layout.consoleMinHeight), maxConsole))
                        .transition(.move(edge: .bottom))
                }
            }
            .clipped()
            .onPreferenceChange(PanelDragHeight.self) { draggedConsoleHeight = $0 }
        }
    }

    @ToolbarContentBuilder
    private var editorToolbar: some ToolbarContent {
        if #available(macOS 26.0, *) {
            ToolbarItemGroup { runControls }
            ToolbarSpacer(.fixed)
            ToolbarItem { KernelStatusMenu() }
            ToolbarSpacer(.fixed)
            ToolbarItem { consoleButton }
        } else {
            ToolbarItemGroup {
                runControls
                KernelStatusMenu()
                consoleButton
            }
        }
    }

    @ViewBuilder
    private var runControls: some View {
        Button {
            app.runActiveDocument()
        } label: {
            Label(app.runCommandTitle, systemImage: app.runCommandIcon)
        }
        .help(app.runCommandHelp)
        .disabled(app.activeDocument == nil)

        Button {
            app.interruptKernel()
        } label: {
            Label("Stop", systemImage: "stop.fill")
        }
        .help("Interrupt execution (⌘.)")
        .disabled(app.kernelStatus != .busy)

        Button {
            app.restartKernel()
        } label: {
            Label("Restart Kernel", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
        }
        .help("Restart kernel (⌃⌘R)")
    }

    private var consoleButton: some View {
        Button {
            app.toggleConsole()
        } label: {
            Label("Console", systemImage: consoleGlyph)
                .foregroundStyle(consoleTint)
        }
        .help(consoleHelp)
    }

    private var consoleGlyph: String {
        app.showConsole ? "terminal.fill" : "terminal"
    }

    private var consoleTint: AnyShapeStyle {
        if app.showConsole || app.consoleRevealPending { return AnyShapeStyle(Color.accentColor) }
        return AnyShapeStyle(.primary)
    }

    private var consoleHelp: String {
        if app.consoleRevealPending && !app.showConsole { return "Show Console — new output (⇧⌘Y)" }
        return app.showConsole ? "Hide Console (⇧⌘Y)" : "Show Console (⇧⌘Y)"
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
                    .frame(width: DS.Layout.statusSlot, height: DS.Layout.statusSlot)
                Text(title)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(width: DS.Layout.kernelLabelWidth, alignment: .leading)
            }
        }
        .help(tooltip)
        .accessibilityLabel("Interpreter: \(title)")
    }

    @ViewBuilder
    private var indicator: some View {
        switch app.kernelStatus {
        case .idle:
            Circle()
                .fill(.green)
                .frame(width: DS.Layout.statusDot, height: DS.Layout.statusDot)
        case .busy:
            Image(systemName: "circle.dotted")
                .font(.system(size: DS.Layout.symbolGlyph, weight: .bold))
                .foregroundStyle(.yellow)
                .symbolEffect(.pulse, options: .repeating)
        case .starting:
            Image(systemName: "circle.dotted")
                .font(.system(size: DS.Layout.symbolGlyph, weight: .bold))
                .foregroundStyle(.orange)
                .symbolEffect(.pulse, options: .repeating)
        case .dead:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: DS.Layout.symbolGlyph))
                .foregroundStyle(.red)
        case .stopped:
            Circle()
                .strokeBorder(Color.secondary, lineWidth: 1)
                .frame(width: DS.Layout.statusDot, height: DS.Layout.statusDot)
        }
    }

    private var title: String {
        let name = app.environmentName
        switch app.kernelStatus {
        case .idle: return name
        case .busy: return "\(name) · Running"
        case .starting: return "\(name) · Starting"
        case .dead: return "\(name) · Crashed"
        case .stopped: return "\(name) · Off"
        }
    }

    private var tooltip: String {
        var parts: [String] = []
        if let version = app.kernelPythonVersion { parts.append("Python \(version)") }
        parts.append(app.kernelStatus.label)
        if let path = app.pythonPath {
            parts.append((path as NSString).abbreviatingWithTildeInPath)
        }
        return parts.joined(separator: " · ")
    }

    private func rowTitle(_ env: PythonEnvironment) -> String {
        if let version = app.environmentVersions[env.executable], !version.isEmpty {
            return "\(env.name) — Python \(version)"
        }
        return env.name
    }
}

