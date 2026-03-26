import XCTest
@testable import VIAudioDownloader

final class VICacheUnitTests: XCTestCase {

    func testValidLengthNoOverlap() {
        let unit = VICacheUnit(key: "test", originalURL: URL(string: "https://example.com/a.mp3")!)
        unit.totalLength = 1000
        unit.insertSegment(VICacheSegment(relativePath: "s0", offset: 0, length: 300))
        unit.insertSegment(VICacheSegment(relativePath: "s1", offset: 500, length: 200))
        // 300 + 200 = 500, no overlap
        XCTAssertEqual(unit.validLength, 500)
    }

    func testValidLengthWithOverlap() {
        let unit = VICacheUnit(key: "test", originalURL: URL(string: "https://example.com/a.mp3")!)
        unit.totalLength = 1000
        unit.insertSegment(VICacheSegment(relativePath: "s0", offset: 0, length: 400))
        unit.insertSegment(VICacheSegment(relativePath: "s1", offset: 300, length: 300))
        // Union: 0..<600, validLength = 600
        XCTAssertEqual(unit.validLength, 600)
    }

    func testIsComplete() {
        let unit = VICacheUnit(key: "test", originalURL: URL(string: "https://example.com/a.mp3")!)
        unit.totalLength = 500
        unit.insertSegment(VICacheSegment(relativePath: "s0", offset: 0, length: 500))
        XCTAssertTrue(unit.isComplete)
    }

    func testIsNotComplete() {
        let unit = VICacheUnit(key: "test", originalURL: URL(string: "https://example.com/a.mp3")!)
        unit.totalLength = 500
        unit.insertSegment(VICacheSegment(relativePath: "s0", offset: 0, length: 300))
        XCTAssertFalse(unit.isComplete)
    }

    func testCachedRanges() {
        let unit = VICacheUnit(key: "test", originalURL: URL(string: "https://example.com/a.mp3")!)
        unit.insertSegment(VICacheSegment(relativePath: "s0", offset: 0, length: 100))
        unit.insertSegment(VICacheSegment(relativePath: "s1", offset: 100, length: 100))
        unit.insertSegment(VICacheSegment(relativePath: "s2", offset: 500, length: 200))
        let ranges = unit.cachedRanges
        XCTAssertEqual(ranges.count, 2)
        XCTAssertEqual(ranges[0], 0..<200)
        XCTAssertEqual(ranges[1], 500..<700)
    }

    func testIsCached() {
        let unit = VICacheUnit(key: "test", originalURL: URL(string: "https://example.com/a.mp3")!)
        unit.insertSegment(VICacheSegment(relativePath: "s0", offset: 0, length: 500))
        XCTAssertTrue(unit.isCached(range: 100..<300))
        XCTAssertFalse(unit.isCached(range: 400..<600))
    }
}
