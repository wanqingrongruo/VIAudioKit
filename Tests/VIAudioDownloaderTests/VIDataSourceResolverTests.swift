import XCTest
@testable import VIAudioDownloader

final class VIDataSourceResolverTests: XCTestCase {

    func testFullyUncached() {
        let unit = VICacheUnit(key: "test", originalURL: URL(string: "https://example.com/a.mp3")!)
        unit.totalLength = 1000
        let sources = VIDataSourceResolver.resolve(range: 0..<1000, unit: unit)
        XCTAssertEqual(sources.count, 1)
        if case .network(let range) = sources[0] {
            XCTAssertEqual(range, 0..<1000)
        } else {
            XCTFail("Expected network source")
        }
    }

    func testFullyCached() {
        let unit = VICacheUnit(key: "test", originalURL: URL(string: "https://example.com/a.mp3")!)
        unit.totalLength = 1000
        unit.insertSegment(VICacheSegment(relativePath: "s0", offset: 0, length: 1000))
        let sources = VIDataSourceResolver.resolve(range: 0..<1000, unit: unit)
        XCTAssertEqual(sources.count, 1)
        if case .file(_, let readRange) = sources[0] {
            XCTAssertEqual(readRange, 0..<1000)
        } else {
            XCTFail("Expected file source")
        }
    }

    func testGapInMiddle() {
        let unit = VICacheUnit(key: "test", originalURL: URL(string: "https://example.com/a.mp3")!)
        unit.totalLength = 1000
        unit.insertSegment(VICacheSegment(relativePath: "s0", offset: 0, length: 300))
        unit.insertSegment(VICacheSegment(relativePath: "s1", offset: 700, length: 300))
        let sources = VIDataSourceResolver.resolve(range: 0..<1000, unit: unit)
        // Expected: file(0-300), network(300-700), file(700-1000)
        XCTAssertEqual(sources.count, 3)
        if case .file(_, let r) = sources[0] { XCTAssertEqual(r, 0..<300) }
        if case .network(let r) = sources[1] { XCTAssertEqual(r, 300..<700) }
        if case .file(_, let r) = sources[2] { XCTAssertEqual(r, 700..<1000) }
    }

    func testGapAtStart() {
        let unit = VICacheUnit(key: "test", originalURL: URL(string: "https://example.com/a.mp3")!)
        unit.totalLength = 1000
        unit.insertSegment(VICacheSegment(relativePath: "s0", offset: 500, length: 500))
        let sources = VIDataSourceResolver.resolve(range: 0..<1000, unit: unit)
        XCTAssertEqual(sources.count, 2)
        if case .network(let r) = sources[0] { XCTAssertEqual(r, 0..<500) }
        if case .file(_, let r) = sources[1] { XCTAssertEqual(r, 500..<1000) }
    }

    func testPartialRangeRequest() {
        let unit = VICacheUnit(key: "test", originalURL: URL(string: "https://example.com/a.mp3")!)
        unit.totalLength = 1000
        unit.insertSegment(VICacheSegment(relativePath: "s0", offset: 0, length: 300))
        // Request only 200-500
        let sources = VIDataSourceResolver.resolve(range: 200..<500, unit: unit)
        XCTAssertEqual(sources.count, 2)
        if case .file(_, let r) = sources[0] { XCTAssertEqual(r, 200..<300) }
        if case .network(let r) = sources[1] { XCTAssertEqual(r, 300..<500) }
    }

    func testNeedsDownload() {
        let unit = VICacheUnit(key: "test", originalURL: URL(string: "https://example.com/a.mp3")!)
        unit.totalLength = 1000
        unit.insertSegment(VICacheSegment(relativePath: "s0", offset: 0, length: 1000))
        XCTAssertFalse(VIDataSourceResolver.needsDownload(range: 0..<500, unit: unit))
        XCTAssertFalse(VIDataSourceResolver.needsDownload(range: 0..<1000, unit: unit))
    }
}
