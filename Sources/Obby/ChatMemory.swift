import Foundation
import AppKit

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
    func appendAction(call: [String: Any], name: String, arguments: [String: Any], response: [String: Any], failed: Bool, undo: UndoEdit? = nil) {
        let result = response["content"] as? String ?? ""
        let data = try? JSONSerialization.data(withJSONObject: ["call": call, "response": response], options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        let raw = data.flatMap { String(data: $0, encoding: .utf8) }
        let summary = ActionPresentation.summary(name, arguments: arguments, result: result, failed: failed)
        // The same failure again right after itself: one line with a count ("Couldn’t create X. ×3").
        if failed, let last = chat.indices.last, chat[last].role == "Action", chat[last].unsuccessful, !chat[last].notice, chat[last].base == summary {
            chat[last].repeats += 1; chat[last].text = summary + " ×\(chat[last].repeats)"; chat[last].rawAction = raw
            return
        }
        let line = ChatLine(role: "Action", text: summary, rawAction: raw, unsuccessful: failed || summary == "Deletion cancelled.", undo: failed ? nil : undo, base: summary)
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
        let heading = arg("heading").trimmingCharacters(in: CharacterSet(charactersIn: "# "))
        if failed { // "Couldn’t update TOK.md." plus Obby's own short reason; never raw exceptions, JSON or full Mac paths.
            let reason = result.hasPrefix("Error: ") ? String(result.dropFirst(7)) : ""
            let safeReason = reason.isEmpty || reason.contains("/Users/") || reason.contains("/private/") || reason.hasPrefix("/") || reason.contains("{") || reason.contains("obby-tmp") || reason.contains("obby-import") ? "" : reason
            if tool == "read_attachment" || tool == "read_file", !safeReason.isEmpty { return safeReason }
            let path = arg("path").isEmpty ? arg("oldPath") : arg("path")
            let verbs = ["write_file": "update", "append_to_file": "update", "replace_section": "update", "append_to_section": "update", "replace_text": "update", "read_section": "read", "create_file": "create", "create_directory": "create",
                         "rename_path": "rename", "move_path": "move", "delete_path": "delete", "read_file": "read", "read_attachment": "read"]
            let target = path.isEmpty ? "the item" : name(path)
            return "Couldn’t \(verbs[tool] ?? "complete this action for") \(target)." + (safeReason.isEmpty ? "" : " " + safeReason)
        }
        if tool == "delete_path" && result == "User declined deletion. Do not retry." { return "Deletion cancelled." }
        if result.hasPrefix("User declined replacing") { return "Kept \(name(arg("path"))) unchanged." }
        switch tool {
        case "create_directory": return "Created the \(name(arg("path"))) folder."
        case "create_file": return "Created \(name(arg("path")))."
        case "write_file", "append_to_file", "replace_text": return "Updated \(name(arg("path")))."
        case "replace_section", "append_to_section": return "Updated the “\(heading)” section of \(name(arg("path")))."
        case "read_section": return "Read the “\(heading)” section of \(name(arg("path")))."
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
    static let toolNames: Set<String> = ["list_directory", "read_file", "read_attachment", "append_to_file", "read_section", "replace_section", "append_to_section", "replace_text", "write_file", "create_file", "create_directory", "rename_path", "move_path", "delete_path", "search_notes"]
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
    var pinned: [String] = [] // Facts the user pinned ("Pin to Memory", "Remember that…"). Never condensed away.
    var earlierActionCount = 0 // Completed actions older than the last 8, folded into a count.
    var missingSince: [String: Date] = [:] // When a remembered file was first found missing (dropped after 7 days).
    var isEmpty: Bool { recentMessages.isEmpty && summary.isEmpty && pinned.isEmpty }
    /// A chat with a real request (it has a title), a pin or completed work. Chats of only small talk are not saved.
    var isWorthSaving: Bool { !title.isEmpty || !pinned.isEmpty || !completedActions.isEmpty || earlierActionCount > 0 }
    /// Structured memory items (for the small "Memory · N items" indicator).
    var itemCount: Int { (currentGoal.isEmpty ? 0 : 1) + (summary.isEmpty ? 0 : 1) + pinned.count + decisions.count + completedActions.count + openQuestions.count + preferences.count + relevantFiles.count }
    /// The compact memory sent with a request (only this chat's, never the whole store).
    var packet: String { packet(missing: []) }
    /// `missing`: remembered files that no longer exist (moved or deleted outside Obby), listed separately.
    func packet(missing: Set<String>) -> String {
        var parts: [String] = []
        if !pinned.isEmpty { parts.append("Pinned by the user (keep these in mind):\n" + pinned.map { "- " + $0 }.joined(separator: "\n")) }
        if !currentGoal.isEmpty { parts.append("Current goal: " + currentGoal) }
        if !summary.isEmpty { parts.append("Summary so far:\n" + summary) }
        func list(_ title: String, _ items: [String]) { if !items.isEmpty { parts.append(title + ":\n" + items.map { "- " + $0 }.joined(separator: "\n")) } }
        list("Decisions", decisions)
        list("Completed actions", completedActions)
        if earlierActionCount > 0 { parts.append("(\(earlierActionCount) earlier action\(earlierActionCount == 1 ? "" : "s") not listed)") }
        list("Open questions and next steps", openQuestions)
        list("Preferences for this task", preferences)
        let present = relevantFiles.filter { !missing.contains($0) }
        if !present.isEmpty { parts.append("Relevant files (read them again if needed; they may have changed): " + present.joined(separator: ", ")) }
        let gone = relevantFiles.filter { missing.contains($0) }
        if !gone.isEmpty { parts.append("Files this task used that no longer exist (moved or deleted outside Obby): " + gone.joined(separator: ", ")) }
        return parts.joined(separator: "\n\n")
    }
    mutating func pin(_ fact: String) {
        let text = fact.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !pinned.contains(text) else { return }
        pinned.append(text); pinned = Array(pinned.suffix(20))
    }
    mutating func remember(file: String) {
        guard !file.isEmpty else { return }
        relevantFiles.removeAll { $0 == file }; relevantFiles.insert(file, at: 0); relevantFiles = Array(relevantFiles.prefix(12))
    }
    /// Records a completed action, clears next steps it completes, and keeps only the last 8 actions verbatim.
    mutating func remember(action: String) {
        completedActions.append(action)
        let done = Self.keyTerms(action)
        if !done.isEmpty { openQuestions.removeAll { !Self.keyTerms($0).isDisjoint(with: done) } }
        if completedActions.count > 8 { earlierActionCount += completedActions.count - 8; completedActions = Array(completedActions.suffix(8)) }
    }
    /// Distinctive words for matching an action to a next step: note names and longer words that aren't generic verbs.
    static func keyTerms(_ text: String) -> Set<String> {
        let generic: Set<String> = ["created", "create", "updated", "update", "added", "adding", "moved", "renamed", "section", "folder", "notes",
                                    "note", "file", "files", "trash", "generate", "write", "make", "read", "check", "checked", "their", "there", "about", "these", "those"]
        let lowered = text.lowercased()
        var terms = Set(lowered.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count >= 5 && !generic.contains($0) })
        if let regex = try? NSRegularExpression(pattern: "([\\p{L}\\p{N} _-]+)\\.md") { // "TOK.md" → "tok"
            for match in regex.matches(in: lowered, range: NSRange(lowered.startIndex..., in: lowered)) {
                if let range = Range(match.range(at: 1), in: lowered) {
                    terms.formUnion(lowered[range].split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { !generic.contains($0) })
                }
            }
        }
        return terms
    }
    /// Files missing for more than 7 days drop out of the task. Pins and About me are never touched.
    mutating func expireMissing(_ missing: Set<String>, now: Date = Date()) {
        for path in missing where missingSince[path] == nil { missingSince[path] = now }
        for path in missingSince.keys where !missing.contains(path) { missingSince.removeValue(forKey: path) }
        let expired = Set(missingSince.filter { now.timeIntervalSince($0.value) > 7 * 24 * 3600 }.keys)
        guard !expired.isEmpty else { return }
        relevantFiles.removeAll { expired.contains($0) }
        for path in expired { missingSince.removeValue(forKey: path) }
    }
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
        pinned = try c.decodeIfPresent([String].self, forKey: .pinned) ?? []
        earlierActionCount = try c.decodeIfPresent(Int.self, forKey: .earlierActionCount) ?? 0
        missingSince = try c.decodeIfPresent([String: Date].self, forKey: .missingSince) ?? [:]
        // Older tasks titled by small talk ("hi there"): clear the title and goal so the next real request sets them.
        if ToolRouting.isGreeting(currentGoal) { currentGoal = "" }
        if ToolRouting.isGreeting(title) { title = "" }
    }
}

/// Small global memory: only durable preferences the user explicitly stated as lasting ("from now on…").
/// Saved as Application Support/Obby/Memory.json.
struct GlobalMemory: Codable, Equatable {
    var preferences: [String] = []
    var folders: [String: String] = [:] // Folder context, keyed "<notes root>|<folder path>".
    var aboutMe: [String] = [] // Facts the user stated about themselves ("I'm doing Biology HL"), newest last.
    init() {}
    init(from decoder: Decoder) throws { // Older Memory.json files may lack any of these.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        preferences = try c.decodeIfPresent([String].self, forKey: .preferences) ?? []
        folders = try c.decodeIfPresent([String: String].self, forKey: .folders) ?? [:]
        aboutMe = try c.decodeIfPresent([String].self, forKey: .aboutMe) ?? []
    }
    /// Sent with every request (small talk too): who the user is, then their lasting preferences.
    var packet: String {
        var parts: [String] = []
        if !aboutMe.isEmpty { parts.append("About the user:\n" + aboutMe.map { "- " + $0 }.joined(separator: "\n")) }
        if !preferences.isEmpty { parts.append("User preferences (apply to every task):\n" + preferences.map { "- " + $0 }.joined(separator: "\n")) }
        return parts.joined(separator: "\n\n")
    }

    // MARK: About me

    static let aboutMeLimit = 15, aboutMeLength = 120
    /// Never stored, even if stated: health, finances, credentials and identity numbers.
    static let sensitiveWords = ["password", "passcode", "pin code", "login", "credential", "social security", "ssn", "passport", "national id",
                                 "credit card", "card number", "bank", "account number", "iban", "salary", "income", "debt", "loan", "net worth",
                                 "diagnos", "medication", "medicine", "illness", "disease", "disorder", "depress", "anxiety", "therapy", "therapist",
                                 "pregnan", "adhd", "autis", "cancer", "diabet", "hiv", "health", "doctor", "hospital", "address is", "phone number"]
    static func isSensitive(_ fact: String) -> Bool {
        let lowered = fact.lowercased()
        return sensitiveWords.contains(where: lowered.contains) || lowered.range(of: "[0-9]{6,}", options: .regularExpression) != nil
    }
    static func normalised(_ text: String) -> [String] {
        text.lowercased().replacingOccurrences(of: "’", with: "'").split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" }).map(String.init)
    }
    /// "My exam is in May" and "My exam is in June" share the subject "my exam" (a newer fact replaces the older one).
    static func subject(_ fact: String) -> String? {
        let words = normalised(fact)
        guard words.first == "my", let verb = words.firstIndex(where: { ["is", "are", "was", "will"].contains($0) }), verb <= 4 else { return nil }
        return words[..<verb].joined(separator: " ")
    }
    static func similar(_ a: String, _ b: String) -> Bool {
        let x = Set(normalised(a)), y = Set(normalised(b))
        guard !x.isEmpty, !y.isEmpty else { return false }
        if x == y || x.isSubset(of: y) || y.isSubset(of: x) { return true }
        return Double(x.intersection(y).count) / Double(x.union(y).count) >= 0.7
    }
    /// Adds facts: sensitive ones are dropped, near duplicates and same-subject facts are replaced by the newer
    /// wording, and when full the oldest are dropped.
    static func merge(_ existing: [String], _ new: [String]) -> [String] {
        var result = existing
        for raw in new {
            var fact = raw.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "-•* "))
            guard fact.count >= 3, !isSensitive(fact) else { continue }
            if fact.count > aboutMeLength { fact = String(fact.prefix(aboutMeLength)) }
            let topic = subject(fact)
            result.removeAll { similar($0, fact) || (topic != nil && subject($0) == topic) }
            result.append(fact)
        }
        return Array(result.suffix(aboutMeLimit))
    }
    /// Only facts the user actually said: most of the fact's words must appear in the user's own message.
    static func isStated(_ fact: String, in userText: String) -> Bool {
        let said = Set(normalised(userText)), words = normalised(fact).filter { $0.count >= 4 }
        guard !words.isEmpty else { return false }
        return Double(words.filter(said.contains).count) / Double(words.count) >= 0.6
    }
    /// Wording that states something about the user ("I'm…", "my exam is…", "I study…").
    static func statesPersonalFact(_ text: String) -> Bool {
        let lowered = " " + text.lowercased().replacingOccurrences(of: "’", with: "'") + " "
        if [" i am ", " i'm ", " im ", " i study ", " i work ", " i prefer ", " i'd prefer ", " i live ", " i go to ", " i take "].contains(where: lowered.contains) { return true }
        return lowered.range(of: " my [a-z]+( [a-z]+)? (is|are) ", options: .regularExpression) != nil
    }
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
        return ["from now on", "going forward", "in future", "in the future", "by default", "always ", "never ", "i prefer", "i'd prefer", "i would prefer", "every time"].contains(where: lowered.contains)
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
        guard rememberChats, !memory.isEmpty, !memory.notesRoot.isEmpty, memory.isWorthSaving else { return } // Small talk alone isn't saved.
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
        let personal = learnAboutMe && GlobalMemory.statesPersonalFact(prompt) // "I'm doing Biology HL": worth learning, no extra request.
        guard compact || didWork || lasting || personal else { return }
        let older = compact ? Array(history.dropLast(8)) : [], recent = Array(history.suffix(compact ? 8 : 2))
        func transcript(_ messages: [[String: Any]], limit: Int) -> String {
            String(messages.map { "\($0["role"] as? String ?? ""): \(ChatMemory.clipped($0["content"] as? String ?? "", limit: limit))" }
                .joined(separator: "\n\n").suffix(max(budget * 2, 2_000)))
        }
        let request = """
        Update this task's memory. Reply with JSON only, using exactly these keys: \
        "summary" (at most 120 words, facts needed to continue the task), "currentGoal" (one sentence), \
        "decisions" (array, at most 8), "openQuestions" (array, at most 6 unresolved next steps), \
        "preferences" (array, at most 5: how the user wants THIS task done, only if they said so), \
        "globalPreferences" (array, at most 3: only preferences the user explicitly said apply from now on or always; otherwise []), \
        "title" (at most 6 words naming the task, e.g. "Biology cell revision"), \
        "aboutUser" (array, at most 3 short facts the user explicitly STATED about themselves in their own messages, such as their subjects, \
        exam dates or how they like to work; never guesses, never note contents, never health, money, passwords or ID numbers; otherwise []). \
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
            if didWork, let raw = json["title"] as? String { // A better short title after real work.
                let title = raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'.#*")))
                let words = title.split(whereSeparator: { $0.isWhitespace }).count
                if (1...6).contains(words), title.count <= 60, !ToolRouting.isGreeting(title) { memory.title = title }
            }
            if let goal = json["currentGoal"] as? String, !goal.isEmpty { memory.currentGoal = ChatMemory.clipped(goal, limit: 240) }
            if let decisions = items("decisions", 8) { memory.decisions = decisions }
            if let questions = items("openQuestions", 6) { memory.openQuestions = questions }
            if let preferences = items("preferences", 5) { memory.preferences = preferences }
            if let facts = items("aboutUser", 3), !facts.isEmpty { learnAboutUser(facts, statedIn: prompt) }
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
        "read_section": ["path", "heading"], "replace_section": ["path", "heading", "content"], "append_to_section": ["path", "heading", "content"], "replace_text": ["path", "find", "replace"],
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
    /// What may be shown of a reply while it is still streaming: everything before the first line that could be the
    /// start of a tool call (JSON, a code fence, a tool name, or a partly written tool name). The full reply replaces it.
    static func visiblePrefix(_ text: String) -> String {
        var kept: [String] = []
        for line in text.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let partialName = trimmed.count >= 4 && trimmed.allSatisfy({ $0.isLetter || $0 == "_" }) && required.keys.contains { $0.hasPrefix(trimmed) }
            if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") || trimmed.hasPrefix("```") || trimmed.hasPrefix("`") || leadingToolName(trimmed) != nil || partialName { break }
            kept.append(line)
        }
        return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// A known tool name immediately followed by `{` or `(`.
    static func leadingToolName(_ text: String) -> String? {
        let body = text.trimmingCharacters(in: CharacterSet(charactersIn: "` "))
        return required.keys.sorted { $0.count > $1.count }.first { name in
            body.hasPrefix(name) && String(body.dropFirst(name.count)).trimmingCharacters(in: .whitespaces).first.map { $0 == "{" || $0 == "(" } == true
        }
    }
}

// MARK: Memory quality: pins, folder context, paths kept in sync

extension AppModel {
    /// Facts learned from a chat (via the memory update): only when learning is on and the user actually said them.
    func learnAboutUser(_ facts: [String], statedIn userText: String) {
        guard learnAboutMe else { return }
        let stated = facts.filter { GlobalMemory.isStated($0, in: userText) }
        guard !stated.isEmpty else { return }
        let before = globalMemory.aboutMe
        globalMemory.aboutMe = GlobalMemory.merge(before, stated)
        if globalMemory.aboutMe != before { globalMemory.save(); appendNotice("Updated what Obby knows about you.") }
    }
    /// Explicit additions ("Remember that I…", Settings → Add…). Sensitive facts are still refused.
    func addAboutMe(_ facts: [String]) {
        let before = globalMemory.aboutMe
        globalMemory.aboutMe = GlobalMemory.merge(before, facts)
        guard globalMemory.aboutMe != before else { appendNotice("That wasn’t saved (it may be sensitive or already known).", failed: true); return }
        globalMemory.save(); appendNotice("Added to About me.")
    }
    /// Pins a fact to this task's memory (never condensed away).
    func pin(_ text: String) {
        let fact = ChatMemory.clipped(text.trimmingCharacters(in: .whitespacesAndNewlines), limit: 300)
        guard !fact.isEmpty else { return }
        memory.pin(fact)
        appendNotice("Pinned to this task’s memory.")
        persistChat()
    }
    /// "Remember that…" / "Remember: …" at the start of a request becomes a pinned fact, decided by Obby, not the model.
    func pinFromRequest(_ prompt: String) {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = text.lowercased()
        for lead in ["please remember that ", "remember that ", "please remember: ", "remember: ", "please remember ", "remember "] where lowered.hasPrefix(lead) {
            let fact = String(text.dropFirst(lead.count)).trimmingCharacters(in: .whitespacesAndNewlines)
            guard fact.count > 3, !fact.hasSuffix("?") else { return } // "Remember when…?" is a question, not a fact.
            let lowerFact = fact.lowercased().replacingOccurrences(of: "’", with: "'")
            if ["i ", "i'm ", "i am ", "i've ", "i'd "].contains(where: lowerFact.hasPrefix) { // About the user, not the task.
                addAboutMe([fact.prefix(1).uppercased() + fact.dropFirst()])
                return
            }
            memory.pin(ChatMemory.clipped(fact.prefix(1).uppercased() + fact.dropFirst(), limit: 300))
            appendNotice("Pinned to this task’s memory.")
            return
        }
    }
    /// Everything memory contributes to a request: lasting preferences, folder context, then this task's memory with
    /// files that no longer exist marked as such.
    func memoryPacket() -> String {
        var missing: Set<String> = []
        if let vault {
            for path in memory.relevantFiles where ((try? vault.resolve(path)).map { !FileManager.default.fileExists(atPath: $0.path) } ?? true) { missing.insert(path) }
            memory.expireMissing(missing)
            missing.formIntersection(memory.relevantFiles)
        }
        return [globalMemory.packet, folderContextPacket(), memory.packet(missing: missing)].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
    func fileExists(_ path: String) -> Bool {
        guard let vault, let url = try? vault.resolve(path) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    func folderKey(_ folder: String) -> String { (vault?.root.path ?? "") + "|" + folder }
    func folderContext(_ folder: String) -> String { globalMemory.folders[folderKey(folder)] ?? "" }
    func setFolderContext(_ folder: String, _ text: String) {
        let value = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
        if value.isEmpty { globalMemory.folders.removeValue(forKey: folderKey(folder)) } else { globalMemory.folders[folderKey(folder)] = value }
        globalMemory.save()
    }
    /// Context for the folders of the open note and the task's main files (nearest first, at most two).
    func folderContextPacket() -> String {
        var folders: [String] = []
        for path in [note].compactMap({ $0 }) + Array(memory.relevantFiles.prefix(3)) {
            var parts = Array(path.split(separator: "/").map(String.init).dropLast())
            while !parts.isEmpty {
                let folder = parts.joined(separator: "/")
                if !folders.contains(folder) { folders.append(folder) }
                parts.removeLast()
            }
        }
        if !folders.contains("") { folders.append("") } // The notes folder itself.
        let found = folders.compactMap { folder -> String? in
            let text = folderContext(folder)
            return text.isEmpty ? nil : "Folder context (\(folder.isEmpty ? "whole notes folder" : folder)): \(text)"
        }
        return found.prefix(2).joined(separator: "\n")
    }
    /// Folder context editor (sidebar → Folder Context…). A note's own folder is used when a note is chosen.
    func editFolderContext(_ path: String) {
        guard let vault else { return }
        let isFolder = ((try? vault.resolve(path, allowRoot: true).resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory) == true
        let folder = isFolder ? path : (path as NSString).deletingLastPathComponent
        let alert = NSAlert()
        alert.messageText = "Folder context for \(folder.isEmpty ? "all notes" : folder)"
        alert.informativeText = "A short note the AI gets whenever it works on notes in this folder, for example “IB Biology HL, exam May 2027, I like flashcards”. It is kept on this Mac, not in your notes."
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 90))
        scroll.hasVerticalScroller = true; scroll.borderType = .bezelBorder
        let field = NSTextView(frame: scroll.bounds)
        field.isRichText = false; field.font = .systemFont(ofSize: 13); field.autoresizingMask = [.width]; field.string = folderContext(folder)
        scroll.documentView = field
        alert.accessoryView = scroll
        alert.addButton(withTitle: "Save"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        setFolderContext(folder, field.string)
    }
    /// A note or folder moved or renamed inside Obby: task memories (current and saved) and folder context follow it.
    func memoryDidMove(_ old: String, _ new: String) {
        func moved(_ path: String) -> String { path == old ? new : path.hasPrefix(old + "/") ? new + path.dropFirst(old.count) : path }
        memory.relevantFiles = memory.relevantFiles.map(moved)
        if let root = vault?.root.path {
            for var record in ChatStore.all(root: root) where record.id != memory.id && record.relevantFiles.contains(where: { moved($0) != $0 }) {
                record.relevantFiles = record.relevantFiles.map(moved); ChatStore.save(record)
            }
        }
        let prefix = folderKey(old)
        var changed = false
        for (key, value) in globalMemory.folders where key == prefix || key.hasPrefix(prefix + "/") {
            globalMemory.folders.removeValue(forKey: key)
            globalMemory.folders[folderKey(new) + key.dropFirst(prefix.count)] = value
            changed = true
        }
        if changed { globalMemory.save() }
        persistChat()
    }
    /// A note or folder moved to the Trash: memories stop referring to it.
    func memoryDidDelete(_ path: String) {
        func gone(_ item: String) -> Bool { item == path || item.hasPrefix(path + "/") }
        memory.relevantFiles.removeAll(where: gone)
        if let root = vault?.root.path {
            for var record in ChatStore.all(root: root) where record.id != memory.id && record.relevantFiles.contains(where: gone) {
                record.relevantFiles.removeAll(where: gone); ChatStore.save(record)
            }
        }
        let prefix = folderKey(path)
        let keys = globalMemory.folders.keys.filter { $0 == prefix || $0.hasPrefix(prefix + "/") }
        if !keys.isEmpty { for key in keys { globalMemory.folders.removeValue(forKey: key) }; globalMemory.save() }
        persistChat()
    }
    /// A saved task that worked on the open note (offered as "Continue: …" in an empty chat).
    var relatedTask: ChatRecord? {
        guard let note, chat.isEmpty else { return nil }
        return savedChats.first { $0.id != memory.id && $0.relevantFiles.contains(note) }
    }
    var relatedNotesEnabled: Bool { isLocalProvider ? relatedNotesLocal : relatedNotesCloud }
    /// Up to three related note excerpts from the in-memory index, within `allowance` tokens (the open note excluded).
    func relatedNotes(for prompt: String, allowance: Int) async -> [NoteSnippet] {
        let meaningful = prompt.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).filter { $0.count >= 3 && !ContextBudget.stopWords.contains(String($0)) && !["the", "and", "you", "are", "for", "can"].contains(String($0)) }
        guard let vault, meaningful.count >= 4, !ToolRouting.isSmallTalk(prompt) else { return [] } // Too short to search on.
        await noteIndex.rebuild(vault: vault) // Only changed files are re-read.
        var used = 0
        return await noteIndex.search(prompt, limit: 3, excluding: Set([note].compactMap { $0 })).filter { snippet in
            guard snippet.score >= 1.0 else { return false } // Weak matches add noise, not help.
            let size = ContextBudget.tokens(snippet.text) + 20
            guard used + size <= allowance else { return false }
            used += size; return true
        }
    }
}

/// Offers only the tools a request needs (small models choose far better from 3 tools than from 15, and call
/// tools they are offered even when nobody asked). Decided from the request's wording: changing tools only when the
/// wording asks for a change; read-only tools when nothing matches; no tools at all for small talk.
enum ToolRouting {
    /// Identity of a tool call for the repeat guard: its name and arguments (key order ignored).
    static func callKey(_ name: String, _ arguments: [String: Any]) -> String {
        let data = try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
        return name + (data.flatMap { String(data: $0, encoding: .utf8) } ?? "")
    }
    /// The reply when repeated failures stop a request: what was done and what wasn't.
    static func stopSummary(done: [String], notDone: [String]) -> String {
        "I stopped because several actions kept failing. " + (done.isEmpty ? "Nothing was changed." : "Done: " + done.joined(separator: " "))
            + (notDone.isEmpty ? "" : " Not done: " + notDone.joined(separator: " "))
    }
    static let reading: Set<String> = ["read_file", "read_section", "search_notes", "list_directory"]
    static let changing: Set<String> = ["write_file", "append_to_file", "replace_section", "append_to_section", "replace_text", "create_file", "create_directory", "move_path", "rename_path", "delete_path"]
    static let baseline: Set<String> = ["read_file", "read_section", "search_notes"]
    /// A greeting or pleasantry ("hi", "hello there", "how are you", "thanks") — never a task title. Narrower than
    /// isSmallTalk, so short real titles like "Cell biology" are kept.
    static func isGreeting(_ text: String) -> Bool {
        let words = text.lowercased().replacingOccurrences(of: "’", with: "'").split(whereSeparator: { !$0.isLetter }).map(String.init)
        let pleasantries: Set<String> = ["hi", "hello", "hey", "hiya", "yo", "sup", "there", "thanks", "thank", "you", "thx", "ok", "okay", "cool", "nice",
                                         "great", "good", "morning", "afternoon", "evening", "how", "are", "doing", "what", "whats", "what's", "s", "up",
                                         "bye", "goodbye", "obby", "test", "testing", "again", "all", "today", "u", "r"]
        return !words.isEmpty && words.count <= 5 && words.allSatisfy(pleasantries.contains)
    }
    /// The one classifier: conversation (no tools, no task memory), a question about the task's memory (memory, no
    /// tools), or work (full memory, routed tools).
    enum Kind { case chat, memoryQuestion, work }
    static let memoryPhrases = ["what were we doing", "what was i doing", "what were we working on", "what did i decide", "what did we decide",
                                "remind me", "what have we done", "what have i done", "what did we do", "where were we", "where did we leave",
                                "what's the plan", "what is the plan", "catch me up", "recap"]
    static func classify(_ prompt: String) -> Kind {
        let lowered = prompt.lowercased().replacingOccurrences(of: "’", with: "'")
        if memoryPhrases.contains(where: lowered.contains) { return .memoryQuestion }
        return isSmallTalk(prompt) ? .chat : .work
    }
    /// Words that point at notes or files; a short message without any of them (and no routing keywords) is small talk.
    static let noteWords = ["note", "notes", "file", "files", "folder", "folders", "md", "pdf", "attach", "attached", "attachment", "document",
                            "section", "heading", "summar", "flashcard", "quiz", "outline", "revision", "search", "find", "read", "open", "where", "which"]
    /// Greetings, thanks, "ok" and other short messages with no note or file words: sent with no tools at all.
    static func isSmallTalk(_ prompt: String) -> Bool {
        let lowered = prompt.lowercased()
        let words = lowered.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard words.count < 6, !lowered.contains(".md"), !lowered.contains("/") else { return false }
        let set = Set(words)
        let pointsAtNotes = noteWords.contains { key in set.contains(key) || (key.count >= 5 && set.contains { $0.hasPrefix(key) }) }
        return !pointsAtNotes && matched(prompt, hasAttachments: false).isEmpty
    }
    /// The tools for a request: an empty set means none (small talk).
    static func tools(for prompt: String, hasAttachments: Bool) -> Set<String> {
        if isSmallTalk(prompt) { return [] }
        return matched(prompt, hasAttachments: hasAttachments).union(baseline)
    }
    /// Tools asked for by the request's wording (reading tools included when the wording is about finding or reading).
    /// Multi-step requests ("make 5 notes … and then delete greeting.md") get every step's tools; if a step is unclear,
    /// create and edit tools are included rather than dropped.
    static func matched(_ prompt: String, hasAttachments: Bool) -> Set<String> {
        var chosen = matchedPart(prompt, hasAttachments: hasAttachments)
        let parts = prompt.lowercased()
            .replacingOccurrences(of: "(,|;|\\band then\\b|\\bthen\\b|\\balso\\b)", with: "\u{1F}", options: .regularExpression)
            .split(separator: "\u{1F}").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard parts.count > 1 else { return chosen }
        let found = parts.map { matchedPart($0, hasAttachments: hasAttachments) }
        guard found.contains(where: { !$0.isEmpty }) else { return chosen } // "hi, thanks": still small talk.
        for tools in found { chosen.formUnion(tools.isEmpty ? createTools.union(editTools) : tools) }
        return chosen
    }
    static let createTools: Set<String> = ["create_file", "create_directory"]
    static let editTools: Set<String> = ["append_to_file", "append_to_section", "replace_section", "replace_text", "write_file"]
    static func matchedPart(_ prompt: String, hasAttachments: Bool) -> Set<String> {
        let lowered = prompt.lowercased()
        let words = Set(lowered.split(whereSeparator: { !$0.isLetter }).map(String.init))
        func mentions(_ keys: [String]) -> Bool {
            keys.contains { key in key.contains(" ") ? lowered.contains(key) : words.contains(key) || (key.count >= 5 && words.contains { $0.hasPrefix(key) }) }
        }
        var chosen: Set<String> = []
        if mentions(["add", "append", "insert", "write", "edit", "update", "change", "rewrite", "replace", "fix", "correct", "put", "include", "expand", "shorten", "improve", "section", "paragraph", "heading", "reword", "format", "remove", "tidy"]) {
            chosen.formUnion(["append_to_file", "append_to_section", "replace_section", "replace_text", "write_file"])
        }
        if mentions(["create", "new note", "new folder", "make a note", "make a folder", "save", "draft", "start a note"]) { chosen.formUnion(createTools) }
        // A create verb with a note/file/folder word anywhere ("make 5 notes", "add two notes about cells").
        if !words.isDisjoint(with: ["create", "make", "add", "new", "write", "start", "draft", "save", "generate"]),
           !words.isDisjoint(with: ["note", "notes", "file", "files", "folder", "folders"]) { chosen.formUnion(createTools) }
        if mentions(["move", "rename", "organise", "organize", "sort", "folder", "archive", "file it", "put it in"]) { chosen.formUnion(["create_directory", "move_path", "rename_path", "list_directory"]) }
        if mentions(["delete", "trash", "get rid"]) { chosen.insert("delete_path") }
        if mentions(["attach", "attached", "attachment", "pdf", "document", "image", "photo", "screenshot", "csv", "scan", "picture"]) || (hasAttachments && mentions(["file", "paper", "reading", "article"])) {
            chosen.insert("read_attachment")
        }
        if mentions(["find", "search", "where", "which", "look", "list", "show", "notes", "note", "read", "summar", "explain", "what", "why", "how", "quiz", "flashcard", "compare", "about"]) {
            chosen.formUnion(reading)
        }
        return chosen
    }
    /// Ollama JSON-schema output for models without native tools: one action or one reply per message.
    static func actionSchema(_ names: [String]) -> [String: Any] {
        ["type": "object",
         "properties": ["action": ["type": "string", "enum": names.sorted() + ["reply"]], "arguments": ["type": "object"], "reply": ["type": "string"]],
         "required": ["action"]]
    }
    enum Action { case reply(String), call(ToolCall), unreadable }
    static func parseAction(_ text: String) -> Action {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let json = try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)) as? [String: Any],
              let action = json["action"] as? String else { return .unreadable }
        if action == "reply" { return .reply(json["reply"] as? String ?? "") }
        guard let needed = TextToolCall.required[action] else { return .unreadable }
        let arguments = ToolCall.arguments(json["arguments"])
        guard needed.allSatisfy({ arguments[$0] is String }) else { return .unreadable }
        return .call(ToolCall(id: "action-" + UUID().uuidString, name: action, arguments: arguments, raw: ["action": json]))
    }
}

