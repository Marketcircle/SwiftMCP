#if canImport(Glibc)
@preconcurrency import Glibc
#endif

import Foundation

/// A reader that splits the bytes of a file descriptor into lines and drops every line longer than a limit.
struct BoundedLineReader {
    /// One line the reader returns.
    enum Line: Equatable {
        /// A line within the limit, without its newline.
        case text(Data)
        /// A line over the limit, whose bytes the reader dropped.
        case tooLong
    }

    /// The number of bytes each read asks for.
    static let chunkSize = 64 * 1024

    /// The file descriptor the reader reads from.
    let fileDescriptor: Int32
    /// The most bytes a line may hold.
    let limit: Int
    /// The bytes read but not yet returned.
    private var buffer = Data()
    /// A Boolean value indicating whether the reader is dropping bytes until the next newline.
    private var discarding = false

    /// Creates a reader for the given file descriptor that drops lines longer than the given number of bytes.
    init(fileDescriptor: Int32, limit: Int) {
        self.fileDescriptor = fileDescriptor
        self.limit = limit
    }

    /// Returns the next line, or nil at the end of the input.
    mutating func next() -> Line? {
        var chunk = [UInt8](repeating: 0, count: Self.chunkSize)
        while true {
            if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
                let wasDiscarding = discarding
                discarding = false
                return wasDiscarding || line.count > limit ? .tooLong : .text(line)
            }
            if buffer.count > limit {
                // The reader keeps no more than the limit while it waits for a newline.
                buffer.removeAll()
                discarding = true
            }

            let count = read(fileDescriptor, &chunk, chunk.count)
            if count < 0, errno == EINTR {
                continue
            }
            guard count > 0 else {
                return finish()
            }
            buffer.append(contentsOf: chunk[0..<count])
        }
    }

    /// Returns the last line when the input ends without a newline, or nil when nothing is left.
    private mutating func finish() -> Line? {
        defer {
            buffer.removeAll()
            discarding = false
        }
        if discarding || buffer.count > limit {
            return .tooLong
        }
        return buffer.isEmpty ? nil : .text(buffer)
    }
}
