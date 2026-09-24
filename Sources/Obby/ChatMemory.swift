import Foundation

// Session-only values. Never encode these into preferences, files, or logs.
enum ChatMemory {
    /// Safety net after ContextBudget.fit: never send a request whose estimated size exceeds the whole window.
    static func checkSize(_ body: [String: Any], window: Int) throws {
        guard ContextBudget.tokens(body) <= window else {
            throw ObbyError("This request is larger than the \(ContextBudget.label(window)) context window. Try a larger Context Window in Settings or a more focused request.")
        }
    }
    /// Attaches the open note (already fitted by ContextBudget, including unsaved edits) to a chat-only request.
    static func withCurrentNote(_ prompt: String, path: String?, text: String) -> String {
        guard let path else { return prompt }
        return prompt + "\n\n<current_note path=\"\(path)\">\n\(text)\n</current_note>"
    }
    static func clipped(_ text: String, limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit)) + "\n[Earlier content truncated]" : text
    }
    static func retainingExchange(_ history: [[String: Any]], prompt: String, reply: String) -> [[String: Any]] {
        // Keep recent user/final-answer pairs verbatim (tool payloads and thinking are never kept); ContextBudget
        // decides per request how many fit, and older pairs are folded into a short summary.
        Array((history + [
            ["role": "user", "content": clipped(prompt, limit: messageLimit)],
            ["role": "assistant", "content": clipped(reply, limit: messageLimit)]
        ]).suffix(keptPairs * 2))
    }
    static let keptPairs = 20, messageLimit = 8_000
    static func trimDisplay(_ lines: [ChatLine]) -> [ChatLine] {
        var recent: [ChatLine] = []
        var remaining = 32_000
        for var line in lines.suffix(40).reversed() {
            line.text = clipped(line.text, limit: 4_000)
            guard line.text.utf8.count <= remaining else { break }
            remaining -= line.text.utf8.count
            recent.append(line)
        }
        var rawBudget = 128_000
        for index in recent.indices {
            if let raw = recent[index].rawAction {
                if raw.utf8.count <= rawBudget { rawBudget -= raw.utf8.count }
                else { recent[index].rawAction = nil }
            }
        }
        return recent.reversed()
    }
}

extension AppModel {
    func appendChat(role: String, text: String) {
        chat = ChatMemory.trimDisplay(chat + [ChatLine(role: role, text: text)])
    }
    func appendAction(call: [String: Any], name: String, arguments: [String: Any], response: [String: Any], failed: Bool) {
        let result = response["content"] as? String ?? ""
        let data = try? JSONSerialization.data(withJSONObject: ["call": call, "response": response], options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let raw = data.flatMap { String(data: $0, encoding: .utf8) }
        let summary = ActionPresentation.summary(name, arguments: arguments, result: result, failed: failed)
        let line = ChatLine(role: "Action", text: summary, rawAction: raw, unsuccessful: failed || summary == "Deletion cancelled.")
        chat = ChatMemory.trimDisplay(chat + [line])
    }
    /// A compact informational line in the action list (not sent to the model).
    func appendNotice(_ text: String, failed: Bool = false) {
        chat = ChatMemory.trimDisplay(chat + [ChatLine(role: "Action", text: text, unsuccessful: failed, notice: true)])
    }
    func clearChat() {
        memory = ChatRecord() // A new chat starts with fresh memory; saved chats stay on disk.
        contextUsage = nil
        chatSession = UUID()
        aiTask?.cancel(); aiTask = nil
        directoryResults.removeAll(keepingCapacity: false)
        history.removeAll(keepingCapacity: false)
        chat.removeAll(keepingCapacity: false)
        busy = false
    }
}

// Display-only transformations. Never send these descriptions back to Ollama.
enum ActionPresentation {
    static func name(_ path: String) -> String { path.split(separator: "/").last.map(String.init) ?? "Obby" }
    static func summary(_ tool: String, arguments: [String: Any], result: String, failed: Bool) -> String {
        func arg(_ key: String) -> String { arguments[key] as? String ?? "" }
        if failed, tool == "read_attachment" || tool == "read_file", result.hasPrefix("Error: ") { return String(result.dropFirst(7)) } // Obby's own reason.
        if failed { return "Couldn’t complete this action. Check the selected folder and try again." }
        if tool == "delete_path" && result == "User declined deletion. Do not retry." { return "Deletion cancelled." }
        switch tool {
        case "create_directory": return "Created the \(name(arg("path"))) folder."
        case "create_file": return "Created \(name(arg("path")))."
        case "write_file": return "Updated \(name(arg("path")))."
        case "read_file", "read_attachment": return "Read \(name(arg("path")))."
        case "list_directory": return "Checked the \(name(arg("path"))) folder."
        case "search_notes": return "Searched your notes for “\(arg("query"))”."
        case "rename_path": return "Renamed \(name(arg("oldPath"))) to \(name(arg("newPath")))."
        case "move_path":
            let parent = arg("newPath").split(separator: "/").dropLast().joined(separator: "/")
            return "Moved \(name(arg("oldPath"))) to \(name(parent))."
        case "delete_path": return "Moved \(name(arg("path"))) to Trash."
        default: return "Completed the action."
        }
    }
    /// DISPLAY ONLY. Hides tool-call markup a model may leak into its reply. The stored reply (`ChatLine.text`) is
    /// never changed; Copy Response and Raw Actions use it as-is. Prose, code and tool names in text are left alone.
    static func reply(_ raw: String) -> String {
        if let data = raw.data(using: .utf8), let json = try? JSONSerialization.jsonObject(with: data), isToolEnvelope(json) { return "" }
        var text = raw
        // Fenced blocks that are serialized tool calls (not ordinary JSON or code examples).
        if let regex = try? NSRegularExpression(pattern: "(?s)```[^\n]*\n(.*?)```") {
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
                guard let range = Range(match.range, in: text), let body = Range(match.range(at: 1), in: text) else { continue }
                let content = String(text[body])
                let parsed = content.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) }
                if content.contains("\"tool_calls\"") || content.contains("\"tool_name\"") || parsed.map(isToolEnvelope) == true { text.removeSubrange(range) }
            }
        }
        // Outside code blocks: lines that are only envelope keys or a bare call such as `search_notes(query="x")`.
        let bareCall = "^\\s*`?(?:" + toolNames.sorted().joined(separator: "|") + ")\\s*\\(.*\\)`?\\s*$"
        var inCode = false
        text = text.components(separatedBy: "\n").filter { line in
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inCode.toggle(); return true }
            if inCode { return true }
            return !line.contains("\"tool_calls\"") && !line.contains("\"tool_name\"") && line.range(of: bareCall, options: .regularExpression) == nil
        }.joined(separator: "\n")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static let toolNames: Set<String> = ["list_directory", "read_file", "read_attachment", "write_file", "create_file", "create_directory", "rename_path", "move_path", "delete_path", "search_notes"]
    /// True only for the shapes of tool calls: {"tool_calls": …}, {"name": <Obby tool>, "arguments": …}, {"function": {…}}.
    static func isToolEnvelope(_ json: Any) -> Bool {
        if let array = json as? [Any] { return !array.isEmpty && array.allSatisfy(isToolEnvelope) }
        guard let object = json as? [String: Any] else { return false }
        if object["tool_calls"] != nil || object["tool_name"] != nil { return true }
        if let name = object["name"] as? String, toolNames.contains(name), object["arguments"] != nil || object["parameters"] != nil { return true }
        if let function = object["function"] as? [String: Any] { return isToolEnvelope(function) }
        return false
    }
}

// Keep tool-call/response pairing intact, but retire obsolete navigation payloads.
enum NavigationContext {
    static let tools: Set<String> = ["list_directory", "search_notes"]
    static func compact(_ messages: inout [[String: Any]]) {
        let results = messages.indices.filter { messages[$0]["role"] as? String == "tool" && tools.contains(messages[$0]["tool_name"] as? String ?? "") }
        for index in results.dropLast(2) {
            messages[index]["content"] = "Earlier navigation results omitted. Use paths already found; search narrowly if more information is needed."
        }
    }
    static func page(_ entries: [Entry], offset: Int) -> String {
        var lines: [String] = []
        var used = 0
        for entry in entries.prefix(50) {
            let line = (entry.isDirectory ? "folder " : "note ") + entry.path
            if used + line.utf8.count > 6_000 && !lines.isEmpty { break }
            lines.append(line); used += line.utf8.count + 1
        }
        if entries.count > lines.count { lines.append("More results: repeat with offset \(offset + lines.count).") }
        return lines.isEmpty ? "No matches." : lines.joined(separator: "\n")
    }
}

// MARK: Persistent chat memory
// NOTES (.md files) are the user's data; CHAT MEMORY is this compact, Obby-managed task state; MODEL CONTEXT is the
// temporary subset assembled for one request. Memory never copies note contents: files are remembered by path and
// read from disk again when needed.

/// One chat's memory, saved as Application Support/Obby/Chats/<id>.json. No API keys, no note contents.
struct ChatRecord: Codable, Identifiable, Equatable {
    struct Message: Codable, Equatable { var role: String; var content: String }
    var id = UUID()
    var title = ""
    var createdAt = Date()
    var updatedAt = Date()
    var notesRoot = "" // Chats are listed per notes folder, since their file paths are relative to it.
    var summary = ""
    var recentMessages: [Message] = []
    var relevantFiles: [String] = []
    var currentGoal = ""
    var decisions: [String] = []
    var completedActions: [String] = []
    var openQuestions: [String] = []
    var isEmpty: Bool { recentMessages.isEmpty && summary.isEmpty }
    /// The compact memory sent with a request (only this chat's, never the whole store).
    var packet: String {
        var parts: [String] = []
        if !currentGoal.isEmpty { parts.append("Current goal: " + currentGoal) }
        if !summary.isEmpty { parts.append("Summary so far:\n" + summary) }
        func list(_ title: String, _ items: [String]) { if !items.isEmpty { parts.append(title + ":\n" + items.map { "- " + $0 }.joined(separator: "\n")) } }
        list("Decisions", decisions)
        list("Completed actions", Array(completedActions.suffix(12)))
        list("Open questions and next steps", openQuestions)
        if !relevantFiles.isEmpty { parts.append("Relevant files (read them again if needed; they may have changed): " + relevantFiles.joined(separator: ", ")) }
        return parts.joined(separator: "\n\n")
    }
    mutating func remember(file: String) {
        guard !file.isEmpty else { return }
        relevantFiles.removeAll { $0 == file }; relevantFiles.insert(file, at: 0); relevantFiles = Array(relevantFiles.prefix(12))
    }
    mutating func remember(action: String) { completedActions.append(action); completedActions = Array(completedActions.suffix(30)) }
}

/// Local JSON files, one per chat, in ~/Library/Application Support/Obby/Chats. No database, no sync, no analytics.
enum ChatStore {
    static var directoryOverride: URL? // The checks use a temporary folder.
    static var directory: URL {
        directoryOverride ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Obby/Chats", isDirectory: true)
    }
    static func file(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString + ".json") }
    static func save(_ record: ChatRecord) {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601; encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(record) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? data.write(to: file(record.id), options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file(record.id).path)
    }
    static func files() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "json" }
    }
    static func all(root: String) -> [ChatRecord] {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return files().compactMap { try? decoder.decode(ChatRecord.self, from: Data(contentsOf: $0)) }
            .filter { $0.notesRoot == root && !$0.isEmpty }.sorted { $0.updatedAt > $1.updatedAt }
    }
    /// Removes chat memory files only; notes and attachments live elsewhere and are never touched.
    static func delete(_ id: UUID) { try? FileManager.default.removeItem(at: file(id)) }
    static func deleteAll() { for url in files() { try? FileManager.default.removeItem(at: url) } }
}

extension AppModel {
    /// Saves the current chat (recent messages + compact memory) when remembering is on.
    func persistChat() {
        memory.recentMessages = history.map { ChatRecord.Message(role: $0["role"] as? String ?? "", content: $0["content"] as? String ?? "") }
        memory.notesRoot = vault?.root.path ?? ""
        memory.updatedAt = Date()
        guard rememberChats, !memory.isEmpty, !memory.notesRoot.isEmpty else { return }
        ChatStore.save(memory)
        reloadSavedChats()
    }
    func reloadSavedChats() {
        savedChats = rememberChats && vault != nil ? Array(ChatStore.all(root: vault!.root.path).prefix(20)) : []
    }
    /// Returns to a saved chat: its memory and recent messages come back; notes are read from disk when needed.
    func openChat(_ record: ChatRecord) {
        guard !busy else { return }
        clearChat()
        memory = record
        history = record.recentMessages.map { ["role": $0.role, "content": $0.content] }
        var lines = record.recentMessages.map { ChatLine(role: $0.role == "user" ? "You" : "Obby", text: $0.content) }
        if !record.summary.isEmpty { lines.insert(ChatLine(role: "Action", text: "Continuing “\(record.title)”. Earlier messages are kept as a short summary.", notice: true), at: 0) }
        chat = ChatMemory.trimDisplay(lines)
    }
    func restoreLatestChat() {
        reloadSavedChats()
        if let latest = savedChats.first { openChat(latest) }
    }
    /// Settings: forget this chat's memory (starts a new chat). Notes and attachments are untouched.
    func clearCurrentChatMemory() { ChatStore.delete(memory.id); clearChat(); reloadSavedChats() }
    /// Settings: forget every remembered chat. Notes and attachments are untouched.
    func clearAllChatMemory() { ChatStore.deleteAll(); clearChat(); reloadSavedChats() }
    /// Only when the kept messages approach the context budget: fold the older ones into the chat's memory
    /// (one request to the current model; a deterministic summary if that fails) and keep the last few verbatim.
    func compactMemoryIfNeeded(provider: AIProvider, window: Int, budget: Int) async {
        let size = history.reduce(0) { $0 + ContextBudget.tokens($1["content"] as? String ?? "") }
        guard size > budget / 2, history.count > 8 else { return }
        let older = Array(history.dropLast(8)), recent = Array(history.suffix(8))
        let transcript = String(older.map { "\($0["role"] as? String ?? ""): \(ChatMemory.clipped($0["content"] as? String ?? "", limit: 1_500))" }
            .joined(separator: "\n\n").suffix(max(budget * 2, 2_000)))
        let request = """
        Update this chat's task memory with the older messages below. Reply with JSON only, using exactly these keys: \
        "summary" (at most 120 words, facts needed to continue), "currentGoal" (one sentence), \
        "decisions" (array, at most 6 short items), "openQuestions" (array, at most 6 unresolved next steps). \
        Mention notes by path only; do not copy note contents.

        Current memory:
        \(memory.packet.isEmpty ? "(empty)" : memory.packet)

        Older messages:
        \(transcript)
        """
        var updated = false
        let chatID = memory.id
        let reply = try? await provider.chat(ChatRequest(model: selectedModel, system: "You maintain a compact task memory for a notes assistant. Reply with JSON only.", messages: [["role": "user", "content": request]], tools: nil, temperature: 0, contextWindow: window, keepAlive: keepAlive.apiValue))
        guard memory.id == chatID else { return } // The user started or opened another chat meanwhile.
        if let reply, let start = reply.text.firstIndex(of: "{"), let end = reply.text.lastIndex(of: "}"),
           let json = try? JSONSerialization.jsonObject(with: Data(reply.text[start...end].utf8)) as? [String: Any] {
            func items(_ key: String) -> [String]? { (json[key] as? [Any])?.compactMap { $0 as? String }.map { ChatMemory.clipped($0, limit: 200) }.prefix(6).map { $0 } }
            if let summary = json["summary"] as? String, !summary.isEmpty { memory.summary = ChatMemory.clipped(summary, limit: 1_200); updated = true }
            if let goal = json["currentGoal"] as? String, !goal.isEmpty { memory.currentGoal = ChatMemory.clipped(goal, limit: 240) }
            if let decisions = items("decisions") { memory.decisions = decisions }
            if let questions = items("openQuestions") { memory.openQuestions = questions }
        }
        if !updated { // Fallback: one line per older exchange, newest kept first.
            let lines = stride(from: 0, to: older.count, by: 2).map { ContextBudget.summaryLine(Array(older[$0..<min($0 + 2, older.count)])) }
            memory.summary = ContextBudget.compactSummary((memory.summary.isEmpty ? [] : [memory.summary]) + lines)
        }
        history = recent
        appendNotice("Older messages were condensed into this chat’s memory.")
    }
}

