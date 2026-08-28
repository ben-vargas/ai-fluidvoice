import Foundation

@MainActor
final class GrokSTTRetryStore {
    static let maxDuration: TimeInterval = 10 * 60
    static let ttl: TimeInterval = 15 * 60
    static let sampleRate = 16_000

    struct Pending: Identifiable {
        let id: UUID
        let samples: [Float]
        let sampleRate: Int
        let createdAt: Date
        let error: GrokSTTError
        let languageCode: String?
    }

    private(set) var pending: Pending?
    private let now: () -> Date

    init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    var hasPending: Bool {
        guard let pending else { return false }
        return self.now().timeIntervalSince(pending.createdAt) < Self.ttl
    }

    func retain(samples: [Float], error: GrokSTTError, languageCode: String?) {
        let maxSamples = Self.sampleRate * Int(Self.maxDuration)
        let truncated = samples.count > maxSamples ? Array(samples.prefix(maxSamples)) : samples
        self.pending = Pending(
            id: UUID(),
            samples: truncated,
            sampleRate: Self.sampleRate,
            createdAt: self.now(),
            error: error,
            languageCode: languageCode
        )
    }

    func consume() -> Pending? {
        let pending = self.pending
        self.pending = nil
        guard let pending, self.now().timeIntervalSince(pending.createdAt) < Self.ttl else {
            return nil
        }
        return pending
    }

    func clear() {
        self.pending = nil
    }
}
