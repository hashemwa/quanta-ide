import AppKit
import SwiftUI

struct EditorAreaView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(spacing: 0) {
            if app.openDocuments.isEmpty {
                WelcomeView()
            } else {
                TabBarView()
                Divider()
                if app.externallyChangedDocumentID != nil {
                    HStack(spacing: DS.Space.s) {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                        Text("This file changed on disk while you have unsaved edits.")
                            .font(.callout)
                        Spacer(minLength: DS.Space.s)
                        Button("Compare") { app.compareExternalVersion() }
                        Button("Keep My Version") { app.keepCurrentVersionAfterExternalChange() }
                        Button("Reload from Disk") { app.reloadExternalVersion() }
                    }
                    .controlSize(.small)
                    .padding(DS.Space.bar)
                    Divider()
                }
                if let notice = app.userNotice {
                    HStack(alignment: .top, spacing: DS.Space.s) {
                        Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                        Text(notice).font(.callout).textSelection(.enabled)
                        Spacer()
                        if app.pausedRunDocumentID != nil {
                            Button("Continue Remaining") {
                                app.userNotice = nil
                                app.continueRemainingCells()
                            }
                            .controlSize(.small)
                        }
                        IconButton("xmark", help: "Dismiss Message") { app.userNotice = nil }
                    }.padding(DS.Space.bar)
                }
                if let splitID = app.splitDocumentID,
                   let secondary = app.openDocuments.first(where: { $0.id == splitID }),
                   let primary = app.openDocuments.first(where: { $0.id == app.primarySplitDocumentID }) ?? app.activeDocument {
                    HSplitView {
                        EditorPaneView(document: primary).frame(minWidth: DS.Layout.editorPaneMin)
                        EditorPaneView(document: secondary, secondary: true).frame(minWidth: DS.Layout.editorPaneMin)
                    }
                } else if let document = app.activeDocument {
                    EditorPaneView(document: document)
                } else {
                    Spacer()
                }
            }
        }
    }
}

private struct EditorPaneView: View {
    @ObservedObject var document: Document
    var secondary = false
    @EnvironmentObject private var app: AppState

    var body: some View {
        VStack(spacing: 0) {
            if app.splitDocumentID != nil {
                PanelBar {
                    LabelMenu(help: "Choose Editor Document") {
                        ForEach(app.openDocuments) { candidate in
                            Button(candidate.displayName) {
                                if secondary { app.splitDocumentID = candidate.id }
                                else { app.primarySplitDocumentID = candidate.id }
                                app.activeDocumentID = candidate.id
                            }
                        }
                    } label: {
                        HStack(spacing: DS.Space.s) {
                            Image(systemName: document.iconName).foregroundStyle(.secondary)
                            Text(document.url.map { app.relativePath($0) } ?? document.displayName)
                                .lineLimit(1).truncationMode(.middle)
                            Image(systemName: "chevron.down").foregroundStyle(.secondary)
                        }.font(.caption)
                    }
                    .help(document.url?.path ?? document.displayName)
                    Spacer(minLength: 0)
                    if document.isDirty {
                        Text("Edited").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            DocumentContentView(document: document).id(document.id)
        }
    }
}

struct DocumentContentView: View {
    @ObservedObject var document: Document
    @EnvironmentObject var app: AppState

    var body: some View {
        content
            .environment(\.monoFontSize, app.editorFontSize - 1)
    }

    @ViewBuilder
    private var content: some View {
        switch document.kind {
        case .script:
            ScriptEditorView(document: document)
        case .notebook:
            if let notebook = document.notebook {
                NotebookView(document: document, notebook: notebook)
            }
        case .dataFrame:
            DataFrameTabView(document: document)
        case .diff:
            DiffView(document: document)
        }
    }
}

struct ScriptEditorView: View {
    @ObservedObject var document: Document
    @EnvironmentObject var app: AppState

    var body: some View {
        ScrollingCodeEditor(
            text: Binding(
                get: { document.text },
                set: { newValue in
                    if document.text != newValue {
                        document.text = newValue
                        if !document.isDirty { document.isDirty = true }
                    }
                }),
            showsLineNumbers: app.showsLineNumbers,
            wrapsLines: app.wrapsCode,
            documentID: document.id,
            onCommand: { command in
                if command == .runCellAndAdvance {
                    app.runSelectionOrLine(in: document)
                    return true
                }
                if command == .runCell {
                    app.runScript(document)
                    return true
                }
                return false
            },
            onFocus: { app.activeDocumentID = document.id })
    }
}

struct TabBarView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(app.openDocuments.filter(\.isPinned) + app.openDocuments.filter { !$0.isPinned }) { document in
                        if document.id != app.openDocuments.first?.id {
                            Divider().frame(height: DS.Layout.tabDividerHeight)
                        }
                        TabItemView(document: document, isActive: document.id == app.activeDocumentID)
                            .id(document.id)
                    }
                }
            }
            .onChange(of: app.activeDocumentID, initial: true) { _, id in
                guard let id else { return }
                withAnimation(reduceMotion ? nil : DS.Motion.quick) {
                    proxy.scrollTo(id, anchor: .center)
                }
            }
        }
        .frame(height: DS.Bar.primary)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct TabItemView: View {
    @ObservedObject var document: Document
    let isActive: Bool
    @EnvironmentObject var app: AppState
    @State private var hovering = false

    var body: some View {
        HStack(spacing: DS.Space.s) {
            Image(systemName: document.iconName)
                .font(.system(size: 10))
                .foregroundStyle(isActive ? Color.accentColor : Color.secondary)
            Text(app.tabTitle(document))
                .font(.callout)
                .foregroundStyle(isActive ? Color.primary : Color.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            ZStack {
                if document.isPinned {
                    Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary)
                } else if hovering {
                    Button {
                        app.closeDocument(document)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .medium))
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(TabCloseButtonStyle())
                    .help("Close Tab (⌘W)")
                    .accessibilityLabel("Close Tab")
                } else if document.isDirty {
                    Circle()
                        .fill(Color.secondary)
                        .frame(width: DS.Layout.statusDot, height: DS.Layout.statusDot)
                        .accessibilityLabel("Unsaved changes")
                }
            }
            .frame(width: 16, height: 16)
        }
        .padding(.leading, DS.Space.bar)
        .padding(.trailing, DS.Space.s)
        .frame(minWidth: DS.Layout.tabMinWidth, maxWidth: DS.Layout.tabMaxWidth)
        .frame(height: DS.Bar.primary)
        .background {
            if isActive {
                Color(nsColor: .textBackgroundColor)
            } else if hovering {
                Rectangle().fill(.quaternary).opacity(0.5)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            app.primarySplitDocumentID = document.id
            app.activeDocumentID = document.id
        }
        .draggable(document.id.uuidString)
        .dropDestination(for: String.self) { items, _ in
            guard let first = items.first, let id = UUID(uuidString: first) else { return false }
            app.reorderDocument(id, before: document.id)
            return true
        }
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { app.activeDocumentID = document.id }
        .scrollAwareHover($hovering)
        .help(document.url?.path ?? document.displayName)
        .contextMenu {
            Button(document.isPinned ? "Unpin Tab" : "Pin Tab") { app.togglePin(document) }
            Button("Split Editor") { app.activeDocumentID = document.id; app.toggleSplitEditor() }
            Divider()
            Button("Close Tab") { app.closeDocument(document) }
            Button("Close Other Tabs") { app.closeOtherDocuments(except: document) }
                .disabled(app.openDocuments.count < 2)
            Divider()
            if let url = document.url {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                Button("Copy Path") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.path, forType: .string)
                }
            }
        }
    }
}

private struct TabCloseButtonStyle: ButtonStyle {
    @State private var hovering = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(hovering || configuration.isPressed ? Color.primary : Color.secondary)
            .background(
                Circle().fill(configuration.isPressed
                              ? AnyShapeStyle(.tertiary)
                              : hovering ? AnyShapeStyle(.quaternary)
                              : AnyShapeStyle(.clear)))
            .contentShape(Circle())
            .scrollAwareHover($hovering)
    }
}

struct WelcomeView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(spacing: 16) {
            Text("Quanta")
                .font(.system(size: 34, weight: .semibold, design: .rounded))
            Text("A native data-science IDE for macOS")
                .foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Button {
                    app.openFolderPanel()
                } label: {
                    Label("Open Folder", systemImage: "folder")
                }
                Button {
                    app.newNotebook()
                } label: {
                    Label("New Notebook", systemImage: "plus.rectangle.on.rectangle")
                }
                Button {
                    app.newScript()
                } label: {
                    Label("New Python File", systemImage: "curlybraces")
                }
            }
            .controlSize(.large)
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
