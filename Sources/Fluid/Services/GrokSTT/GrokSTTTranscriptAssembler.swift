import Foundation

/// Builds the live transcript from `transcript.partial` events.
///
/// xAI sends each utterance in pieces: interim results and chunk finals, keyed by `start`. A newer result for
/// the same `start` replaces the older one. When the utterance ends, one result with both `is_final` and
/// `speech_final` restates the whole utterance, including every earlier chunk final, so it replaces that
/// utterance's pieces instead of being added after them.
nonisolated struct GrokSTTTranscriptAssembler: Sendable {
    private var completedUtterances: [String] = []
    private var segmentOrder: [Double] = []
    private var segments: [Double: String] = [:]

    mutating func record(start: Double, text: String, isUtteranceFinal: Bool = false) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if isUtteranceFinal {
            // A repeated utterance final arrives with no new pieces in between.
            if self.segmentOrder.isEmpty, self.completedUtterances.last == trimmed { return }
            self.completedUtterances.append(trimmed)
            self.segmentOrder = []
            self.segments = [:]
            return
        }

        if self.segments[start] == nil {
            self.segmentOrder.append(start)
        }
        self.segments[start] = trimmed
    }

    mutating func replaceWithServerText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        self.completedUtterances = [trimmed]
        self.segmentOrder = []
        self.segments = [:]
    }

    var transcript: String {
        (self.completedUtterances + self.segmentOrder.compactMap { self.segments[$0] }).joined(separator: " ")
    }
}
