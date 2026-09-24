import Foundation

// A small provider layer. The rest of Obby talks to `AIProvider`; each provider only
// translates Obby's neutral chat messages to and from its own HTTP API. Tools are always
// executed by Obby's own Swift code (`executeTool`), never by a provider.
//
// Neutral message format (what `send` keeps in `messages` and `history`):
//   ["role": "user" | "assistant" | "tool", "content": String]
//   assistant may add "tool_calls": [["id", "function": ["name", "arguments": [String: Any]]]]
//             and "_native": the provider's own reply payload (kept only for the current request)
//   tool adds "tool_name" and "tool_call_id"

enum ProviderKind: String, CaseIterable, Identifiable {
    case ollama, openAI = "openai", anthropic, gemini
    var id: String { rawValue }
    static var stored: ProviderKind { ProviderKind(rawValue: UserDefaults.standard.string(forKey: "aiProvider") ?? "") ?? .ollama }
    var label: String {
        switch self {
        case .ollama: return "Ollama"
        case .openAI: return "OpenAI-compatible"
        case .anthropic: return "Anthropic"
        case .gemini: return "Gemini"
        }
    }
    /// Ollama keeps the original "model" key so existing settings carry over.
    var modelKey: String { self == .ollama ? "model" : "model." + rawValue }
}

struct ToolCall {
    var id: String
    var name: String
    var arguments: [String: Any]
    var raw: [String: Any] // Exactly what the provider returned, for the raw-action display.
    var neutral: [String: Any] { ["id": id, "function": ["name": name, "arguments": arguments]] }
    static func arguments(_ value: Any?) -> [String: Any] {
        if let dictionary = value as? [String: Any] { return dictionary }
        if let raw = value as? String, let data = raw.data(using: .utf8), let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return decoded }
        return [:]
    }
}

struct ChatRequest {
    var model: String
    var system: String
    var messages: [[String: Any]]
    var tools: [[String: Any]]? // nil means chat only: no tools are offered to the model.
    var temperature: Double
    var contextWindow: Int // Effective window for this request (setting capped at the model limit).
    var keepAlive: Any
}

struct ChatReply {
    var text: String
    var toolCalls: [ToolCall]
    var message: [String: Any] // Neutral assistant message to append to the running context.
}

@MainActor protocol AIProvider {
    var kind: ProviderKind { get }
    var isLocal: Bool { get }
    func listModels() async throws -> [String]
    /// Whether this model can use native tool/function calling. Obby never fakes tool use.
    func supportsTools(_ model: String) async -> Bool
    /// Maximum context the provider reports for this model, if it can be discovered. nil = unknown.
    func contextLimit(_ model: String) async -> Int?
    func chat(_ request: ChatRequest) async throws -> ChatReply
}

func neutralAssistant(_ text: String, _ calls: [ToolCall], native: Any? = nil) -> [String: Any] {
    var message: [String: Any] = ["role": "assistant", "content": text]
    if !calls.isEmpty { message["tool_calls"] = calls.map(\.neutral) }
    if let native { message["_native"] = native }
    return message
}

private func functionParts(_ tool: [String: Any]) -> (String, String, Any) {
    let function = tool["function"] as? [String: Any] ?? [:]
    return (function["name"] as? String ?? "", function["description"] as? String ?? "", function["parameters"] ?? ["type": "object", "properties": [:]])
}

// MARK: Ollama (local). Uses AppModel.request, which only allows loopback addresses.

struct OllamaProvider: AIProvider {
    let send: (String, [String: Any]?) async throws -> [String: Any]
    var kind: ProviderKind { .ollama }
    var isLocal: Bool { true }
    func listModels() async throws -> [String] {
        let json = try await send("/api/tags", nil)
        return (json["models"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }.sorted()
    }
    func contextLimit(_ model: String) async -> Int? {
        guard let json = try? await send("/api/show", ["model": model]), let info = json["model_info"] as? [String: Any] else { return nil }
        return info.first { $0.key.hasSuffix(".context_length") }.flatMap { ($0.value as? NSNumber)?.intValue }
    }
    func supportsTools(_ model: String) async -> Bool {
        // Recent Ollama versions report capabilities; older ones don't, so keep the previous behaviour.
        guard let json = try? await send("/api/show", ["model": model]), let capabilities = json["capabilities"] as? [String] else { return true }
        return capabilities.contains("tools")
    }
    static func native(_ message: [String: Any]) -> [String: Any] {
        var message = message
        message.removeValue(forKey: "tool_call_id"); message.removeValue(forKey: "_native")
        return message
    }
    func body(_ request: ChatRequest) -> [String: Any] {
        var options: [String: Any] = ["temperature": request.temperature]
        options["num_ctx"] = request.contextWindow // Otherwise Ollama silently uses its server default (often 4K).
        var body: [String: Any] = ["keep_alive": request.keepAlive, "model": request.model, "stream": false, "messages": [["role": "system", "content": request.system]] + request.messages.map(Self.native), "options": options]
        if let tools = request.tools { body["tools"] = tools }
        return body
    }
    func chat(_ request: ChatRequest) async throws -> ChatReply {
        let body = body(request)
        try ChatMemory.checkSize(body, window: request.contextWindow)
        let response = try await send("/api/chat", body)
        guard let message = response["message"] as? [String: Any] else { throw ObbyError("Ollama returned no message.") }
        var context = message
        context.removeValue(forKey: "thinking")
        let calls = try (message["tool_calls"] as? [[String: Any]] ?? []).enumerated().map { index, call -> ToolCall in
            guard let function = call["function"] as? [String: Any], let name = function["name"] as? String else { throw ObbyError("Invalid tool call") }
            return ToolCall(id: call["id"] as? String ?? "obby_call_\(index)", name: name, arguments: ToolCall.arguments(function["arguments"]), raw: call)
        }
        return ChatReply(text: message["content"] as? String ?? "", toolCalls: calls, message: context)
    }
}

// MARK: Shared HTTPS transport for the other providers.

@MainActor enum RemoteHTTP {
    /// Test hook, mirroring AppModel.requestOverride.
    static var override: ((URL, [String: String], [String: Any]?) async throws -> [String: Any])?
    static func isLoopback(_ string: String) -> Bool {
        guard let host = URLComponents(string: string.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased() else { return false }
        return ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)
    }
    static func validatedBase(_ string: String) throws -> URL {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLComponents(string: trimmed), let scheme = parts.scheme?.lowercased(), let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil else {
            throw ObbyError("Enter a valid base URL, such as https://api.openai.com/v1.")
        }
        guard scheme == "https" || (scheme == "http" && isLoopback(trimmed)) else {
            throw ObbyError("Use an https:// address. Plain http:// is only allowed for a server on this Mac (localhost).")
        }
        parts.query = nil; parts.fragment = nil
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        guard let url = parts.url else { throw ObbyError("Enter a valid base URL.") }
        return url
    }
    static func json(_ url: URL, headers: [String: String], body: [String: Any]? = nil) async throws -> [String: Any] {
        if let override { return try await override(url, headers, body) }
        var request = URLRequest(url: url)
        request.timeoutInterval = body == nil ? 20 : 300
        for (field, value) in headers { request.setValue(value, forHTTPHeaderField: field) }
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        let session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let detail = ((json?["error"] as? [String: Any])?["message"] as? String) ?? (json?["error"] as? String) ?? String(decoding: data.prefix(300), as: UTF8.self)
            throw ObbyError("Request failed (\(code)): \(detail)")
        }
        guard let json else { throw ObbyError("Unexpected response from the AI provider.") }
        return json
    }
}

// MARK: OpenAI-compatible (/v1/models, /v1/chat/completions). Works with many hosted and local servers.

struct OpenAICompatibleProvider: AIProvider {
    let base: URL
    let apiKey: String?
    let toolsEnabled: Bool
    var kind: ProviderKind { .openAI }
    var isLocal: Bool { RemoteHTTP.isLoopback(base.absoluteString) }
    var headers: [String: String] { apiKey.map { ["Authorization": "Bearer \($0)"] } ?? [:] }
    func listModels() async throws -> [String] {
        let json = try await RemoteHTTP.json(base.appendingPathComponent("models"), headers: headers)
        return (json["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }.sorted()
    }
    func supportsTools(_ model: String) async -> Bool { toolsEnabled } // Not discoverable through this API; the user declares it.
    func contextLimit(_ model: String) async -> Int? { nil } // Not exposed by the OpenAI-compatible API; the setting is used as-is.
    static func native(_ message: [String: Any]) -> [String: Any] {
        let content = message["content"] as? String ?? ""
        switch message["role"] as? String {
        case "tool": return ["role": "tool", "tool_call_id": message["tool_call_id"] as? String ?? "", "content": content]
        case "assistant":
            let calls = message["tool_calls"] as? [[String: Any]] ?? []
            var out: [String: Any] = ["role": "assistant", "content": content.isEmpty && !calls.isEmpty ? NSNull() as Any : content as Any]
            if !calls.isEmpty {
                out["tool_calls"] = calls.map { call -> [String: Any] in
                    let function = call["function"] as? [String: Any] ?? [:]
                    let data = try? JSONSerialization.data(withJSONObject: ToolCall.arguments(function["arguments"]))
                    return ["id": call["id"] as? String ?? "", "type": "function", "function": ["name": function["name"] as? String ?? "", "arguments": data.map { String(decoding: $0, as: UTF8.self) } ?? "{}"]]
                }
            }
            return out
        default: return ["role": "user", "content": content]
        }
    }
    func body(_ request: ChatRequest) -> [String: Any] {
        var body: [String: Any] = ["model": request.model, "messages": [["role": "system", "content": request.system]] + request.messages.map(Self.native)]
        if let tools = request.tools { body["tools"] = tools }
        return body
    }
    func chat(_ request: ChatRequest) async throws -> ChatReply {
        let body = body(request)
        try ChatMemory.checkSize(body, window: request.contextWindow)
        let json = try await RemoteHTTP.json(base.appendingPathComponent("chat/completions"), headers: headers, body: body)
        guard let message = (json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any] else { throw ObbyError("The provider returned no message.") }
        let text = message["content"] as? String ?? ""
        let calls = (message["tool_calls"] as? [[String: Any]] ?? []).enumerated().compactMap { index, call -> ToolCall? in
            guard let function = call["function"] as? [String: Any], let name = function["name"] as? String else { return nil }
            return ToolCall(id: call["id"] as? String ?? "obby_call_\(index)", name: name, arguments: ToolCall.arguments(function["arguments"]), raw: call)
        }
        return ChatReply(text: text, toolCalls: calls, message: neutralAssistant(text, calls))
    }
}

// MARK: Anthropic Messages API.

struct AnthropicProvider: AIProvider {
    let apiKey: String
    static let base = "https://api.anthropic.com/v1"
    var kind: ProviderKind { .anthropic }
    var isLocal: Bool { false }
    var headers: [String: String] { ["x-api-key": apiKey, "anthropic-version": "2023-06-01"] }
    func listModels() async throws -> [String] {
        let json = try await RemoteHTTP.json(URL(string: Self.base + "/models?limit=1000")!, headers: headers)
        return (json["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
    }
    func supportsTools(_ model: String) async -> Bool { true }
    func contextLimit(_ model: String) async -> Int? { 200_000 } // Current Claude models; always above Obby's largest setting.
    static func native(_ messages: [[String: Any]]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        var results: [[String: Any]] = []
        func flush() { if !results.isEmpty { out.append(["role": "user", "content": results]); results = [] } }
        for message in messages {
            let content = message["content"] as? String ?? ""
            switch message["role"] as? String {
            case "tool":
                results.append(["type": "tool_result", "tool_use_id": message["tool_call_id"] as? String ?? "", "content": content.isEmpty ? "(empty)" : content])
            case "assistant":
                flush()
                if let native = message["_native"] as? [[String: Any]] { out.append(["role": "assistant", "content": native]); continue }
                var blocks: [[String: Any]] = content.isEmpty ? [] : [["type": "text", "text": content]]
                for call in message["tool_calls"] as? [[String: Any]] ?? [] {
                    let function = call["function"] as? [String: Any] ?? [:]
                    blocks.append(["type": "tool_use", "id": call["id"] as? String ?? "", "name": function["name"] as? String ?? "", "input": ToolCall.arguments(function["arguments"])])
                }
                if blocks.isEmpty { blocks = [["type": "text", "text": "(no reply)"]] }
                out.append(["role": "assistant", "content": blocks])
            default:
                flush()
                out.append(["role": "user", "content": content.isEmpty ? "(empty)" : content])
            }
        }
        flush()
        return out
    }
    func body(_ request: ChatRequest) -> [String: Any] {
        var body: [String: Any] = ["model": request.model, "max_tokens": 4096, "system": request.system, "messages": Self.native(request.messages)]
        if let tools = request.tools {
            body["tools"] = tools.map { tool -> [String: Any] in let (name, description, parameters) = functionParts(tool); return ["name": name, "description": description, "input_schema": parameters] }
        }
        return body
    }
    func chat(_ request: ChatRequest) async throws -> ChatReply {
        let body = body(request)
        try ChatMemory.checkSize(body, window: request.contextWindow)
        let json = try await RemoteHTTP.json(URL(string: Self.base + "/messages")!, headers: headers, body: body)
        guard let blocks = json["content"] as? [[String: Any]] else { throw ObbyError("Anthropic returned no message.") }
        let text = blocks.filter { $0["type"] as? String == "text" }.compactMap { $0["text"] as? String }.joined(separator: "\n")
        let calls = blocks.filter { $0["type"] as? String == "tool_use" }.enumerated().compactMap { index, block -> ToolCall? in
            guard let name = block["name"] as? String else { return nil }
            return ToolCall(id: block["id"] as? String ?? "obby_call_\(index)", name: name, arguments: ToolCall.arguments(block["input"]), raw: block)
        }
        return ChatReply(text: text, toolCalls: calls, message: neutralAssistant(text, calls, native: blocks))
    }
}

// MARK: Google Gemini API (generateContent).

struct GeminiProvider: AIProvider {
    let apiKey: String
    static let base = "https://generativelanguage.googleapis.com/v1beta"
    var kind: ProviderKind { .gemini }
    var isLocal: Bool { false }
    var headers: [String: String] { ["x-goog-api-key": apiKey] } // Header, never a URL query parameter.
    func listModels() async throws -> [String] {
        let json = try await RemoteHTTP.json(URL(string: Self.base + "/models?pageSize=1000")!, headers: headers)
        return (json["models"] as? [[String: Any]] ?? [])
            .filter { ($0["supportedGenerationMethods"] as? [String] ?? []).contains("generateContent") }
            .compactMap { ($0["name"] as? String).map { $0.hasPrefix("models/") ? String($0.dropFirst(7)) : $0 } }
    }
    func supportsTools(_ model: String) async -> Bool { !model.lowercased().contains("gemma") } // Gemma models on this API lack function calling.
    func contextLimit(_ model: String) async -> Int? {
        guard let path = try? Self.modelPath(model), let url = URL(string: Self.base + "/models/" + path),
              let json = try? await RemoteHTTP.json(url, headers: headers) else { return nil }
        return (json["inputTokenLimit"] as? NSNumber)?.intValue
    }
    static func modelPath(_ model: String) throws -> String {
        let name = model.hasPrefix("models/") ? String(model.dropFirst(7)) : model
        guard name.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil else { throw ObbyError("Enter a Gemini model name, for example one from the list in Settings.") }
        return name
    }
    static func native(_ messages: [[String: Any]]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        var responses: [[String: Any]] = []
        func flush() { if !responses.isEmpty { out.append(["role": "user", "parts": responses]); responses = [] } }
        for message in messages {
            let content = message["content"] as? String ?? ""
            switch message["role"] as? String {
            case "tool":
                var response: [String: Any] = ["name": message["tool_name"] as? String ?? "", "response": ["result": content]]
                if let id = message["tool_call_id"] as? String, !id.hasPrefix("obby_") { response["id"] = id }
                responses.append(["functionResponse": response])
            case "assistant":
                flush()
                // The native reply keeps Gemini's thought signatures, which it requires back during tool use.
                if let native = message["_native"] as? [String: Any] { out.append(native); continue }
                var parts: [[String: Any]] = content.isEmpty ? [] : [["text": content]]
                for call in message["tool_calls"] as? [[String: Any]] ?? [] {
                    let function = call["function"] as? [String: Any] ?? [:]
                    parts.append(["functionCall": ["name": function["name"] as? String ?? "", "args": ToolCall.arguments(function["arguments"])]])
                }
                if parts.isEmpty { parts = [["text": "(no reply)"]] }
                out.append(["role": "model", "parts": parts])
            default:
                flush()
                out.append(["role": "user", "parts": [["text": content.isEmpty ? "(empty)" : content]]])
            }
        }
        flush()
        return out
    }
    func body(_ request: ChatRequest) -> [String: Any] {
        var body: [String: Any] = ["systemInstruction": ["parts": [["text": request.system]]], "contents": Self.native(request.messages)]
        if let tools = request.tools {
            body["tools"] = [["functionDeclarations": tools.map { tool -> [String: Any] in let (name, description, parameters) = functionParts(tool); return ["name": name, "description": description, "parameters": parameters] }]]
        }
        return body
    }
    func chat(_ request: ChatRequest) async throws -> ChatReply {
        let body = body(request)
        try ChatMemory.checkSize(body, window: request.contextWindow)
        let path = try Self.modelPath(request.model)
        guard let url = URL(string: Self.base + "/models/" + path + ":generateContent") else { throw ObbyError("Invalid Gemini model name.") }
        let json = try await RemoteHTTP.json(url, headers: headers, body: body)
        guard var content = (json["candidates"] as? [[String: Any]])?.first?["content"] as? [String: Any] else {
            let reason = (json["promptFeedback"] as? [String: Any])?["blockReason"] as? String
            throw ObbyError(reason.map { "Gemini declined this request (\($0))." } ?? "Gemini returned no message.")
        }
        content["role"] = "model"
        let parts = content["parts"] as? [[String: Any]] ?? []
        let text = parts.filter { $0["thought"] as? Bool != true }.compactMap { $0["text"] as? String }.joined()
        let calls = parts.compactMap { $0["functionCall"] as? [String: Any] }.enumerated().compactMap { index, call -> ToolCall? in
            guard let name = call["name"] as? String else { return nil }
            return ToolCall(id: call["id"] as? String ?? "obby_call_\(index)", name: name, arguments: ToolCall.arguments(call["args"]), raw: call)
        }
        return ChatReply(text: text, toolCalls: calls, message: neutralAssistant(text, calls, native: content))
    }
}
