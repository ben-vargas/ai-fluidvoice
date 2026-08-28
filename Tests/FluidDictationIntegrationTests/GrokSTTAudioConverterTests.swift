@testable import FluidVoice_Debug
import XCTest

final class GrokSTTAudioConverterTests: XCTestCase {
    func testFrameConstants() {
        XCTAssertEqual(GrokSTTAudioConverter.sampleRate, 16_000)
        XCTAssertEqual(GrokSTTAudioConverter.frameDuration, 0.100, accuracy: 0.0001)
        XCTAssertEqual(GrokSTTAudioConverter.samplesPerFrame, 1_600)
        XCTAssertEqual(GrokSTTAudioConverter.bytesPerFrame, 3_200)
    }

    func testFloat32ConvertsToPCM16LE() {
        let samples = [Float](repeating: 0.5, count: 1_600)
        let data = GrokSTTAudioConverter.pcm16LE(fromFloat32: samples)
        XCTAssertEqual(data.count, 3_200)

        let expected = Int16((0.5 * Float(Int16.max)).rounded()).littleEndian
        let value = data.withUnsafeBytes { $0.load(as: Int16.self) }
        XCTAssertEqual(value, expected)
    }

    func testPlusMinusOneClamp() {
        let data = GrokSTTAudioConverter.pcm16LE(fromFloat32: [2.0, -2.0, 1.0, -1.0])
        let values: [Int16] = data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Int16.self)).map { Int16(littleEndian: $0) }
        }
        XCTAssertEqual(values[0], Int16.max)
        XCTAssertEqual(values[1], -Int16.max)
        XCTAssertEqual(values[2], Int16.max)
        XCTAssertEqual(values[3], -Int16.max)
    }

    func testWAVHeaderPlusPCM() {
        let wav = GrokSTTAudioConverter.wav(fromFloat32: [0.0, 0.5])
        XCTAssertEqual(wav.count, 44 + 4)
        XCTAssertEqual(String(data: wav.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: wav.subdata(in: 8..<12), encoding: .ascii), "WAVE")
    }
}
