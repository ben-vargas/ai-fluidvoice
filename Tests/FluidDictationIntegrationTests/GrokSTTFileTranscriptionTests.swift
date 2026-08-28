@testable import FluidVoice_Debug
import XCTest

final class GrokSTTFileTranscriptionTests: XCTestCase {
    func testCloudUploadCopy() {
        XCTAssertEqual(
            GrokSTTCloudUploadCopy.videoNotice,
            "This video will be decoded on your Mac; the extracted audio will be sent to xAI."
        )
        XCTAssertTrue(GrokSTTCloudUploadCopy.audioNotice.localizedCaseInsensitiveContains("xAI"))
        XCTAssertTrue(GrokSTTCloudUploadCopy.audioNotice.localizedCaseInsensitiveContains("audio"))
        XCTAssertEqual(
            GrokSTTCloudUploadCopy.meetingNotice(isVideo: true),
            GrokSTTCloudUploadCopy.videoNotice
        )
        XCTAssertEqual(
            GrokSTTCloudUploadCopy.meetingNotice(isVideo: false),
            GrokSTTCloudUploadCopy.audioNotice
        )
        XCTAssertTrue(GrokSTTCloudUploadCopy.localAPITranscribeNotice.contains("selected voice engine"))
        XCTAssertTrue(GrokSTTCloudUploadCopy.localAPITranscribeNotice.contains("xAI"))
        XCTAssertTrue(GrokSTTCloudUploadCopy.localAPITranscribeNotice.localizedCaseInsensitiveContains("no local fallback"))
        XCTAssertTrue(GrokSTTCloudUploadCopy.speakerLabelsUnavailable.localizedCaseInsensitiveContains("local"))
        XCTAssertTrue(GrokSTTCloudUploadCopy.speakerLabelsUnavailable.localizedCaseInsensitiveContains("diarize"))
    }

    func testSpeakerLabelsStayOnLocalEnginePath() {
        XCTAssertTrue(
            MeetingTranscriptionService.shouldAttemptSpeakerLabels(
                speakerLabelsEnabled: true,
                isSupported: true,
                isVideoContainer: false,
                isCloudEngine: false
            )
        )
        XCTAssertFalse(
            MeetingTranscriptionService.shouldAttemptSpeakerLabels(
                speakerLabelsEnabled: true,
                isSupported: true,
                isVideoContainer: false,
                isCloudEngine: true
            )
        )
        XCTAssertFalse(
            MeetingTranscriptionService.shouldAttemptSpeakerLabels(
                speakerLabelsEnabled: true,
                isSupported: true,
                isVideoContainer: true,
                isCloudEngine: false
            )
        )
        XCTAssertTrue(SettingsStore.SpeechModel.grokSTT.isCloudEngine)
    }

    func testLocalAPIErrorCopyAppendsCloudNoticeOnlyForGrok() {
        let error = GrokSTTError.videoUploadForbidden
        let local = GrokSTTCloudUploadCopy.localAPIErrorMessage(error, isCloudEngine: false)
        XCTAssertEqual(local, error.localizedDescription)
        XCTAssertFalse(local.contains(GrokSTTCloudUploadCopy.localAPITranscribeNotice))

        let cloud = GrokSTTCloudUploadCopy.localAPIErrorMessage(error, isCloudEngine: true)
        XCTAssertTrue(cloud.hasPrefix(error.localizedDescription))
        XCTAssertTrue(cloud.contains(GrokSTTCloudUploadCopy.localAPITranscribeNotice))
    }

    func testGrokPrefersNativeFileTranscription() {
        let provider = GrokSTTProvider(resolver: StubGrokSTTResolver())
        XCTAssertTrue(provider.prefersNativeFileTranscription)
    }
}

#if !os(iOS)
@MainActor
final class GrokSTTLiveFileTranscriptionTests: XCTestCase {
    func testL11MeetingsAudioFileNativeREST() async throws {
        guard ProcessInfo.processInfo.environment["GROK_STT_LIVE"] == "1" else {
            throw XCTSkip("Set GROK_STT_LIVE=1 to run authorized meeting REST probe L11")
        }

        let resolver = GrokSTTCredentialResolver.shared
        guard resolver.isSourceConfigured else {
            throw XCTSkip("No Grok STT credential source configured for L11")
        }

        let http = GrokSTTURLSessionHTTPClient()
        let client = GrokSTTRESTClient(resolver: resolver, http: http)
        let fixture = try Self.fixtureWAVURL()

        let result = try await client.transcribeFile(at: fixture, languageCode: nil)
        XCTAssertFalse(result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

        let videoURL = FileManager.default.temporaryDirectory.appendingPathComponent("l11-container.mp4")
        FileManager.default.createFile(atPath: videoURL.path, contents: Data("not-uploaded".utf8))
        defer { try? FileManager.default.removeItem(at: videoURL) }
        do {
            _ = try await client.transcribeFile(at: videoURL, languageCode: nil)
            XCTFail("L11 must not POST a video container")
        } catch {
            XCTAssertEqual(error as? GrokSTTError, .videoUploadForbidden)
        }
    }

    private static func fixtureWAVURL() throws -> URL {
        let bundle = Bundle(for: GrokSTTFileTranscriptionTests.self)
        guard let url = bundle.url(forResource: "dictation_fixture", withExtension: "wav") else {
            throw XCTSkip("dictation_fixture.wav is not in the test bundle")
        }
        return url
    }
}
#endif
