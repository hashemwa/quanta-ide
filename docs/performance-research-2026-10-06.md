# Performance research and animation restoration — October 6, 2026

The subsequent [user-supplied Instruments trace audit](instruments-trace-audit-2026-10-06.md)
records real Release-build frame hitches around native window resizing. It
supersedes the earlier lack of an interaction recording, while explaining the
limits of the trace's exported per-view data.

Animations are restored at the user's request. The corrected vertical sidebar and
conditional bottom-panel layout remain in place. The animation-removal step in
[the panel repair](panel-layout-repair-2026-10-06.md) is now superseded.

## What changed

Navigator and console reveal/hide, active-tab scrolling, Git disclosure, floating
toolbar fades, progress appearance, input focus feedback, notebook page/edge
scrolling, and plot zoom reset use their original animations again. The root
transaction no longer disables inherited animations. Existing Reduce Motion
handling is restored alongside the effects.

The Python lexer used to find the end of the current line separately for every
number. A dense numeric line repeatedly scanned overlapping suffixes, making
that portion of tokenization quadratic. The lexer now remembers the current
line's end; its cursor only moves forward, and crossing a line ending refreshes
the boundary. Number recognition, f-string handling, and token ranges are unchanged.

Each Python editor also retains its latest source/token snapshot. Highlighting
and the immediate completion-context check share that snapshot. Editing,
undoing, replacing the document source, or changing the language cannot reuse
tokens for a different source. Script editors use the same highlighting entry
point as notebook editors. This avoids duplicate parsing without changing the
completion delay or switching the editor framework.

## Measurements

The standalone [editor benchmark](../scripts/benchmark-editor.swift) compiles
the app's actual `PythonHighlighter.swift` and `EditorTheme.swift`. It takes
the median of seven calls using different appended source text on each call.
Source generation and text-storage construction are outside the timed interval.
The final row includes tokenization, foreground-color application, and the
completion-context check. It does not measure a full keystroke, frame rate,
Copilot/network latency, or native window zoom.

| Synthetic workload, optimized Swift | Before | After |
| --- | ---: | ---: |
| Tokenize 500 numbers on one line | 0.409 ms | 0.148 ms |
| Tokenize 2,000 numbers on one line | 4.698 ms | 0.582 ms |
| Tokenize 10,000 numbers on one line | 98.028 ms | 2.920 ms |
| Tokenize 2,000 short assignment lines | 0.786 ms | 0.863 ms |
| Highlight and check completion, 2,000 assignment lines | 4.970 ms | 3.893 ms |

The dense-line case improves about 34 times. Short-line tokenization has no
meaningful established improvement; small submillisecond differences are noise.
Token counts and aggregate checksums match before and after. Regression tests
also verify the exact numeric sequence across CR/LF/CRLF, interpolation, and
triple-quoted strings, and compare editor colors after edits, undo, and source
replacement with a fresh highlight.

A ten-second Instruments Time Profiler recording of the isolated unoptimized
baseline produced 6,066 main-thread samples. Resolving executable addresses against
its native symbol table identified `Lexer.lineEnd` on 3,885 sample stacks (64%).
This confirms substantial CPU work in the repeated suffix scan. The recording
ended at its configured time limit and terminated only the benchmark process.
It is not a recording of the user's notebook or of SwiftUI interaction hitches.

An additional `-Onone` run measured 2,000 numbers on one line at 247.338 ms
before and 1.141 ms after. The 10,000-number case measured 6,528.241 ms before
and 5.828 ms after. These are illustrative Debug microbenchmarks; part of that
run overlapped functional verification. They are not clean end-to-end latency
comparisons. The earlier sample identified the user's app as a Debug executable
under `debugserver`. Release is the appropriate configuration for interaction
profiling, but that observation does not prove why the actual IDE felt slow.

Benchmark executables, source snapshot, CSVs, and profiling artifacts are in
the ignored `.build/performance-audit/` directory. To repeat the current optimized
benchmark from the project root:

```sh
mkdir -p .build/performance-audit
xcrun swiftc -O -D REUSE_TOKENS -module-cache-path .build/performance-audit/module-cache Quanta/Editor/EditorTheme.swift Quanta/Editor/PythonHighlighter.swift scripts/benchmark-editor.swift -o .build/performance-audit/lexer-current
.build/performance-audit/lexer-current
```

## Primary-source research

- Apple's [Understanding and improving SwiftUI performance](https://developer.apple.com/documentation/xcode/understanding-and-improving-swiftui-performance)
  describes slow view calculations, excessive update frequency, broad observable
  dependencies, and geometry/state feedback. Its structured documentation was
  read in addition to the browser page.
- Apple's [Demystify SwiftUI performance](https://developer.apple.com/videos/play/wwdc2023/10160/)
  explains dependency scope, stable view identity, and expensive work in view bodies.
- Apple's [Optimize SwiftUI performance with Instruments](https://developer.apple.com/videos/play/wwdc2025/306/)
  shows how to correlate SwiftUI updates with Time Profiler, Hangs, and Hitches.
- Apple's [Profile, fix, and verify](https://developer.apple.com/videos/play/wwdc2026/268/)
  distinguishes CPU work, actor contention, and blocked main-thread I/O, and
  recommends profiling Release builds and comparing recordings.
- CodeEdit's [Highlighter](https://github.com/CodeEditApp/CodeEditSourceEditor/blob/main/Sources/CodeEditSourceEditor/Highlighting/Highlighter.swift)
  and [VisibleRangeProvider](https://github.com/CodeEditApp/CodeEditSourceEditor/blob/main/Sources/CodeEditSourceEditor/Highlighting/VisibleRangeProvider.swift)
  track edited/invalid ranges and prioritize visible text instead of recoloring
  every document indiscriminately.
- STTextView's [viewport layout delegate](https://github.com/krzyzanowskim/STTextView/blob/main/Sources/STTextViewAppKit/STTextView%2BNSTextViewportLayoutControllerDelegate.swift)
  reuses layout fragment views, prefetches a limited region, and avoids assigning
  unchanged frames. Its architecture was inspected; source was not copied.

These sources support reducing unnecessary work and measuring expensive paths.
They do not establish that Quanta's animations themselves caused the reported lag.

## What remains worth profiling

| Local code path | Evidence | Practical implication |
| --- | --- | --- |
| Python/Markdown source coloring | Python's repeated numeric-line scan is measured and fixed. Coloring still examines the entire edited source; Markdown still runs full-source patterns. | Very large individual cells/scripts can remain expensive. Correct incremental highlighting needs lexical-state invalidation across multiline strings and fences. |
| Notebook width changes | Width changes remeasure realized cells and update native/SwiftUI text layouts. Existing coalescing, virtualization, hidden-view guards, and height caches remain. The later user trace includes repeated resize-associated hitches. | Native/SwiftUI layout is a measured lead; the aggregate trace does not uniquely identify the expensive hosted cell or panel. |
| Root/sidebar observable dependencies | `AppState` remains a broad `ObservableObject`; several top-level views observe it. Individual notebook cells observe their own state. | Unrelated publications may cause extra top-level updates. CPU stacks and targeted measurements can guide the investigation while per-view SwiftUI capture is unavailable. |
| Draft/autosave and explicit save | Draft file writes use a utility queue, but notebook fingerprinting and serialization occur before dispatch. Explicit save writes synchronously. | Large notebooks may pause during save/autosave. Moving serialization needs an immutable snapshot and save/recovery ordering; this pass does not alter persistence semantics. |
| Large file navigator selection | Outline updates compare the tree and Git status. A missing exact selection URL can trigger per-item symlink resolution. | Large projects or symlink selections may spend time on main-thread comparison/I/O. No project-scale trace quantifies this yet. |
| Cold panels and third-party web outputs | The layout repair intentionally restores active-pane mounting. Terminal/editor caches remain independently owned. | A cold pane or complex HTML/Plotly content can still take time. Reintroducing hidden pane retention would risk the layout regression. |

For the reported window-zoom/panel issue, the subsequent Release interaction
trace establishes actual hitches. Its Time Profiler and Hitches data remain usable
despite empty SwiftUI lanes. The per-view SwiftUI instrument has been set aside
after the capture-workflow advice did not resolve the user's problem. Investigate
native/SwiftUI layout around resize intervals using CPU stacks and targeted
measurements; restoring per-view capture is not a prerequisite. No universal
absence of lag or flicker is claimed.

## Verification

- All 395 native tests pass, with zero failures and no recorded runtime warnings.
- The optimized Release application builds successfully.
- Existing panel/footer geometry, notebook virtualization/resize/zoom, completion,
  output, export, and undo regressions remain passing.
- Two new syntax regressions exercise dense numeric lines and real script-editor
  changes rather than using a timing threshold in CI.
- The user's running application was not stopped or relaunched. The rebuilt app
  must be launched to load these changes.
