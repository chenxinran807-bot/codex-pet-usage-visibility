import XCTest
@testable import QuotaOverlayApp

final class ScaffoldTests: XCTestCase {
    func testAppMetadataProvidesDisplayName() {
        XCTAssertEqual(AppMetadata.name, "Quota Overlay")
    }
}
