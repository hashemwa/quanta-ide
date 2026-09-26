# Local Data browser

The first provider set is local SQLite, DuckDB, CSV, TSV and Parquet. Open files from
Files, the Data menu, or the Data navigator's add button. Data source documents are
read-only, independent of the Python kernel, and currently session-only. Remote
connections and database editing are not part of this milestone.

`LocalDataSource` classifies supported files. `LocalDataConnection` is the synchronous
query boundary; implementations run off the UI thread under `DataSession`, which owns
cancellation, deadlines, page state, filtering and sorting. `DataPage` retains nulls
separately from empty strings and preserves numeric values as engine-formatted text.
The AppKit DataFrame table presents bounded pages and copies original values.

SQLite uses Apple's SQLite3 C module with read-only connections, statement validation,
row stepping, size limits and sqlite3_interrupt. DuckDB uses a narrow dynamic C adapter
to the bundled library, read-only persistent connections and SELECT statement validation.
CSV/TSV/Parquet use DuckDB's in-memory connection with explicit reader paths. Automatic
extension installation and loading are disabled. No Python, Node, network database,
or user package installation is needed for browsing.

Limits: 200 displayed rows per page, 256 columns, 4 MB text per page, 10 seconds per
operation, 128 MB DuckDB memory, no DuckDB temporary spill files. A limit violation is
shown as an error rather than silently truncating copied values. Metadata browsing is
limited to 1,000 tables/views. Queries run on fresh connections; an externally locked
database reports the engine error. Paging reruns a bounded query, so an external writer
can change later pages. Add ORDER BY when stable ordering matters. Header detection
currently assumes the first CSV/TSV row contains column names; custom reader options
can be entered in SQL. Column statistics cover the whole filtered query result,
using aggregate queries in batches of at most 32 columns to bound memory use.
All batches share the operation's cancellation token and 10-second deadline;
inconsistent row counts across batches are rejected if the source changes.

The loading-code action opens a new unsaved notebook. SQLite and DuckDB loading code
uses a read-only connection and the executed SQL. CSV/TSV/Parquet code loads the source
file using pandas; browser-only filters are not translated into pandas expressions.
Those scientific packages are user environment dependencies, not browser dependencies.

## Adding a provider

1. Add source selection and a `LocalDataConnection` implementation; keep engines out of views.
2. Preserve null, binary, timestamp and high-precision value semantics. Never substitute
   shortened display text for exported or copied original values.
3. Support cancellation, deadlines, bounded output and read-only access before exposing
   queries. Do not install dependencies into the user's environment on open.
4. Reuse DataSession and DataFrameNSTable and add fixtures in LocalDataTests for schema,
   paging, Unicode/quoted paths, nulls, precision, malformed files and cancellation.

Next contributions can add file format options, saved queries, budgeted full-column
profiling and selected remote database providers. Remote credentials should be stored
in Keychain; connection-specific limits and cancellation are part of the provider contract.
