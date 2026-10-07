# Panel layout repair — October 6, 2026

The subsequent [performance research](performance-research-2026-10-06.md) restores
animations at the user's request while keeping this layout repair. The animation
removal below describes the earlier step, not the current behavior.

The user reported that the previous interaction polish broke the navigator layout
and did not produce a noticeable improvement in responsiveness. The panel retention
change was a regression. Passing the earlier tests did not establish a user-visible
speedup or correct placement of the file footer.

## Cause and correction

The retained navigator panes were placed in a `ZStack`. The Files pane's view builder
returns both the file list and its footer. Those siblings therefore participated in
the overlay layout instead of the original vertical layout. The footer appeared over
the list near the top of the sidebar. The old test checked view identity and scroll
position, but did not check the footer's coordinates.

The navigator now uses its original `VStack` and active-pane switch. The bottom
panel's hidden mounting and zero-height wrapper are also reverted, and plots mount
only when selected. Hidden panels are no longer kept in layout. TerminalSession
still owns its cached browser and shell session independently of the panel view.
Variable inspector filters remain persistent without changing its view structure.

## Animations removed

- Navigator reveal/hide, console reveal/hide, active-tab scrolling, and Git section
  expansion no longer request an animation.
- Floating toolbar visibility, progress-indicator appearance, and input focus borders
  no longer fade. The progress spinner still communicates ongoing work.
- Programmatic notebook page/edge navigation and double-click plot zoom reset apply
  their final positions directly.
- The main interface disables inherited SwiftUI animation transactions.

These are app-controlled effects. macOS window zoom, menus, sheets, trackpad momentum,
and third-party interactive plot effects are not global system preferences changed
by this patch. Removing animation delays does not establish that all rendering or
interaction bottlenecks have been resolved.

## Verification and performance evidence

- All 393 native tests pass; the completed result reports no runtime warnings.
- The optimized Release app builds successfully.
- The revised sidebar test checks the actual native list and filter coordinates in
  light/dark modes at 280- and 440-point widths. After three Files/Search cycles per
  configuration, the footer remains at the bottom and cannot overlap the file list.
  A removed search field cannot retain its window or keyboard focus.
- The bottom panel is absent while hidden, and five reopen cycles reattach the
  cached terminal browser with the original dimensions.
- Sidebar captures were inspected visually and are in `.build/panel-repair/`.
- A three-second read-only sample of the user's running IDE identified a Debug
  executable launched under `debugserver`, with the debugger's backtrace-recording
  library loaded. The main thread was waiting for events during this sample.

The idle sample does not diagnose the reported interaction latency. Debugger and
Debug-build overhead can affect responsiveness, so the optimized Release app is
the appropriate build for judging it. No measured perceptible speedup is claimed.
The existing notebook-work coalescing/caching and output improvements remain,
but their presence is not proof that a particular user interaction became faster.

The earlier LaTeX, Markdown/Copilot, file-reopening, export, and enhanced/text output
fixes remain in place. The running app was not stopped; loading this correction
requires relaunching a rebuilt copy.
