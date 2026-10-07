import Combine

final class VariablesPanelState: ObservableObject {
    @Published var selected: String?
    @Published var query = ""
    @Published var typeFilter = "All Types"
    @Published var sortByType = false
}
