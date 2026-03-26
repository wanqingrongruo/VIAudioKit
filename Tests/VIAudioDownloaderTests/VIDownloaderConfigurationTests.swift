import XCTest
@testable import VIAudioDownloader

final class VIDownloaderConfigurationTests: XCTestCase {

    // MARK: - Default identity canonicalizer

    func testDefaultCanonicalizerKeepsQueryIntact() {
        let config = VIDownloaderConfiguration()
        let url = URL(string: "https://cdn.example.com/audio/song.mp3?token=abc123&expires=999999")!
        let canonical = config.urlCanonicalizer(url)
        XCTAssertEqual(canonical.absoluteString, url.absoluteString)
    }

    func testDefaultCanonicalizerKeepsFragmentIntact() {
        let config = VIDownloaderConfiguration()
        let url = URL(string: "https://cdn.example.com/audio/song.mp3#section")!
        let canonical = config.urlCanonicalizer(url)
        XCTAssertEqual(canonical.absoluteString, url.absoluteString)
    }

    func testDefaultDifferentQueryProducesDifferentKey() {
        let config = VIDownloaderConfiguration()
        let url1 = URL(string: "https://oss.aliyun.com/bucket/song.mp3?Expires=1111&Signature=aaa")!
        let url2 = URL(string: "https://oss.aliyun.com/bucket/song.mp3?Expires=2222&Signature=bbb")!
        let key1 = config.cacheKey(for: url1)
        let key2 = config.cacheKey(for: url2)
        XCTAssertNotEqual(key1, key2, "With identity canonicalizer, different queries should produce different keys")
    }

    // MARK: - stripQueryCanonicalizer

    func testStripQueryCanonicalizerStripsQuery() {
        var config = VIDownloaderConfiguration()
        config.urlCanonicalizer = VIDownloaderConfiguration.stripQueryCanonicalizer
        let url = URL(string: "https://cdn.example.com/audio/song.mp3?token=abc123")!
        let canonical = config.urlCanonicalizer(url)
        XCTAssertEqual(canonical.absoluteString, "https://cdn.example.com/audio/song.mp3")
    }

    func testStripQueryCanonicalizerSameAudioSameKey() {
        var config = VIDownloaderConfiguration()
        config.urlCanonicalizer = VIDownloaderConfiguration.stripQueryCanonicalizer
        let url1 = URL(string: "https://oss.aliyun.com/bucket/song.mp3?Expires=1111&Signature=aaa")!
        let url2 = URL(string: "https://oss.aliyun.com/bucket/song.mp3?Expires=2222&Signature=bbb")!
        let key1 = config.cacheKey(for: url1)
        let key2 = config.cacheKey(for: url2)
        XCTAssertEqual(key1, key2)
    }

    // MARK: - General

    func testDifferentAudioProducesDifferentCacheKey() {
        let config = VIDownloaderConfiguration()
        let url1 = URL(string: "https://cdn.example.com/audio/song1.mp3")!
        let url2 = URL(string: "https://cdn.example.com/audio/song2.mp3")!
        let key1 = config.cacheKey(for: url1)
        let key2 = config.cacheKey(for: url2)
        XCTAssertNotEqual(key1, key2)
    }

    func testCustomCanonicalizer() {
        var config = VIDownloaderConfiguration()
        config.urlCanonicalizer = { url in
            var components = URLComponents()
            components.path = url.path
            return components.url ?? url
        }
        let url1 = URL(string: "https://cdn1.example.com/song.mp3")!
        let url2 = URL(string: "https://cdn2.example.com/song.mp3")!
        let key1 = config.cacheKey(for: url1)
        let key2 = config.cacheKey(for: url2)
        XCTAssertEqual(key1, key2)
    }
}
