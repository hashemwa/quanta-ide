import AppKit
import SwiftUI

struct VariablesPanel: View {
    @EnvironmentObject var app: AppState
    @State private var selected: String?
    @State private var query = ""
    @State private var typeFilter = "All Types"
    @State private var sortByType = false
    @State private var inspected: VariableInfo?

    private var visibleVariables: [VariableInfo] {
        app.variables.filter {
            (query.isEmpty || $0.name.localizedStandardContains(query) || $0.summary.localizedStandardContains(query))
                && (typeFilter == "All Types" || $0.typeName == typeFilter)
        }.sorted {
            sortByType && $0.typeName != $1.typeName ? $0.typeName < $1.typeName : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if typeFilter != "All Types" {
                PanelBar {
                    Text(typeFilter).font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    IconButton("xmark.circle.fill", help: "Show All Variable Types") { typeFilter = "All Types" }
                }
            }
            if app.variables.isEmpty {
                ContentUnavailableView {
                    Label("No Variables", systemImage: "cube.transparent")
                } description: {
                    Text("Run some code to populate the kernel namespace.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(visibleVariables, selection: $selected) { variable in
                    VariableRowView(variable: variable, changed: app.changedVariables.contains(variable.name), inspect: { inspected = variable })
                        .tag(variable.name)
                }
                .listStyle(.sidebar)
                .overlay {
                    if visibleVariables.isEmpty {
                        ContentUnavailableView {
                            Label("No Matching Variables", systemImage: "magnifyingglass")
                        } description: {
                            Text("Try another name or variable type.")
                        } actions: {
                            Button("Clear Filters") { query = ""; typeFilter = "All Types" }
                        }
                    }
                }
            }
            PanelBar(height: DS.Bar.footer) {
                IconButton("arrow.clockwise", help: "Refresh Variables", glass: true) { app.refreshVariables() }
                FilterField(text: $query, prompt: "Filter Variables")
                IconMenu(typeFilter == "All Types" ? "ellipsis" : "line.3.horizontal.decrease.circle.fill",
                         help: "Filter and Sort Variables", glass: true) {
                    Picker("Type", selection: $typeFilter) {
                        Text("All Types").tag("All Types")
                        ForEach(Array(Set(app.variables.map(\.typeName))).sorted(), id: \.self) { Text($0).tag($0) }
                    }.pickerStyle(.inline)
                    Divider()
                    Picker("Sort", selection: $sortByType) {
                        Text("Name").tag(false)
                        Text("Type").tag(true)
                    }.pickerStyle(.inline)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .sheet(item: $inspected) { variable in VariableInspector(variable: variable) }
        .onChange(of: app.variables.map(\.typeName)) { _, types in
            if typeFilter != "All Types", !types.contains(typeFilter) { typeFilter = "All Types" }
        }
    }
}

struct VariableRowView: View {
    let variable: VariableInfo
    var changed = false
    var inspect: () -> Void = {}
    private var app: AppState { AppState.shared }

    private var detail: String {
        variable.summary.isEmpty
            ? variable.typeName
            : "\(variable.typeName) · \(variable.summary)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Space.xxs) {
            HStack(spacing: DS.Space.s) {
                if changed {
                    Circle().fill(Color.accentColor).frame(width: DS.Layout.statusDot, height: DS.Layout.statusDot)
                        .help("New or changed since the previous variable refresh")
                }
                Text(variable.name)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                if let shape = variable.shape {
                    Pill(shape)
                        .help("Shape: \(shape)")
                }
                Spacer(minLength: 0)
                IconButton("magnifyingglass", help: "Inspect Variable") { inspect() }
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
            if variable.isDataFrame { app.openDataFrame(named: variable.name) } else { inspect() }
        }
        .contextMenu {
            Button("Inspect Variable…") { inspect() }
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

private struct VariableInspector: View {
    let variable: VariableInfo
    @Environment(\.dismiss) private var dismiss
    @State private var root: VariableNode?
    @State private var error: String?
    @State private var bytes: Int?
    @State private var request = UUID()
    private var app: AppState { AppState.shared }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(variable.name, systemImage: "cube") {
                IconButton("arrow.clockwise", help: "Refresh Inspection") { load() }
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            if let root {
                List {
                    OutlineGroup([root], children: \.children) { node in
                        VStack(alignment: .leading, spacing: DS.Space.xxs) {
                            Text(node.name + " · " + node.type).font(.caption.weight(.semibold))
                            Text(node.value).font(.caption.monospaced()).lineLimit(3).textSelection(.enabled).help(node.value)
                        }
                    }
                }
            } else if let error {
                ContentUnavailableView("Couldn’t Inspect Variable", systemImage: "exclamationmark.triangle", description: Text(error))
            } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            Text((bytes.map { "\($0.formatted()) bytes (shallow) · " } ?? "") + "Preview: up to 4 levels / 300 entries")
                .font(.caption).foregroundStyle(.secondary).padding(DS.Space.m)
        }
        .frame(width: DS.Layout.inspectionWidth, height: DS.Layout.inspectionHeight)
        .onAppear(perform: load)
        .onDisappear { request = UUID() }
    }

    private func load() {
        root = nil
        error = nil
        guard app.isWorkspaceTrusted, app.kernelTransition == nil else {
            error = "Trust this workspace and choose a Python session before inspecting variables."
            return
        }
        guard app.kernelStatus == .idle else { error = "Wait for the kernel to finish, then refresh."; return }
        let token = UUID()
        request = token
        app.kernel.request(["op": "variable", "name": variable.name]) { message in
            guard request == token else { return true }
            switch message["type"] as? String {
            case "variable":
                if let dict = message["node"] as? [String: Any] { root = VariableNode(dict) }
                else { error = "The kernel returned an invalid preview." }
                bytes = message["bytes"] as? Int
                return true
            case "variable_error", "dead":
                error = message["error"] as? String ?? "The kernel stopped."
                return true
            default: return false
            }
        }
    }
}
