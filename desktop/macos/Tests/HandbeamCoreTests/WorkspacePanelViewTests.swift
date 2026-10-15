import XCTest
@testable import HandbeamCore

final class WorkspacePanelViewTests: XCTestCase {
    func testNativeSwitcherMatchesWebPanelOrder() {
        XCTAssertEqual(
            WorkspacePanelView.allCases.map(\.rawValue),
            ["changes", "files", "browser", "terminal"]
        )
        XCTAssertEqual(
            WorkspacePanelView.allCases.map(\.title),
            ["Changes", "Files", "Browser", "Terminal"]
        )
    }
}
