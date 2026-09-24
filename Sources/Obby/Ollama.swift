import Foundation

extension AppModel {
    func localURL(_ route: String) throws -> URL {
        guard let base = URLComponents(string: endpoint), base.scheme == "http" || base.scheme == "https", let host = base.host, ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host.lowercased()), base.user == nil, base.password == nil, var parts = URLComponents(string: endpoint) else { throw ObbyError("Ollama must use a local address, such as http://localhost:11434.") }
        parts.path = route; parts.query = nil; parts.fragment = nil
        guard let url = parts.url else { throw ObbyError("Invalid Ollama URL") }; return url
    }
    func request(_ route: String, body: [String: Any]? = nil, timeout: TimeInterval? = nil) async throws -> [String: Any] {
        if let requestOverride { return try await requestOverride(route, body) }
        var request = URLRequest(url: try localURL(route)); request.timeoutInterval = timeout ?? (body == nil ? 5 : 300)
        if let body { request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.httpBody = try JSONSerialization.data(withJSONObject: body) }
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        let session = URLSession(configuration: config, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { throw ObbyError(String(data: data, encoding: .utf8) ?? "Ollama request failed") }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ObbyError("Unexpected Ollama response") }
        return json
    }
    /// Reads the provider's model list. `launch` (explicit user actions only) may start Ollama.app; app launch never does.
    func connect(launch: Bool = false) async {
        persistSettings()
        let kind = provider
        guard kind != .ollama else {
            guard await ensureOllamaRunning(launch: launch), provider == .ollama else {
                connected = false; loadedModels = []
                return
            }
            do {
                models = try await OllamaProvider(send: { try await self.request($0, body: $1) }).listModels()
                connected = true
                if !models.contains(selectedModel) { selectedModel = models.first ?? "" }
                persistSettings()
                await refreshModelStatus()
            } catch { connected = false; status = "Ollama offline: \(error.localizedDescription)" }
            await refreshToolSupport(); await refreshContextCap()
            return
        }
        hasAPIKey = Keychain.exists(kind.rawValue)
        do {
            let list = try await makeProvider().listModels()
            guard kind == provider else { return }
            models = list; connected = true; modelSettingsError = nil
            persistSettings()
        } catch {
            guard kind == provider else { return }
            connected = false; models = []
            modelSettingsError = describe(error)
            status = "\(kind.label): \(describe(error))"
        }
        await refreshToolSupport(); await refreshContextCap()
    }
    var toolDefinitions: [[String: Any]] {
        let specs: [(String, String, [String])] = [
            ("list_directory", "List only direct children of the specific folder needed; never recursive. Paths are relative to Obby. Use known paths directly. Optional offset pages through results.", ["path"]),
            ("read_file", "Read a specific relevant Markdown note. Use search_notes to locate unknown paths first; do not read unrelated notes.", ["path"]),
            ("read_attachment", "Read the text of a PDF, TXT, MD, CSV or image file attached to the current note (text in images and scanned pages is recognised by Obby). Pass the path exactly as listed by Obby or as written in the note's link (e.g. Attachments/Paper.pdf); Obby resolves it. Other file types cannot be read.", ["path"]),
            ("write_file", "Replace an existing Markdown note with its complete updated content. Read it first.", ["path", "content"]),
            ("create_file", "Create a new Markdown note. Parent folder must exist. \"/\" separates folders; if the note's title itself contains a slash, write it as \"／\" (U+FF0F) in the file name, e.g. Biology ／ Enzymes.md.", ["path", "content"]),
            ("create_directory", "Create a folder and missing parent folders.", ["path"]),
            ("rename_path", "Rename a note or folder to a relative destination path. Write a slash inside a note title as \"／\" (U+FF0F); \"/\" separates folders.", ["oldPath", "newPath"]),
            ("move_path", "Move a note or folder to a relative destination path.", ["oldPath", "newPath"]),
            ("delete_path", "Request user confirmation to move a note or folder to Trash.", ["path"]),
            ("search_notes", "Preferred way to find notes by name or content at any depth. Returns relative paths only, not file contents or a tree. Optional path scopes search to a folder; optional offset pages results.", ["query"])]
        return specs.map { name, description, args in
            var properties: [String: Any] = Dictionary(uniqueKeysWithValues: args.map { ($0, ["type": "string"]) })
            if NavigationContext.tools.contains(name) { properties["offset"] = ["type": "integer", "minimum": 0] }
            if name == "search_notes" { properties["path"] = ["type": "string", "description": "Optional relative folder scope"] }
            return ["type": "function", "function": ["name": name, "description": description, "parameters": ["type": "object", "properties": properties, "required": args]]]
        }
    }
    func executeTool(_ name: String, arguments: [String: Any]) throws -> String {
        guard let vault else { throw ObbyError("Choose an Obby folder first.") }
        func arg(_ key: String) throws -> String { guard let value = arguments[key] as? String else { throw ObbyError("Missing argument: \(key)") }; return value }
        guard save() else { throw ObbyError("Save failed. Resolve the note error first.") }
        var feedback: String
        switch name {
        case "list_directory":
            let path = try arg("path"), offset = max(0, arguments["offset"] as? Int ?? 0)
            let url = try vault.resolve(path, allowRoot: true)
            let date = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
            let key = url.path + "#" + String(offset)
            if let cached = directoryResults[key], cached.0 == date { return cached.1 }
            let result = NavigationContext.page(Array(try vault.entries(path).dropFirst(offset).prefix(51)), offset: offset)
            if directoryResults.count >= 8 { directoryResults.removeAll() }
            directoryResults[key] = (date, result)
            return result
        case "read_file": return try vault.read(arg("path"))
        case "read_attachment": return try vault.attachmentText(resolveAttachment(toolAttachmentLink(arg("path"))).path)
        case "search_notes":
            let offset = max(0, arguments["offset"] as? Int ?? 0)
            return try NavigationContext.page(vault.searchPage(arg("query"), folder: arguments["path"] as? String ?? "", offset: offset, limit: 51), offset: offset)
        case "write_file", "create_file":
            let path = try arg("path"); try vault.write(path, content: arg("content"), create: name == "create_file"); feedback = "\(name == "create_file" ? "Created" : "Updated") \(path)"
        case "create_directory": let path = try arg("path"); try vault.mkdir(path); feedback = "Created folder \(path)"
        case "move_path", "rename_path": let old = try arg("oldPath"), new = try arg("newPath"); try vault.move(old, new); didMove(old, new); feedback = "Moved \(old) to \(new)"
        case "delete_path":
            let path = try arg("path"); _ = try vault.resolve(path)
            guard confirmDelete(path) else { return "User declined deletion. Do not retry." }; try vault.delete(path); feedback = "Moved \(path) to Trash"
        default: throw ObbyError("Unknown tool: \(name)")
        }
        directoryResults.removeAll()
        refresh(); return feedback
    }
    func send(_ prompt: String) {
        guard !busy, !switchingModel, !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !selectedModel.isEmpty, vault != nil, save() else { return }
        directoryResults.removeAll()
        busy = true; appendChat(role: "You", text: prompt); persistSettings()
        // Chat memory: title and starting goal from the first request (compaction refreshes the goal), the open note as a relevant file.
        let firstLine = prompt.replacingOccurrences(of: "\n", with: " ")
        if memory.title.isEmpty { memory.title = String(firstLine.prefix(60)) }
        if memory.currentGoal.isEmpty { memory.currentGoal = String(firstLine.prefix(240)) }
        if let note { memory.remember(file: note) }
        let session = chatSession
        aiTask = Task {
            defer { if session == chatSession { busy = false; aiTask = nil; directoryResults.removeAll() }; Task { await refreshModelStatus() } }
            do {
                if self.provider == .ollama { // Starts Ollama.app if needed (setting permitting); loads no model by itself.
                    let wasConnected = connected
                    guard await ensureOllamaRunning(launch: true) else {
                        if session == chatSession { appendChat(role: "Obby", text: ollamaIssue?.message ?? OllamaIssue.notRunning.message) }
                        return
                    }
                    if !wasConnected { await connect() }
                }
                let provider = try makeProvider()
                if provider.kind == .ollama { usedOllamaModels.insert(selectedModel) } // Remembered for the unload on quit.
                await refreshToolSupport()
                let useTools = toolsAvailable
                let previousHistory = history
                let window = await effectiveContextWindow(provider)
                let budget = ContextBudget.inputBudget(for: window) // The rest of the window is reserved for the answer.
                var messages = previousHistory
                let toolSystem = "You are Obby, a\(provider.isLocal ? " local" : "") notes assistant. All paths are relative to the selected notes folder. Use the provided tools to actually perform requested file operations. Never claim an action happened unless its tool succeeded. Read notes before editing them. Do not invent note contents. For content or unknown filenames, prefer search_notes directly: its local search handles any nesting depth. If a relative path is known, read or operate on it directly without listing its ancestors. Use list_directory only for the specific folder currently needed. Never crawl all folders or request a full structure unless the user explicitly requests a recursive inventory. Do not repeat unchanged listings. Search results contain paths; read only notes relevant to this request. Page results only when needed, and narrow searches or scope them to a relevant folder. Earlier navigation results may be retired; retain the useful paths in your reasoning, not a copy of the tree. Current note path: \(note ?? "none"). Selected folder: \(folder.isEmpty ? "/" : folder). All notes are plain Markdown. No shell or external access is available."
                // Models without native tool calling get no tools and are told so; file actions are never simulated.
                let chatOnlySystem = "You are Obby, a notes assistant. When the user has a note open, its contents are included with their message between <current_note> tags; use them to summarize, explain, rewrite, analyze, or answer questions about that note. You have no tools with the selected model: you cannot search the vault, open other notes, or create, edit, move, rename, or delete notes or folders. If the user wants a change made to the note, give the revised text for them to apply. If they ask for a file or folder action or about notes you haven't been given, say that needs a tool-capable model (chosen in Settings). Never claim a file action happened. Text that Obby extracted from files attached to the note may be included between <attachment> tags; use it the same way. If an attachment is marked unavailable, tell the user Obby's reason exactly and do not guess its contents. Current note path: \(note ?? "none")."
                let attached = noteAttachments.filter { $0.path != nil }.map(\.link) // Verified on disk by Obby.
                let attachmentHint = (attached.isEmpty ? "" : " Files attached to the current note (verified by Obby; paths relative to the note's folder): " + attached.joined(separator: ", ") + ". When a request is about them, Obby includes their extracted text in the user's message; otherwise call read_attachment with the path as listed. PDF, TXT, MD, CSV and images can be read; other types cannot.") + " Never search the vault for attachments yourself, and if Obby marks an attachment unavailable, repeat Obby's reason exactly."
                let baseSystem = useTools ? toolSystem + attachmentHint : chatOnlySystem
                let tools = useTools ? toolDefinitions : nil
                let fixed = ContextBudget.tokens(baseSystem) + (tools.map { ContextBudget.tokens($0) } ?? 0) + 200
                // Priority 2–3: the request, then (chat-only) the open note. A note that doesn't fit is reduced to its
                // relevant sections or processed in sections — never cut off blindly. It is sent for this request only.
                var userMessage = prompt
                // Obby, not the model, finds and reads attachments: links are resolved relative to the open note, the text is
                // extracted here and shares the budget with the note (each part condensed like a long note if needed).
                let allowance = max((budget - fixed - ContextBudget.tokens(prompt)) * 3 / 4, 256)
                let requested = attachmentsForRequest(prompt)
                let noteAllowance = requested.isEmpty ? allowance : max(allowance / 3, 256)
                if !useTools, let note {
                    let fitted = try await condenseLongText(text, title: (note as NSString).lastPathComponent, request: prompt, provider: provider, window: window, allowance: noteAllowance)
                    userMessage = ChatMemory.withCurrentNote(prompt, path: note, text: fitted)
                }
                for item in requested {
                    let share = max((allowance - (useTools ? 0 : noteAllowance)) / requested.count, 256)
                    let extracted: String
                    do { extracted = try await readAttachment(item.link) }
                    catch is CancellationError { throw CancellationError() }
                    catch {
                        appendNotice(error.localizedDescription, failed: true)
                        userMessage += "\n\n<attachment name=\"\(item.name)\" status=\"unavailable\">Obby could not read this file: \(error.localizedDescription)</attachment>"
                        continue
                    }
                    appendNotice("Read \(item.name).")
                    let content = try await condenseLongText(extracted, title: item.name, request: prompt, provider: provider, window: window, allowance: share)
                    userMessage += "\n\n<attachment name=\"\(item.name)\" path=\"\(item.link)\">\n\(content)\n</attachment>"
                }
                if note != nil, requested.isEmpty, prompt.lowercased().contains("attach"), noteAttachments.isEmpty {
                    appendNotice("This note has no attachments.", failed: true)
                    userMessage += "\n\n[Obby: the current note has no attached files.]"
                }
                messages.append(["role": "user", "content": userMessage])
                let current = previousHistory.count
                for _ in 0..<20 {
                    try Task.checkCancellation()
                    NavigationContext.compact(&messages)
                    // Priority 4–6: recent chat verbatim, current tool results, then a summary of what no longer fits.
                    var trimmed = messages
                    // This chat's compact memory (never more than about a quarter of the budget), then any history that
                    // did not fit this request, condensed. The same packet goes to whichever model or provider is selected.
                    let packet = String(memory.packet.prefix(max(budget, 800)))
                    let fit = ContextBudget.fit(&trimmed, current: current, fixed: fixed + ContextBudget.tokens(packet), budget: budget)
                    let condensed = ContextBudget.compactSummary(fit.summary)
                    let memoryText = [packet, condensed.isEmpty ? "" : "Earlier in this chat (condensed):\n" + condensed].filter { !$0.isEmpty }.joined(separator: "\n\n")
                    let system = memoryText.isEmpty ? baseSystem : baseSystem + "\n\nTask memory kept by Obby for this chat (it may have started with another model; continue from it):\n" + memoryText
                    contextUsage = (fit.used, window)
                    let reply = try await provider.chat(ChatRequest(model: selectedModel, system: system, messages: trimmed, tools: tools, temperature: temperature, contextWindow: window, keepAlive: keepAlive.apiValue))
                    try Task.checkCancellation()
                    messages.append(reply.message)
                    if !reply.text.isEmpty { appendChat(role: "Obby", text: reply.text) }
                    guard !reply.toolCalls.isEmpty else {
                        let kept = ChatMemory.retainingExchange(previousHistory, prompt: prompt, reply: reply.text)
                        let dropped = (previousHistory + [["role": "user", "content": prompt], ["role": "assistant", "content": reply.text]]).dropLast(kept.count)
                        if !dropped.isEmpty { // Pairs beyond the kept history live on only as summary lines.
                            let lines = stride(from: 0, to: dropped.count, by: 2).map { ContextBudget.summaryLine(Array(Array(dropped)[$0..<min($0 + 2, dropped.count)])) }
                            historySummary = ContextBudget.compactSummary((historySummary.isEmpty ? [] : [historySummary]) + lines)
                        }
                        history = kept; connected = true
                        if session == chatSession { await compactMemoryIfNeeded(provider: provider, window: window, budget: budget) }
                        if session == chatSession { persistChat() }
                        return
                    }
                    for call in reply.toolCalls {
                        try Task.checkCancellation()
                        let result: String
                        var failed = false
                        do { // Same sandboxed Swift tools for every provider; attachment text is extracted off the main thread.
                            result = readsAttachment(call) ? try await readAttachment(toolAttachmentLink(call.arguments["path"] as? String ?? "")) : try executeTool(call.name, arguments: call.arguments)
                        }
                        catch { failed = true; result = "Error: \(error.localizedDescription)" }
                        var content = result
                        if !failed, call.name == "read_file" || readsAttachment(call), ContextBudget.tokens(result) > budget * 3 / 5 { // A long note or document read by a tool.
                            content = try await condenseLongText(result, title: call.arguments["path"] as? String ?? "note", request: prompt, provider: provider, window: window, allowance: budget * 3 / 5)
                        }
                        if !failed { // Remember files by path and completed changes; never their contents.
                            for key in ["path", "newPath"] { if let path = call.arguments[key] as? String, call.name != "search_notes", call.name != "list_directory" { memory.remember(file: readsAttachment(call) ? ((try? resolveAttachment(toolAttachmentLink(path)).path) ?? path) : path) } }
                            if !["read_file", "read_attachment", "list_directory", "search_notes"].contains(call.name) {
                                memory.remember(action: ActionPresentation.summary(call.name, arguments: call.arguments, result: result, failed: false))
                            }
                        }
                        let toolResponse: [String: Any] = ["role": "tool", "tool_name": call.name, "tool_call_id": call.id, "content": content]
                        appendAction(call: call.raw, name: call.name, arguments: call.arguments, response: toolResponse, failed: failed)
                        messages.append(toolResponse)
                    }
                }
                throw ObbyError("Stopped after 20 tool rounds. You can ask Obby to continue.")
            } catch {
                if session == chatSession { appendChat(role: "Obby", text: Task.isCancelled ? "Stopped." : describe(error)) }
            }
        }
    }
}
/// One attachment link from the open note, checked on disk by the resolver: `path` when found, `error` otherwise.
struct NoteAttachment: Equatable { let link: String; let name: String; let path: String?; let error: String? }

extension AppModel {
    /// Deterministic list of the open note's attachment links (files and images; links to other notes excluded),
    /// each resolved by Obby. The AI is only told about entries whose `path` is set (verified on disk).
    var noteAttachments: [NoteAttachment] {
        guard note != nil else { return [] }
        var seen = Set<String>()
        return NoteLinks.links(in: text).compactMap { link in
            guard let target = NoteLinks.target(link.destination), !seen.contains(target) else { return nil }
            let ext = (target as NSString).pathExtension.lowercased()
            guard ext != "md" || target.contains("Attachments/") else { return nil }
            seen.insert(target)
            let name = (target as NSString).lastPathComponent
            do { return NoteAttachment(link: target, name: name, path: try resolveAttachment(target).path, error: nil) }
            catch { return NoteAttachment(link: target, name: name, path: nil, error: error.localizedDescription) }
        }
    }
    /// A path from a tool call as a link relative to the open note. An Obby-relative path inside the note's folder
    /// (e.g. "School/Biology/Attachments/X.pdf") is accepted too; everything still goes through the one resolver.
    func toolAttachmentLink(_ raw: String) -> String {
        let value = NoteLinks.target(raw) ?? raw
        if !noteFolder.isEmpty, value.hasPrefix(noteFolder + "/"), (try? resolveAttachment(value)) == nil { return String(value.dropFirst(noteFolder.count + 1)) }
        return value
    }
    /// read_attachment, or read_file pointed at a non-Markdown file (treated as an attachment read, not an error).
    func readsAttachment(_ call: ToolCall) -> Bool {
        call.name == "read_attachment" || (call.name == "read_file" && !((call.arguments["path"] as? String ?? "").lowercased().hasSuffix(".md")))
    }
    /// Resolves (relative to the open note) and extracts a PDF/TXT/MD/CSV attachment off the main thread.
    /// Errors are Obby's own, e.g. "Couldn’t find Synapses.pdf in this note’s Attachments folder."
    func readAttachment(_ link: String) async throws -> String {
        guard let vault else { throw ObbyError("Choose an Obby folder first.") }
        let path = try resolveAttachment(link).path
        return try await Task.detached(priority: .userInitiated) { try vault.attachmentText(path) }.value
    }
    /// The attachments a request is about: ones named in it, or (when it mentions an attachment, PDF, document…) the
    /// readable ones. Missing files are included so Obby can report them.
    func attachmentsForRequest(_ prompt: String) -> [NoteAttachment] {
        let all = noteAttachments
        guard !all.isEmpty else { return [] }
        let lowered = prompt.lowercased()
        let named = all.filter { lowered.contains($0.name.lowercased()) || lowered.contains(($0.name as NSString).deletingPathExtension.lowercased()) }
        if !named.isEmpty { return named }
        let generic = ["attach", "pdf", "document", "file", "csv", "paper", "txt", "article", "reading", "spreadsheet", "image", "photo", "picture", "screenshot", "scan"]
        guard generic.contains(where: lowered.contains) else { return [] }
        let readable = all.filter { Vault.readableAttachmentExtensions.contains(($0.name as NSString).pathExtension.lowercased()) }
        // Prefer the kind the request names: PDFs for "PDF", images for "photo"/"screenshot"…, otherwise documents first.
        func ext(_ item: NoteAttachment) -> String { (item.name as NSString).pathExtension.lowercased() }
        let pdfs = readable.filter { ext($0) == "pdf" }, images = readable.filter { Vault.isImage(ext($0)) }, documents = readable.filter { !Vault.isImage(ext($0)) }
        let wantsImage = ["image", "photo", "picture", "screenshot", "scan"].contains(where: lowered.contains)
        let pool = lowered.contains("pdf") && !pdfs.isEmpty ? pdfs : wantsImage && !images.isEmpty ? images : !documents.isEmpty ? documents : readable
        return Array((pool.isEmpty ? all : pool).prefix(3))
    }
}
final class NoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
