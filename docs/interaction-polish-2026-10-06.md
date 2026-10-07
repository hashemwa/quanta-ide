# Interaction and output polish — October 6, 2026

The user subsequently reported broken panel layout and no noticeable speedup.
The [panel layout repair](panel-layout-repair-2026-10-06.md) reverts the panel
retention changes. Its verification supersedes the earlier panel-retention checks.
The subsequent [performance research](performance-research-2026-10-06.md) restores
animations and measures/fixes a Python lexer bottleneck. The original interaction
polish did not establish a perceptible speedup.

This follow-up builds on the [notebook and app audit](notebook-audit-2026-10-06.md).
It targets unnecessary updates, panel reconstruction, notebook layout, and reading
custom outputs. The earlier LaTeX, Markdown, Copilot, navigation, and export fixes
remain in place. No running user app or notebook was modified to perform the tests.

## What changes for a user

| Experience | Before | After |
| --- | --- | --- |
| Switching left navigator panes | The attempted retention change put the file footer over the list. | The original vertical layout is restored. Only the active pane mounts; its footer remains below its list. |
| Keyboard input after switching panes | Retaining an invisible native input could leave it focused unless the native control also honored disabled state. | Removed panes detach their inputs. Native disabled-state and stale focus-request guards remain. |
| Reopening the right variable inspector | Its filter, type choice, sorting, and selection were transient view state. | These choices survive the inspector being reconstructed. Detail popovers remain transient. |
| Hiding/reopening the bottom panel | The attempted retention change kept a hidden, zero-height panel mounted. | The original conditional panel layout is restored. The terminal session and cached browser survive independently; hidden panel views are removed. |
| Repeated tab/file/cell clicks | Assigning unchanged selection or document state could publish app-wide updates. | Repeated choices skip those publications. Selection notifications and toolbar positioning coalesce. |
| Editing a cell with existing outputs | Source/status updates could redraw output views and request unnecessary notebook measurements. | Output views subscribe to output changes. Cell refreshes and editor measurements coalesce; unchanged editor height does not request another canvas measurement. Markdown/output hosting views are reused when their content can update in place. |
| Resizing and laying out long notebooks | Offscreen height estimates could repeatedly scan source text, and document updates compared every cell ID. | Estimates are cached with content revisions; notebook structure has its own revision. Hidden canvases defer layout. Font changes update realized views in one pass. The earlier resize/zoom coalescing remains in place. |
| Updating equation fonts | Pending replacement images could leave a temporary blank equation. | The existing image remains visible while the replacement is pending. Stale callbacks still cannot overwrite newer results. |
| Repeated array output updates | A heatmap bitmap could be recreated when its view updated. | A bounded cache reuses the bitmap for an unchanged payload. New payloads have separate cache identities. |
| Large lists/dictionaries | A large root container opened automatically, creating a long initial output. | Containers with more than 12 children start collapsed. Expanded native containers still preview at most 300 children. |
| Reading array/model outputs | The visual preview obscured access to the saved text; model parameters could dominate the notebook. | Array previews are labeled as sampled/relative, and arrays, collections, and model cards expose a text disclosure and Copy Text. Model cards initially show 12 parameters, with the rest expandable and a 300-parameter native preview limit. Tooltips show saved field text; learned attributes are labeled without claiming a successful fit. |
| Choosing ordinary Python output | Custom data previews were always used when available. | Settings → General → Notebook Outputs → **Use enhanced data outputs** switches between custom data views and saved Python text. HTML and PDF export use the same choice. |

## Which custom outputs earn their space

| Output | Assessment | Improvement in this pass | Further useful work |
| --- | --- | --- | --- |
| pandas tables | The strongest custom output: rows/columns are easier to inspect than a printed representation. Existing paging, copying original saved values, and saved snapshots are useful. | A global text option, with no loss of the existing saved snapshot when switching views. | Keep treating it as a preview rather than a complete dataset backup. |
| NumPy shape, dtype, statistics, sparkline, heatmap | Useful for quick inspection. A sampled line and normalized heatmap are less suitable for precise analysis because they lack axes and a value/color scale. | Clear preview captions, easy access to saved numbers, reusable heatmaps, and the text option. | Index/range labels, hover values, and a heatmap scale would add meaning. Users can already make a normal plot for detailed analysis. |
| Expandable collections | Useful for nested records/configuration. A tree adds little for a short flat list; short representations already remain text. | Large roots start collapsed; saved text remains accessible. | Better search within a large saved tree would help more than displaying more rows at once. |
| scikit-learn model cards | The least essential custom view. Model type and learned attribute names help orientation, but long parameter lists add clutter and attribute presence is not proof of a successful fit. | Compact default parameter view, expandable remaining parameters, wrapping learned-attribute badges, field tooltips, saved text, and the global text option. | Emphasize changed parameters and offer deeper learned-value inspection rather than adding more badges. |

Plots, images, tracebacks, HTML, equations, ordinary printed output, and unknown-MIME
fallbacks serve separate purposes. The enhanced-data toggle does not remove their
formatting. The previous audit documents their existing behavior and limitations.

## Output setting behavior

Enhanced data outputs default to on and persist across launches. Turning them off
changes saved custom DataFrame, array, collection, and model-card outputs to their
text fallback immediately. Switching back restores saved structured previews.
Neither switch changes notebook serialization or discards saved MIME data.

The setting also reaches the Python bridge. While off, future results of these
types skip custom table snapshots, array statistics, tree conversion, and model
parameter inspection. They produce Python text instead. Existing representation
and output-budget limits still apply; plain mode does not accelerate the user's
computation itself. Results created as text need a rerun to create a new structured
preview after re-enabling the setting. Explicit non-data rich output remains rich.

Native text and parameter previews are bounded for responsiveness. Copy/export
retain saved text, and export retains saved fields. The Python bridge may already
have bounded these representations. A saved preview is not a serialization of
the complete Python value.

## What was already good

Notebook virtualization already realizes nearby cells, retains editor undo state,
preserves a visible scroll anchor, and prefetches during idle time. Print output
already batches transport and honors output budgets. DataFrame tables already use
native paged views. Markdown parsing and equation images already have bounded
caches. Copilot already cancels stale work and keeps ghost text out of source/undo
storage. These mechanisms remain intact.

## Verification

- The native suite passes 393 tests, including 11 new interaction/output regressions.
- The optimized Release application builds successfully.
- The completed native test result reports no runtime warnings.
- Python UI/inspection workflows pass 37 tests with 3 optional-package skips;
  the standard-library-only run passes with 13 skips.
- Python execution/interactive workflows pass 21 tests with 2 optional-package skips.
- Revised native tests check file list/footer separation in four theme/width
  configurations after repeated Files/Search switching, and bottom-panel hiding/showing
  five times. They verify detached inputs, absence of hidden panels, and restored
  terminal dimensions.
- Inspector reconstruction retains a query entered through the native search field,
  the selected variable, its type filter, and sorting choice.
- Twenty repeated cell selections publish no unchanged app/selection state. Status
  flags and same-height typing trigger no canvas size callback; adding lines grows
  the editor correctly without replacing it.
- Thirty reads of an unchanged heatmap reuse the same image; a new payload uses a
  different image. A 2,000-parameter saved card stays compact at narrow/wide widths
  while its export retains the final saved parameter.
- Native enhanced/text/enhanced transitions preserve notebook serialization and
  restore the statistic layout. The inspected light-mode enhanced/restored captures
  match; screenshots are in the ignored `.build/interaction-polish/` directory.
- The existing 400-cell resize/zoom, scrolling, undo, removal, execution, Copilot,
  rich output, and multipage PDF regressions remain part of the passing suite.

These checks establish correctness and remove identifiable sources of repeated
work. They are not frame-rate measurements. No Instruments trace, long-session
memory measurement, or exhaustive physical click/animation sweep was captured.
The native zoom path is covered; the user's physical toolbar double-click gesture
and macOS double-click preference were not manually exercised. Complex third-party
HTML/Plotly content and arbitrary huge notebooks can still be expensive. Universal
zero lag/flicker is not established.

The changes are in source and the rebuilt application. An already-running copy
must be restarted to load them; the audit did not interrupt the user's session.
