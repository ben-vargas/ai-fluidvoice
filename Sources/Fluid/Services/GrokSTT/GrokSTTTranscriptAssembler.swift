import Foundation

/// Last-write-wins transcript assembler. Port of Quill’s per-`start` rule.
nonisolated struct GrokSTTTranscriptAssembler: Sendable {
    private var segmentOrder: [Double] = []
    private var segments: [Double: String] = [:]

    mutating func record(start: Double, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if self.segments[start] == nil {
            self.segmentOrder.append(start)
        }
        self.segments[start] = trimmed
    }

    mutating func replaceWithServerText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        self.segmentOrder = [-1]
        self.segments = [-1: trimmed]
    }

    var transcript: String {
        self.segmentOrder.compactMap { self.segments[$0] }.joined(separator: " ")
    }
}
