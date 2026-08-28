import AVFoundation
import Foundation
import UniformTypeIdentifiers

nonisolated protocol GrokSTTHTTPPerforming: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

final nonisolated class GrokSTTURLSessionHTTPClient: GrokSTTHTTPPerforming, @unchecked Sendable {
    private let session: URLSession

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.waitsForConnectivity = false
            self.session = URLSession(configuration: configuration)
        }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await self.session.data(for: request)
    }
}

/// REST `POST https://api.x.ai/v1/stt` for empty-socket retry and meeting/file audio.
final nonisolated class GrokSTTRESTClient: @unchecked Sendable {
    static let endpoint = URL(string: "https://api.x.ai/v1/stt")!
    static let dictationTimeout: TimeInterval = 60
    static let meetingTimeoutCap: TimeInterval = 600
    static let maxFileBytes = 500 * 1024 * 1024

    /// Meetings timeout: `min(600, 30 + 2 * durationSeconds)`. Unknown/non-positive duration uses the cap.
    static func meetingTimeout(durationSeconds: TimeInterval) -> TimeInterval {
        guard durationSeconds.isFinite, durationSeconds > 0 else {
            return self.meetingTimeoutCap
        }
        return min(self.meetingTimeoutCap, 30 + (2 * durationSeconds))
    }

    static func isVideoContainer(_ fileURL: URL) -> Bool {
        let ext = fileURL.pathExtension
        guard !ext.isEmpty, let type = UTType(filenameExtension: ext) else {
            return false
        }
        return type.conforms(to: .movie)
    }

    static func sanitizedFilename(_ raw: String) -> String {
        let last = (raw as NSString).lastPathComponent
        let cleaned = last
            .replacingOccurrences(of: "\"", with: "_")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "audio.bin" : cleaned
    }

    static func mimeType(forFilename filename: String) -> String {
        switch (filename as NSString).pathExtension.lowercased() {
        case "wav", "wave":
            return "audio/wav"
        case "mp3":
            return "audio/mpeg"
        case "m4a":
            return "audio/mp4"
        case "aac":
            return "audio/aac"
        case "flac":
            return "audio/flac"
        case "ogg", "oga", "opus":
            return "audio/ogg"
        case "webm":
            return "audio/webm"
        default:
            return "application/octet-stream"
        }
    }

    private let http: any GrokSTTHTTPPerforming
    private let resolver: any GrokSTTCredentialResolving

    init(
        resolver: any GrokSTTCredentialResolving,
        http: any GrokSTTHTTPPerforming = GrokSTTURLSessionHTTPClient()
    ) {
        self.resolver = resolver
        self.http = http
    }

    func transcribePCM(
        _ samples: [Float],
        languageCode: String?,
        keyterms: [String] = [],
        credential: GrokSTTCredential? = nil,
        timeout: TimeInterval = GrokSTTRESTClient.dictationTimeout
    ) async throws -> ASRTranscriptionResult {
        if samples.isEmpty {
            throw GrokSTTError.invalidAudio
        }
        let wav = GrokSTTAudioConverter.wav(fromFloat32: samples)
        return try await self.transcribeWAV(
            wav,
            filename: "dictation.wav",
            languageCode: languageCode,
            keyterms: keyterms,
            credential: credential,
            timeout: timeout
        )
    }

    func transcribeWAV(
        _ wav: Data,
        filename: String,
        languageCode: String?,
        keyterms: [String],
        credential: GrokSTTCredential?,
        timeout: TimeInterval
    ) async throws -> ASRTranscriptionResult {
        if wav.count > Self.maxFileBytes {
            throw GrokSTTError.fileTooLarge
        }
        return try await self.sendFileWithUnauthorizedRetry(
            file: wav,
            filename: Self.sanitizedFilename(filename),
            mimeType: "audio/wav",
            languageCode: languageCode,
            keyterms: keyterms,
            credential: credential,
            timeout: timeout
        )
    }

    /// Native meeting/file REST. Sends the user file as-is (no `audio_format`). Never POSTs a video container.
    func transcribeFile(
        at fileURL: URL,
        languageCode: String?,
        keyterms: [String] = [],
        credential: GrokSTTCredential? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> ASRTranscriptionResult {
        if Self.isVideoContainer(fileURL) {
            throw GrokSTTError.videoUploadForbidden
        }
        let size = Self.fileSizeBytes(at: fileURL)
        if size > Self.maxFileBytes {
            throw GrokSTTError.fileTooLarge
        }
        if size <= 0 {
            throw GrokSTTError.invalidAudio
        }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        } catch {
            throw GrokSTTError.invalidAudio
        }
        let filename = Self.sanitizedFilename(fileURL.lastPathComponent)
        let mimeType = Self.mimeType(forFilename: filename)
        let resolvedTimeout = timeout ?? Self.meetingTimeout(durationSeconds: Self.durationSeconds(of: fileURL))
        return try await self.sendFileWithUnauthorizedRetry(
            file: data,
            filename: filename,
            mimeType: mimeType,
            languageCode: languageCode,
            keyterms: keyterms,
            credential: credential,
            timeout: resolvedTimeout
        )
    }

    private func initialCredential(_ supplied: GrokSTTCredential?) async throws -> GrokSTTCredential {
        if let supplied {
            return supplied
        }
        return try await self.resolver.resolveCredential()
    }

    private func sendFileWithUnauthorizedRetry(
        file: Data,
        filename: String,
        mimeType: String,
        languageCode: String?,
        keyterms: [String],
        credential: GrokSTTCredential?,
        timeout: TimeInterval
    ) async throws -> ASRTranscriptionResult {
        var current = try await self.initialCredential(credential)
        var didRetryUnauthorized = false
        while true {
            do {
                return try await self.sendMultipart(
                    file: file,
                    filename: filename,
                    mimeType: mimeType,
                    languageCode: languageCode,
                    keyterms: keyterms,
                    credential: current,
                    timeout: timeout
                )
            } catch let error as GrokSTTError where error == .unauthorized {
                guard current.source == .grokCLISession, !didRetryUnauthorized else {
                    throw error
                }
                didRetryUnauthorized = true
                current = try await self.resolver.resolveCredentialAfterUnauthorized(
                    rejectedBearerFingerprint: current.bearerFingerprint
                )
            }
        }
    }

    static func fileSizeBytes(at fileURL: URL) -> Int64 {
        let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey])
        if let size = values?.fileSize {
            return Int64(size)
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
        return attributes?[.size] as? Int64 ?? -1
    }

    static func durationSeconds(of fileURL: URL) -> TimeInterval {
        guard let file = try? AVAudioFile(forReading: fileURL) else { return 0 }
        let rate = file.processingFormat.sampleRate
        guard rate > 0 else { return 0 }
        return Double(file.length) / rate
    }

    private func sendMultipart(
        file: Data,
        filename: String,
        mimeType: String,
        languageCode: String?,
        keyterms: [String],
        credential: GrokSTTCredential,
        timeout: TimeInterval
    ) async throws -> ASRTranscriptionResult {
        let boundary = "FluidGrokSTT\(UUID().uuidString.replacingOccurrences(of: "-", with: ""))"
        var body = Data()

        func appendField(name: String, value: String) {
            body.append(Data("--\(boundary)\r\n".utf8))
            body.append(Data("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
            body.append(Data("\(value)\r\n".utf8))
        }

        if let languageCode, !languageCode.isEmpty {
            appendField(name: "language", value: languageCode)
            appendField(name: "format", value: "true")
        }
        for term in keyterms {
            appendField(name: "keyterm", value: term)
        }

        body.append(Data("--\(boundary)\r\n".utf8))
        body.append(
            Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".utf8)
        )
        body.append(Data("Content-Type: \(mimeType)\r\n\r\n".utf8))
        body.append(file)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(credential.bearer)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("\(body.count)", forHTTPHeaderField: "Content-Length")
        request.httpBody = body
        request.timeoutInterval = timeout

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await self.http.data(for: request)
        } catch {
            throw GrokSTTTransportErrorMapper.map(error)
        }

        guard let http = response as? HTTPURLResponse else {
            throw GrokSTTError.offline
        }
        if http.statusCode != 200 {
            throw GrokSTTError.fromHTTPStatus(http.statusCode)
        }

        let decoded: GrokSTTRESTTranscriptResponse
        do {
            decoded = try JSONDecoder().decode(GrokSTTRESTTranscriptResponse.self, from: data)
        } catch {
            throw GrokSTTError.server(status: http.statusCode, message: "unexpected response")
        }
        let text = decoded.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if text.isEmpty {
            throw GrokSTTError.emptyTranscript
        }
        return ASRTranscriptionResult(text: text, confidence: 1)
    }
}

private nonisolated struct GrokSTTRESTTranscriptResponse: Decodable, Sendable {
    let text: String?
}
