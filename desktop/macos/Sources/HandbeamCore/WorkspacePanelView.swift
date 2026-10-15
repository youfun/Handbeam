public enum WorkspacePanelView: String, CaseIterable {
    case changes
    case files
    case browser
    case terminal

    public var title: String {
        switch self {
        case .changes: "Changes"
        case .files: "Files"
        case .browser: "Browser"
        case .terminal: "Terminal"
        }
    }
}
