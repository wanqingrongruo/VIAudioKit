import XCTest
import AVFoundation
@testable import VIAudioPlayer

final class VIAudioBufferQueueTests: XCTestCase {

    private func makeBuffer(frames: UInt32 = 1024) -> AVAudioPCMBuffer? {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44100, channels: 2, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        return buffer
    }

    func testEnqueueDequeue() {
        let queue = VIAudioBufferQueue(capacity: 4)
        let buf = makeBuffer()!
        queue.enqueue(buf)
        XCTAssertEqual(queue.count, 1)
        let dequeued = queue.dequeue()
        XCTAssertNotNil(dequeued)
        XCTAssertEqual(queue.count, 0)
    }

    func testDequeueEmptyReturnsNil() {
        let queue = VIAudioBufferQueue(capacity: 4)
        XCTAssertNil(queue.dequeue())
    }

    func testFlush() {
        let queue = VIAudioBufferQueue(capacity: 4)
        for _ in 0..<3 {
            queue.enqueue(makeBuffer()!)
        }
        XCTAssertEqual(queue.count, 3)
        queue.flush()
        XCTAssertEqual(queue.count, 0)
    }

    func testBufferedDuration() {
        let queue = VIAudioBufferQueue(capacity: 4)
        // 1024 frames at 44100 Hz ≈ 0.0232 seconds
        queue.enqueue(makeBuffer(frames: 44100)!)
        let dur = queue.bufferedDuration
        XCTAssertEqual(dur, 1.0, accuracy: 0.001)
    }
}
