@testable import FluidVoice_Debug
import XCTest

final class GrokSTTTranscriptAssemblerTests: XCTestCase {
    func testLastWriteWinsPerStart() {
        var assembler = GrokSTTTranscriptAssembler()
        assembler.record(start: 0, text: "hel")
        assembler.record(start: 0, text: "hello")
        assembler.record(start: 1.2, text: "world")
        XCTAssertEqual(assembler.transcript, "hello world")
    }

    func testEmptyInterimDoesNotWipe() {
        var assembler = GrokSTTTranscriptAssembler()
        assembler.record(start: 0, text: "hello")
        assembler.record(start: 0, text: "  ")
        assembler.record(start: 1, text: "")
        XCTAssertEqual(assembler.transcript, "hello")
    }

    func testIsFinalTwiceDoesNotDuplicate() {
        var assembler = GrokSTTTranscriptAssembler()
        assembler.record(start: 0, text: "hello there")
        assembler.record(start: 0, text: "hello there")
        XCTAssertEqual(assembler.transcript, "hello there")
    }

    func testServerDoneTextReplacesAssembler() {
        var assembler = GrokSTTTranscriptAssembler()
        assembler.record(start: 0, text: "partial")
        assembler.record(start: 1, text: "words")
        assembler.replaceWithServerText("final transcript")
        XCTAssertEqual(assembler.transcript, "final transcript")
        assembler.replaceWithServerText("   ")
        XCTAssertEqual(assembler.transcript, "final transcript")
    }
}
