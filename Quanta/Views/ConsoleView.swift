import SwiftUI

struct ConsoleView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        ConsoleBody(console: app.console)
    }
}

private struct ConsoleBody: View {
    @ObservedObject var console: ConsoleModel
    @EnvironmentObject var app: AppState
    @State private var input = ""
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
            PanelHeader("Console", systemImage: "terminal") {
                IconButton("trash", help: "Clear Console (⌘K)") { console.clear() }
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(console.lines) { line in
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
                .onChange(of: console.revision) { _, _ in
                    guard pinnedToBottom, let last = console.lines.last else { return }
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
                .onAppear {
                    guard let last = console.lines.last else { return }
                    DispatchQueue.main.async { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: .textBackgroundColor))

            Divider()

            HStack(spacing: DS.Space.s) {
                Text("»")
                    .font(.system(size: app.editorFontSize - 1, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.accentColor)
                TextField("Run Python in the kernel…", text: $input)
                    .textFieldStyle(.plain)
                    .font(.system(size: app.editorFontSize - 1, design: .monospaced))
                    .focused($inputFocused)
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
                    .foregroundStyle(Color.accentColor)
            }
            Text(ANSIRenderer.attributed(line.text.trimmingTrailingNewlines))
                .foregroundStyle(color)
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
