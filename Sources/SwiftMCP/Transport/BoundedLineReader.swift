#if canImport(Glibc)
@preconcurrency import Glibc
#endif

import Foundation

/// A reader that splits a file descriptor's bytes into lines and drops lines over a limit.
struct BoundedLineReader: IteratorProtocol {
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
    /// The buffer every read fills.
    private var chunk = [UInt8](repeating: 0, count: BoundedLineReader.chunkSize)

    /// Creates a reader for the given file descriptor and line limit in bytes.
    init(fileDescriptor: Int32, limit: Int) {
        self.fileDescriptor = fileDescriptor
        self.limit = limit
    }

    /// Returns the next line, or nil at the end of the input or after a failed read.
    mutating func next() -> Line? {
        while true {
            if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = Self.strippingCarriageReturn(Data(buffer[buffer.startIndex..<newline]))
                buffer.removeSubrange(buffer.startIndex...newline)
                let wasDiscarding = discarding
                discarding = false
                return wasDiscarding || line.count > limit ? .tooLong : .text(line)
            }
            if buffer.count > limit {
                // The reader drops the buffered bytes of an over-limit line.
                buffer.removeAll()
                discarding = true
            }

            let count = read(fileDescriptor, &chunk, Self.chunkSize)
            if count < 0 {
                if errno == EINTR {
                    continue
                }
                // A failed read keeps the buffer for the next call.
                return nil
            }
            if count == 0 {
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
        return buffer.isEmpty ? nil : .text(Self.strippingCarriageReturn(buffer))
    }

    /// Returns the line without a trailing carriage return.
    private static func strippingCarriageReturn(_ line: Data) -> Data {
        line.last == UInt8(ascii: "\r") ? line.dropLast() : line
    }
}
