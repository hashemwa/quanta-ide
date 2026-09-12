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
                if let document = app.activeDocument {
                    DocumentContentView(document: document)
                        .id(document.id)
                } else {
                    Spacer()
                }
            }
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
            })
    }
}

struct TabBarView: View {
    @EnvironmentObject var app: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(app.openDocuments) { document in
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
            Text(document.displayName)
                .font(.callout)
                .foregroundStyle(isActive ? Color.primary : Color.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            ZStack {
                if hovering {
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
        .frame(minWidth: 96, maxWidth: 220)
        .frame(height: DS.Bar.primary)
        .background {
            if isActive {
                Color(nsColor: .textBackgroundColor)
            } else if hovering {
                Rectangle().fill(.quaternary).opacity(0.5)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { app.activeDocumentID = document.id }
        .scrollAwareHover($hovering)
        .help(document.url?.path ?? document.displayName)
        .contextMenu {
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
            Image(systemName: "hurricane")
                .font(.system(size: 54, weight: .thin))
                .foregroundStyle(Color.accentColor)
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
