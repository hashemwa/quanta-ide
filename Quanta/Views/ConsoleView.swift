import SwiftUI

struct ConsoleView: View {
    var query = ""
    var scope = "All"
    @EnvironmentObject var app: AppState

    var body: some View {
        ConsoleBody(console: app.console, query: query, scope: scope)
    }
}

private struct ConsoleBody: View {
    @ObservedObject var console: ConsoleModel
    @EnvironmentObject var app: AppState
    @State private var input = ""
    let query: String
    let scope: String

    private var visibleLines: [ConsoleLine] {
        console.lines.filter { line in
            (query.isEmpty || line.text.localizedStandardContains(query))
                && (scope == "All" || (scope == "Errors" && line.kind == .stderr)
                    || (scope == "Output" && [.stdout, .result].contains(line.kind))
                    || (scope == "Commands" && line.kind == .input))
        }
    }
    @State private var pinnedToBottom = true
    @State private var historyIndex = 0
    @FocusState private var inputFocused: Bool

    private func recallHistory(_ offset: Int) -> KeyPress.Result {
        guard let entry = console.historyEntry(offset: offset, from: historyIndex) else {
            return .ignored
        }
        historyIndex = entry.index
        input = entry.text
        return .handled
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(visibleLines) { line in
                            ConsoleLineView(line: line, fontSize: app.editorFontSize - 1)
                                .id(line.id)
                        }
                        Color.clear
                            .frame(height: 1)
                            .onAppear { pinnedToBottom = true }
                            .onDisappear { pinnedToBottom = false }
                    }
                    .padding(.horizontal, DS.Space.bar)
                    .padding(.vertical, DS.Space.m)
                }
                .overlay(alignment: .bottomTrailing) {
                    if !pinnedToBottom, let last = visibleLines.last {
                        Button { proxy.scrollTo(last.id, anchor: .bottom); pinnedToBottom = true } label: {
                            Label("Latest", systemImage: "arrow.down")
                        }.buttonStyle(.bordered).controlSize(.small).padding(DS.Space.m)
                    }
                }
                .onChange(of: console.revision) { _, _ in
                    guard pinnedToBottom, let last = visibleLines.last else { return }
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
                .onAppear {
                    guard let last = visibleLines.last else { return }
                    DispatchQueue.main.async { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))
            .overlay {
                if visibleLines.isEmpty, !query.isEmpty || scope != "All" {
                    NavigatorEmptyState("No Results", systemImage: "magnifyingglass",
                                        detail: query.isEmpty ? "No \(scope.lowercased()) in the console."
                                                              : "No console message matches “\(query)”.")
                }
            }

            Divider()

            HStack(spacing: DS.Space.s) {
                Text("»")
                    .font(.system(size: app.editorFontSize - 1, weight: .bold, design: .monospaced))
                    .foregroundStyle(.secondary)
                TextField("Run Python in the kernel…", text: $input)
                    .textFieldStyle(.plain)
                    .font(.system(size: app.editorFontSize - 1, design: .monospaced))
                    .focused($inputFocused)
                    .disabled(app.kernelStatus == .busy || app.kernelStatus == .starting)
                    .help(app.kernelStatus == .busy ? "Wait for execution to finish, or interrupt the kernel" : "Run Python in the current kernel")
                    .onSubmit {
                        let code = input.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !code.isEmpty else { return }
                        input = ""
                        console.recordHistory(code)
                        historyIndex = console.history.count
                        app.runConsoleInput(code)
                        inputFocused = true
                    }
                    .onKeyPress(.upArrow) { recallHistory(-1) }
                    .onKeyPress(.downArrow) { recallHistory(1) }
                    .onAppear { historyIndex = console.history.count }
                    .onChange(of: console.focusRequest, initial: true) { _, value in
                        guard value != console.handledFocusRequest else { return }
                        console.handledFocusRequest = value
                        DispatchQueue.main.async { inputFocused = true }
                    }
            }
            .padding(.horizontal, DS.Space.bar)
            .padding(.vertical, DS.Space.s)
        }
    }
}

struct ConsoleLineView: View {
    let line: ConsoleLine
    var fontSize: CGFloat = 12

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            if line.kind == .input {
                Text("»")
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: DS.Space.xs) {
                Text(ANSIRenderer.attributed(line.text.trimmingTrailingNewlines)).foregroundStyle(color)
                if line.kind == .stderr {
                    ForEach(Array(TracebackLocation.parse(line.text).enumerated()), id: \.offset) { _, location in
                        Button("\(URL(fileURLWithPath: location.file).lastPathComponent):\(location.line)") {
                            AppState.shared.navigateTo(file: location.file, line: location.line)
                        }.buttonStyle(.link).help("Go to \(location.file), line \(location.line)")
                    }
                }
            }
        }
        .font(.system(size: fontSize, design: .monospaced))
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .stderrRule(line.kind == .stderr)
    }

    private var color: Color {
        switch line.kind {
        case .system: return .secondary
        case .input, .result, .stdout, .stderr: return .primary
        }
    }
}
