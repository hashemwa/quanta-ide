# Instruments trace audit — October 6, 2026

The user supplied `~/Desktop/test trace.trace`. The original recording was read;
exports and analysis are in the ignored `.build/user-trace-audit/` directory.
No application code or panel appearance was changed as part of this analysis.

## Recording and coverage

- Instruments 27, SwiftUI template, macOS 27.0.1 on Apple Silicon.
- Quanta was launched from the Xcode **Release** products directory.
- Recording duration: **10.153 seconds**, including launch. Instruments reports
  the recording's end reason as **Target app exited**.
- Time Profiler sampling interval: **100 microseconds** (high frequency).
- SwiftUI instrument setting: **Layout Updates — Not Included**.
- 29,395 CPU sample rows across Quanta's threads; 26,352 main-thread rows with
  100-microsecond weight each, totaling **2,635.2 ms sampled main-thread CPU**.
- 44 frame-hitch events; no rows in the exported potential-hang table.
- The exported SwiftUI update, update-group, filtered-update, change/cause, and
  layout-update tables returned no rows. Their absence in these exports is not
  evidence that SwiftUI did no work: its rendering and layout functions are present
  in the CPU stacks. The analysis therefore uses CPU stacks and frame events, not
  a per-view cause/effect graph.

This is a useful interaction recording, but not an idle-baseline comparison or
before/after measurement. The exact actions and the user's subjective ordering
were not supplied with the trace. Later clusters are identified as resize activity
from native window-manager resize calls, frame-setting, and animation callbacks.
The physical gesture that initiated each resize is not identifiable from those
calls alone.

## What the trace shows

| Observation | Recorded value | Interpretation |
| --- | ---: | --- |
| Frame-hitch events | 44 | The run contains measurable frame misses. |
| Total reported hitch duration | 1,366.662 ms | Sum of the recorded hitch durations; not total CPU time or a continuous freeze. |
| Largest hitch | 366.665 ms at 0.917 s | Near launch; CPU stacks include first-window setup, Metal device/plugin loading, color-space conversion, and initial UI creation. |
| Hitch events after 2 s | 39, totaling 949.997 ms | Most recorded hitch events occurred after the initial launch work. |
| Largest hitch after 2 s | 66.666 ms at 8.071 s | Occurs within a native window-resize sequence. |

The resize-associated clusters, using time relative to the recording start:

| Time range | Hitch count | Sum of reported hitch duration | Largest hitch |
| --- | ---: | ---: | ---: |
| 2.8–3.8 s | 6 | 133.333 ms | 33.333 ms |
| 5.3–6.1 s | 7 | 291.666 ms | 58.333 ms |
| 6.7–7.4 s | 7 | 141.666 ms | 41.667 ms |
| 8.0–8.7 s | 9 | 299.999 ms | 66.666 ms |

Main-thread CPU bursts align with these groups. Samples contain
`NSWindow._resizeFromWindowManagerWithTargetGeometry`, native frame updates,
`NSAnimationManager.performAnimations`, window layout, and SwiftUI view-graph
rendering. This supports investigating the layout work performed during resizing.
It does not establish that the animation duration or a particular glass control
is itself the underlying defect.

## Where sampled main-thread CPU went

These are **inclusive** stack weights across the entire recording. Categories
overlap; they must not be added together. For example, a SwiftUI render can occur
inside an AppKit subtree layout. Sample weights estimate active CPU cost, not the
wall duration of a single function call or the time spent blocked on I/O.

| Code path present on a sampled stack | Inclusive sampled CPU |
| --- | ---: |
| AppKit view-subtree layout | 1,441.2 ms |
| SwiftUI view-graph rendering | 935.2 ms |
| `NSHostingView.layout` | 635.0 ms |
| Auto Layout solving/fitting | 302.6 ms |
| SwiftUI size proposals/constraint updates | 299.0 ms |
| `NotebookCanvas.layoutCells` | 161.8 ms |
| Python highlighter | 0.3 ms |

The direct notebook-layout work is concentrated near launch: approximately
128.2 ms of its 161.8 ms appears between 0.75 and 2 s. Later resize bursts include
roughly 8–9 ms of direct `NotebookCanvas.layoutCells` work per selected analysis
window; the much larger costs are in native/SwiftUI layout and rendering.
This does not exonerate hosted notebook content: its deferred SwiftUI layout can
execute outside a `NotebookCanvas` stack. It does mean that blaming only the
canvas's synchronous loop would overstate what these samples show.

Examples in individual hitches include native file-outline row frame updates,
segmented-control layer layout, SwiftUI stack sizing, and hosted content rendering.
Those are framework paths shared by several parts of the interface. An aggregate
CPU profile cannot uniquely assign their cost to the left sidebar, inspector,
toolbar, or an individual Markdown cell without more context.

## What this does and does not establish

The trace establishes real frame hitches in a **Release** app, including repeated
resize-associated hitches after startup. Debug-only overhead cannot explain this
recording. The earlier numeric-lexer optimization remains useful for editing dense
source, but syntax parsing is negligible in this particular run.

This recording does not establish a Copilot/network bottleneck, an autosave stall,
or a mathematical-rendering defect as the dominant cause of its resize bursts.
External Python/Copilot processes are outside the exported Quanta-only CPU data;
their latency and CPU usage are not ruled out for other workflows. A recording
with no potential-hang rows does not imply an absence of frame hitches.

There is no defensible before/after claim for the resize issue yet. Animations
remain restored, and the earlier panel layout repair remains in place. A broad
visual redesign or another animation-removal patch is not supported by this trace.

## Focused follow-up

Enabling Layout Updates alone does not address a missing SwiftUI stream. After
the user enabled it and still saw empty lanes, the capture workflow was checked
against Apple's documentation and isolated local probes.

Apple's [Instruments walkthrough](https://developer.apple.com/videos/play/wwdc2025/306/)
explains that SwiftUI profiling data is transferred and processed after recording
stops. Blank lanes while recording are therefore not sufficient to diagnose a
missing stream. An [Apple Developer Tools engineer](https://developer.apple.com/forums/thread/812557)
also identifies a known data-transfer issue when the app exits before recording
stops. The supplied trace's **Target app exited** end reason matches that condition;
the newer screenshot alone does not establish whether recording had finished.

Two isolated native `NSHostingView` probes were recorded on the same Mac with
Xcode/Instruments 27.0 and macOS 27.0.1. An observable counter updated text and
layout every 50 ms. Each recording attached to the probe, included Layout Updates,
and stopped after eight seconds with the probe still running. The probe was
terminated only after Instruments finished saving the trace. No Quanta process
was launched, terminated, or changed for these checks.

| Probe compilation | SwiftUI update rows | Update-group rows | CPU sample rows |
| --- | ---: | ---: | ---: |
| `-Onone -g` | 73,760 | 9,357 | 997 |
| `-O -g` | 65,582 | 8,281 | 973 |

The update rows in these minimal probes are categorized as Other Updates; they
are evidence of a working SwiftUI stream, not validation of Quanta's per-view body
metadata. The standalone legacy `swiftui-layout-updates` table returned zero rows
even in these successful recordings; its count alone is not a reliable capture
health check. Probe source, recording options, traces, and XML exports are retained
in the ignored `.build/user-trace-audit/` directory. These checks show that SwiftUI
updates and update groups can be recorded on this toolchain. They do not prove
that every Quanta capture issue is resolved or measure Quanta's interaction latency.

The recommended stop-before-quit workflow did not resolve the user's visible
problem: a subsequent screenshot shows **No Data** for View Body Updates,
Representable Updates, and Other Updates, while CPU samples and hitch events are
present. The new recording was not supplied on disk, so its diagnostics and end
reason have not been inspected. The original trace's exit condition is a plausible
explanation for that original run, not a confirmed explanation for the later
screenshots. The isolated probes did not validate Quanta body-update capture.

The SwiftUI instrument is now set aside as an optional diagnostic. Further work
on the app's lag should use the existing Time Profiler stacks and Hitches data;
missing per-view data is not a reason to suspend that investigation. There is no
verified fix for Quanta's SwiftUI capture problem, and repeatedly changing the
same recording options is not the current plan.

If SwiftUI capture is revisited, the documented workflow is:

1. Start a fresh SwiftUI recording with Layout Updates included.
2. Exercise the slow interaction with Quanta kept open.
3. Press **Stop in Instruments**, leaving Quanta running until transfer and
   processing complete; do not end the run by quitting Quanta.
4. Expand the SwiftUI track and select **View Body Updates** to inspect all body
   updates. The **Long Updates** summary includes only long updates and can be
   empty independently of whether other updates were recorded.
5. Save the completed trace. If update groups remain empty after processing,
   inspect that recording's end reason and diagnostics rather than assuming that
   another Layout Updates toggle will fix it.

Keep launch separate from the interaction region. A 20–30 second
recording with pauses between title-bar zoom, navigator/inspector toggles, notebook
scrolling, and typing makes their costs easier to distinguish. A single-action
recording is also useful when one gesture is consistently slow.

Correlate the hitch intervals with main-thread CPU stacks and native layout,
constraint-solving, and SwiftUI rendering costs. When per-view capture becomes
available, use it to distinguish necessary resize layout from repeated
invalidation. The initial
targets are the root split/inspector hierarchy, native toolbar/segmented controls,
and hosted notebook text/output views. These are profiling targets, not proven
individual defects.

This follows Apple's [SwiftUI performance guidance](https://developer.apple.com/documentation/xcode/understanding-and-improving-swiftui-performance)
and its [Instruments walkthrough](https://developer.apple.com/videos/play/wwdc2025/306/):
correlate long updates with CPU work, identify the relevant view, then measure the
same interaction after a targeted change.
