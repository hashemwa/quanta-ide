import AppKit
import SwiftUI

enum EditorPane: Hashable {
    case primary, secondary
}

protocol DocumentCanvas: AnyObject {
    var view: NSView { get }
    func focus(in window: NSWindow)
}

final class DocumentViewCache {
    struct Key: Hashable {
        let documentID: UUID
        let pane: EditorPane
    }

    static let shared = DocumentViewCache()
    static let capacity = 12
    static let didRelease = Notification.Name("QuantaDocumentCanvasesReleased")

    private var entries: [Key: DocumentCanvas] = [:]
    private var recency: [Key] = []

    var count: Int { entries.count }

    func contains(_ canvas: DocumentCanvas) -> Bool {
        entries.values.contains { $0 === canvas }
    }

    func canvas<T: DocumentCanvas>(for key: Key, make: () -> T) -> T {
        recency.removeAll { $0 == key }
        recency.append(key)
        if let cached = entries[key] as? T { return cached }
        let made = make()
        entries[key] = made
        if recency.count > Self.capacity {
            while recency.count > Self.capacity { entries[recency.removeFirst()] = nil }
            NotificationCenter.default.post(name: Self.didRelease, object: self)
        }
        return made
    }

    func retain(documents: Set<UUID>, splitVisible: Bool) {
        let released = entries.keys.filter {
            !documents.contains($0.documentID) || (!splitVisible && $0.pane == .secondary)
        }
        guard !released.isEmpty else { return }
        released.forEach { entries[$0] = nil }
        recency.removeAll { entries[$0] == nil }
        NotificationCenter.default.post(name: Self.didRelease, object: self)
    }
}

struct EditorStage: NSViewRepresentable {
    @ObservedObject var document: Document
    let pane: EditorPane
    let showsLineNumbers: Bool
    let wrapsLines: Bool
    let scrollRequest: UUID?
    @Environment(\.monoFontSize) private var monoFontSize

    func makeNSView(context: Context) -> EditorStageView { EditorStageView() }

    func updateNSView(_ stage: EditorStageView, context: Context) {
        stage.show(canvas())
    }

    static func dismantleNSView(_ stage: EditorStageView, coordinator: ()) {
        stage.releaseCanvases()
    }

    private func canvas() -> DocumentCanvas? {
        let key = DocumentViewCache.Key(documentID: document.id, pane: pane)
        switch document.kind {
        case .notebook:
            guard let notebook = document.notebook else { return nil }
            let canvas = DocumentViewCache.shared.canvas(for: key) {
                NotebookCanvas(document: document, notebook: notebook, monoFontSize: monoFontSize)
            }
            canvas.update(document: document, notebook: notebook, monoFontSize: monoFontSize,
                          scrollRequest: scrollRequest)
            return canvas
        case .script:
            let canvas = DocumentViewCache.shared.canvas(for: key) { ScriptCanvas(document: document) }
            canvas.update(document: document, showsLineNumbers: showsLineNumbers, wrapsLines: wrapsLines)
            return canvas
        case .dataSource, .dataFrame, .diff:
            return nil
        }
    }
}

final class EditorStageView: NSView {
    private struct Entry {
        weak var canvas: DocumentCanvas?
        let view: NSView
    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    private var releaseObserver: NSObjectProtocol?
    private weak var visibleCanvas: DocumentCanvas?
    private var focusedOnAttach = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        releaseObserver = NotificationCenter.default.addObserver(
            forName: DocumentViewCache.didRelease, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.removeReleasedCanvases() }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let releaseObserver { NotificationCenter.default.removeObserver(releaseObserver) }
    }

    private func removeReleasedCanvases() {
        for (key, entry) in entries where entry.canvas.map({ !DocumentViewCache.shared.contains($0) }) ?? true {
            if entry.view.superview === self { entry.view.removeFromSuperview() }
            entries[key] = nil
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, !focusedOnAttach, let visibleCanvas else { return }
        focusedOnAttach = true
        DispatchQueue.main.async { [weak visibleCanvas] in visibleCanvas?.focus(in: window) }
    }

    private func focusIsInside(_ view: NSView?) -> Bool {
        guard let view, let responder = window?.firstResponder as? NSView else { return false }
        return responder.isDescendant(of: view)
    }

    func show(_ canvas: DocumentCanvas?) {
        removeReleasedCanvases()
        let previous = visibleCanvas
        let focusWasInDocument = focusIsInside(previous?.view)
        if focusWasInDocument, canvas !== previous { window?.makeFirstResponder(nil) }
        let visibleKey = canvas.map(ObjectIdentifier.init)
        if let canvas, let visibleKey, entries[visibleKey]?.view.superview !== self {
            let view = canvas.view
            view.translatesAutoresizingMaskIntoConstraints = true
            addSubview(view)
            entries[visibleKey] = Entry(canvas: canvas, view: view)
        }
        for (key, entry) in entries {
            let visible = key == visibleKey
            entry.view.autoresizingMask = visible ? [.width, .height] : []
            if visible, entry.view.frame != bounds { entry.view.frame = bounds }
            if entry.view.isHidden == visible { entry.view.isHidden = !visible }
        }
        visibleCanvas = canvas
        guard let canvas, canvas !== previous, let window else { return }
        if focusWasInDocument || window.firstResponder === window || !focusedOnAttach {
            focusedOnAttach = true
            DispatchQueue.main.async { [weak canvas] in canvas?.focus(in: window) }
        }
    }

    func releaseCanvases() {
        for entry in entries.values where entry.view.superview === self {
            entry.view.removeFromSuperview()
        }
        entries.removeAll()
    }
}
