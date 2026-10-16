import Foundation
import Testing
@testable import SwiftMCP

/// Tests how the line buffer splits and drops TCP and process lines.
@Suite("Line buffer")
struct LineBufferTests {
    /// Checks that lines within the limit come back whole and in order.
    @Test func linesWithinTheLimitComeBackWhole() async {
        let buffer = LineBuffer(limit: 10)
        await buffer.append(Data("one\ntwo\nthr".utf8))
        #expect(await buffer.processLines() == [.text("one"), .text("two")])
        #expect(await buffer.getRemaining() == .text("thr"))
    }

    /// Checks that a line over the limit is dropped across appends and the next line still comes through.
    @Test func longLineIsDroppedAcrossAppends() async {
        let buffer = LineBuffer(limit: 10)
        await buffer.append(Data(String(repeating: "x", count: 30).utf8))
        #expect(await buffer.processLines().isEmpty)
        await buffer.append(Data(String(repeating: "x", count: 30).utf8))
        #expect(await buffer.processLines().isEmpty)
        await buffer.append(Data("x\nok\n".utf8))
        #expect(await buffer.processLines() == [.tooLong, .text("ok")])
    }

    /// Checks that an over-limit tail without a newline reports as too long.
    @Test func longRemainderIsTooLong() async {
        let buffer = LineBuffer(limit: 10)
        await buffer.append(Data(String(repeating: "x", count: 30).utf8))
        _ = await buffer.processLines()
        #expect(await buffer.getRemaining() == .tooLong)
        #expect(await buffer.getRemaining() == nil)
    }
}
