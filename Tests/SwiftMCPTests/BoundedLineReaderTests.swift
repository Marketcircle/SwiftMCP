import Foundation
import Testing
@testable import SwiftMCP

@Suite("Bounded line reader")
struct BoundedLineReaderTests {
    /// Returns every line a reader with the given limit produces for the given input.
    private func lines(of input: String, limit: Int) throws -> [BoundedLineReader.Line] {
        let pipe = Pipe()
        let writer = pipe.fileHandleForWriting
        // The writer runs on its own queue because a long input fills the pipe before the reader starts.
        DispatchQueue.global().async {
            try? writer.write(contentsOf: Data(input.utf8))
            try? writer.close()
        }

        var reader = BoundedLineReader(fileDescriptor: pipe.fileHandleForReading.fileDescriptor, limit: limit)
        var result: [BoundedLineReader.Line] = []
        while let line = reader.next() {
            result.append(line)
        }
        return result
    }

    /// Checks that lines within the limit come back whole and in order.
    @Test func linesWithinTheLimitComeBackWhole() throws {
        #expect(try lines(of: "one\ntwo\n", limit: 10) == [.text(Data("one".utf8)), .text(Data("two".utf8))])
    }

    /// Checks that a line over the limit is dropped and the next line still comes through.
    @Test func longLineIsDroppedAndReadingContinues() throws {
        let long = String(repeating: "x", count: 50)
        #expect(try lines(of: "\(long)\nok\n", limit: 10) == [.tooLong, .text(Data("ok".utf8))])
    }

    /// Checks that a line longer than one read is dropped without holding all of it.
    @Test func lineLongerThanOneReadIsDropped() throws {
        let long = String(repeating: "x", count: BoundedLineReader.chunkSize * 3)
        #expect(try lines(of: "\(long)\nok\n", limit: 1024) == [.tooLong, .text(Data("ok".utf8))])
    }

    /// Checks that a last line without a newline still comes back.
    @Test func lastLineWithoutNewlineComesBack() throws {
        #expect(try lines(of: "one\ntwo", limit: 10) == [.text(Data("one".utf8)), .text(Data("two".utf8))])
    }
}
