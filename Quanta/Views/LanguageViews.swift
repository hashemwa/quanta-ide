import SwiftUI

struct LanguageSettingsView: View {
    @ObservedObject var service: PythonLanguageService

    var body: some View {
        Section {
            Toggle("Python language intelligence", isOn: $service.enabled)
            LabeledContent("Status") { Text(service.status).foregroundStyle(.secondary) }
            LabeledContent("Language server") {
                Text(service.serverPath.isEmpty ? "Automatic" : (service.serverPath as NSString).abbreviatingWithTildeInPath)
                    .lineLimit(2).truncationMode(.middle).help(service.serverPath)
            }
            HStack {
                Button("Choose Executable…") { service.chooseServer() }
                Button("Use Automatic") { service.useAutomaticServer() }.disabled(service.serverPath.isEmpty)
                Button("Restart") { service.restart() }.disabled(!service.enabled)
            }
        } header: {
            Text("Python Analysis")
        } footer: {
            Text("Install Node.js and Pyright (npm install -g pyright), then restart analysis. Quanta checks standard Homebrew and ~/.local/bin locations. Analysis requires a trusted workspace and interpreter; it does not run notebook cells.")
                .textSelection(.enabled)
        }
    }
}

struct LanguageIssuesView: View {
    @ObservedObject var service: PythonLanguageService
    @ObservedObject var document: Document

    private var issues: [LanguageDiagnostic] { service.diagnostics[document.id, default: []] }

    var body: some View {
        if !issues.isEmpty {
            HStack(spacing: DS.Space.s) {
                Menu {
                    ForEach(issues) { issue in
                        Button(label(issue)) {
                            AppState.shared.revealLanguageLocation(documentID: document.id, editorID: issue.editorID, offset: issue.range.location)
                        }
                    }
                } label: {
                    Label("\(issues.count) \(issues.count == 1 ? "Issue" : "Issues")", systemImage: "exclamationmark.triangle")
                }
                .fixedSize()
                .help("Show Python Analysis Issues")
                Text("Python analysis").foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .font(.caption)
            .controlSize(.small)
            .padding(.horizontal, DS.Space.bar)
            .frame(height: DS.Bar.secondary)
            Divider()
        }
    }

    private func label(_ issue: LanguageDiagnostic) -> String {
        let cell = document.notebook?.cells.firstIndex { $0.id == issue.editorID }
        let location = cell.map { "Cell \($0 + 1), line \(issue.line)" } ?? "Line \(issue.line)"
        return "\(location): \(issue.message)"
    }
}
