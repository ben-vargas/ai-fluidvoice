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
}
