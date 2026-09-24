import AppKit
import Combine
import SwiftUI

final class VariableStore: ObservableObject {
    @Published var items: [VariableInfo] = []
    @Published var changed: Set<String> = []
}

struct VariablesPanel: View {
    @ObservedObject private var store = AppState.shared.variableStore
    private var app: AppState { AppState.shared }
    @State private var selected: String?
    @State private var detailsFor: String?
    @State private var query = ""
    @State private var typeFilter = "All Types"
    @State private var sortByType = false

    private var visibleVariables: [VariableInfo] {
        store.items.filter {
            (query.isEmpty || $0.name.localizedStandardContains(query) || $0.summary.localizedStandardContains(query))
                && (typeFilter == "All Types" || $0.typeName == typeFilter)
        }.sorted {
            sortByType && $0.typeName != $1.typeName ? $0.typeName < $1.typeName : $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }

    private var filterMenu: BarMenu {
        let types = ["All Types"] + Set(store.items.map(\.typeName)).sorted()
        return BarMenu(sections: [
            .init(title: "Type", items: types.map { type in
                .init(title: type, isOn: typeFilter == type) { typeFilter = type }
            }),
            .init(title: "Sort By", items: [
                .init(title: "Name", isOn: !sortByType) { sortByType = false },
                .init(title: "Type", isOn: sortByType) { sortByType = true },
            ]),
        ], isActive: typeFilter != "All Types")
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
            if store.items.isEmpty {
                NavigatorEmptyState("No Variables", systemImage: "cube.transparent",
                                    detail: "Run code to see the variables it defines.")
            } else {
                List(visibleVariables, selection: $selected) { variable in
                    VariableRowView(variable: variable, changed: store.changed.contains(variable.name),
                                    showingDetails: detailsBinding(for: variable))
                        .tag(variable.name)
                }
                .listStyle(.sidebar)
                .contextMenu(forSelectionType: String.self) { names in
                    if let variable = variable(named: names.first) {
                        VariableMenuItems(variable: variable) { detailsFor = variable.name }
                    }
                } primaryAction: { names in
                    guard let variable = variable(named: names.first) else { return }
                    if variable.isDataFrame { app.openDataFrame(named: variable.name) }
                    else if variable.isInspectable { detailsFor = variable.name }
                }
                .overlay {
                    if visibleVariables.isEmpty {
                        NavigatorEmptyState("No Matching Variables", systemImage: "magnifyingglass",
                                            detail: "Try another name or variable type.") {
                            Button("Clear Filters") { query = ""; typeFilter = "All Types" }
                        }
                    }
                }
            }
            FilterBar(text: $query, prompt: "Filter Variables", menu: filterMenu) {
                FilterBarButton("arrow.clockwise", help: "Refresh Variables") { app.refreshVariables() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: store.items.map(\.typeName)) { _, types in
            if typeFilter != "All Types", !types.contains(typeFilter) { typeFilter = "All Types" }
        }
    }

    private func variable(named name: String?) -> VariableInfo? {
        guard let name else { return nil }
        return store.items.first { $0.name == name }
    }

    private func detailsBinding(for variable: VariableInfo) -> Binding<Bool> {
        Binding(get: { detailsFor == variable.name },
                set: { if !$0, detailsFor == variable.name { detailsFor = nil } })
    }
}

private struct VariableMenuItems: View {
    let variable: VariableInfo
    let showDetails: () -> Void
    private var app: AppState { AppState.shared }

    var body: some View {
        if variable.isInspectable {
            Button("Show Details", action: showDetails)
        }
        if variable.isDataFrame {
            Button("Open as Table") { app.openDataFrame(named: variable.name) }
        }
        Button("Copy Name") { copy(variable.name) }
        Button("Copy Summary") { copy(variable.detail) }
        Divider()
        Button("Delete Variable…", role: .destructive) {
            app.deleteVariable(named: variable.name)
        }
    }

    private func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }
}

struct VariableRowView: View {
    let variable: VariableInfo
    var changed = false
    @Binding var showingDetails: Bool
    private var app: AppState { AppState.shared }

    var body: some View {
        InspectorRow(variable.name, type: variable.typeName, detail: variable.detail, marked: changed) {
            if variable.isInspectable {
                IconButton("info.circle", help: "Show Details") { showingDetails = true }
            }
            if variable.isDataFrame {
                IconButton("arrow.up.forward.square", help: "Open as Table") {
                    app.openDataFrame(named: variable.name)
                }
            }
        }
        .popover(isPresented: $showingDetails, arrowEdge: .leading) {
            VariableDetails(variable: variable)
        }
    }
}

extension VariableInfo {
    var detail: String {
        [shape, summary.isEmpty ? nil : summary].compactMap { $0 }.joined(separator: " · ")
    }
}

private struct VariableDetails: View {
    let variable: VariableInfo
    @State private var root: VariableNode?
    @State private var error: String?
    @State private var bytes: Int?
    @State private var request = UUID()
    private var app: AppState { AppState.shared }

    var body: some View {
        VStack(spacing: 0) {
            if let root {
                List {
                    OutlineGroup(root.children ?? [], children: \.children) { node in
                        VStack(alignment: .leading, spacing: DS.Space.xxs) {
                            HStack(spacing: DS.Space.s) {
                                Text(node.name).font(.caption.monospaced().weight(.semibold)).lineLimit(1)
                                Spacer(minLength: DS.Space.s)
                                Text(node.type).font(.caption).foregroundStyle(.secondary)
                            }
                            Text(node.value).font(.caption.monospaced()).lineLimit(3).textSelection(.enabled).help(node.value)
                        }
                    }
                }
                .listStyle(.inset)
            } else if let error {
                ContentUnavailableView("Couldn’t Show Details", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            PanelBar {
                Text(bytes.map { "\($0.formatted(.byteCount(style: .memory))) · first 4 levels, 300 items" } ?? "")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: DS.Space.s)
                IconButton("arrow.clockwise", help: "Refresh Details") { load() }
            }
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
