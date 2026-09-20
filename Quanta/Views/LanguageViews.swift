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
            Text("Quanta includes the native ty analyzer; no Node.js or additional installation is required. Choose an executable only to override the bundled version. Analysis requires a trusted workspace and interpreter; it does not run notebook cells.")
                .textSelection(.enabled)
        }
    }
}

struct LanguageIssuesView: View {
    @ObservedObject var service: PythonLanguageService
    @ObservedObject var document: Document

    private var issues: [LanguageDiagnostic] { service.diagnostics[document.id, default: []] }

    var body: some View {
        Menu {
            if issues.isEmpty {
                Text("No issues in this document")
            } else {
                ForEach(issues) { issue in
                    Button(label(issue)) {
                        AppState.shared.revealLanguageLocation(documentID: document.id, editorID: issue.editorID, offset: issue.range.location)
                    }
                }
            }
            Divider()
            Text(service.status)
        } label: {
            Label("\(issues.count) Python \(issues.count == 1 ? "Issue" : "Issues")",
                  systemImage: issues.isEmpty ? "checkmark.circle" : "exclamationmark.triangle")
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(issues.isEmpty ? DS.StatusColors.success : DS.StatusColors.warning)
        }
        .menuIndicator(.hidden)
        .accessibilityLabel(issues.isEmpty ? "Python analysis: no issues" : "Python analysis: \(issues.count) issues")
        .help(issues.isEmpty ? "Python Analysis — No Issues" : "Show \(issues.count) Python Analysis \(issues.count == 1 ? "Issue" : "Issues")")
    }

    private func label(_ issue: LanguageDiagnostic) -> String {
        let cell = document.notebook?.cells.firstIndex { $0.id == issue.editorID }
        let location = cell.map { "Cell \($0 + 1), line \(issue.line)" } ?? "Line \(issue.line)"
        return "\(location): \(issue.message)"
    }
}

struct LanguageNavigationPresentation: ViewModifier {
    @ObservedObject var service: PythonLanguageService
    func body(content: Content) -> some View {
        content.sheet(isPresented: $service.showingReferences) {
            VStack(alignment: .leading, spacing: DS.Space.bar) {
                Text("References").font(.headline)
                if service.references.isEmpty {
                    Text("No references found.").foregroundStyle(.secondary)
                } else {
                    List(service.references) { reference in
                        Button(reference.label) { service.reveal(reference) }.buttonStyle(.plain)
                    }
                }
                HStack { Spacer(); Button("Done") { service.showingReferences = false }.keyboardShortcut(.cancelAction) }
            }
            .padding(DS.Space.bar)
            .frame(width: 520, height: 360)
        }
    }
}
