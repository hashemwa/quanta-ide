import Combine
import Foundation

final class Document: ObservableObject, Identifiable {
    enum Kind: Equatable {
        case script
        case notebook
        case dataSource
        case dataFrame
        case diff
    }

    let id = UUID()
    let kind: Kind
    @Published var url: URL?
    @Published var isPinned = false
    @Published var isDirty = false
    var fileModificationDate: Date?

    @Published var text: String = ""

    @Published var notebook: Notebook?

    private(set) var dataSession: DataSession?
    let dataFrameName: String?
    @Published var dataFrame: DataFramePayload?
    @Published var dataFrameError: String?
    @Published var dataFrameSummary: DataSummary?
    @Published var isLoadingDataFrame = false
    @Published var dataFrameFilter = ""
    @Published var dataFrameSortColumn: Int?
    @Published var dataFrameSortAscending = true
    var dataFrameRequest = 0

    @Published var diffSource: DiffSource?
    @Published var diff: DiffDocument?
    @Published var diffError: String?

    var deletedCells: [(dict: [String: Any], index: Int,
                        restoreSource: (cellID: UUID, source: String)?)] = []
    var clearedOutputs: [(cellID: UUID, outputs: [CellOutput], executionCount: Int?, duration: Double?)] = []

    var lastSelectedCellID: UUID?

    let find = FindState()

    private let untitledName: String
    let draftKey: String

    init(script url: URL?, text: String, draftKey: String = Document.makeDraftKey()) {
        self.kind = .script
        self.url = url
        self.text = text
        self.dataFrameName = nil
        self.untitledName = "Untitled.py"
        self.notebook = nil
        self.diffSource = nil
        self.draftKey = draftKey
    }

    init(notebook: Notebook, url: URL?, draftKey: String = Document.makeDraftKey()) {
        self.kind = .notebook
        self.url = url
        self.notebook = notebook
        self.dataFrameName = nil
        self.untitledName = "Untitled.ipynb"
        self.diffSource = nil
        self.draftKey = draftKey
    }

    static func makeDraftKey() -> String {
        String(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(12))
    }

    init(dataFrameNamed name: String) {
        self.kind = .dataFrame
        self.url = nil
        self.dataFrameName = name
        self.untitledName = name
        self.diffSource = nil
        self.draftKey = ""
    }

    init(diff source: DiffSource) {
        self.kind = .diff
        self.url = nil
        self.dataFrameName = nil
        self.untitledName = source.fileName
        self.diffSource = source
        self.draftKey = ""
    }

    init(data session: DataSession) {
        kind = .dataSource
        dataSession = session
        url = session.source.url
        dataFrameName = nil
        untitledName = session.source.name
        diffSource = nil
        draftKey = ""
    }

    var isFileBacked: Bool {
        kind == .script || kind == .notebook
    }

    var displayName: String {
        switch kind {
        case .dataFrame: return dataFrameName ?? "DataFrame"
        case .diff: return "\(untitledName) (\(diffSource?.area.label ?? "Diff"))"
        default: return url?.lastPathComponent ?? untitledName
        }
    }

    var iconName: String {
        switch kind {
        case .script: return "curlybraces"
        case .notebook: return "text.book.closed"
        case .dataSource, .dataFrame: return "tablecells"
        case .diff: return "plus.forwardslash.minus"
        }
    }
}

final class FindState: ObservableObject {
    @Published var isVisible = false
    @Published var query = ""
    @Published var replacement = ""
    @Published var showReplace = false
    @Published var matches: [(cellID: UUID, range: NSRange)] = []
    @Published var currentIndex = 0
    @Published var focusRequest = 0
    var hasNavigated = false
}
