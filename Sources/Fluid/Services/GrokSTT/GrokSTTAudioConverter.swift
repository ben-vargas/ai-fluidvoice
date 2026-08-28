import Foundation

nonisolated enum GrokSTTAudioConverter {
    static let sampleRate = 16_000
    static let frameDuration: TimeInterval = 0.100
    static let samplesPerFrame = 1_600
    static let bytesPerFrame = 3_200

    static func pcm16LE(fromFloat32 samples: ArraySlice<Float>) -> Data {
        var data = Data(count: samples.count * 2)
        data.withUnsafeMutableBytes { raw in
            let out = raw.bindMemory(to: Int16.self)
            for (i, sample) in samples.enumerated() {
                let clamped = max(-1.0, min(1.0, sample))
                out[i] = Int16((clamped * Float(Int16.max)).rounded()).littleEndian
            }
        }
        return data
    }

    static func pcm16LE(fromFloat32 samples: [Float]) -> Data {
        self.pcm16LE(fromFloat32: samples[...])
    }

    /// 44-byte WAV header + PCM16. Matches `DictationAudioHistoryStore.wavData`.
    static func wav(fromFloat32 samples: [Float], sampleRate: Int = sampleRate, channels: Int = 1) -> Data {
        let bitsPerSample = 16
        let bytesPerSample = bitsPerSample / 8
        let dataByteCount = samples.count * bytesPerSample
        let byteRate = sampleRate * channels * bytesPerSample
        let blockAlign = channels * bytesPerSample

        var data = Data()
        data.reserveCapacity(44 + dataByteCount)
        data.append(contentsOf: Array("RIFF".utf8))
        Self.appendUInt32LE(UInt32(36 + dataByteCount), to: &data)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        Self.appendUInt32LE(16, to: &data)
        Self.appendUInt16LE(1, to: &data)
        Self.appendUInt16LE(UInt16(channels), to: &data)
        Self.appendUInt32LE(UInt32(sampleRate), to: &data)
        Self.appendUInt32LE(UInt32(byteRate), to: &data)
        Self.appendUInt16LE(UInt16(blockAlign), to: &data)
        Self.appendUInt16LE(UInt16(bitsPerSample), to: &data)
        data.append(contentsOf: Array("data".utf8))
        Self.appendUInt32LE(UInt32(dataByteCount), to: &data)
        data.append(self.pcm16LE(fromFloat32: samples))
        return data
    }

    private static func appendUInt16LE(_ value: UInt16, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }

    private static func appendUInt32LE(_ value: UInt32, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}
