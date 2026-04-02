import AVFoundation

/// Thread-safe FIFO queue of decoded PCM buffers.
/// The decode thread enqueues buffers; the render thread dequeues them.
public final class VIAudioBufferQueue: @unchecked Sendable {

    private var buffers: [AVAudioPCMBuffer] = []
    private let condition = NSCondition()
    private let capacity: Int
    private var _isFlushing = false

    /// Number of buffers currently enqueued.
    public var count: Int {
        condition.lock()
        defer { condition.unlock() }
        return buffers.count
    }

    /// Whether the queue is empty.
    public var isEmpty: Bool {
        condition.lock()
        defer { condition.unlock() }
        return buffers.isEmpty
    }

    /// Whether the queue is at capacity.
    public var isFull: Bool {
        condition.lock()
        defer { condition.unlock() }
        return buffers.count >= capacity
    }

    /// Total decoded duration currently in the queue.
    public var bufferedDuration: TimeInterval {
        condition.lock()
        defer { condition.unlock() }
        return buffers.reduce(0) { total, buf in
            let frames = Double(buf.frameLength)
            let rate = buf.format.sampleRate
            return total + (rate > 0 ? frames / rate : 0)
        }
    }

    public init(capacity: Int) {
        self.capacity = capacity
    }

    /// Enqueue a buffer. Blocks if the queue is full until space is available
    /// or `flush()` is called.
    /// - Returns: `true` if the buffer was enqueued, `false` if flushed/cancelled.
    @discardableResult
    public func enqueue(_ buffer: AVAudioPCMBuffer) -> Bool {
        condition.lock()
        while buffers.count >= capacity && !_isFlushing {
            condition.wait()
        }
        guard !_isFlushing else {
            condition.unlock()
            return false
        }
        buffers.append(buffer)
        condition.signal()
        condition.unlock()
        return true
    }

    /// Non-blocking enqueue. Returns false if queue is full or flushing.
    @discardableResult
    public func tryEnqueue(_ buffer: AVAudioPCMBuffer) -> Bool {
        condition.lock()
        guard !_isFlushing, buffers.count < capacity else {
            condition.unlock()
            return false
        }
        buffers.append(buffer)
        condition.signal()
        condition.unlock()
        return true
    }

    /// Dequeue the next buffer. Returns nil if the queue is empty.
    public func dequeue() -> AVAudioPCMBuffer? {
        condition.lock()
        defer { condition.unlock() }
        guard !buffers.isEmpty else { return nil }
        let buffer = buffers.removeFirst()
        condition.signal()
        return buffer
    }

    /// Dequeue a buffer, blocking up to `timeout` if the queue is empty.
    public func dequeue(timeout: TimeInterval) -> AVAudioPCMBuffer? {
        condition.lock()
        if buffers.isEmpty {
            _ = condition.wait(until: Date().addingTimeInterval(timeout))
        }
        guard !buffers.isEmpty else {
            condition.unlock()
            return nil
        }
        let buffer = buffers.removeFirst()
        condition.signal()
        condition.unlock()
        return buffer
    }

    /// Remove all buffered data and unblock any waiting enqueue calls.
    public func flush() {
        condition.lock()
        _isFlushing = true
        buffers.removeAll()
        condition.broadcast()
        condition.unlock()
    }

    /// Reset flushing state so the queue can accept new buffers.
    public func reset() {
        condition.lock()
        _isFlushing = false
        buffers.removeAll()
        condition.broadcast()
        condition.unlock()
    }
}
