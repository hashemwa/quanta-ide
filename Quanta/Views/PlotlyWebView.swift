import Combine
import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct PlotlyFigureView: View {
    let html: String
    let jsPath: String
    let image: NSImage?
    var imageData: Data = Data()
    let height: Double
    let cacheKey: UUID
    @StateObject private var controller = PlotlyController()
    @State private var panMode = false

    private var rendererPath: String { PlotlyWebView.availableScriptPath(jsPath) ?? "" }

    var body: some View {
        if !rendererPath.isEmpty {
            VStack(alignment: .leading, spacing: DS.Space.xxs) {
                PlotlyWebView(html: html, jsPath: rendererPath, cacheKey: cacheKey,
                              controller: controller)
                    .frame(maxWidth: DS.Layout.outputMaxWidth)
                    .frame(height: CGFloat(height) + 16)
                    .clipShape(RoundedRectangle(cornerRadius: DS.Radius.card))
                    .accessibilityAction(named: "Zoom In") { controller.zoom(0.75) }
                    .accessibilityAction(named: "Zoom Out") { controller.zoom(1.35) }
                    .accessibilityAction(named: "Reset View") { controller.resetView() }
                    .accessibilityAction(named: "Copy Image") { controller.copyPNG() }
                    .accessibilityAction(named: "Open Image in Window") {
                        PlotWindow.open(html: html, jsPath: rendererPath)
                    }
                    .accessibilityAction(named: "Save Image as PNG…") { controller.savePNG() }
                    .plotControls(pinned: panMode || controller.isExporting) { controls }
                if let error = controller.exportError {
                    PlotErrorMessage(message: error)
                        .frame(maxWidth: DS.Layout.outputMaxWidth)
                }
            }
        } else if let image {
            ImageOutputView(data: imageData, image: image, fileName: "figure.png")
                .help("Static preview — plotly.js was not found in this environment; install the plotly package for interactive figures")
        } else {
            Label("Figure could not be rendered — plotly.js is missing and no image was saved with this output.",
                  systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(DS.Space.m)
                .outputCard(.warning)
        }
    }

    @ViewBuilder
    private var controls: some View {
        IconButton("plus.magnifyingglass", help: "Zoom In") {
            controller.zoom(0.75)
        }
        IconButton("minus.magnifyingglass", help: "Zoom Out") {
            controller.zoom(1.35)
        }
        IconButton(panMode ? "hand.draw.fill" : "hand.draw", help: "Pan Mode", isActive: panMode) {
            panMode.toggle()
            controller.setDragMode(pan: panMode)
        }
        IconButton("house", help: "Reset View") { controller.resetView() }
        ToolbarDivider()
        if controller.isExporting {
            ProgressView().controlSize(.small)
                .frame(width: DS.Layout.slot)
                .accessibilityLabel("Exporting plot")
        }
        IconButton("doc.on.doc", help: "Copy Image") { controller.copyPNG() }
            .disabled(controller.isExporting)
        IconButton("macwindow.badge.plus", help: "Open Image in Window (⌥⌘P)") {
            PlotWindow.open(html: html, jsPath: rendererPath)
        }
        IconButton("square.and.arrow.down", help: "Save Image as PNG…") {
            controller.savePNG()
        }
        .disabled(controller.isExporting)
    }
}

final class PlotlyController: ObservableObject {
    weak var webView: WKWebView?
    @Published var exportError: String?
    @Published private(set) var isExporting = false

    private static let target = "document.querySelector('.plotly-graph-div')"

    private func run(_ js: String) {
        webView?.evaluateJavaScript(js, completionHandler: nil)
    }

    func zoom(_ factor: Double) {
        run("""
        (function () {
            var gd = \(Self.target);
            if (!gd || !gd._fullLayout) { return; }
            if (gd._fullLayout.xaxis) {
                function scaled(range) {
                    var c = (range[0] + range[1]) / 2;
                    var h = (range[1] - range[0]) / 2 * \(factor);
                    return [c - h, c + h];
                }
                Plotly.relayout(gd, {
                    'xaxis.range': scaled(gd._fullLayout.xaxis.range),
                    'yaxis.range': scaled(gd._fullLayout.yaxis.range),
                });
            } else if (gd._fullLayout.scene) {
                var eye = (gd._fullLayout.scene.camera || {}).eye || {x: 1.25, y: 1.25, z: 1.25};
                Plotly.relayout(gd, {'scene.camera.eye': {
                    x: eye.x * \(factor), y: eye.y * \(factor), z: eye.z * \(factor)}});
            }
        })();
        """)
    }

    func setDragMode(pan: Bool) {
        run("Plotly.relayout(\(Self.target), {dragmode: '\(pan ? "pan" : "zoom")'});")
    }

    func resetView() {
        run("""
        (function () {
            var gd = \(Self.target);
            if (!gd || !gd._fullLayout) { return; }
            if (gd._fullLayout.xaxis) {
                Plotly.relayout(gd, {'xaxis.autorange': true, 'yaxis.autorange': true});
            } else {
                Plotly.relayout(gd, {'scene.camera': null});
            }
        })();
        """)
    }

    func savePNG() {
        exportPNG { data in
            let panel = NSSavePanel()
            panel.nameFieldStringValue = "plot.png"
            panel.allowedContentTypes = [.png]
            if panel.runModal() == .OK, let url = panel.url {
                do {
                    try data.write(to: url, options: .atomic)
                } catch {
                    self.exportError = "Couldn’t save plot: \(error.localizedDescription)"
                }
            }
        }
    }

    func copyPNG() {
        exportPNG { data in
            NSPasteboard.general.clearContents()
            if !NSPasteboard.general.setData(data, forType: .png) {
                self.exportError = "Couldn’t copy the plot to the clipboard."
            }
        }
    }

    private func exportPNG(_ completion: @escaping (Data) -> Void) {
        guard !isExporting else { return }
        exportError = nil
        guard let webView else {
            exportError = "The plot renderer is unavailable. Reopen the output and try again."
            return
        }
        isExporting = true
        webView.callAsyncJavaScript(
            "return await Plotly.toImage(\(Self.target), {format: 'png', scale: 2});",
            arguments: [:], in: nil, in: .page) { result in
            DispatchQueue.main.async {
                self.isExporting = false
                guard case .success(let value) = result,
                      let dataURL = value as? String,
                      dataURL.hasPrefix("data:image/png;base64,"),
                      let comma = dataURL.firstIndex(of: ","),
                      let data = Data(base64Encoded: String(dataURL[dataURL.index(after: comma)...])),
                      !data.isEmpty else {
                    self.exportError = "Couldn’t export this plot. Wait for it to finish loading and try again."
                    return
                }
                completion(data)
            }
        }
    }

}

struct PlotlyWebView: NSViewRepresentable {
    let html: String
    let jsPath: String
    let cacheKey: UUID
    var controller: PlotlyController? = nil

    private static var scriptCache: [String: String] = [:]
    private static var viewCache: [UUID: WKWebView] = [:]
    private static var viewOrder: [UUID] = []

    static func availableScriptPath(_ path: String) -> String? {
        if !path.isEmpty, FileManager.default.isReadableFile(atPath: path) { return path }
        return RichOutput.bundledPlotlyPath
    }

    static func document(html: String, script: String, fillsWindow: Bool = false) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline' 'unsafe-eval'; style-src 'unsafe-inline'; img-src data: blob:; font-src data:; base-uri 'none'; form-action 'none'">
        <style>
        html, body { margin: 0; padding: 0; background: transparent; }
        \(fillsWindow ? ".plotly-graph-div { height: 100vh !important; width: 100vw !important; }" : "")
        </style><script>\(script.replacingOccurrences(of: "</script", with: "<\\/script"))</script></head><body>\(html)</body></html>
        """
    }

    static func script(at path: String) -> String? {
        if let cached = scriptCache[path] { return cached.isEmpty ? nil : cached }
        let script = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        scriptCache[path] = script
        return script.isEmpty ? nil : script
    }

    static func preloadScript(at path: String) {
        guard scriptCache[path] == nil else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let script = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            DispatchQueue.main.async {
                if scriptCache[path] == nil { scriptCache[path] = script }
            }
        }
    }

    static func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let featuresSel = NSSelectorFromString("_features")
        let setSel = NSSelectorFromString("_setEnabled:forFeature:")
        guard WKPreferences.responds(to: featuresSel),
              configuration.preferences.responds(to: setSel),
              let method = class_getInstanceMethod(WKPreferences.self, setSel),
              let features = WKPreferences.perform(featuresSel)?.takeUnretainedValue() as? [AnyObject]
        else { return configuration }
        for feature in features {
            guard feature.responds(to: NSSelectorFromString("key")),
                  let key = feature.value(forKey: "key") as? String,
                  key == "PreferPageRenderingUpdatesNear60FPSEnabled" else { continue }
            typealias SetEnabled = @convention(c) (AnyObject, Selector, Bool, AnyObject) -> Void
            unsafeBitCast(method_getImplementation(method), to: SetEnabled.self)(
                configuration.preferences, setSel, false, feature)
        }
        return configuration
    }

    func makeCoordinator() -> RichOutputView.Coordinator { RichOutputView.Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        if let cached = Self.viewCache[cacheKey], cached.superview == nil {
            Self.viewOrder.removeAll { $0 == cacheKey }
            Self.viewOrder.append(cacheKey)
            controller?.webView = cached
            cached.navigationDelegate = context.coordinator
            return cached
        }
        let webView = NotebookEmbeddedWebView(frame: .zero, configuration: Self.makeConfiguration())
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        let script = Self.script(at: jsPath) ?? ""
        let document = Self.document(html: html, script: script)
        webView.loadHTMLString(document, baseURL: nil)
        Self.viewCache[cacheKey] = webView
        Self.viewOrder.removeAll { $0 == cacheKey }
        Self.viewOrder.append(cacheKey)
        while Self.viewOrder.count > 6 {
            Self.viewCache.removeValue(forKey: Self.viewOrder.removeFirst())
        }
        controller?.webView = webView
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        controller?.webView = webView
    }
}

class PlotZoomableWebView: WKWebView {
    override func mouseMoved(with event: NSEvent) {
        if CursorZoneView.contains(windowPoint: event.locationInWindow, in: window) {
            NSCursor.arrow.set()
            return
        }
        super.mouseMoved(with: event)
    }

    override func cursorUpdate(with event: NSEvent) {
        if CursorZoneView.contains(windowPoint: event.locationInWindow, in: window) {
            NSCursor.arrow.set()
            return
        }
        super.cursorUpdate(with: event)
    }

    override func magnify(with event: NSEvent) {
        let location = convert(event.locationInWindow, from: nil)
        let deltaY = -Double(event.magnification) * 200
        let js = """
        (() => {
          const el = document.elementFromPoint(\(location.x), \(location.y));
          if (!el) { return; }
          el.dispatchEvent(new WheelEvent('wheel', {
            clientX: \(location.x), clientY: \(location.y),
            deltaY: \(deltaY), deltaMode: 0, ctrlKey: true,
            bubbles: true, cancelable: true, view: window,
          }));
        })();
        """
        evaluateJavaScript(js)
    }
}

final class NotebookEmbeddedWebView: PlotZoomableWebView {
    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.control) {
            super.scrollWheel(with: event)
        } else {
            nextResponder?.scrollWheel(with: event)
        }
    }
}

final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var bounds = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return bounds }
        if bounds.width > document.frame.width {
            bounds.origin.x = (document.frame.width - bounds.width) / 2
        }
        if bounds.height > document.frame.height {
            bounds.origin.y = (document.frame.height - bounds.height) / 2
        }
        return bounds
    }
}

final class PlotImageView: NSImageView {
    override func mouseDown(with event: NSEvent) {
        guard event.clickCount == 2, let scrollView = enclosingScrollView else {
            super.mouseDown(with: event)
            return
        }
        scrollView.animator().magnification = 1
    }
}

@MainActor
enum PlotWindow {
    private static var windows: [NSWindow] = []

    static func owns(_ window: NSWindow) -> Bool {
        windows.contains { $0 === window }
    }

    private final class CloseDelegate: NSObject, NSWindowDelegate {
        func windowWillClose(_ notification: Notification) {
            guard let closing = notification.object as? NSWindow else { return }
            Task { @MainActor in PlotWindow.windows.removeAll { $0 === closing } }
        }
    }
    private static let closeDelegate = CloseDelegate()
    private static let navigationDelegate = RichOutputView.Coordinator()

    private static let defaultSize = NSSize(width: 960, height: 640)

    static func open(html: String, jsPath: String) {
        let script = PlotlyWebView.script(at: jsPath) ?? ""
        let document = PlotlyWebView.document(html: html, script: script, fillsWindow: true)
        let webView = PlotZoomableWebView(frame: NSRect(origin: .zero, size: defaultSize),
                                          configuration: PlotlyWebView.makeConfiguration())
        webView.navigationDelegate = navigationDelegate
        webView.setValue(false, forKey: "drawsBackground")
        webView.loadHTMLString(document, baseURL: nil)
        present(webView, size: defaultSize)
    }

    static func open(image: NSImage) {
        let natural = image.size.width > 0 && image.size.height > 0 ? image.size : defaultSize
        let imageView = PlotImageView(frame: NSRect(origin: .zero, size: natural))
        imageView.image = image
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter

        let size = fittedSize(for: natural)
        let scrollView = NSScrollView(frame: NSRect(origin: .zero, size: size))
        scrollView.contentView = CenteringClipView()
        scrollView.documentView = imageView
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.25
        scrollView.maxMagnification = 8
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        present(scrollView, size: size)
    }

    private static func fittedSize(for natural: NSSize) -> NSSize {
        guard natural.width > 0, natural.height > 0 else { return defaultSize }
        guard let visible = NSScreen.main?.visibleFrame.insetBy(dx: 40, dy: 40),
              visible.width > 0, visible.height > 0 else { return natural }
        let scale = min(1, visible.width / natural.width, visible.height / natural.height)
        return NSSize(width: natural.width * scale, height: natural.height * scale)
    }

    private static func present(_ content: NSView, size: NSSize) {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Plot"
        window.contentView = content
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = closeDelegate
        windows.append(window)
        window.makeKeyAndOrderFront(nil)
    }
}
