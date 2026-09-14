import SwiftUI
import WebKit

struct BottomPanel: View {
    @EnvironmentObject private var app: AppState
    @ObservedObject private var terminal = AppState.shared.terminal

    @State private var consoleQuery = ""
    @State private var consoleScope = "All"
    @State private var showingSearch = false

    var body: some View {
        VStack(spacing: 0) {
            PanelBar(rule: .below) {
                PanelPicker("Panel", selection: $app.bottomPane, values: BottomPane.allCases) { $0.rawValue }
                    .fixedSize()
                Spacer(minLength: DS.Space.s)
                if app.bottomPane == .terminal {
                    Text(terminal.running ? "Shell" : terminal.exitStatus.map { "Exited (\($0))" } ?? "Not started")
                        .font(.caption).foregroundStyle(.secondary)
                        .help(terminal.directory.map { "Session started in \($0.path)" } ?? "Shell session")
                    IconButton("plus", help: "New Terminal Session…") { app.newTerminalSession() }
                    IconButton("trash", help: "Clear Terminal Scrollback") { terminal.clear() }
                } else {
                    if consoleScope != "All" {
                        Text(consoleScope).font(.caption).foregroundStyle(.secondary)
                    }
                    IconMenu(consoleScope == "All" ? "line.3.horizontal.decrease" : "line.3.horizontal.decrease.circle.fill",
                             help: "Filter Console Messages") {
                        Picker("Messages", selection: $consoleScope) {
                            ForEach(["All", "Errors", "Output", "Commands"], id: \.self) { Text($0) }
                        }.pickerStyle(.inline)
                    }
                    IconButton("magnifyingglass", help: "Search Console", isActive: showingSearch) {
                        showingSearch.toggle()
                        if !showingSearch { consoleQuery = "" }
                    }
                    IconButton("trash", help: "Clear Python Console (⌘K)") { app.console.clear() }
                }
                IconButton("xmark", help: "Hide Panel") { app.setConsoleVisible(false) }
            }
            if app.bottomPane == .console {
                if showingSearch {
                    PanelSearchBar(prompt: "Find in console", text: $consoleQuery) {
                        consoleQuery = ""
                        showingSearch = false
                    }
                }
                ConsoleView(query: consoleQuery, scope: consoleScope)
            } else if let error = terminal.error {
                ContentUnavailableView {
                    Label("Terminal Couldn’t Start", systemImage: "exclamationmark.triangle")
                } description: { Text(error) } actions: {
                    Button("Retry") { app.showTerminal() }
                }
            } else {
                TerminalSurface(session: terminal)
                if !terminal.running {
                    HStack {
                        Text("Shell exited. Start a new session to continue.")
                        Spacer()
                        Button("New Session") { app.showTerminal() }
                    }.font(.caption).padding(DS.Space.s)
                }
            }
        }
        .onChange(of: app.bottomPane) { _, pane in if pane == .terminal { app.showTerminal() } }
    }
}

private struct TerminalSurface: NSViewRepresentable {
    let session: TerminalSession
    @Environment(\.colorScheme) private var scheme
    @EnvironmentObject private var app: AppState
    func makeNSView(context: Context) -> WKWebView { session.webView() }
    func updateNSView(_ view: WKWebView, context: Context) {
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
        confirmDestructive(title: "Replace the terminal session?",
                           message: "The current shell and its foreground command will be stopped. A new shell will start in \(directory.path).",
                           button: "New Session") {
            self.terminal.restart(in: directory)
            self.bottomPane = .terminal
            self.setConsoleVisible(true)
        }
    }
}
