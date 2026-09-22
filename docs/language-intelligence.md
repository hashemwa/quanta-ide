# Language intelligence

Quanta currently keeps Python editor support small and native: AppKit provides the text
editor, a Swift lexical scanner provides syntax coloring, and the selected Python kernel
provides completions and call documentation for the live session. The app does not bundle
a separate Python analyzer or language-server runtime.

Semantic diagnostics, navigation, refactoring, and completion before execution are
deferred until a Swift-native design can provide them without adding a large runtime or
helper binary to the application.
