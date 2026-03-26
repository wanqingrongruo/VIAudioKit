import XCTest
@testable import VIAudioDownloader

final class VICacheSegmentTests: XCTestCase {

    func testEndCalculation() {
        let seg = VICacheSegment(relativePath: "test_0", offset: 100, length: 500)
        XCTAssertEqual(seg.end, 600)
    }

    func testContains() {
        let seg = VICacheSegment(relativePath: "test_0", offset: 100, length: 500)
        XCTAssertFalse(seg.contains(99))
        XCTAssertTrue(seg.contains(100))
        XCTAssertTrue(seg.contains(599))
        XCTAssertFalse(seg.contains(600))
    }

    func testOverlapFullyInside() {
        let seg = VICacheSegment(relativePath: "test_0", offset: 100, length: 500)
        let overlap = seg.overlap(with: 200..<400)
        XCTAssertEqual(overlap, 200..<400)
    }

    func testOverlapPartialLeft() {
        let seg = VICacheSegment(relativePath: "test_0", offset: 100, length: 500)
        let overlap = seg.overlap(with: 50..<200)
        XCTAssertEqual(overlap, 100..<200)
    }

    func testOverlapPartialRight() {
        let seg = VICacheSegment(relativePath: "test_0", offset: 100, length: 500)
        let overlap = seg.overlap(with: 500..<700)
        XCTAssertEqual(overlap, 500..<600)
    }

    func testOverlapDisjoint() {
        let seg = VICacheSegment(relativePath: "test_0", offset: 100, length: 500)
        let overlap = seg.overlap(with: 700..<800)
        XCTAssertNil(overlap)
    }
}
