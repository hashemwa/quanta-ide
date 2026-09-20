import AppKit
import SwiftUI

struct NotebookView: View {
    @ObservedObject var document: Document
    @ObservedObject var notebook: Notebook
    @ObservedObject var find: FindState
    @EnvironmentObject var app: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(document: Document, notebook: Notebook) {
        self.document = document
        self.notebook = notebook
        self.find = document.find
    }

    var body: some View {
        VStack(spacing: 0) {
            NotebookNavigator(document: document, notebook: notebook)
            if find.isVisible {
                FindBarView(document: document, find: find)
                Divider()
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DS.Space.l) {
                        ForEach(notebook.cells) { cell in
                            CellView(cell: cell, document: document, notebook: notebook)
                                .id(cell.id)
                        }
                        HStack(spacing: 10) {
                            Button {
                                app.appendCell(type: .code, to: notebook, in: document)
                            } label: {
                                Label("Code", systemImage: "plus")
                            }
                            Button {
                                app.appendCell(type: .markdown, to: notebook, in: document)
                            } label: {
                                Label("Markdown", systemImage: "plus")
                            }
                            Spacer()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .padding(.leading, DS.Space.m + DS.Layout.cellGutterWidth + DS.Space.m)
                        .padding(.top, DS.Space.xs)
                    }
                    .padding(.vertical, DS.Space.l)
                    .padding(.trailing, DS.Space.xl)
                    .background(NotebookScrollMarker())
                }
                .onChange(of: app.scrollRequest) { _, target in
                    guard let target, notebook.cells.contains(where: { $0.id == target }) else { return }
                    withAnimation(reduceMotion ? nil : DS.Motion.quick) {
                        proxy.scrollTo(target, anchor: nil)
                    }
                    app.scrollRequest = nil
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .background(CommandModeHost())
        .environment(\.monoFontSize, app.editorFontSize - 1)
    }
}

struct FindBarView: View {
    @ObservedObject var document: Document
    @ObservedObject var find: FindState
    @EnvironmentObject var app: AppState
    @State private var handledFocusRequest = 0

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: DS.Space.m) {
                IconButton(find.showReplace ? "chevron.down" : "chevron.right",
                           help: find.showReplace ? "Hide replace" : "Show replace",
                           symbolWeight: .semibold) {
                    find.showReplace.toggle()
                }

                SearchField(text: $find.query, prompt: "Find in notebook",
                            focusRequest: find.focusRequest,
                            handledFocusRequest: $handledFocusRequest) {
                        let backwards = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
                        app.findAdvance(in: document, delta: backwards ? -1 : 1)
                    }
                    .frame(minWidth: DS.Layout.findFieldMinWidth, idealWidth: DS.Layout.findFieldIdealWidth, maxWidth: .infinity)
                    .onChange(of: find.query) { _, _ in app.findQueryChanged(in: document) }

                Text(countLabel)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 54, alignment: .leading)

                IconButton("chevron.up", help: "Previous match (⇧⌘G)") {
                    app.findAdvance(in: document, delta: -1)
                }
                IconButton("chevron.down", help: "Next match (⌘G)") {
                    app.findAdvance(in: document, delta: 1)
                }

                IconButton("xmark", help: "Close find bar (Esc)", symbolWeight: .semibold) {
                    app.closeFind(in: document)
                }
            }
            .frame(height: DS.Bar.secondary)
            if find.showReplace {
                HStack(spacing: DS.Space.m) {
                    Image(systemName: "arrow.2.squarepath")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(width: DS.Layout.slot)
                    TextField("Replace with", text: $find.replacement)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .frame(minWidth: DS.Layout.findFieldMinWidth, idealWidth: DS.Layout.findFieldIdealWidth, maxWidth: .infinity)
                        .onSubmit { app.replaceCurrentMatch(in: document) }
                    Button("Replace") { app.replaceCurrentMatch(in: document) }
                        .disabled(find.matches.isEmpty)
                    Button("Replace All") { app.replaceAllMatches(in: document) }
                        .disabled(find.matches.isEmpty)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .frame(height: DS.Bar.secondary)
            }
        }
        .padding(.horizontal, DS.Space.bar)
        .background(.bar)
        .onExitCommand { app.closeFind(in: document) }
    }

    private var countLabel: String {
        if find.query.isEmpty { return "" }
        if find.matches.isEmpty { return "0 found" }
        return "\(find.currentIndex + 1) of \(find.matches.count)"
    }
}

private struct CommandModeHost: NSViewRepresentable {
    func makeNSView(context: Context) -> CommandCatcherView {
        CommandCatcherView(frame: .zero)
    }

    func updateNSView(_ view: CommandCatcherView, context: Context) {}
}

private struct NotebookScrollMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        DispatchQueue.main.async { NotebookScrolling.register(marker: view) }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        NotebookScrolling.register(marker: nsView)
    }
}

enum NotebookScrolling {
    private static var markers = NSHashTable<NSView>.weakObjects()

    static func register(marker: NSView) { markers.add(marker) }

    static func scrollView(in window: NSWindow?) -> NSScrollView? {
        for marker in markers.allObjects where marker.window === window {
            var node: NSView? = marker.superview
            while let current = node {
                if let scroll = current as? NSScrollView { return scroll }
                node = current.superview
            }
        }
        return nil
    }

    static func page(up: Bool, in window: NSWindow?) {
        guard let scrollView = scrollView(in: window) else { return }
        let clip = scrollView.contentView
        var origin = clip.bounds.origin
        origin.y = clamp(origin.y + clip.bounds.height * 0.9 * (up ? -1 : 1), in: scrollView)
        animate(clip, scrollView, to: origin)
    }

    static func scrollToEdge(top: Bool, in window: NSWindow?) {
        guard let scrollView = scrollView(in: window) else { return }
        let clip = scrollView.contentView
        var origin = clip.bounds.origin
        origin.y = top ? 0 : clamp(.greatestFiniteMagnitude, in: scrollView)
        animate(clip, scrollView, to: origin)
    }

    private static func clamp(_ y: CGFloat, in scrollView: NSScrollView) -> CGFloat {
        let maxY = max(0, (scrollView.documentView?.frame.height ?? 0) - scrollView.contentView.bounds.height)
        return max(0, min(y, maxY))
    }

    private static func animate(_ clip: NSClipView, _ scrollView: NSScrollView, to origin: NSPoint) {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            clip.setBoundsOrigin(origin)
            scrollView.reflectScrolledClipView(clip)
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            clip.animator().setBoundsOrigin(origin)
        }
        scrollView.reflectScrolledClipView(clip)
    }
}

final class CommandCatcherView: NSView {
    private static var all = NSHashTable<CommandCatcherView>.weakObjects()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        Self.all.add(self)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    static func activeCatcher(in window: NSWindow) -> CommandCatcherView? {
        all.allObjects.first { $0.window === window }
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        AppState.shared.isCommandMode = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        AppState.shared.isCommandMode = false
        return true
    }

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .option, .control])
        if modifiers.isEmpty {
            switch event.keyCode {
            case 116: NotebookScrolling.page(up: true, in: window); return
            case 121: NotebookScrolling.page(up: false, in: window); return
            case 115: NotebookScrolling.scrollToEdge(top: true, in: window); return
            case 119: NotebookScrolling.scrollToEdge(top: false, in: window); return
            case 49:
                NotebookScrolling.page(up: event.modifierFlags.contains(.shift), in: window)
                return
            default:
                break
            }
        }
        _ = AppState.shared.handleCommandModeKey(event)
    }
}

struct CellView: View {
    @ObservedObject var cell: NotebookCell
    @ObservedObject var document: Document
    @ObservedObject var notebook: Notebook
    private var app: AppState { AppState.shared }
    @ObservedObject private var selection = AppState.shared.selection
    @State private var hovering = false
    @Environment(\.monoFontSize) private var monoFontSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isSelected: Bool { selection.selectedCellIDs.contains(cell.id) || selection.selectedCellID == cell.id }

    var body: some View {
        HStack(alignment: .top, spacing: DS.Space.m) {
            gutter
            VStack(alignment: .leading, spacing: DS.Space.s) {
                content
                if cell.cellType == .code && !cell.outputs.isEmpty {
                    outputs
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.leading, DS.Space.m)
        .draggable(cell.id.uuidString)
        .dropDestination(for: String.self) { values, _ in
            guard let raw = values.first, let draggedID = UUID(uuidString: raw) else { return false }
            app.reorderCells(draggedID: draggedID, before: cell.id,
                             in: notebook, document: document)
            return true
        }
        .scrollAwareHover($hovering)
        .contextMenu { menuItems }
    }

    private var gutter: some View {
        VStack(spacing: 4) {
            if cell.cellType == .code {
                if cell.isRunning {
                    ProgressView()
                        .controlSize(.mini)
                        .frame(height: DS.Layout.statusSlot)
                } else if cell.isQueued {
                    Image(systemName: "clock")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .help("Queued — waiting for earlier cells")
                } else {
                    Text(cell.executionCount.map { "[\($0)]" } ?? "[ ]")
                        .font(.caption.monospaced())
                        .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                }
                if cell.hasStaleOutput && !cell.isRunning {
                    Image(systemName: "clock.badge.exclamationmark")
                        .foregroundStyle(.orange).font(.caption)
                        .help("Output is stale: the source changed after the last run")
                        .accessibilityLabel("Output is stale")
                }
                if let duration = cell.lastDuration, !cell.isRunning {
                    Text(Self.durationLabel(duration))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .help("Last run time: \(Self.durationLabel(duration))")
                }
                IconButton("play.fill", help: "Run cell (⌘↩)") {
                    app.runCell(cell, in: document, advance: false)
                }
                .opacity(hovering || isSelected ? 1 : 0)
                .allowsHitTesting(hovering || isSelected)
                .disabled(cell.isRunning)
                .animation(reduceMotion ? nil : DS.Motion.hover, value: hovering || isSelected)
            } else if cell.cellType == .markdown {
                markdownToggle
                    .opacity(hovering || isSelected ? 1 : 0)
                    .allowsHitTesting(hovering || isSelected)
                    .animation(reduceMotion ? nil : DS.Motion.hover, value: hovering || isSelected)
            }
            IconMenu("plus", help: "Insert Code or Markdown Above or Below") {
                CellInsertionActions(cell: cell, notebook: notebook, document: document)
            }
            .opacity(hovering || isSelected ? 1 : 0)
            .allowsHitTesting(hovering || isSelected)
            .accessibilityHidden(!(hovering || isSelected))
        }
        .frame(width: DS.Layout.cellGutterWidth)
        .padding(.top, DS.Space.m)
        .contentShape(Rectangle())
        .onTapGesture {
            app.activeDocumentID = document.id
            app.selectCell(cell, in: notebook, modifiers: NSEvent.modifierFlags)
        }
    }

    static func durationLabel(_ seconds: Double) -> String {
        if seconds < 0.1 { return "<0.1s" }
        if seconds < 60 { return String(format: "%.1fs", seconds) }
        let minutes = Int(seconds) / 60
        return "\(minutes)m \(Int(seconds) % 60)s"
    }

    @ViewBuilder
    private var content: some View {
        if cell.isSourceCollapsed {
            collapsedSource
        } else if cell.cellType != .markdown || cell.isEditingMarkdown {
            editor
        } else {
            MarkdownView(source: cell.source.isEmpty
                         ? "*Empty markdown cell — double-click to edit*"
                         : cell.source,
                         selectable: true,
                         attachments: Notebook.attachmentData(cell.extraKeys["attachments"]),
                         baseDirectory: document.url?.deletingLastPathComponent())
                .padding(.horizontal, DS.Layout.cellTextInset)
                .padding(.vertical, DS.Space.s)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .selectionOutline(isSelected)
                .onTapGesture(count: 2) {
                    cell.isEditingMarkdown = true
                    app.selectedCellID = cell.id
                    app.focusCellEditor(cell.id)
                }
                .onTapGesture {
                    app.activeDocumentID = document.id
                    app.selectedCellID = cell.id
                    app.enterCommandMode()
                }
        }
    }

    private var collapsedSource: some View {
        Button {
            app.setSourceCollapsed(false, for: cell, in: document)
        } label: {
            HStack(spacing: DS.Space.s) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                Text(collapsedPreview)
                    .font(.system(size: monoFontSize - 1, design: .monospaced))
                    .lineLimit(1)
                Text("⋯")
                    .font(.subheadline)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, DS.Space.m)
            .padding(.vertical, DS.Space.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .hoverHighlight(radius: DS.Radius.card)
            .inputCard(focused: isSelected)
        }
        .buttonStyle(.plain)
        .help("Expand source (\(max(1, cell.source.components(separatedBy: "\n").count)) lines)")
    }

    private var collapsedPreview: String {
        cell.source.components(separatedBy: "\n").first { !$0.isEmpty } ?? "(empty cell)"
    }

    private var editor: some View {
        GrowingCodeEditor(
            text: Binding(
                get: { cell.source },
                set: { newValue in
                    if cell.source != newValue {
                        cell.source = newValue
                        if !document.isDirty { document.isDirty = true }
                    }
                }),
            height: $cell.editorHeight,
            cellID: cell.id,
            onCommand: { command in
                app.handleCellCommand(command, cell: cell, document: document)
                return true
            },
            onFocus: { app.activeDocumentID = document.id; app.selectedCellID = cell.id },
            onEscape: { app.enterCommandMode() })
        .frame(height: cell.editorHeight)
        .padding(.horizontal, DS.Space.xs)
        .inputCard(focused: isSelected)
    }

    @ViewBuilder
    private var outputs: some View {
        if cell.isOutputCollapsed {
            Button {
                app.setOutputCollapsed(false, for: cell, in: document)
            } label: {
                HStack(spacing: DS.Space.s) {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                    Text("Output hidden")
                        .font(.subheadline)
                }
                .foregroundStyle(.tertiary)
                .padding(.horizontal, DS.Space.m)
                .padding(.vertical, 3)
            }
            .buttonStyle(.plain)
            .hoverHighlight()
            .help("Show output (O)")
        } else {
            OutputListView(cell: cell)
        }
    }

    private var markdownToggle: some View {
        IconButton(cell.isEditingMarkdown ? "eye" : "pencil",
                   help: cell.isEditingMarkdown ? "Preview markdown" : "Edit markdown") {
            if cell.isEditingMarkdown {
                cell.isEditingMarkdown = false
            } else {
                cell.isEditingMarkdown = true
                app.selectedCellID = cell.id
                app.focusCellEditor(cell.id)
            }
        }
    }

    @ViewBuilder
    private var menuItems: some View {
        Button("Run Cell") { app.runCell(cell, in: document, advance: false) }
        if selection.selectedCellIDs.count > 1 {
            Button("Run Selected Cells") { app.runSelectedCells() }
        }
        Button("Run Cells Above") { app.runCells(above: cell, in: document) }
        Button("Run Cells Below") { app.runCells(below: cell, in: document) }
        Button("Run All Cells") { app.runAllCells(in: document) }
        Divider()
        Button("Copy Cell") { app.copyCell(cell, in: notebook) }
        Button("Cut Cell") {
            app.copyCell(cell, in: notebook)
            app.deleteCell(cell, in: notebook, document: document)
        }
        Button("Paste Cell Below") { app.pasteCell(after: cell, in: notebook, document: document) }
        Button("Duplicate Cell") { app.duplicateCell(cell, in: notebook, document: document) }
        Divider()
        CellInsertionActions(cell: cell, notebook: notebook, document: document)
        Divider()
        if cell.cellType == .code {
            Button("Convert to Markdown") { app.convertCell(cell, to: .markdown, in: document) }
        } else {
            Button("Convert to Code") { app.convertCell(cell, to: .code, in: document) }
        }
        Button(cell.isSourceCollapsed ? "Expand Source" : "Collapse Source") {
            app.setSourceCollapsed(!cell.isSourceCollapsed, for: cell, in: document)
        }
        if cell.cellType == .code {
            Button(cell.isOutputCollapsed ? "Show Output" : "Hide Output") {
                app.setOutputCollapsed(!cell.isOutputCollapsed, for: cell, in: document)
            }
            Button("Clear Output") {
                app.clearOutput(for: cell, in: document)
            }
            if !document.clearedOutputs.isEmpty {
                Button("Undo Clear Output") { app.undoClearedOutput(in: document) }
            }
        }
        Divider()
        Button("Move Up") { app.moveCell(cell, direction: -1, in: notebook, document: document) }
        Button("Move Down") { app.moveCell(cell, direction: 1, in: notebook, document: document) }
        Divider()
        Button("Delete Cell", role: .destructive) {
            app.deleteCell(cell, in: notebook, document: document)
        }
    }
}
