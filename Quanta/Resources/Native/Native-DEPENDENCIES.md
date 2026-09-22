# Bundled native engine

- DuckDB 1.5.5, MIT, https://github.com/duckdb/duckdb/releases/tag/v1.5.5

License texts accompany this file. `scripts/native-tools` pins release archive SHA-256
values from the upstream GitHub release metadata and uses DuckDB's universal library.
The binary is downloaded only during
build preparation, not by the running application, and is excluded from source control.
The shared Xcode scheme embeds executable code under Contents/Frameworks and re-signs
the bundle. Release packaging signs the nested code
with the distribution identity before notarization. Re-run engine integration tests when
updating the version; the DuckDB adapter uses the pinned release's C ABI.
