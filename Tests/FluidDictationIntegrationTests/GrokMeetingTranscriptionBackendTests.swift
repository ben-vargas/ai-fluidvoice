@testable import FluidVoice_Debug
import XCTest

@MainActor
final class GrokMeetingTranscriptionBackendTests: XCTestCase {
    func testDescriptorIsHostedLegacyContractWithGrokLanguages() {
        let descriptor = GrokMeetingTranscriptionBackend.descriptor
        XCTAssertEqual(descriptor.id, .grokSTT)
        XCTAssertEqual(descriptor.execution, .hosted)
        XCTAssertEqual(descriptor.resultContract, .legacyResult)
        XCTAssertTrue(descriptor.supportedLanguageCodes.isSuperset(of: ["en", "es", "fr", "de"]))
    }

    func testPlansNonEnglishMeetingsTheLegacyBackendRejects() throws {
        let backend = GrokMeetingTranscriptionBackend(legacyExecutor: { _, _ in
            throw MeetingProcessingError.noRecoverableAudio
        })
        let request = self.makeRequest(languageCode: "es")
        let plan = try backend.plan(request)
        XCTAssertEqual(plan.backendID, .grokSTT)
        XCTAssertNil(plan.agreementDefect(with: request, descriptor: backend.descriptor))

        let legacy = MeetingLegacyCompatibilityBackend(legacyExecutor: { _, _ in
            throw MeetingProcessingError.noRecoverableAudio
        })
        XCTAssertThrowsError(try legacy.plan(request))
    }

    func testRejectsLanguagesGrokDoesNotSupport() {
        let backend = GrokMeetingTranscriptionBackend(legacyExecutor: { _, _ in
            throw MeetingProcessingError.noRecoverableAudio
        })
        XCTAssertThrowsError(try backend.plan(self.makeRequest(languageCode: "bg"))) { error in
            XCTAssertEqual(
                error as? MeetingBackendError,
                .unsupportedLanguage(backend: .grokSTT, languageCode: "bg")
            )
        }
    }

    func testDefaultRegistryResolvesTheGrokBackend() throws {
        let backend = try MeetingTranscriptionBackendRegistry.makeDefault().makeBackend(
            id: .grokSTT,
            context: MeetingBackendHostContext(legacyExecutor: { _, _ in
                throw MeetingProcessingError.noRecoverableAudio
            })
        )
        XCTAssertTrue(backend is GrokMeetingTranscriptionBackend)
    }

    // MARK: - Fixtures

    private func makeRequest(languageCode: String) -> MeetingBackendRequest {
        let timebase = MeetingTimebaseMetadata(
            startedHostTime: 0,
            machTimebaseNumerator: 1,
            machTimebaseDenominator: 1,
            firstPresentationTime: nil
        )
        var session = MeetingSession(
            configuration: MeetingCaptureConfiguration(
                mode: .onlineCall,
                title: "Grok fixture",
                languageCode: languageCode,
                microphone: MeetingMicrophoneIdentity(captureDeviceID: "mic-1", displayName: "Mic")
            ),
            timebase: timebase
        )
        let chunk = MeetingAudioChunk(
            id: UUID(),
            sequence: 0,
            relativeFilePath: "tracks/microphone/chunk_0.caf",
            presentationStart: MeetingMediaTime(value: 0, timescale: 1000),
            presentationEnd: MeetingMediaTime(value: 1000, timescale: 1000),
            discontinuities: [],
            sha256: "fixture-0",
            byteCount: 1024,
            finalizationState: .finalized
        )
        session.audioTracks = [
            MeetingAudioTrack(
                id: UUID(),
                kind: .microphone,
                sourceIdentifier: "microphone",
                sourceDisplayName: "microphone",
                format: nil,
                timebase: timebase,
                health: .waiting,
                chunks: [chunk]
            ),
        ]
        return MeetingBackendRequest(
            attemptID: UUID(),
            session: session,
            sessionDirectory: FileManager.default.temporaryDirectory,
            configuration: MeetingFinalProcessingConfiguration(languageCode: languageCode)
        )
    }
}
