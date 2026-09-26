import AppKit
import SwiftUI

struct NotebookChrome: View {
    @ObservedObject var document: Document
    @ObservedObject var find: FindState
    let pane: EditorPane

    init(document: Document, pane: EditorPane) {
        self.document = document
        self.find = document.find
        self.pane = pane
    }

    var body: some View {
        VStack(spacing: 0) {
            if find.isVisible {
                FindBarView(document: document, find: find)
                Divider()
            }
        }
        .frame(maxWidth: .infinity)
        .background(CommandModeHost(documentID: document.id, pane: pane))
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
                           help: find.showReplace ? "Hide Replace" : "Show Replace",
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

                IconButton("chevron.up", help: "Previous Match (⇧⌘G)") {
                    app.findAdvance(in: document, delta: -1)
                }
                IconButton("chevron.down", help: "Next Match (⌘G)") {
                    app.findAdvance(in: document, delta: 1)
                }

                IconButton("xmark", help: "Close Find Bar (Esc)", symbolWeight: .semibold) {
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
    let documentID: UUID
    let pane: EditorPane

    func makeNSView(context: Context) -> CommandCatcherView {
        let view = CommandCatcherView(frame: .zero)
        view.documentID = documentID
        view.pane = pane
        return view
    }

    func updateNSView(_ view: CommandCatcherView, context: Context) {
        view.documentID = documentID
        view.pane = pane
    }
}

enum NotebookScrolling {
    private static var scrollViews = NSHashTable<NSScrollView>.weakObjects()
    private static var destinations: [ObjectIdentifier: DocumentViewCache.Key] = [:]

    static func register(scrollView: NSScrollView, documentID: UUID, pane: EditorPane = .primary) {
        scrollViews.add(scrollView)
        let present = Set(scrollViews.allObjects.map(ObjectIdentifier.init))
        destinations = destinations.filter { present.contains($0.key) }
        destinations[ObjectIdentifier(scrollView)] = .init(documentID: documentID, pane: pane)
    }

    static func focusedPane(in window: NSWindow) -> EditorPane? {
        guard let focused = window.firstResponder as? NSView,
              let scrollView = scrollViews.allObjects.first(where: { focused.isDescendant(of: $0) }) else { return nil }
        return destinations[ObjectIdentifier(scrollView)]?.pane
    }

    static func scrollView(in window: NSWindow?) -> NSScrollView? {
        guard let window else { return nil }
        let visible = scrollViews.allObjects.filter { $0.window === window && !$0.isHiddenOrHasHiddenAncestor }
        if let focused = window.firstResponder as? NSView,
           let scrollView = visible.first(where: { focused.isDescendant(of: $0) }) {
            return scrollView
        }
        if let catcher = window.firstResponder as? CommandCatcherView,
           let documentID = catcher.documentID {
            let destination = DocumentViewCache.Key(documentID: documentID, pane: catcher.pane)
            return visible.first { destinations[ObjectIdentifier($0)] == destination }
        }
        return visible.first { destinations[ObjectIdentifier($0)]?.documentID == AppState.shared.activeDocumentID }
            ?? visible.first
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
    var documentID: UUID?
    var pane: EditorPane = .primary

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        Self.all.add(self)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    static func activeCatcher(in window: NSWindow, documentID: UUID? = nil,
                              pane: EditorPane? = nil) -> CommandCatcherView? {
        let visible = all.allObjects.filter { $0.window === window && !$0.isHiddenOrHasHiddenAncestor }
        let documentID = documentID ?? AppState.shared.activeDocumentID
        let matching = visible.filter { $0.documentID == documentID }
        let pane = pane ?? (window.firstResponder as? CommandCatcherView)?.pane ?? NotebookScrolling.focusedPane(in: window)
        return matching.first { $0.pane == pane } ?? matching.first ?? visible.first
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
