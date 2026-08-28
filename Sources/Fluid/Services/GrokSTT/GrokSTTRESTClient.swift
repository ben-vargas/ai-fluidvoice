import Foundation

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

/// REST `POST https://api.x.ai/v1/stt` for empty-socket retry (and later meetings).
final nonisolated class GrokSTTRESTClient: @unchecked Sendable {
    static let endpoint = URL(string: "https://api.x.ai/v1/stt")!
    static let dictationTimeout: TimeInterval = 60
    static let maxFileBytes = 500 * 1024 * 1024

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
        var current = try await self.initialCredential(credential)
        var didRetryUnauthorized = false
        while true {
            do {
                return try await self.sendMultipart(
                    file: wav,
                    filename: filename,
                    mimeType: "audio/wav",
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

    private func initialCredential(_ supplied: GrokSTTCredential?) async throws -> GrokSTTCredential {
        if let supplied {
            return supplied
        }
        return try await self.resolver.resolveCredential()
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
