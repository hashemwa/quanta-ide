import AppKit
import SwiftUI

struct VariablesPanel: View {
    @EnvironmentObject var app: AppState
    @State private var selected: String?

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader("Variables", systemImage: "list.bullet.rectangle", height: DS.Bar.primary) {
                IconButton("arrow.clockwise", help: "Refresh Variables") { app.refreshVariables() }
            }

            if app.variables.isEmpty {
                ContentUnavailableView {
                    Label("No Variables", systemImage: "cube.transparent")
                } description: {
                    Text("Run some code to populate the kernel namespace.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(app.variables, selection: $selected) { variable in
                    VariableRowView(variable: variable)
                        .tag(variable.name)
                }
                .listStyle(.inset)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

struct VariableRowView: View {
    let variable: VariableInfo
    private var app: AppState { AppState.shared }

    private var detail: String {
        variable.summary.isEmpty
            ? variable.typeName
            : "\(variable.typeName) · \(variable.summary)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xxs) {
            HStack(spacing: DS.Space.s) {
                Text(variable.name)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                if let shape = variable.shape {
                    Pill(shape)
                        .help("Shape: \(shape)")
                }
                Spacer(minLength: 0)
                if variable.isDataFrame {
                    IconButton("arrow.up.forward.square", help: "Open as Table") {
                        app.openDataFrame(named: variable.name)
                    }
                }
            }
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 1)
        .contentShape(Rectangle())
        .help(detail)
        .onTapGesture(count: 2) {
            if variable.isDataFrame {
                app.openDataFrame(named: variable.name)
            }
        }
        .contextMenu {
            if variable.isDataFrame {
                Button("Open as Table") { app.openDataFrame(named: variable.name) }
            }
            Button("Copy Name") { copyToPasteboard(variable.name) }
            Button("Copy Summary") { copyToPasteboard(detail) }
            Divider()
            Button("Delete Variable…", role: .destructive) {
                app.deleteVariable(named: variable.name)
            }
        }
    }

    private func copyToPasteboard(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }
}
