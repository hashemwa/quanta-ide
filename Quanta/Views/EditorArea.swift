import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct EditorAreaView: View {
    @EnvironmentObject var app: AppState

    var body: some View {
        VStack(spacing: 0) {
            if app.openDocuments.isEmpty {
                WelcomeView()
            } else {
                TabBarView()
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
                    ProportionalHSplit(fraction: app.editorSplitFraction) {
                        EditorPaneView(document: primary)
                            .clipped()
                        ColumnResizeHandle(fraction: $app.editorSplitFraction)
                        EditorPaneView(document: secondary, secondary: true)
                            .clipped()
                    }
                    .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                    .coordinateSpace(name: "editorSplit")
                    .clipped()
                } else if let document = app.activeDocument {
                    EditorPaneView(document: document)
                } else {
                    Spacer()
                }
            }
        }
    }
}

private struct ProportionalHSplit: Layout {
    var fraction: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 3 else {
            for subview in subviews {
                subview.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
            }
            return
        }
        let divider = max(DS.Layout.hairline, subviews[1].sizeThatFits(.init(width: 1, height: bounds.height)).width)
        let usable = max(0, bounds.width - divider)
        let minPane = min(DS.Layout.editorPaneMin, usable / 2)
        let left = EditorSplit.width(fraction: fraction, total: usable, minPane: minPane)
        var x = bounds.minX
        subviews[0].place(at: CGPoint(x: x, y: bounds.minY),
                          proposal: ProposedViewSize(width: left, height: bounds.height))
        x += left
        subviews[1].place(at: CGPoint(x: x, y: bounds.minY),
                          proposal: ProposedViewSize(width: divider, height: bounds.height))
        x += divider
        subviews[2].place(at: CGPoint(x: x, y: bounds.minY),
                          proposal: ProposedViewSize(width: bounds.maxX - x, height: bounds.height))
    }
}

private enum EditorSplit {
    static func width(fraction: CGFloat, total: CGFloat, minPane: CGFloat) -> CGFloat {
        guard total.isFinite, total > 0, fraction.isFinite else { return 0 }
        let maxLeft = max(minPane, total - minPane)
        return min(max(total * fraction, minPane), maxLeft)
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
    @State private var insertion: TabInsertion?
    @State private var trackingDrop = false

    private var tabs: [Document] {
        app.openDocuments.filter(\.isPinned) + app.openDocuments.filter { !$0.isPinned }
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(tabs) { document in
                        TabItemView(document: document, isActive: document.id == app.activeDocumentID,
                                    insertion: $insertion, trackingDrop: $trackingDrop)
                            .id(document.id)
                    }
                    Color.clear
                        .frame(minWidth: DS.Layout.tabMinWidth, maxWidth: .infinity)
                        .frame(height: DS.Bar.primary)
                        .onDrop(of: [.utf8PlainText, .plainText, .text],
                                delegate: TabEndDropDelegate(app: app, insertion: $insertion,
                                                             trackingDrop: $trackingDrop))
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
        .background {
            if insertion != nil {
                TabDragEndMonitor {
                    trackingDrop = false
                    insertion = nil
                }
            }
        }
    }
}

struct TabItemView: View {
    @ObservedObject var document: Document
    let isActive: Bool
    @Binding var insertion: TabInsertion?
    @Binding var trackingDrop: Bool
    @EnvironmentObject var app: AppState
    @State private var hovering = false
    @State private var width: CGFloat = DS.Layout.tabMinWidth

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
        .overlay(alignment: insertion?.after == true ? .trailing : .leading) {
            if insertion?.id == document.id {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: DS.Space.xxs)
                    .padding(.vertical, DS.Space.xs)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            app.primarySplitDocumentID = document.id
            app.activeDocumentID = document.id
        }
        .onGeometryChange(for: CGFloat.self) { proxy in proxy.size.width } action: { width = $0 }
        .draggable(document.id.uuidString)
        .onDrop(of: [.utf8PlainText, .plainText, .text],
                delegate: TabReorderDropDelegate(target: document.id, width: width,
                                                 app: app, insertion: $insertion,
                                                 trackingDrop: $trackingDrop))
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

struct TabInsertion: Equatable {
    var id: UUID
    var after: Bool
}

private struct TabReorderDropDelegate: DropDelegate {
    let target: UUID
    let width: CGFloat
    let app: AppState
    @Binding var insertion: TabInsertion?
    @Binding var trackingDrop: Bool

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.utf8PlainText, .plainText, .text])
    }

    func dropEntered(info: DropInfo) {
        trackingDrop = true
        updateInsertion(info)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        if trackingDrop { updateInsertion(info) }
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        insertion = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        let after = insertion?.id == target ? (insertion?.after ?? false) : info.location.x >= width / 2
        trackingDrop = false
        insertion = nil
        return Self.loadTabID(from: info) { id in
            app.reorderDocument(id, beside: target, after: after)
        }
    }

    private func updateInsertion(_ info: DropInfo) {
        insertion = TabInsertion(id: target, after: info.location.x >= width / 2)
    }

    static func loadTabID(from info: DropInfo, deliver: @escaping (UUID) -> Void) -> Bool {
        let types: [UTType] = [.utf8PlainText, .plainText, .text]
        guard let provider = info.itemProviders(for: types).first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.utf8PlainText.identifier, options: nil) { item, _ in
            let raw: String?
            if let data = item as? Data {
                raw = String(data: data, encoding: .utf8)
            } else if let string = item as? String {
                raw = string
            } else {
                raw = (item as? NSString) as String?
            }
            guard let raw, let id = UUID(uuidString: raw.trimmingCharacters(in: .whitespacesAndNewlines)) else { return }
            DispatchQueue.main.async { deliver(id) }
        }
        return true
    }
}

private struct TabEndDropDelegate: DropDelegate {
    let app: AppState
    @Binding var insertion: TabInsertion?
    @Binding var trackingDrop: Bool

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.utf8PlainText, .plainText, .text])
    }

    func dropEntered(info: DropInfo) {
        trackingDrop = true
        markEnd()
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        if trackingDrop { markEnd() }
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        insertion = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        trackingDrop = false
        insertion = nil
        return TabReorderDropDelegate.loadTabID(from: info) { id in
            app.moveDocumentToEnd(id)
        }
    }

    private func markEnd() {
        if let last = app.openDocuments.last {
            insertion = TabInsertion(id: last.id, after: true)
        }
    }
}

private struct TabDragEndMonitor: NSViewRepresentable {
    var onEnded: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onEnded: onEnded) }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.start()
        return NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onEnded = onEnded
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.stop()
    }

    final class Coordinator {
        var onEnded: () -> Void
        private var monitor: Any?

        init(onEnded: @escaping () -> Void) { self.onEnded = onEnded }

        func start() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .keyDown]) { [weak self] event in
                if event.type == .keyDown, event.keyCode != 53 { return event }
                DispatchQueue.main.async { self?.onEnded() }
                return event
            }
        }

        func stop() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
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
