import Foundation

// Deterministic context management shared by every provider. Obby, not the model, decides what fits:
//   window (setting, capped at the model's limit) − reserved output = input budget
//   input budget ≥ system/tools + current request (+ current note) + recent chat + current tool results
// Older chat is condensed into a short summary, older tool results are dropped, long notes are processed in sections.

enum ContextWindow: Int, CaseIterable, Identifiable {
    case k4 = 4096, k8 = 8192, k16 = 16384, k32 = 32768
    var id: Int { rawValue }
    var label: String { "\(rawValue / 1024)K" }
    static var stored: ContextWindow { ContextWindow(rawValue: UserDefaults.standard.integer(forKey: "contextWindow")) ?? .k16 }
}

enum ContextBudget {
    /// Rough, stable estimate (~4 UTF-8 bytes per token). Deliberately conservative for Latin text.
    static func tokens(_ text: String) -> Int { (text.utf8.count + 3) / 4 }
    static func tokens(_ value: Any) -> Int {
        guard JSONSerialization.isValidJSONObject(value), let data = try? JSONSerialization.data(withJSONObject: value) else {
            return tokens(String(describing: value))
        }
        return (data.count + 3) / 4
    }
    /// Output room kept free in every request, separate from the input.
    static func reserve(for window: Int) -> Int { min(max(window / 4, 1_024), 4_096) }
    static func inputBudget(for window: Int) -> Int { window - reserve(for: window) }
    static func windowLabel(_ window: Int) -> String { window % 1_024 == 0 ? "\(window / 1_024)K" : label(window) }
    static func label(_ tokens: Int) -> String { tokens >= 1_000 ? String(format: "%.1fK", Double(tokens) / 1_000) : "\(tokens)" }

    /// Fits `messages` (history, then the current user message at `current`, then this turn's tool exchange) into `budget`.
    /// Returns summary lines for any history that had to be condensed, and the estimated tokens used.
    static func fit(_ messages: inout [[String: Any]], current: Int, fixed: Int, budget: Int) -> (summary: [String], used: Int) {
        var history = Array(messages[..<current])
        var turn = Array(messages[current...])
        var summary: [String] = []
        func total() -> Int { fixed + tokens(summary.joined(separator: "\n")) + (history + turn).reduce(0) { $0 + tokens($1) } }
        // 1. Condense the oldest chat first (pairs of user question + answer), keeping recent messages verbatim.
        while total() > budget, !history.isEmpty {
            let pair = history.prefix(2)
            history.removeFirst(min(2, history.count))
            summary.append(summaryLine(Array(pair)))
        }
        // 2. Earlier tool results in this turn become one-line placeholders (the tool call pairing is kept).
        for index in turn.indices where total() > budget && turn[index]["role"] as? String == "tool" && index != turn.lastIndex(where: { $0["role"] as? String == "tool" }) {
            let content = turn[index]["content"] as? String ?? ""
            turn[index]["content"] = "[Earlier \(turn[index]["tool_name"] as? String ?? "tool") result removed to save context (\(content.count) characters). Run the tool again if it is still needed.]"
        }
        // 3. Last resort: shorten the newest tool result to what is left.
        if total() > budget, let last = turn.lastIndex(where: { $0["role"] as? String == "tool" }), let content = turn[last]["content"] as? String {
            let room = max(0, budget - (total() - tokens(turn[last]))) * 4 - 400
            if room > 200, room < content.utf8.count {
                let kept = String(content.prefix(room))
                turn[last]["content"] = kept + "\n[Result shortened to fit the context window (\(kept.count) of \(content.count) characters). Search or ask for a specific part to see more.]"
            }
        }
        messages = history + turn
        return (summary, total())
    }
    static func summaryLine(_ pair: [[String: Any]]) -> String {
        func clip(_ value: Any?, _ limit: Int) -> String {
            let text = (value as? String ?? "").replacingOccurrences(of: "\n", with: " ")
            return text.count > limit ? String(text.prefix(limit)) + "…" : text
        }
        let user = pair.first { $0["role"] as? String == "user" }?["content"]
        let reply = pair.first { $0["role"] as? String == "assistant" }?["content"]
        return "- User asked: \(clip(user, 160)) | Obby replied: \(clip(reply, 240))"
    }
    /// Keeps the combined summary short, newest lines first to survive.
    static func compactSummary(_ lines: [String], limit: Int = 1_500) -> String {
        var kept: [String] = []
        var size = 0
        for line in lines.reversed() {
            guard size + line.count <= limit else { break }
            kept.insert(line, at: 0); size += line.count + 1
        }
        return kept.joined(separator: "\n")
    }

    // MARK: Long notes

    /// Splits text at headings and blank lines into sections of at most `maxTokens` (long paragraphs are split further).
    static func sections(_ text: String, maxTokens: Int) -> [String] {
        let limit = max(maxTokens, 200) * 4
        var blocks: [String] = []
        var current: [String] = []
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("#") || (line.trimmingCharacters(in: .whitespaces).isEmpty && !current.isEmpty) {
                if !current.isEmpty { blocks.append(current.joined(separator: "\n")); current = [] }
            }
            current.append(line)
        }
        if !current.isEmpty { blocks.append(current.joined(separator: "\n")) }
        var sections: [String] = []
        var buffer = ""
        for block in blocks {
            var piece = block
            while piece.utf8.count > limit { // One oversized paragraph: cut at a sentence or space near the limit.
                let head = String(piece.prefix(limit / 2))
                let cut = head.range(of: ". ", options: .backwards)?.upperBound ?? head.range(of: " ", options: .backwards)?.upperBound ?? head.endIndex
                if !buffer.isEmpty { sections.append(buffer); buffer = "" }
                sections.append(String(head[..<cut]))
                piece = String(piece[piece.index(piece.startIndex, offsetBy: head.distance(from: head.startIndex, to: cut))...])
            }
            if buffer.utf8.count + piece.utf8.count + 1 > limit, !buffer.isEmpty { sections.append(buffer); buffer = "" }
            buffer += (buffer.isEmpty ? "" : "\n") + piece
        }
        if !buffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { sections.append(buffer) }
        return sections
    }
    static let wholeNoteWords = ["summar", "whole", "entire", "overview", "outline", "tl;dr", "tldr", "all of", "everything", "key points", "main points", "rewrite", "proofread", "translate"]
    static let stopWords: Set<String> = ["this", "that", "note", "what", "with", "from", "about", "does", "have", "which", "where", "when", "there", "their", "would", "could", "should", "please", "tell", "into", "more", "some"]
    static func keywords(_ request: String) -> Set<String> {
        Set(request.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count >= 4 && !stopWords.contains($0) })
    }
    static func relevance(_ section: String, _ keywords: Set<String>) -> Int {
        let lower = section.lowercased()
        return keywords.reduce(0) { $0 + (lower.contains($1) ? 1 : 0) }
    }
}

extension AppModel {
    /// Effective window: the Context Window setting, capped at what the provider reports for this model.
    func effectiveContextWindow(_ provider: AIProvider) async -> Int {
        let chosen = contextWindow.rawValue
        let key = provider.kind.rawValue + "/" + selectedModel
        if contextLimits[key] == nil { contextLimits[key] = await provider.contextLimit(selectedModel) ?? 0 }
        let limit = contextLimits[key] ?? 0
        return limit > 0 ? min(chosen, limit) : chosen
    }
    /// The setting capped at the model's limit, without making a request.
    var effectiveWindow: Int { contextCap.map { min(contextWindow.rawValue, $0) } ?? contextWindow.rawValue }
    /// Looks up (once per model and session) the selected model's context limit so Settings can show the effective value.
    func refreshContextCap() async {
        guard !selectedModel.isEmpty, let provider = try? makeProvider() else { contextCap = nil; return }
        let model = selectedModel
        _ = await effectiveContextWindow(provider)
        guard model == selectedModel else { return }
        let limit = contextLimits[provider.kind.rawValue + "/" + model] ?? 0
        contextCap = limit > 0 ? limit : nil
    }
    /// Fits a long note into `allowance` tokens without blind truncation: the relevant sections verbatim when the
    /// request is about part of the note and they fit; otherwise a section-by-section digest made with the same model.
    func condenseLongText(_ text: String, title: String, request: String, provider: AIProvider, window: Int, allowance: Int, depth: Int = 0) async throws -> String {
        guard ContextBudget.tokens(text) > allowance else { return text }
        if depth == 0 { appendNotice("\(title) is too large to send at once. Obby will process it in sections.") }
        let chunkTokens = max(ContextBudget.inputBudget(for: window) - 600 - ContextBudget.tokens(request), 300)
        let sections = ContextBudget.sections(text, maxTokens: chunkTokens)
        let lowered = request.lowercased()
        if depth == 0, !ContextBudget.wholeNoteWords.contains(where: { lowered.contains($0) }) {
            let keywords = ContextBudget.keywords(request)
            let ranked = sections.indices.map { ($0, ContextBudget.relevance(sections[$0], keywords)) }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }
            var picked: [Int] = [], used = 0
            for (index, _) in ranked where used + ContextBudget.tokens(sections[index]) <= allowance - 100 {
                picked.append(index); used += ContextBudget.tokens(sections[index])
            }
            if !picked.isEmpty, picked.count < sections.count {
                return "[Only the parts of \"\(title)\" relevant to the request are included (\(picked.count) of \(sections.count) sections).]\n\n" + picked.sorted().map { sections[$0] }.joined(separator: "\n\n…\n\n")
            }
        }
        let system = "You are helping answer a request about a long note that is being read in sections. Using only the section provided, write concise notes with everything relevant to the request (for a summary request, summarize the section). Keep names, numbers and headings accurate. Do not invent anything. If nothing in the section is relevant, reply exactly: Nothing relevant."
        var digests: [String] = []
        for (index, section) in sections.enumerated() {
            try Task.checkCancellation()
            let content = "User request: \(request)\n\nSection \(index + 1) of \(sections.count) of \"\(title)\":\n\n\(section)"
            let reply = try await provider.chat(ChatRequest(model: selectedModel, system: system, messages: [["role": "user", "content": content]], tools: nil, temperature: temperature, contextWindow: window, keepAlive: keepAlive.apiValue))
            if !reply.text.lowercased().hasPrefix("nothing relevant") { digests.append("Section \(index + 1): \(reply.text)") }
        }
        let combined = "[\"\(title)\" was too large to send at once; Obby read it in \(sections.count) sections. Notes from each section:]\n\n" + (digests.isEmpty ? "No section was relevant to the request." : digests.joined(separator: "\n\n"))
        if ContextBudget.tokens(combined) > allowance {
            if depth < 2 { return try await condenseLongText(combined, title: title, request: request, provider: provider, window: window, allowance: allowance, depth: depth + 1) }
            return String(combined.prefix(allowance * 4)) // Several passes already; keep what fits.
        }
        return combined
    }
}
