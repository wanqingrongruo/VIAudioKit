import Foundation
import CryptoKit

/// Configuration for the chunked downloader and cache system.
public struct VIDownloaderConfiguration: Sendable {

    /// Transforms a URL into a stable canonical form before generating the cache key.
    /// Use this to strip volatile query parameters (e.g. Alibaba Cloud / AWS signed URLs).
    /// Default: identity (keeps original URL unchanged). Set to `stripQueryCanonicalizer`
    /// if your URLs contain expiring tokens.
    public var urlCanonicalizer: @Sendable (URL) -> URL

    /// Optional custom cache-key generator. When nil the default SHA-256 of the
    /// canonicalized URL string is used.
    public var cacheKeyGenerator: (@Sendable (URL) -> String)?

    /// Root directory for all cached data. Each audio resource gets its own subdirectory.
    public var cacheDirectory: URL

    /// Maximum total bytes allowed on disk. Oldest-accessed units are evicted first.
    public var maxCacheSize: Int64

    /// Default chunk size in bytes for range requests.
    public var defaultChunkSize: Int

    /// Timeout interval for individual HTTP range requests.
    public var requestTimeoutInterval: TimeInterval

    /// Maximum number of retries on network errors.
    /// 网络错误时的最大重试次数。
    public var maxRetryCount: Int

    // MARK: - Initializer

    public init(
        cacheDirectory: URL? = nil,
        maxCacheSize: Int64 = 500 * 1024 * 1024,
        defaultChunkSize: Int = 512 * 1024,
        requestTimeoutInterval: TimeInterval = 30,
        maxRetryCount: Int = 20,
        urlCanonicalizer: (@Sendable (URL) -> URL)? = nil,
        cacheKeyGenerator: (@Sendable (URL) -> String)? = nil
    ) {
        self.cacheDirectory = cacheDirectory ?? Self.defaultCacheDirectory
        self.maxCacheSize = maxCacheSize
        self.defaultChunkSize = defaultChunkSize
        self.requestTimeoutInterval = requestTimeoutInterval
        self.maxRetryCount = max(0, maxRetryCount)
        self.urlCanonicalizer = urlCanonicalizer ?? Self.identityCanonicalizer
        self.cacheKeyGenerator = cacheKeyGenerator
    }

    // MARK: - Defaults

    /// Default: returns the original URL unchanged.
    public static let identityCanonicalizer: @Sendable (URL) -> URL = { $0 }

    /// Convenience canonicalizer that strips query and fragment.
    /// Useful for cloud storage URLs with expiring tokens (Alibaba Cloud OSS, AWS S3, etc.).
    public static let stripQueryCanonicalizer: @Sendable (URL) -> URL = { url in
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.query = nil
        components?.fragment = nil
        return components?.url ?? url
    }

    /// SHA-256 of the canonicalized absolute URL string.
    public func cacheKey(for url: URL) -> String {
        if let custom = cacheKeyGenerator {
            return custom(url)
        }
        let canonical = urlCanonicalizer(url)
        let digest = SHA256.hash(data: Data(canonical.absoluteString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Platform cache directory

    private static var defaultCacheDirectory: URL {
        let base: URL
        #if os(iOS) || os(tvOS) || os(watchOS)
        base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        #elseif os(macOS)
        base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        #else
        base = FileManager.default.temporaryDirectory
        #endif
        return base.appendingPathComponent("VIAudioKit", isDirectory: true)
    }
}
