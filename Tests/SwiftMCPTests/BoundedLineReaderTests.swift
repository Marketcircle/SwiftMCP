import Foundation
import Testing
@testable import SwiftMCP

/// Tests how the bounded line reader splits and drops lines.
@Suite("Bounded line reader")
struct BoundedLineReaderTests {
    /// Returns every line a reader with the given limit produces for the given input.
    private func lines(of input: String, limit: Int) throws -> [BoundedLineReader.Line] {
        let pipe = Pipe()
        let writer = pipe.fileHandleForWriting
        // A background queue writes the input while the reader reads it.
        DispatchQueue.global().async {
            try? writer.write(contentsOf: Data(input.utf8))
            try? writer.close()
        }

        return withExtendedLifetime(pipe) {
            Array(IteratorSequence(BoundedLineReader(fileDescriptor: pipe.fileHandleForReading.fileDescriptor, limit: limit)))
        }
    }

    /// Checks that a Windows line ending comes back without its carriage return.
    @Test func carriageReturnIsStripped() throws {
        #expect(try lines(of: "one\r\ntwo\r", limit: 10) == [.text(Data("one".utf8)), .text(Data("two".utf8))])
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
