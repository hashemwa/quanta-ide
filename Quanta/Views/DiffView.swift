import AppKit
import SwiftUI

struct DiffView: View {
    @ObservedObject var document: Document
    private var app: AppState { AppState.shared }
    @Environment(\.monoFontSize) private var monoFontSize
    @State private var expandedGaps: Set<Int> = []

    private static let gutterAdvance: CGFloat = 0.62
    private static let minimumGutterDigits = 3

    private var source: DiffSource? { document.diffSource }

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(document.displayName, systemImage: "plus.forwardslash.minus") {
                if let diff = document.diff, diff.isNotebook {
                    Text("Cell sources only")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .help("Outputs, execution counts and metadata are not compared.")
                }
                if let diff = document.diff, diff.hasChanges {
                    Text("+\(diff.additions) −\(diff.deletions)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help("\(diff.additions) added, \(diff.deletions) removed · \(diff.oldLabel) → \(diff.newLabel)")
                }
                if let source, source.status != .deleted {
                    IconButton("doc.text", help: "Open File") { app.openFile(source.url) }
                }
                if let source, !source.isAdHoc {
                    stageButton(source)
                }
                IconButton("arrow.clockwise", help: "Reload changes (⌘R)") { app.reloadDiff(document) }
            }
            content
        }
        .onReceive(document.$diff) { _ in expandedGaps.removeAll() }
    }

    @ViewBuilder
    private func stageButton(_ source: DiffSource) -> some View {
        switch source.area {
        case .unstaged:
            IconButton("plus", help: "Stage Changes") { app.stage(source) }
        case .staged:
            IconButton("minus", help: "Unstage Changes") { app.unstage(source) }
        case .conflicted:
            IconButton("checkmark", help: "Mark Resolved") { app.stage(source) }
        }
    }

    @ViewBuilder
    private var content: some View {
        if let diff = document.diff {
            if diff.isBinary {
                unavailable("Binary File", "Quanta can't show changes to binary files.")
            } else if diff.isTooLarge {
                unavailable("Too Many Lines", "This file is too large to compare here.")
            } else if !diff.hasChanges {
                unavailable("No Changes", "\(source?.fileName ?? "The file") matches \(diff.oldLabel).")
            } else {
                rows(diff)
            }
        } else if let error = document.diffError {
            ContentUnavailableView {
                Label("Couldn't Load Changes", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            } actions: {
                Button("Retry") { app.reloadDiff(document) }
                    .controlSize(.small)
            }
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func unavailable(_ title: String, _ message: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: "plus.forwardslash.minus")
        } description: {
            Text(message)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func rows(_ diff: DiffDocument) -> some View {
        let display = diff.displayRows(context: DS.Layout.diffContextLines, expanded: expandedGaps)
        let gutter = gutterWidth(diff)
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(display) { row in
                    if row.kind == .gap {
                        DiffGapRow(row: row, gutter: gutter) {
                            expandedGaps.insert(row.runStart)
                        }
                    } else {
                        DiffLineRow(row: row, gutter: gutter, fontSize: monoFontSize)
                    }
                }
            }
            .padding(.vertical, DS.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    private func gutterWidth(_ diff: DiffDocument) -> CGFloat {
        let largest = diff.rows.reduce(0) { max($0, $1.oldLine ?? 0, $1.newLine ?? 0) }
        let digits = max(Self.minimumGutterDigits, String(largest).count)
        return CGFloat(digits) * monoFontSize * Self.gutterAdvance + DS.Space.s
    }
}

private struct DiffLineRow: View {
    let row: DiffRow
    let gutter: CGFloat
    let fontSize: CGFloat

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(row.oldLine.map { String($0) } ?? "")
                .frame(width: gutter, alignment: .trailing)
            Text(row.newLine.map { String($0) } ?? "")
                .frame(width: gutter, alignment: .trailing)
            Text(marker)
                .frame(width: DS.Layout.diffMarkerWidth, alignment: .center)
                .foregroundStyle(markerColor)
            Text(row.text.isEmpty ? " " : row.text)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: fontSize, design: .monospaced))
        .foregroundStyle(.tertiary)
        .padding(.horizontal, DS.Space.m)
        .padding(.vertical, DS.Layout.diffLineInset)
        .background(fill)
    }

    private var marker: String {
        switch row.kind {
        case .added: return "+"
        case .removed: return "-"
        default: return " "
        }
    }

    private var markerColor: Color {
        switch row.kind {
        case .added: return DS.Git.added
        case .removed: return DS.Git.removed
        default: return .clear
        }
    }

    private var fill: Color {
        switch row.kind {
        case .added: return DS.Git.addedFill
        case .removed: return DS.Git.removedFill
        default: return .clear
        }
    }
}

private struct DiffGapRow: View {
    let row: DiffRow
    let gutter: CGFloat
    let expand: () -> Void

    var body: some View {
        Button(action: expand) {
            HStack(spacing: DS.Space.s) {
                Image(systemName: "ellipsis")
                Text("\(row.hiddenCount) unchanged lines")
                Spacer(minLength: 0)
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
            .padding(.leading, gutter * 2 + DS.Space.m)
            .padding(.vertical, DS.Space.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .hoverHighlight()
        .help("Show the \(row.hiddenCount) hidden lines")
    }
}
