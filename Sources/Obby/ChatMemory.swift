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
        if failed { // "Couldn’t update TOK.md." plus Obby's own short reason; never raw exceptions, JSON or full Mac paths.
            let reason = result.hasPrefix("Error: ") ? String(result.dropFirst(7)) : ""
            let safeReason = reason.isEmpty || reason.contains("/Users/") || reason.contains("/private/") || reason.hasPrefix("/") || reason.contains("{") ? "" : reason
            if tool == "read_attachment" || tool == "read_file", !safeReason.isEmpty { return safeReason }
            let path = arg("path").isEmpty ? arg("oldPath") : arg("path")
            let verbs = ["write_file": "update", "append_to_file": "update", "create_file": "create", "create_directory": "create",
                         "rename_path": "rename", "move_path": "move", "delete_path": "delete", "read_file": "read", "read_attachment": "read"]
            let target = path.isEmpty ? "the item" : name(path)
            return "Couldn’t \(verbs[tool] ?? "complete this action for") \(target)." + (safeReason.isEmpty ? "" : " " + safeReason)
        }
        if tool == "delete_path" && result == "User declined deletion. Do not retry." { return "Deletion cancelled." }
        switch tool {
        case "create_directory": return "Created the \(name(arg("path"))) folder."
        case "create_file": return "Created \(name(arg("path")))."
        case "write_file", "append_to_file": return "Updated \(name(arg("path")))."
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
        switch TextToolCall.parse(raw) { // A tool call written as text is an action, never prose.
        case .calls(_, let prose): return prose
        case .invalid: return ""
        case .notACall: break
        }
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
        let bareCall = "^\\s*`?(?:" + toolNames.sorted().joined(separator: "|") + ")\\s*[({].*[)}]`?\\s*$"
        var inCode = false
        text = text.components(separatedBy: "\n").filter { line in
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inCode.toggle(); return true }
            if inCode { return true }
            return !line.contains("\"tool_calls\"") && !line.contains("\"tool_name\"") && line.range(of: bareCall, options: .regularExpression) == nil
        }.joined(separator: "\n")
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    static let toolNames: Set<String> = ["list_directory", "read_file", "read_attachment", "append_to_file", "write_file", "create_file", "create_directory", "rename_path", "move_path", "delete_path", "search_notes"]
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
    var preferences: [String] = [] // Preferences the user stated for this task only.
    var isEmpty: Bool { recentMessages.isEmpty && summary.isEmpty }
    /// Structured memory items (for the small "Memory · N items" indicator).
    var itemCount: Int { (currentGoal.isEmpty ? 0 : 1) + (summary.isEmpty ? 0 : 1) + decisions.count + completedActions.count + openQuestions.count + preferences.count + relevantFiles.count }
    /// The compact memory sent with a request (only this chat's, never the whole store).
    var packet: String {
        var parts: [String] = []
        if !currentGoal.isEmpty { parts.append("Current goal: " + currentGoal) }
        if !summary.isEmpty { parts.append("Summary so far:\n" + summary) }
        func list(_ title: String, _ items: [String]) { if !items.isEmpty { parts.append(title + ":\n" + items.map { "- " + $0 }.joined(separator: "\n")) } }
        list("Decisions", decisions)
        list("Completed actions", Array(completedActions.suffix(12)))
        list("Open questions and next steps", openQuestions)
        list("Preferences for this task", preferences)
        if !relevantFiles.isEmpty { parts.append("Relevant files (read them again if needed; they may have changed): " + relevantFiles.joined(separator: ", ")) }
        return parts.joined(separator: "\n\n")
    }
    mutating func remember(file: String) {
        guard !file.isEmpty else { return }
        relevantFiles.removeAll { $0 == file }; relevantFiles.insert(file, at: 0); relevantFiles = Array(relevantFiles.prefix(12))
    }
    mutating func remember(action: String) { completedActions.append(action); completedActions = Array(completedActions.suffix(30)) }
}

extension ChatRecord {
    /// Tolerant loading: fields added in later versions (or missing from an edited file) fall back to defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init()
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt) ?? createdAt
        notesRoot = try c.decodeIfPresent(String.self, forKey: .notesRoot) ?? ""
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        recentMessages = try c.decodeIfPresent([Message].self, forKey: .recentMessages) ?? []
        relevantFiles = try c.decodeIfPresent([String].self, forKey: .relevantFiles) ?? []
        currentGoal = try c.decodeIfPresent(String.self, forKey: .currentGoal) ?? ""
        decisions = try c.decodeIfPresent([String].self, forKey: .decisions) ?? []
        completedActions = try c.decodeIfPresent([String].self, forKey: .completedActions) ?? []
        openQuestions = try c.decodeIfPresent([String].self, forKey: .openQuestions) ?? []
        preferences = try c.decodeIfPresent([String].self, forKey: .preferences) ?? []
    }
}

/// Small global memory: only durable preferences the user explicitly stated as lasting ("from now on…").
/// Saved as Application Support/Obby/Memory.json.
struct GlobalMemory: Codable, Equatable {
    var preferences: [String] = []
    var packet: String { preferences.isEmpty ? "" : "User preferences (apply to every task):\n" + preferences.map { "- " + $0 }.joined(separator: "\n") }
    static var file: URL { ChatStore.root.appendingPathComponent("Memory.json") }
    static func load() -> GlobalMemory { (try? JSONDecoder().decode(GlobalMemory.self, from: Data(contentsOf: file))) ?? GlobalMemory() }
    func save() {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? FileManager.default.createDirectory(at: ChatStore.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? data.write(to: Self.file, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.file.path)
    }
    /// Only phrasing that states a lasting preference can add to global memory; other details stay with the task.
    static func statesLastingPreference(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return ["from now on", "going forward", "in future", "in the future", "by default", "always ", "never ", "remember that i", "remember i ", "i prefer", "i'd prefer", "i would prefer", "every time"].contains(where: lowered.contains)
    }
}

/// Local JSON files, one per chat, in ~/Library/Application Support/Obby/Chats. No database, no sync, no analytics.
enum ChatStore {
    static var rootOverride: URL? // The checks use a temporary folder.
    /// ~/Library/Application Support/Obby: tasks in Chats/, global preferences in Memory.json.
    static var root: URL { rootOverride ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Obby", isDirectory: true) }
    static var directory: URL { root.appendingPathComponent("Chats", isDirectory: true) }
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
    func clearAllChatMemory() {
        ChatStore.deleteAll(); try? FileManager.default.removeItem(at: GlobalMemory.file)
        globalMemory = GlobalMemory(); clearChat(); reloadSavedChats()
    }
    func forgetGlobalPreference(_ item: String) { globalMemory.preferences.removeAll { $0 == item }; globalMemory.save() }
    /// Updates the task's structured memory, but only when it matters: after meaningful work (files changed, a
    /// document read or summarised), when the user states a lasting preference, or when the kept messages approach
    /// the context budget (then older messages are folded in and only the last few stay verbatim). One request to
    /// the current model; if it fails, a plain deterministic summary is used for compaction.
    func updateMemory(provider: AIProvider, window: Int, budget: Int, prompt: String, didWork: Bool) async {
        let size = history.reduce(0) { $0 + ContextBudget.tokens($1["content"] as? String ?? "") }
        let compact = size > budget / 2 && history.count > 8
        let lasting = GlobalMemory.statesLastingPreference(prompt)
        guard compact || didWork || lasting else { return }
        let older = compact ? Array(history.dropLast(8)) : [], recent = Array(history.suffix(compact ? 8 : 2))
        func transcript(_ messages: [[String: Any]], limit: Int) -> String {
            String(messages.map { "\($0["role"] as? String ?? ""): \(ChatMemory.clipped($0["content"] as? String ?? "", limit: limit))" }
                .joined(separator: "\n\n").suffix(max(budget * 2, 2_000)))
        }
        let request = """
        Update this task's memory. Reply with JSON only, using exactly these keys: \
        "summary" (at most 120 words, facts needed to continue the task), "currentGoal" (one sentence), \
        "decisions" (array, at most 6), "openQuestions" (array, at most 6 unresolved next steps), \
        "preferences" (array, at most 5: how the user wants THIS task done, only if they said so), \
        "globalPreferences" (array, at most 3: only preferences the user explicitly said apply from now on or always; otherwise []). \
        Mention notes by path only; never copy note contents.

        Current memory:
        \(memory.packet.isEmpty ? "(empty)" : memory.packet)
        \(older.isEmpty ? "" : "\nOlder messages to fold in:\n" + transcript(older, limit: 1_500) + "\n")
        Latest exchange:
        \(transcript(Array(history.suffix(2)), limit: 3_000))
        """
        var updated = false
        let chatID = memory.id
        let reply = try? await provider.chat(ChatRequest(model: selectedModel, system: "You maintain a compact task memory for a notes assistant. Reply with JSON only.", messages: [["role": "user", "content": request]], tools: nil, temperature: 0, contextWindow: window, keepAlive: keepAlive.apiValue))
        guard memory.id == chatID else { return } // The user started or opened another chat meanwhile.
        if let reply, let start = reply.text.firstIndex(of: "{"), let end = reply.text.lastIndex(of: "}"),
           let json = try? JSONSerialization.jsonObject(with: Data(reply.text[start...end].utf8)) as? [String: Any] {
            func items(_ key: String, _ limit: Int) -> [String]? {
                (json[key] as? [Any]).map { Array($0.compactMap { $0 as? String }.map { ChatMemory.clipped($0, limit: 200) }.prefix(limit)) }
            }
            if let summary = json["summary"] as? String, !summary.isEmpty { memory.summary = ChatMemory.clipped(summary, limit: 1_200); updated = true }
            if let goal = json["currentGoal"] as? String, !goal.isEmpty { memory.currentGoal = ChatMemory.clipped(goal, limit: 240) }
            if let decisions = items("decisions", 6) { memory.decisions = decisions }
            if let questions = items("openQuestions", 6) { memory.openQuestions = questions }
            if let preferences = items("preferences", 5) { memory.preferences = preferences }
            if lasting, let global = items("globalPreferences", 3), !global.isEmpty { // Never promoted without explicit wording.
                for item in global where !globalMemory.preferences.contains(item) { globalMemory.preferences.append(item) }
                globalMemory.preferences = Array(globalMemory.preferences.suffix(10))
                globalMemory.save()
            }
        }
        guard compact else { return }
        if !updated { // Fallback: one line per older exchange, newest kept first.
            let lines = stride(from: 0, to: older.count, by: 2).map { ContextBudget.summaryLine(Array(older[$0..<min($0 + 2, older.count)])) }
            memory.summary = ContextBudget.compactSummary((memory.summary.isEmpty ? [] : [memory.summary]) + lines)
        }
        history = recent
        appendNotice("Older messages were condensed into this task’s memory.")
    }
}

/// Tool calls a model wrote as text instead of using native function calling (common with small local models),
/// e.g. `write_file{"path":"TOK.md","content":"…"}` or `{"tool":"write_file","path":"TOK.md","content":"…"}`.
/// Only a reply that ends in (or consists of) calls to known Obby tools with all required arguments is accepted;
/// ordinary JSON, code and unknown names stay text. Execution still goes through Obby's sandboxed tool layer.
enum TextToolCall {
    static let required: [String: [String]] = [
        "list_directory": ["path"], "read_file": ["path"], "read_attachment": ["path"], "search_notes": ["query"],
        "write_file": ["path", "content"], "append_to_file": ["path", "content"], "create_file": ["path", "content"],
        "create_directory": ["path"], "rename_path": ["oldPath", "newPath"], "move_path": ["oldPath", "newPath"], "delete_path": ["path"]]
    enum Outcome { case notACall, calls([ToolCall], prose: String), invalid(String) }

    static func parse(_ text: String) -> Outcome {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .notACall }
        let whole = parseWhole(trimmed)
        if case .notACall = whole {} else { return whole }
        // Prose followed by a call: split at the first line that starts one, and accept only if the rest parses.
        let lines = trimmed.components(separatedBy: "\n")
        for index in lines.indices.dropFirst() {
            let line = lines[index].trimmingCharacters(in: .whitespaces)
            guard line.hasPrefix("```") || line.hasPrefix("{") || leadingToolName(line) != nil else { continue }
            let rest = lines[index...].joined(separator: "\n")
            switch parseWhole(rest.trimmingCharacters(in: .whitespacesAndNewlines)) {
            case .calls(let calls, _): return .calls(calls, prose: lines[..<index].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))
            case .invalid(let reason): return .invalid(reason)
            case .notACall: continue
            }
        }
        return .notACall
    }
    private static func parseWhole(_ text: String) -> Outcome {
        var body = text
        if body.hasPrefix("```"), body.hasSuffix("```"), body.count > 6, let newline = body.firstIndex(of: "\n") { // One fenced block.
            body = String(body[body.index(after: newline)..<body.index(body.endIndex, offsetBy: -3)])
        }
        body = body.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "`")))
        var found: [(String, [String: Any])]
        if let json = jsonValue(body) {
            guard let calls = envelopes(json) else { return .notACall } // Ordinary JSON is just text.
            found = calls
        } else if let name = leadingToolName(body) {
            guard let call = namedCall(body, name: name) else { return .invalid("the \(name) request couldn’t be read") }
            found = [call]
        } else { return .notACall }
        var calls: [ToolCall] = []
        for (name, arguments) in found {
            let missing = (required[name] ?? []).filter { arguments[$0] as? String == nil }
            guard missing.isEmpty else { return .invalid("\(name) is missing \(missing.joined(separator: " and "))") }
            calls.append(ToolCall(id: "text-" + UUID().uuidString, name: name, arguments: arguments, raw: ["text_tool_call": ["name": name, "arguments": arguments]]))
        }
        return calls.isEmpty ? .notACall : .calls(calls, prose: "")
    }
    private static func jsonValue(_ text: String) -> Any? {
        guard text.first == "{" || text.first == "[" else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(text.utf8))
    }
    /// {"tool"|"name"|"tool_name"|"function": <tool>, "arguments"|"parameters"|"args"|"input": {…}} (or flat arguments),
    /// {"tool_calls": […]}, {"function": {…}}, or an array of these. Unknown tool names are never accepted.
    private static func envelopes(_ json: Any) -> [(String, [String: Any])]? {
        if let array = json as? [Any] {
            let parsed = array.compactMap(envelopes)
            return !array.isEmpty && parsed.count == array.count ? parsed.flatMap { $0 } : nil
        }
        guard let object = json as? [String: Any] else { return nil }
        if let list = object["tool_calls"] { return envelopes(list) }
        if let function = object["function"] as? [String: Any] { return envelopes(function) }
        guard let name = (object["tool"] ?? object["name"] ?? object["tool_name"] ?? object["function"]) as? String, required[name] != nil else { return nil }
        if let nested = object["arguments"] ?? object["parameters"] ?? object["args"] ?? object["input"] { return [(name, ToolCall.arguments(nested))] }
        return [(name, object.filter { !["tool", "name", "tool_name", "function", "type", "id"].contains($0.key) })]
    }
    /// `write_file{…}`, `write_file {…}`, `write_file({…})`
    private static func namedCall(_ text: String, name: String) -> (String, [String: Any])? {
        var rest = String(text.dropFirst(name.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        if rest.hasPrefix("("), rest.hasSuffix(")") { rest = String(rest.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let object = jsonValue(rest) as? [String: Any] else { return nil }
        if let nested = object["arguments"] ?? object["parameters"] { return (name, ToolCall.arguments(nested)) }
        return (name, object)
    }
    /// A known tool name immediately followed by `{` or `(`.
    static func leadingToolName(_ text: String) -> String? {
        let body = text.trimmingCharacters(in: CharacterSet(charactersIn: "` "))
        return required.keys.sorted { $0.count > $1.count }.first { name in
            body.hasPrefix(name) && String(body.dropFirst(name.count)).trimmingCharacters(in: .whitespaces).first.map { $0 == "{" || $0 == "(" } == true
        }
    }
}

