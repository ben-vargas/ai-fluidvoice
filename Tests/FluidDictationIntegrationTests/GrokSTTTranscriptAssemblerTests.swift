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

    func testUtteranceFinalReplacesItsPieces() {
        var assembler = GrokSTTTranscriptAssembler()
        assembler.record(start: 0, text: "Here's a test of FluidVoice debug")
        assembler.record(start: 2.1, text: "that is")
        assembler.record(start: 2.1, text: "that is configured with an AI provider authenticated to Anthropic.")
        assembler.record(start: 6.4, text: "to use the API in cleanup.")
        let utterance = "Here's a test of FluidVoice debug that is configured with an AI provider authenticated to Anthropic to use the API in cleanup."
        assembler.record(start: 0, text: utterance, isUtteranceFinal: true)
        XCTAssertEqual(assembler.transcript, utterance)

        assembler.record(start: 9, text: "Second")
        XCTAssertEqual(assembler.transcript, utterance + " Second")
        assembler.record(start: 9, text: "Second sentence.", isUtteranceFinal: true)
        XCTAssertEqual(assembler.transcript, utterance + " Second sentence.")
    }

    func testRepeatedUtteranceFinalIsNotDuplicated() {
        var assembler = GrokSTTTranscriptAssembler()
        assembler.record(start: 0, text: "hello there")
        assembler.record(start: 0, text: "hello there", isUtteranceFinal: true)
        assembler.record(start: 0, text: "hello there", isUtteranceFinal: true)
        XCTAssertEqual(assembler.transcript, "hello there")
    }

    func testEmptyUtteranceFinalKeepsPieces() {
        var assembler = GrokSTTTranscriptAssembler()
        assembler.record(start: 0, text: "hello")
        assembler.record(start: 1, text: "world")
        assembler.record(start: 0, text: " ", isUtteranceFinal: true)
        XCTAssertEqual(assembler.transcript, "hello world")
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
