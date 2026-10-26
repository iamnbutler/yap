import Foundation

/// Cleans up a chunk of dictation with an OpenAI model, for `Refiner`.
///
/// The Responses API with a JSON schema, like the on-device model's
/// `@Generable` output: a reply that is only the text leaves the model less
/// room to answer it. Measured on dictated questions and requests, neither
/// model answered or carried one out, and `Refiner.accepts` checks anyway.
struct OpenAICleanup: Sendable {
    let model: String
    /// The lowest each model takes: cleaning up needs no thinking, and every
    /// step of it is latency before the text is typed.
    let effort: String
    private let apiKey: String
    private let endpoint: URL

    /// Luna is the fastest GPT-6 model, about 1.7 s for a sentence. Sol is
    /// smarter and slower, 2.5 to 5 s, and doesn't take `none`.
    init?(
        _ cleanup: Config.Cleanup, apiKey: String,
        endpoint: URL = URL(string: "https://api.openai.com/v1/responses")!
    ) {
        switch cleanup {
        case .openAIFast: (model, effort) = ("gpt-6-luna", "none")
        case .openAISmart: (model, effort) = ("gpt-6.1-sol", "low")
        case .appleIntelligence, .off: return nil
        }
        self.apiKey = apiKey
        self.endpoint = endpoint
    }

    func clean(_ chunk: String, instructions: String) async throws -> String {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        // Past this the text is typed as heard: a slow clean-up is worse
        // than none.
        request.timeoutInterval = 10
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try body(chunk: chunk, instructions: instructions)

        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return try Self.decode(data, status: status)
    }

    func body(chunk: String, instructions: String) throws -> Data {
        let schema: [String: Any] = [
            "type": "object",
            "properties": ["text": ["type": "string"]],
            "required": ["text"],
            "additionalProperties": false,
        ]
        let body: [String: Any] = [
            "model": model,
            "reasoning": ["effort": effort],
            "instructions": instructions,
            "input": "<dictation>\n\(chunk)\n</dictation>",
            "text": ["format": ["type": "json_schema", "name": "cleaned", "strict": true, "schema": schema]],
            "store": false,
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    static func decode(_ data: Data, status: Int) throws -> String {
        struct Response: Decodable {
            struct Item: Decodable {
                struct Content: Decodable {
                    let type: String
                    let text: String?
                }
                let type: String
                let content: [Content]?
            }
            let output: [Item]
        }
        struct Cleaned: Decodable { let text: String }
        struct Failure: Decodable {
            struct Detail: Decodable { let message: String }
            let error: Detail
        }

        guard (200..<300).contains(status) else {
            let message =
                (try? JSONDecoder().decode(Failure.self, from: data))?.error.message
                ?? String(decoding: data.prefix(500), as: UTF8.self)
            throw TranscriptionError.api(status: status, message: message)
        }
        let output = try JSONDecoder().decode(Response.self, from: data).output
            .filter { $0.type == "message" }
            .flatMap { $0.content ?? [] }
            .first { $0.type == "output_text" }?.text
        guard let output else {
            throw TranscriptionError.api(status: status, message: "No text in the response.")
        }
        return try JSONDecoder().decode(Cleaned.self, from: Data(output.utf8)).text
    }
}
