import Foundation

/// One-shot speech-to-text through OpenAI's transcription endpoint.
///
/// Not the Realtime API. Dictation needs one transcript per key hold, and the
/// plain endpoint takes a finished clip and returns text: no socket to keep
/// warm, no per-minute session billing, and no protocol drift to track.
public struct OpenAITranscription: Sendable {
    public static let defaultModel = "gpt-transcribe"

    public let model: String
    /// Biases spelling toward words the model would otherwise guess at.
    public let prompt: String?
    private let apiKey: String
    private let endpoint: URL

    public init(
        apiKey: String,
        model: String = Self.defaultModel,
        prompt: String? = nil,
        endpoint: URL = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
    ) {
        self.apiKey = apiKey
        self.model = model
        self.prompt = prompt
        self.endpoint = endpoint
    }

    public func transcribe(wav: Data) async throws -> String {
        let boundary = "yap-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(
            "multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body(wav: wav, boundary: boundary)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return try Self.decode(data, status: status)
    }

    func body(wav: Data, boundary: String) -> Data {
        var fields = [("model", model), ("response_format", "json")]
        if let prompt, !prompt.isEmpty { fields.append(("prompt", prompt)) }

        var body = Data()
        for (name, value) in fields {
            body.append("--\(boundary)\r\n")
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.append("\(value)\r\n")
        }
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"speech.wav\"\r\n")
        body.append("Content-Type: audio/wav\r\n\r\n")
        body.append(wav)
        body.append("\r\n--\(boundary)--\r\n")
        return body
    }

    static func decode(_ data: Data, status: Int) throws -> String {
        struct Success: Decodable { let text: String }
        struct Failure: Decodable {
            struct Detail: Decodable { let message: String }
            let error: Detail
        }

        guard (200..<300).contains(status) else {
            if let failure = try? JSONDecoder().decode(Failure.self, from: data) {
                throw TranscriptionError.api(status: status, message: failure.error.message)
            }
            throw TranscriptionError.api(
                status: status, message: String(decoding: data.prefix(500), as: UTF8.self))
        }
        return try JSONDecoder().decode(Success.self, from: data).text
    }
}

public enum TranscriptionError: Error, LocalizedError {
    case api(status: Int, message: String)

    public var errorDescription: String? {
        switch self {
        case .api(let status, let message): return "OpenAI \(status): \(message)"
        }
    }
}

/// A RIFF/WAVE container around raw PCM.
public enum WAV {
    /// Wraps interleaved little-endian 16-bit samples.
    public static func pcm16(_ samples: Data, sampleRate: Int, channels: Int = 1) -> Data {
        let blockAlign = channels * 2
        var data = Data()
        data.append("RIFF")
        data.append(le: UInt32(36 + samples.count))
        data.append("WAVE")
        data.append("fmt ")
        data.append(le: UInt32(16))
        data.append(le: UInt16(1))  // PCM
        data.append(le: UInt16(channels))
        data.append(le: UInt32(sampleRate))
        data.append(le: UInt32(sampleRate * blockAlign))
        data.append(le: UInt16(blockAlign))
        data.append(le: UInt16(16))
        data.append("data")
        data.append(le: UInt32(samples.count))
        data.append(samples)
        return data
    }
}

extension Data {
    fileprivate mutating func append(_ string: String) {
        append(contentsOf: Array(string.utf8))
    }

    fileprivate mutating func append<T: FixedWidthInteger>(le value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }
}
