import Foundation
import JavaScriptCore

enum NotebookMath {
    private static let context: JSContext? = {
        guard let url = Bundle.main.url(forResource: "katex.min", withExtension: "js", subdirectory: "KaTeX")
                ?? Bundle.main.url(forResource: "katex.min", withExtension: "js"),
              let script = try? String(contentsOf: url, encoding: .utf8),
              let context = JSContext() else { return nil }
        context.evaluateScript(script)
        return context
    }()

    static func html(_ tex: String, display: Bool) -> String {
        let options: [String: Any] = ["output": "mathml", "displayMode": display,
                                     "throwOnError": false, "trust": false, "maxExpand": 1000, "maxSize": 20]
        if let context, let katex = context.objectForKeyedSubscript("katex"),
           let result = katex.invokeMethod("renderToString", withArguments: [tex, options]),
           !result.isUndefined, let html = result.toString() { return html }
        return "<code class=\"math-error\">\(RichOutput.escape(tex))</code>"
    }
}
