import AppKit
import SwiftUI

struct NotebookView: View {
    @ObservedObject var document: Document
    @ObservedObject var notebook: Notebook
    @ObservedObject var find: FindState
    @ObservedObject private var presentation = AppState.shared.editorPresentation

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
            NotebookScrollView(document: document, notebook: notebook,
                               scrollRequest: presentation.scrollRequest)
        }
        .background(DS.Chrome.canvas)
        .background(CommandModeHost())
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
        .background(DS.Chrome.bar)
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

enum NotebookScrolling {
    private static var scrollViews = NSHashTable<NSScrollView>.weakObjects()

    static func register(scrollView: NSScrollView) { scrollViews.add(scrollView) }

    static func scrollView(in window: NSWindow?) -> NSScrollView? {
        scrollViews.allObjects.first { $0.window === window }
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
