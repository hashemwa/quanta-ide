import SwiftUI

struct ConsoleView: View {
    var query = ""
    var scope = "All"
    var isActive = true
    @EnvironmentObject var app: AppState

    var body: some View {
        ConsoleBody(console: app.console, query: query, scope: scope, isActive: isActive)
    }
}

private struct ConsoleBody: View {
    @ObservedObject var console: ConsoleModel
    @EnvironmentObject var app: AppState
    let query: String
    let scope: String
    let isActive: Bool

    private var visibleLines: [ConsoleLine] {
        console.lines.filter { line in
            (query.isEmpty || line.text.localizedStandardContains(query))
                && (scope == "All" || (scope == "Errors" && line.kind == .stderr)
                    || (scope == "Output" && [.stdout, .result].contains(line.kind))
                    || (scope == "Commands" && line.kind == .input))
        }
    }
    @State private var pinnedToBottom = true

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

            ConsoleInputView(input: console.input, console: console, isActive: isActive,
                             focusRequest: console.focusRequest) { pinnedToBottom = true }
        }
    }
}

private struct ConsoleInputView: View {
    @ObservedObject var input: ConsoleInputState
    let console: ConsoleModel
    let isActive: Bool
    let focusRequest: Int
    let didSubmit: () -> Void
    @EnvironmentObject private var app: AppState
    @FocusState private var inputFocused: Bool

    private func focusIfRequested() {
        guard isActive, focusRequest != console.handledFocusRequest else { return }
        console.handledFocusRequest = focusRequest
        inputFocused = true
    }

    var body: some View {
        HStack(spacing: DS.Space.s) {
            Text("»")
                .font(.system(size: app.editorFontSize - 1, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)
            TextField("Run Python in the kernel…", text: $input.text)
                .textFieldStyle(.plain)
                .font(.system(size: app.editorFontSize - 1, design: .monospaced))
                .focused($inputFocused)
                .help(app.kernelStatus == .busy ? "Wait for execution to finish, or interrupt the kernel" : "Run Python in the current kernel")
                .onSubmit {
                    guard app.kernelStatus != .busy, app.kernelStatus != .starting else { return }
                    if input.submitInput(app.runConsoleInput) {
                        didSubmit()
                        inputFocused = true
                    }
                }
                .onKeyPress(.upArrow) { input.recallHistory(-1) ? .handled : .ignored }
                .onKeyPress(.downArrow) { input.recallHistory(1) ? .handled : .ignored }
                .onChange(of: focusRequest, initial: true) { _, _ in focusIfRequested() }
                .onChange(of: isActive) { _, active in
                    if active { focusIfRequested() }
                    else { inputFocused = false }
                }
        }
        .padding(.horizontal, DS.Space.bar)
        .frame(minHeight: DS.Bar.footer)
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
