import Foundation

/// Buffers bytes to return full newline-delimited lines.
actor LineBuffer {
    /// One line the buffer returns.
    enum Line: Equatable, Sendable {
        /// A line within the limit, without its newline.
        case text(String)
        /// A line over the limit, whose bytes the buffer dropped.
        case tooLong
    }

    /// The most bytes a line may hold.
    let limit: Int
    private var buffer = Data()
    /// A Boolean value indicating whether the buffer is dropping bytes until the next newline.
    private var discarding = false

    /// Creates a buffer that drops lines longer than the given number of bytes, 4 MB by default.
    init(limit: Int = 4 * 1024 * 1024) {
        self.limit = limit
    }

    func append(_ data: Data) {
        buffer.append(data)
    }

    func processLines() -> [Line] {
        var lines: [Line] = []
        while let range = buffer.firstRange(of: Data([0x0A])) {
            let lineData = buffer[..<range.lowerBound]
            buffer.removeSubrange(..<range.upperBound)

            let wasDiscarding = discarding
            discarding = false
            if wasDiscarding || lineData.count > limit {
                lines.append(.tooLong)
            } else if let line = String(data: lineData, encoding: .utf8) {
                lines.append(.text(line))
            }
        }
        if buffer.count > limit {
            // The buffer drops the bytes of an over-limit line until its newline arrives.
            buffer.removeAll()
            discarding = true
        }
        return lines
    }

    func getRemaining() -> Line? {
        defer {
            buffer.removeAll()
            discarding = false
        }
        if discarding || buffer.count > limit {
            return .tooLong
        }
        guard !buffer.isEmpty, let line = String(data: buffer, encoding: .utf8) else { return nil }
        return .text(line)
    }
}
