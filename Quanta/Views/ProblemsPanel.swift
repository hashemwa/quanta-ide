import SwiftUI

struct ProblemsPanel: View {
    @ObservedObject var document: Document
    @ObservedObject var state: DocumentCodeTools
    let reveal: (PythonDiagnostic) -> Void
    @State private var selected: PythonDiagnostic.ID?

    var body: some View {
        VStack(spacing: 0) {
            if let notice = state.notice {
                Text(notice)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DS.Space.bar)
                Divider()
            }
            if state.diagnostics.isEmpty {
                NavigatorEmptyState(state.isChecking ? "Checking Code…" : state.hasChecked ? "No Problems Found" : "Python Code Checks",
                                    systemImage: state.hasChecked ? "checkmark.circle" : "exclamationmark.bubble",
                                    detail: state.hasChecked ? "\(document.displayName) · \(state.toolName)"
                                        : "Syntax checks run after you pause typing. Install Ruff in the selected environment for more checks and formatting.")
            } else {
                List(state.diagnostics, selection: $selected) { diagnostic in
                    HStack(alignment: .top, spacing: DS.Space.s) {
                        Image(systemName: diagnostic.severity == .error ? "xmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(diagnostic.severity == .error ? .red : .orange)
                        VStack(alignment: .leading, spacing: DS.Space.xxs) {
                            Text(diagnostic.message).font(.callout)
                            Text("\(location(diagnostic)) · \(diagnostic.code)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .tag(diagnostic.id)
                    .accessibilityLabel("\(diagnostic.message), \(location(diagnostic))")
                }
                .listStyle(.plain)
                .onChange(of: selected) { _, value in
                    if let diagnostic = state.diagnostics.first(where: { $0.id == value }) { reveal(diagnostic) }
                }
                .onChange(of: state.diagnostics) { _, diagnostics in
                    if !diagnostics.contains(where: { $0.id == selected }) { selected = nil }
                }
            }
        }
    }

    private func location(_ diagnostic: PythonDiagnostic) -> String {
        if let index = document.notebook?.cells.firstIndex(where: { $0.id == diagnostic.sourceID }) {
            return "Cell \(index + 1), line \(diagnostic.line):\(diagnostic.column)"
        }
        return "\(document.displayName):\(diagnostic.line):\(diagnostic.column)"
    }
}

struct ProblemsToolbar: View {
    @ObservedObject var state: DocumentCodeTools
    let check: () -> Void

    var body: some View {
        if state.isChecking || state.isFormatting {
            ProgressView().controlSize(.mini)
                .help(state.isFormatting ? "Formatting Code" : "Checking Code")
        } else if state.hasChecked {
            Text(state.diagnostics.isEmpty ? "No problems" : "\(state.diagnostics.count) problems")
                .font(.caption).foregroundStyle(.secondary)
        }
        IconButton("arrow.clockwise", help: "Check Python Code", action: check)
    }
}

struct CodeToolsMonitor: ViewModifier {
    let document: Document
    @EnvironmentObject private var app: AppState

    func body(content: Content) -> some View {
        content
            .onAppear { app.configureCodeTools(for: document) }
            .onChange(of: document.id) { _, _ in app.configureCodeTools(for: document) }
            .onChange(of: app.codeToolsPython) { _, _ in app.configureCodeTools(for: document) }
            .onChange(of: app.workspace?.rootURL) { _, _ in app.configureCodeTools(for: document) }
            .onChange(of: document.url) { _, _ in app.configureCodeTools(for: document) }
            .onChange(of: app.isWorkspaceTrusted) { _, _ in app.configureCodeTools(for: document) }
            .onChange(of: app.kernelTransition != nil) { _, _ in app.configureCodeTools(for: document) }
    }
}
