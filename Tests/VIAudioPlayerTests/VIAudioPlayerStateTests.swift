import XCTest
@testable import VIAudioPlayer

final class VIAudioPlayerStateTests: XCTestCase {

    // MARK: - VIPlayerState.== 基础 case

    func testSameSimpleStatesAreEqual() {
        XCTAssertEqual(VIPlayerState.idle, .idle)
        XCTAssertEqual(VIPlayerState.preparing, .preparing)
        XCTAssertEqual(VIPlayerState.ready, .ready)
        XCTAssertEqual(VIPlayerState.playing, .playing)
        XCTAssertEqual(VIPlayerState.paused, .paused)
        XCTAssertEqual(VIPlayerState.buffering, .buffering)
        XCTAssertEqual(VIPlayerState.finished, .finished)
    }

    func testDifferentSimpleStatesAreNotEqual() {
        XCTAssertNotEqual(VIPlayerState.idle, .playing)
        XCTAssertNotEqual(VIPlayerState.playing, .paused)
        XCTAssertNotEqual(VIPlayerState.buffering, .finished)
    }

    // MARK: - VIPlayerState.failed 关联值比较

    func testFailedWithSameErrorTypeAndCodeAreEqual() {
        let err = NSError(domain: "test", code: 42)
        let s1 = VIPlayerState.failed(.networkError(err))
        let s2 = VIPlayerState.failed(.networkError(err))
        XCTAssertEqual(s1, s2)
    }

    func testFailedWithDifferentErrorCodesAreNotEqual() {
        let e1 = NSError(domain: "test", code: 1)
        let e2 = NSError(domain: "test", code: 2)
        let s1 = VIPlayerState.failed(.networkError(e1))
        let s2 = VIPlayerState.failed(.networkError(e2))
        XCTAssertNotEqual(s1, s2)
    }

    func testFailedWithDifferentErrorCasesAreNotEqual() {
        let err = NSError(domain: "test", code: 0)
        let s1 = VIPlayerState.failed(.networkError(err))
        let s2 = VIPlayerState.failed(.decodingFailed(err))
        XCTAssertNotEqual(s1, s2)
    }

    func testFailedNotEqualToNonFailedState() {
        let err = NSError(domain: "test", code: 0)
        XCTAssertNotEqual(VIPlayerState.failed(.networkError(err)), .idle)
        XCTAssertNotEqual(VIPlayerState.failed(.networkError(err)), .playing)
    }

    // MARK: - VIPlayerError.== 关联值比较

    func testSourceCreationFailedEquality() {
        XCTAssertEqual(VIPlayerError.sourceCreationFailed, .sourceCreationFailed)
    }

    func testSameErrorCaseAndCodeAreEqual() {
        let err = NSError(domain: "com.test", code: 99)
        XCTAssertEqual(VIPlayerError.networkError(err), .networkError(err))
        XCTAssertEqual(VIPlayerError.decodingFailed(err), .decodingFailed(err))
    }

    func testDifferentErrorCasesAreNotEqual() {
        let err = NSError(domain: "com.test", code: 0)
        XCTAssertNotEqual(VIPlayerError.networkError(err), .decodingFailed(err))
        XCTAssertNotEqual(VIPlayerError.renderingFailed(err), .seekFailed(err))
    }

    func testSameCaseDifferentDomainAreNotEqual() {
        let e1 = NSError(domain: "domain.a", code: 1)
        let e2 = NSError(domain: "domain.b", code: 1)
        XCTAssertNotEqual(VIPlayerError.networkError(e1), .networkError(e2))
    }

    func testSameCaseDifferentCodeAreNotEqual() {
        let e1 = NSError(domain: "com.test", code: 1)
        let e2 = NSError(domain: "com.test", code: 2)
        XCTAssertNotEqual(VIPlayerError.decoderCreationFailed(e1), .decoderCreationFailed(e2))
    }

    // MARK: - 状态去重：相同 failed 不触发 didSet

    func testSameFailedStateDoesNotTriggerDidSet() {
        // 验证 VIPlayerState.== 对相同 failed 返回 true，确保 didSet 内的 guard 能正确过滤
        let err = NSError(domain: "com.test", code: 42)
        let state = VIPlayerState.failed(.networkError(err))
        XCTAssertTrue(state == state)
    }

    func testDifferentFailedStatesAreDifferent() {
        // 验证不同错误会被识别为不同状态，不会被 guard state != oldValue 过滤掉
        let e1 = NSError(domain: "com.test", code: 1)
        let e2 = NSError(domain: "com.test", code: 2)
        let s1 = VIPlayerState.failed(.networkError(e1))
        let s2 = VIPlayerState.failed(.networkError(e2))
        XCTAssertFalse(s1 == s2)
    }
}
