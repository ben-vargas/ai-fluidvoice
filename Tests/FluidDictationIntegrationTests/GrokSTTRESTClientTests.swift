@testable import FluidVoice_Debug
import XCTest

final class GrokSTTRESTClientTests: XCTestCase {
    func testTranscribePCMPostsWAVWithOptionsBeforeFile() async throws {
        let http = FakeGrokSTTHTTPClient()
        http.enqueue(status: 200, json: ["text": "hello from rest"])
        let client = GrokSTTRESTClient(resolver: RecordingGrokSTTResolver(), http: http)
        let result = try await client.transcribePCM(
            [Float](repeating: 0.1, count: 1_600),
            languageCode: "en",
            keyterms: ["FluidVoice"]
        )
        XCTAssertEqual(result.text, "hello from rest")
        XCTAssertEqual(http.requests.count, 1)
        let request = http.requests[0]
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url, GrokSTTRESTClient.endpoint)
        XCTAssertTrue((request.value(forHTTPHeaderField: "Authorization") ?? "").hasPrefix("Bearer "))
        let body = request.httpBody ?? Data()
        let bodyString = String(decoding: body, as: UTF8.self)
        let languageRange = bodyString.range(of: "name=\"language\"")
        let keytermRange = bodyString.range(of: "name=\"keyterm\"")
        let formatRange = bodyString.range(of: "name=\"format\"")
        let fileRange = bodyString.range(of: "name=\"file\"")
        XCTAssertNotNil(languageRange)
        XCTAssertNotNil(keytermRange)
        XCTAssertNotNil(formatRange)
        XCTAssertNotNil(fileRange)
        XCTAssertLessThan(languageRange!.lowerBound, fileRange!.lowerBound)
        XCTAssertLessThan(keytermRange!.lowerBound, fileRange!.lowerBound)
        XCTAssertLessThan(formatRange!.lowerBound, fileRange!.lowerBound)
        XCTAssertTrue(body.starts(with: Data("--".utf8)) || bodyString.contains("RIFF") || body.count > 44)
        XCTAssertGreaterThan(body.count, 44)
        XCTAssertFalse(bodyString.contains("diarize"))
    }

    func testAutoLanguageOmitsLanguageAndFormat() async throws {
        let http = FakeGrokSTTHTTPClient()
        http.enqueue(status: 200, json: ["text": "auto"])
        let client = GrokSTTRESTClient(resolver: RecordingGrokSTTResolver(), http: http)
        _ = try await client.transcribePCM([0.1, 0.2], languageCode: nil)
        let bodyString = String(decoding: http.requests[0].httpBody ?? Data(), as: UTF8.self)
        XCTAssertFalse(bodyString.contains("name=\"language\""))
        XCTAssertFalse(bodyString.contains("name=\"format\""))
    }

    func testCLI401RetriesOnceWithAlternate() async throws {
        let http = FakeGrokSTTHTTPClient()
        http.enqueue(status: 401, json: ["error": "unauthorized"])
        http.enqueue(status: 200, json: ["text": "recovered"])
        let resolver = RecordingGrokSTTResolver(
            source: .grokCLISession,
            bearer: "cli-a",
            alternateBearer: "cli-b"
        )
        let client = GrokSTTRESTClient(resolver: resolver, http: http)
        let result = try await client.transcribePCM([0.2], languageCode: nil)
        XCTAssertEqual(result.text, "recovered")
        XCTAssertEqual(http.requests.count, 2)
        XCTAssertEqual(resolver.unauthorizedCallCount, 1)
    }

    func testAPIKey401DoesNotRetry() async {
        let http = FakeGrokSTTHTTPClient()
        http.enqueue(status: 401, json: ["error": "unauthorized"])
        let resolver = RecordingGrokSTTResolver(source: .apiKey, alternateBearer: "unused")
        let client = GrokSTTRESTClient(resolver: resolver, http: http)
        do {
            _ = try await client.transcribePCM([0.2], languageCode: nil)
            XCTFail("API key 401 must not retry")
        } catch {
            XCTAssertEqual(error as? GrokSTTError, .unauthorized)
        }
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(resolver.unauthorizedCallCount, 0)
    }

    func test403DoesNotRetry() async {
        let http = FakeGrokSTTHTTPClient()
        http.enqueue(status: 403, json: ["error": "forbidden"])
        let resolver = RecordingGrokSTTResolver(source: .grokCLISession, alternateBearer: "unused")
        let client = GrokSTTRESTClient(resolver: resolver, http: http)
        do {
            _ = try await client.transcribePCM([0.2], languageCode: nil)
            XCTFail("403 must not retry")
        } catch {
            XCTAssertEqual(error as? GrokSTTError, .forbidden)
        }
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(resolver.unauthorizedCallCount, 0)
    }

    func testNetworkFailureMapsToOffline() async {
        let http = FakeGrokSTTHTTPClient()
        http.enqueueFailure(NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet))
        let client = GrokSTTRESTClient(resolver: RecordingGrokSTTResolver(), http: http)
        do {
            _ = try await client.transcribePCM([0.2], languageCode: nil)
            XCTFail("offline must throw")
        } catch {
            XCTAssertEqual(error as? GrokSTTError, .offline)
        }
    }

    func testEmptySamplesThrowInvalidAudio() async {
        let client = GrokSTTRESTClient(resolver: RecordingGrokSTTResolver(), http: FakeGrokSTTHTTPClient())
        do {
            _ = try await client.transcribePCM([], languageCode: nil)
            XCTFail("empty PCM must throw")
        } catch {
            XCTAssertEqual(error as? GrokSTTError, .invalidAudio)
        }
    }

    func testMeetingTimeoutFormula() {
        XCTAssertEqual(GrokSTTRESTClient.meetingTimeout(durationSeconds: 10), 50)
        XCTAssertEqual(GrokSTTRESTClient.meetingTimeout(durationSeconds: 300), 600)
        XCTAssertEqual(GrokSTTRESTClient.meetingTimeout(durationSeconds: 0), 600)
        XCTAssertEqual(GrokSTTRESTClient.meetingTimeout(durationSeconds: -4), 600)
        XCTAssertEqual(GrokSTTRESTClient.meetingTimeout(durationSeconds: .nan), 600)
        XCTAssertEqual(GrokSTTRESTClient.meetingTimeout(durationSeconds: .infinity), 600)
    }

    func testM4AIsNotAVideoContainer() {
        XCTAssertFalse(GrokSTTRESTClient.isVideoContainer(URL(fileURLWithPath: "/tmp/clip.m4a")))
        XCTAssertFalse(GrokSTTRESTClient.isVideoContainer(URL(fileURLWithPath: "/tmp/clip.wav")))
        XCTAssertFalse(GrokSTTRESTClient.isVideoContainer(URL(fileURLWithPath: "/tmp/clip.mp3")))
        XCTAssertTrue(GrokSTTRESTClient.isVideoContainer(URL(fileURLWithPath: "/tmp/clip.mp4")))
        XCTAssertTrue(GrokSTTRESTClient.isVideoContainer(URL(fileURLWithPath: "/tmp/clip.mov")))
        XCTAssertTrue(GrokSTTRESTClient.isVideoContainer(URL(fileURLWithPath: "/tmp/clip.m4v")))
    }

    func testTranscribeFilePostsOriginalFilenameWithoutAudioFormat() async throws {
        let http = FakeGrokSTTHTTPClient()
        http.enqueue(status: 200, json: ["text": "from-file"])
        let client = GrokSTTRESTClient(resolver: RecordingGrokSTTResolver(), http: http)
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("standup.wav")
        try GrokSTTAudioConverter.wav(fromFloat32: [Float](repeating: 0.2, count: 1_600)).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }

        let result = try await client.transcribeFile(
            at: fileURL,
            languageCode: "en",
            keyterms: ["FluidVoice"]
        )
        XCTAssertEqual(result.text, "from-file")
        XCTAssertEqual(http.requests.count, 1)
        let body = http.requests[0].httpBody ?? Data()
        let bodyString = String(decoding: body, as: UTF8.self)
        XCTAssertTrue(bodyString.contains("filename=\"standup.wav\""))
        XCTAssertTrue(bodyString.contains("Content-Type: audio/wav"))
        XCTAssertFalse(bodyString.contains("audio_format"))
        XCTAssertFalse(bodyString.contains("diarize"))
        let languageRange = bodyString.range(of: "name=\"language\"")
        let fileRange = bodyString.range(of: "name=\"file\"")
        XCTAssertNotNil(languageRange)
        XCTAssertNotNil(fileRange)
        XCTAssertLessThan(languageRange!.lowerBound, fileRange!.lowerBound)
        XCTAssertEqual(
            http.requests[0].timeoutInterval,
            GrokSTTRESTClient.meetingTimeout(durationSeconds: GrokSTTRESTClient.durationSeconds(of: fileURL)),
            accuracy: 0.1
        )
    }

    func testVideoContainerIsNotPosted() async {
        let http = FakeGrokSTTHTTPClient()
        http.enqueue(status: 200, json: ["text": "should-not-see"])
        let client = GrokSTTRESTClient(resolver: RecordingGrokSTTResolver(), http: http)
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("interview.mp4")
        FileManager.default.createFile(atPath: fileURL.path, contents: Data("not-a-real-mp4".utf8))
        defer { try? FileManager.default.removeItem(at: fileURL) }

        do {
            _ = try await client.transcribeFile(at: fileURL, languageCode: nil)
            XCTFail("video containers must not be POSTed")
        } catch {
            XCTAssertEqual(error as? GrokSTTError, .videoUploadForbidden)
        }
        XCTAssertEqual(http.requests.count, 0)
    }

    func testFileTooLargeThrowsBeforeUpload() async throws {
        let http = FakeGrokSTTHTTPClient()
        http.enqueue(status: 200, json: ["text": "should-not-see"])
        let client = GrokSTTRESTClient(resolver: RecordingGrokSTTResolver(), http: http)
        let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("huge.wav")
        FileManager.default.createFile(atPath: fileURL.path, contents: Data("RIFF".utf8))
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.truncate(atOffset: UInt64(GrokSTTRESTClient.maxFileBytes) + 1)
        try handle.close()
        defer { try? FileManager.default.removeItem(at: fileURL) }

        do {
            _ = try await client.transcribeFile(at: fileURL, languageCode: nil)
            XCTFail("oversized files must fail before upload")
        } catch {
            XCTAssertEqual(error as? GrokSTTError, .fileTooLarge)
        }
        XCTAssertEqual(http.requests.count, 0)
    }

    func testErrorsDoNotEmbedBearer() async {
        let http = FakeGrokSTTHTTPClient()
        http.enqueue(status: 401, json: ["error": "Bearer supersecret-token-value-12345678901234567890"])
        let client = GrokSTTRESTClient(resolver: RecordingGrokSTTResolver(), http: http)
        do {
            _ = try await client.transcribePCM([0.2], languageCode: nil)
            XCTFail("expected unauthorized")
        } catch let error as GrokSTTError {
            let ns = error.asNSError()
            XCTAssertEqual(Array(ns.userInfo.keys), [NSLocalizedDescriptionKey])
            XCTAssertFalse(ns.localizedDescription.contains("Bearer"))
            XCTAssertFalse(String(describing: error).contains("supersecret"))
        } catch {
            XCTFail("expected GrokSTTError, got \(error)")
        }
    }
}
