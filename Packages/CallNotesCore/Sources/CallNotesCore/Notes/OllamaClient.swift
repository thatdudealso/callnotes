import Foundation

/// One chat message sent to Ollama.
public struct OllamaChatMessage: Codable, Sendable, Equatable {
    public var role: String
    public var content: String

    public init(role: String, content: String) {
        self.role = role
        self.content = content
    }
}

/// A locally installed Ollama model as reported by `/api/tags`.
public struct OllamaModelTag: Sendable, Equatable {
    public var name: String
    public var digest: String

    public init(name: String, digest: String) {
        self.name = name
        self.digest = digest
    }
}

/// HTTP surface used by the Ollama notes providers.
public protocol OllamaServing: Sendable {
    func chat(model: String, messages: [OllamaChatMessage], numCtx: Int) async throws -> String
    func listModels() async throws -> [OllamaModelTag]
}

/// Localhost Ollama client. Chat uses the OpenAI-compatible completions path
/// from plan section 7.1; health uses `/api/tags` so digests can be checked.
public struct OllamaClient: OllamaServing {
    public var baseURL: URL
    public var session: URLSession
    public var keepAlive: String

    public init(
        baseURL: URL = URL(string: "http://127.0.0.1:11434")!,
        session: URLSession = .shared,
        keepAlive: String = "30m"
    ) {
        self.baseURL = baseURL
        self.session = session
        self.keepAlive = keepAlive
    }

    public func chat(model: String, messages: [OllamaChatMessage], numCtx: Int) async throws -> String {
        let url = baseURL.appending(path: "/v1/chat/completions")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 180
        let body = ChatRequest(
            model: model,
            messages: messages,
            temperature: 0,
            responseFormat: .init(type: "json_object"),
            options: .init(numCtx: numCtx),
            keepAlive: keepAlive
        )
        request.httpBody = try JSONEncoder().encode(body)
        let (data, response) = try await session.data(for: request)
        try Self.throwIfHTTPError(response, data: data)
        return try Self.decodeChatContent(data)
    }

    public func listModels() async throws -> [OllamaModelTag] {
        let url = baseURL.appending(path: "/api/tags")
        var request = URLRequest(url: url)
        request.timeoutInterval = 2
        let (data, response) = try await session.data(for: request)
        try Self.throwIfHTTPError(response, data: data)
        let decoded = try JSONDecoder().decode(TagsResponse.self, from: data)
        return decoded.models.map { OllamaModelTag(name: $0.name, digest: $0.digest) }
    }

    public func health(of model: PinnedNotesModel) async -> ProviderHealth {
        do {
            let tags = try await listModels()
            guard let tag = tags.first(where: { Self.namesMatch($0.name, model.name) }) else {
                return .unavailable(reason: "Ollama does not have \(model.name)")
            }
            if model.matches(digest: tag.digest) {
                return .healthy
            }
            return .degraded(reason: "\(model.name) digest is \(tag.digest), expected \(model.digest)")
        } catch {
            return .unavailable(reason: error.localizedDescription)
        }
    }

    public static func makeIfReady() async -> OllamaClient? {
        let client = OllamaClient()
        do {
            _ = try await client.listModels()
            return client
        } catch {
            return nil
        }
    }

    static func namesMatch(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs { return true }
        let left = lhs.hasSuffix(":latest") ? String(lhs.dropLast(":latest".count)) : lhs
        let right = rhs.hasSuffix(":latest") ? String(rhs.dropLast(":latest".count)) : rhs
        return left == right || lhs == rhs + ":latest" || rhs == lhs + ":latest"
    }

    static func decodeChatContent(_ data: Data) throws -> String {
        if let openai = try? JSONDecoder().decode(OpenAIChatResponse.self, from: data),
            let content = openai.choices.first?.message.content,
            !content.isEmpty
        {
            return content
        }
        if let native = try? JSONDecoder().decode(NativeChatResponse.self, from: data),
            let content = native.message?.content,
            !content.isEmpty
        {
            return content
        }
        throw NotesGenerationError.schemaInvalid("Ollama chat response had no content")
    }

    private static func throwIfHTTPError(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw NotesGenerationError.ollamaUnavailable(body)
        }
    }

    private struct ChatRequest: Encodable {
        var model: String
        var messages: [OllamaChatMessage]
        var temperature: Double
        var responseFormat: ResponseFormat
        var options: Options
        var keepAlive: String

        enum CodingKeys: String, CodingKey {
            case model, messages, temperature, options
            case responseFormat = "response_format"
            case keepAlive = "keep_alive"
        }
    }

    private struct ResponseFormat: Encodable {
        var type: String
    }

    private struct Options: Encodable {
        var numCtx: Int

        enum CodingKeys: String, CodingKey {
            case numCtx = "num_ctx"
        }
    }

    private struct TagsResponse: Decodable {
        var models: [Tag]
        struct Tag: Decodable {
            var name: String
            var digest: String
        }
    }

    private struct OpenAIChatResponse: Decodable {
        var choices: [Choice]
        struct Choice: Decodable {
            var message: Message
        }
        struct Message: Decodable {
            var content: String
        }
    }

    private struct NativeChatResponse: Decodable {
        var message: Message?
        struct Message: Decodable {
            var content: String
        }
    }
}
