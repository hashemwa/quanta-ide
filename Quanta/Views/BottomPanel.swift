import SwiftUI
import WebKit

struct BottomPanel: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject private var terminal = AppState.shared.terminal

    @State private var plotSelection: UUID?
    @State private var plotAllFiles = false
    @State private var consoleQuery = ""
    @State private var consoleScope = "All"
    @State private var showingSearch = false

    private static let paneSegments: [IconSegmentedControl<BottomPane>.Segment] = [
        .init(value: .console, title: BottomPane.console.rawValue, help: "Console"),
        .init(value: .terminal, title: BottomPane.terminal.rawValue, help: "Terminal"),
        .init(value: .plots, title: BottomPane.plots.rawValue, help: "Plots"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            PanelBar(height: DS.Bar.primary) {
                IconSegmentedControl(segments: Self.paneSegments, selection: $app.bottomPane, fillsWidth: false)
                    .accessibilityLabel("Panel")
                Spacer(minLength: DS.Space.s)
                if app.bottomPane == .terminal {
                    if let status = terminal.exitStatus, !terminal.running {
                        Text("Exited (\(status))")
                            .font(.caption).foregroundStyle(.secondary)
                            .help(terminal.directory.map { "Session started in \($0.path)" } ?? "Shell session")
                    } else if !terminal.running {
                        Text("Not started")
                            .font(.caption).foregroundStyle(.secondary)
                            .help("Start Terminal Session")
                    }
                    IconButton("arrow.clockwise", help: "Restart Terminal Session…") { app.newTerminalSession() }
                    IconButton("trash", help: "Clear Terminal Scrollback") { terminal.clear() }
                } else if app.bottomPane == .plots {
                    PlotsToolbar(history: app.plots, selection: $plotSelection, allFiles: $plotAllFiles)
                } else if app.bottomPane == .console {
                    if consoleScope != "All" {
                        Text(consoleScope).font(.caption).foregroundStyle(.secondary)
                    }
                    IconMenu(consoleScope == "All" ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill",
                             help: "Filter Console Messages") {
                        Picker("Messages", selection: $consoleScope) {
                            ForEach(["All", "Errors", "Output", "Commands"], id: \.self) { Text($0) }
                        }.pickerStyle(.inline)
                    }
                    IconButton("magnifyingglass", help: "Search Console", isActive: showingSearch) {
                        showingSearch.toggle()
                        if !showingSearch { consoleQuery = "" }
                    }
                    IconButton("trash", help: "Clear Console (⌘K)") { app.console.clear() }
                }
                IconButton("xmark", help: "Hide Panel (⇧⌘Y)") { app.setConsoleVisible(false) }
            }
            if showingSearch, app.bottomPane == .console {
                PanelSearchBar(prompt: "Find in console", text: $consoleQuery) {
                    consoleQuery = ""
                    showingSearch = false
                }
            }
            ZStack {
                if app.bottomPane == .plots { PlotsPanel(history: app.plots, selection: $plotSelection, allFiles: $plotAllFiles) }
                ConsoleView(query: consoleQuery, scope: consoleScope, isActive: app.bottomPane == .console)
                    .opacity(app.bottomPane == .console ? 1 : 0)
                    .allowsHitTesting(app.bottomPane == .console)
                    .accessibilityHidden(app.bottomPane != .console)
                terminalPane
                    .opacity(app.bottomPane == .terminal ? 1 : 0)
                    .allowsHitTesting(app.bottomPane == .terminal)
                    .accessibilityHidden(app.bottomPane != .terminal)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipped()
        .onAppear { _ = terminal.webView() }
        .onDisappear { terminal.setActive(false) }
        .onChange(of: app.bottomPane) { _, pane in
            if pane == .console { app.console.focusRequest += 1 }
            if pane == .terminal { app.showTerminal() }
            if pane == .plots { app.showPlots() }
        }
    }

    @ViewBuilder
    private var terminalPane: some View {
        if let error = terminal.error {
            NavigatorEmptyState("Terminal Couldn’t Start", systemImage: "exclamationmark.triangle",
                                detail: error) {
                Button("Try Again") { app.showTerminal() }
            }
        } else {
            VStack(spacing: 0) {
                TerminalSurface(session: terminal, isActive: app.bottomPane == .terminal)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if !terminal.running, terminal.exitStatus != nil {
                    Divider()
                    HStack {
                        Text("Shell exited. Start a new session to continue.")
                        Spacer()
                        Button("Restart Session") { app.showTerminal() }
                    }.font(.caption).padding(DS.Space.s)
                }
            }
        }
    }
}

private struct TerminalSurface: NSViewRepresentable {
    let session: TerminalSession
    let isActive: Bool
    @Environment(\.colorScheme) private var scheme
    @EnvironmentObject private var app: AppState
    func makeNSView(context: Context) -> WKWebView { session.webView() }
    func updateNSView(_ view: WKWebView, context: Context) {
        session.setActive(isActive)
        session.appearance(dark: scheme == .dark, size: app.editorFontSize - 1)
    }
}

extension AppState {
    func showPythonConsole() {
        bottomPane = .console
        setConsoleVisible(true)
        console.focusRequest += 1
    }
    func showTerminal() {
        bottomPane = .terminal
        setConsoleVisible(true)
        terminal.start(in: workspace?.rootURL ?? FileManager.default.homeDirectoryForCurrentUser)
        terminal.focus()
    }
    func newTerminalSession() {
        let directory = workspace?.rootURL ?? FileManager.default.homeDirectoryForCurrentUser
        guard terminal.running else { showTerminal(); return }
        confirmDestructive(title: "Restart the terminal session?",
                           message: "The current shell and its foreground command will be stopped. A new shell will start in \(directory.path).",
                           button: "Restart Session") {
            self.terminal.restart(in: directory)
            self.bottomPane = .terminal
            self.setConsoleVisible(true)
            self.terminal.focus()
        }
    }
}
