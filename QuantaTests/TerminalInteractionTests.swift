import AppKit
import Combine
import WebKit
import XCTest
@testable import Quanta

@MainActor
final class TerminalInteractionTests: XCTestCase {
    private func load(_ session: TerminalSession, width: CGFloat = 640, height: CGFloat = 240,
                      renderOffscreen: Bool = false) async -> WKWebView {
        let loaded = expectation(description: "Terminal renderer is ready")
        let observation = session.$isReady.sink { ready in if ready { loaded.fulfill() } }
        let view = session.webView()
        if renderOffscreen {
            view.configuration.userContentController.addUserScript(WKUserScript(
                source: "window.requestAnimationFrame = callback => setTimeout(() => callback(performance.now()), 16); window.cancelAnimationFrame = token => clearTimeout(token);",
                injectionTime: .atDocumentStart, forMainFrameOnly: true))
        }
        view.frame = NSRect(x: 0, y: 0, width: width, height: height)
        await fulfillment(of: [loaded], timeout: 15)
        observation.cancel()
        return view
    }

    func testTerminalGridFitsThePaddedViewport() async throws {
        let session = TerminalSession()
        session.appearance(dark: false, size: 20)
        let view = await load(session)
        let result = try await view.evaluateJavaScript("(() => { fit.fit(); const rect = document.querySelector('.xterm-screen').getBoundingClientRect(); return {left:rect.left,top:rect.top,right:rect.right,bottom:rect.bottom,width:innerWidth,height:innerHeight,font:term.options.fontSize}; })()")
        let bounds = try XCTUnwrap(result as? [String: Double])
        XCTAssertEqual(bounds["font"], 20)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(bounds["left"]), 10)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(bounds["top"]), 6)
        XCTAssertLessThanOrEqual(try XCTUnwrap(bounds["right"]), try XCTUnwrap(bounds["width"]) - 10 + 0.5)
        XCTAssertLessThanOrEqual(try XCTUnwrap(bounds["bottom"]), try XCTUnwrap(bounds["height"]) - 6 + 0.5)
    }

    func testHiddenTerminalDoesNotFocusAndActivationHonorsEarlyFocusRequest() async throws {
        let hidden = TerminalSession()
        let hiddenView = await load(hidden)
        let initiallyFocused = try await hiddenView.evaluateJavaScript("document.activeElement === term.textarea")
        XCTAssertEqual(initiallyFocused as? Bool, false)

        let active = TerminalSession()
        active.setActive(true)
        active.focus()
        let activeView = await load(active)
        let focused = try await activeView.evaluateJavaScript("document.activeElement === term.textarea")
        XCTAssertEqual(focused as? Bool, true)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 240),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = activeView
        let responder = try XCTUnwrap(window.firstResponder as? NSView)
        XCTAssertTrue(responder === activeView || responder.isDescendant(of: activeView))
        active.setActive(false)
        let blurred = try await activeView.evaluateJavaScript("document.activeElement === term.textarea")
        XCTAssertEqual(blurred as? Bool, false)
        window.contentView = nil
        active.focus()
        active.setActive(true)
        window.contentView = activeView
        let restored = try XCTUnwrap(window.firstResponder as? NSView)
        XCTAssertTrue(restored === activeView || restored.isDescendant(of: activeView))
    }

    func testTerminalDrainsOutputBeforeReportingExit() async {
        let session = TerminalSession()
        let exited = expectation(description: "Shell exited after final output")
        var output = Data()
        session.onOutput = { output.append($0) }
        session.start(in: FileManager.default.temporaryDirectory, shell: "/bin/sh")
        let observation = session.$exitStatus.sink { status in if status != nil { exited.fulfill() } }
        defer { observation.cancel(); session.stop() }
        session.send("stty -echo; head -c 100000 /dev/zero | tr '\\000' x; printf 'QUANTA_FINAL_%s\\n' OUTPUT; exit\n")
        await fulfillment(of: [exited], timeout: 10)
        let text = String(decoding: output, as: UTF8.self)
        XCTAssertTrue(text.contains(String(repeating: "x", count: 100000)))
        XCTAssertTrue(text.contains("QUANTA_FINAL_OUTPUT"))
        XCTAssertFalse(session.running)
    }

    func testLongTerminalOutputRendersInLightAndDarkAppearance() async throws {
        let directory = URL(fileURLWithPath: "/tmp/quanta-console-terminal-review", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for dark in [false, true] {
            let session = TerminalSession()
            session.appearance(dark: dark, size: 13)
            let view = await load(session, width: 720, height: 240, renderOffscreen: true)
            let window = OffscreenTerminalWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = view
            let screenBounds = NSScreen.screens.reduce(NSRect.zero) { $0.union($1.frame) }
            window.setFrameOrigin(NSPoint(x: screenBounds.maxX + view.frame.width + 1000,
                                          y: screenBounds.maxY + view.frame.height + 1000))
            window.orderBack(nil)
            defer { window.close() }
            let output = (1...60).map { index in
                "\u{1B}[32m✓\u{1B}[0m Batch \(index): processed 2,048 records — mean=13.24, elapsed=0.02s\r\n"
            }.joined() + "\u{1B}[33mWarning:\u{1B}[0m A long diagnostic wraps within the pane without hiding its final words or the shell prompt.\r\nquanta ~/analysis % "
            let written = expectation(description: "Terminal finishes rendering representative output")
            var renderingError: Error?
            var renderedText: String?
            view.callAsyncJavaScript("fit.fit(); await new Promise(resolve => term.write(output, resolve)); await new Promise((resolve, reject) => { const deadline = setTimeout(() => { subscription.dispose(); reject(new Error('Terminal did not render offscreen')); }, 2500); const subscription = term.onRender(() => { subscription.dispose(); clearTimeout(deadline); resolve(); }); term.refresh(0, term.rows - 1); }); return document.querySelector('.xterm-rows').textContent;",
                                     arguments: ["output": output], in: nil, in: .page) { result in
                switch result {
                case .success(let text): renderedText = text as? String
                case .failure(let error): renderingError = error
                }
                written.fulfill()
            }
            await fulfillment(of: [written], timeout: 5)
            if let renderingError { throw renderingError }
            XCTAssertTrue(try XCTUnwrap(renderedText).contains("quanta ~/analysis %"))
            let image: NSImage = try await withCheckedThrowingContinuation { continuation in
                view.takeSnapshot(with: nil) { image, error in
                    if let image { continuation.resume(returning: image) }
                    else { continuation.resume(throwing: error ?? QuantaError("Terminal snapshot was unavailable")) }
                }
            }
            let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            XCTAssertGreaterThan(data.count, 2000)
            try data.write(to: directory.appendingPathComponent("terminal-\(dark ? "dark" : "light").png"))
        }
    }
}

private final class OffscreenTerminalWindow: NSWindow {
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}
