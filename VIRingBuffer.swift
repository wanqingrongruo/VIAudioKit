import Foundation

/// 环形缓冲区，用于推送模式解码器的数据中转。
///
/// 线程安全：内部使用 `NSCondition` 在生产者（`write`）与消费者（`read`）之间同步，
/// 保留 1 字节区分满/空状态。
final class VIRingBuffer {

    // MARK: - 属性

    /// 环形缓冲区底层存储
    private var buffer: Data
    /// 读指针
    private var head: Int = 0
    /// 写指针
    private var tail: Int = 0
    /// 缓冲区容量
    let capacity: Int
    /// 同步条件变量
    private let condition = NSCondition()

    /// 标记流是否已关闭（不再有新数据写入）
    private(set) var isClosed: Bool = false
    /// 标记是否已中止（立即停止所有操作）
    private(set) var isAborted: Bool = false
    /// 标记是否正在 seek（重置缓冲区期间暂停读取）
    private(set) var isSeeking: Bool = false
    /// 累计写入字节数
    private(set) var totalBytesWritten: Int64 = 0

    // MARK: - 初始化

    /// 创建指定容量的环形缓冲区
    /// - Parameter capacity: 缓冲区字节容量，默认 10MB
    init(capacity: Int = 10 * 1024 * 1024) {
        self.capacity = capacity
        self.buffer = Data(count: capacity)
    }

    // MARK: - 写入

    /// 将数据写入环形缓冲区。
    /// 当缓冲区满时会阻塞等待，直到有可用空间或缓冲区被关闭。
    /// - Parameter data: 待写入的原始数据
    func write(_ data: Data) {
        var offset = 0
        while offset < data.count {
            condition.lock()

            // 计算环形缓冲区可用空间（保留 1 字节区分满/空）
            var available = (head - tail - 1 + capacity) % capacity
            while available == 0 && !isClosed {
                condition.wait()
                available = (head - tail - 1 + capacity) % capacity
            }

            if isClosed {
                condition.unlock()
                return
            }

            let chunkSize = min(data.count - offset, available)

            data.withUnsafeBytes { ptr in
                guard let bytes = ptr.bindMemory(to: UInt8.self).baseAddress else { return }
                let src = bytes + offset
                let firstPart = min(chunkSize, capacity - tail)

                buffer.withUnsafeMutableBytes { rbPtr in
                    guard let rbBase = rbPtr.bindMemory(to: UInt8.self).baseAddress else { return }
                    memcpy(rbBase + tail, src, firstPart)
                    if chunkSize > firstPart {
                        memcpy(rbBase, src + firstPart, chunkSize - firstPart)
                    }
                }
            }

            tail = (tail + chunkSize) % capacity
            offset += chunkSize
            totalBytesWritten += Int64(chunkSize)

            condition.signal()
            condition.unlock()
        }
    }

    // MARK: - 读取

    /// 从环形缓冲区读取数据到指定指针。
    /// 当缓冲区为空时会阻塞等待，直到有数据、被关闭或被中止。
    /// - Parameters:
    ///   - buf: 目标缓冲区指针
    ///   - size: 请求读取的字节数
    /// - Returns: 实际读取的字节数，`-1` 表示 EOF（调用方负责转换为具体错误码）
    func read(into buf: UnsafeMutablePointer<UInt8>, size: Int32) -> Int32 {
        condition.lock()
        defer { condition.unlock() }

        // 等待数据可用
        while head == tail && !isClosed && !isAborted && !isSeeking {
            condition.wait()
        }

        // 中止、seek 或缓冲区已空且关闭时返回 EOF
        if isAborted || isSeeking || (head == tail && isClosed) {
            return -1
        }

        // 计算可读字节数
        var available = 0
        if tail > head {
            available = tail - head
        } else {
            available = capacity - head + tail
        }

        let toRead = min(Int(size), available)
        let firstPart = min(toRead, capacity - head)

        buffer.withUnsafeBytes { rbPtr in
            guard let rbBase = rbPtr.bindMemory(to: UInt8.self).baseAddress else { return }
            memcpy(buf, rbBase + head, firstPart)
            if toRead > firstPart {
                memcpy(buf + firstPart, rbBase, toRead - firstPart)
            }
        }

        head = (head + toRead) % capacity
        condition.signal()
        return Int32(toRead)
    }

    // MARK: - 状态控制

    /// 关闭缓冲区，标记不再有新数据写入。
    /// 消费者读完剩余数据后会收到 EOF。
    func close() {
        condition.lock()
        isClosed = true
        condition.broadcast()
        condition.unlock()
    }

    /// 中止缓冲区，立即终止所有读写操作。
    func abort() {
        condition.lock()
        isAborted = true
        isClosed = true
        condition.broadcast()
        condition.unlock()
    }

    /// 开始 seek：重置读写指针和计数器，暂停消费者读取。
    func beginSeek() {
        condition.lock()
        isSeeking = true
        isClosed = false
        head = 0
        tail = 0
        totalBytesWritten = 0
        condition.broadcast()
        condition.unlock()
    }

    /// 结束 seek：恢复消费者读取。
    func endSeek() {
        condition.lock()
        isSeeking = false
        condition.unlock()
    }

    /// 完全重置缓冲区到初始状态。
    func reset() {
        condition.lock()
        head = 0
        tail = 0
        isClosed = false
        isAborted = false
        isSeeking = false
        totalBytesWritten = 0
        condition.broadcast()
        condition.unlock()
    }
}
