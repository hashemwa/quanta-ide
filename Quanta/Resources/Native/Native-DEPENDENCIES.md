# Bundled native engines

- ty 0.0.82, MIT, https://github.com/astral-sh/ty/releases/tag/0.0.82
- DuckDB 1.5.5, MIT, https://github.com/duckdb/duckdb/releases/tag/v1.5.5

License texts accompany this file. `scripts/native-tools` pins release archive SHA-256
values from the upstream GitHub release metadata. It combines ty's arm64/x86_64
executables and uses DuckDB's universal library. Binaries are downloaded only during
build preparation, not by the running application, and are excluded from source control.
The shared Xcode scheme embeds executable code under Contents/MacOS and
Contents/Frameworks and re-signs the bundle. Release packaging signs the nested code
with the distribution identity before notarization. Re-run engine integration tests when
updating either version; the DuckDB adapter uses the pinned release's C ABI.
