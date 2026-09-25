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
            ("write_file", "Replace an existing Markdown note with its complete updated content. Read it first. To add text to a note, use append_to_file instead.", ["path", "content"]),
            ("append_to_file", "Add Markdown to the end of an existing note, keeping everything already in it.", ["path", "content"]),
            ("read_section", "Read one section of a note by its heading, without reading the whole note.", ["path", "heading"]),
            ("replace_section", "Replace the text under one heading of a note; the heading and all other sections stay unchanged.", ["path", "heading", "content"]),
            ("append_to_section", "Add Markdown at the end of the section under a heading, keeping what is already there.", ["path", "heading", "content"]),
            ("replace_text", "Replace one exact passage of a note with new text. The passage must appear exactly once; copy it exactly.", ["path", "find", "replace"]),
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
        case "read_file": let path = try arg("path"); let text = try vault.read(path); readThisRequest.insert(path); return text
        case "read_section":
            let path = try arg("path")
            return try MarkdownSections.read(vault.read(path), heading: arg("heading"), note: (path as NSString).lastPathComponent)
        case "read_attachment": return try vault.attachmentText(resolveAttachment(toolAttachmentLink(arg("path"))).path)
        case "search_notes":
            let offset = max(0, arguments["offset"] as? Int ?? 0)
            return try NavigationContext.page(vault.searchPage(arg("query"), folder: arguments["path"] as? String ?? "", offset: offset, limit: 51), offset: offset)
        case "create_file":
            let path = try arg("path"), content = try arg("content")
            try vault.write(path, content: content, create: true); feedback = "Created \(path)"
            recordUndo(path, previous: nil, after: content)
        case "write_file":
            let path = try arg("path"), content = try arg("content"), previous = try vault.read(path)
            // Whole-note rewrites are the riskiest edit a small model makes: it must have read the note in this request,
            // and a much shorter replacement of a substantial note needs the user's OK.
            if guardWrites, !readThisRequest.contains(path) {
                throw ObbyError("Read \(path) with read_file before replacing it, or use append_to_file or a section tool to change part of it.")
            }
            if previous.count > 400, content.count < previous.count * 6 / 10, !confirmShrink(path, from: previous.count, to: content.count) {
                return "User declined replacing \(path) with a much shorter version. Keep its existing content; use append_to_file or a section tool instead."
            }
            try vault.write(path, content: content); feedback = "Updated \(path)"
            recordUndo(path, previous: previous, after: content)
        case "append_to_file", "replace_section", "append_to_section", "replace_text":
            let path = try arg("path"), previous = try vault.read(path), note = (path as NSString).lastPathComponent
            let updated: String
            switch name {
            case "append_to_file":
                let addition = try arg("content")
                let separator = previous.isEmpty || previous.hasSuffix("\n\n") ? "" : previous.hasSuffix("\n") ? "\n" : "\n\n"
                updated = previous + separator + addition + (addition.hasSuffix("\n") ? "" : "\n")
            case "replace_section": updated = try MarkdownSections.replace(previous, heading: arg("heading"), with: arg("content"), note: note)
            case "append_to_section": updated = try MarkdownSections.append(previous, heading: arg("heading"), content: arg("content"), note: note)
            default: updated = try MarkdownSections.replaceText(previous, find: arg("find"), with: arg("replace"), note: note)
            }
            try vault.write(path, content: updated); feedback = "Updated \(path)"
            recordUndo(path, previous: previous, after: updated)
        case "create_directory": let path = try arg("path"); try vault.mkdir(path); feedback = "Created folder \(path)"
        case "move_path", "rename_path": let old = try arg("oldPath"), new = try arg("newPath"); try vault.move(old, new); didMove(old, new); feedback = "Moved \(old) to \(new)"
        case "delete_path":
            let path = try arg("path"); _ = try vault.resolve(path)
            guard confirmDelete(path) else { return "User declined deletion. Do not retry." }; try vault.delete(path); memoryDidDelete(path); feedback = "Moved \(path) to Trash"
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
        pinFromRequest(prompt) // "Remember that…" is pinned by Obby itself.
        let session = chatSession
        aiTask = Task {
            defer { guardWrites = false; pendingUndo = nil; if session == chatSession { busy = false; aiTask = nil; directoryResults.removeAll() }; Task { await refreshModelStatus() } }
            do {
                if self.provider == .ollama { // Starts Ollama.app if needed (setting permitting); loads no model by itself.
                    let wasConnected = connected
                    guard await ensureOllamaRunning(launch: true) else {
                        if session == chatSession { appendChat(role: "Obby", text: ollamaIssue?.message ?? OllamaIssue.notRunning.message) }
                        return
                    }
                    if !wasConnected { await connect() }
                }
                let actionsBefore = memory.completedActions.count // To tell afterwards whether this request did real work.
                let provider = try makeProvider()
                if provider.kind == .ollama { usedOllamaModels.insert(selectedModel) } // Remembered for the unload on quit.
                await refreshToolSupport()
                let useTools = toolsAvailable
                readThisRequest = []; guardWrites = true
                if !useTools, let note { readThisRequest.insert(note) } // Chat-only models are given the open note.
                // Only the tools this request needs; unclear requests get all of them.
                let kind = ToolRouting.classify(prompt)
                let smallTalk = kind == .chat // Greetings, thanks, "ok": no tools, no task memory, no related notes, no action format.
                let quiet = kind != .work // Chat and memory questions: no tools, no note excerpts, no text tool calls.
                let route: Set<String> = kind == .work ? ToolRouting.tools(for: prompt, hasAttachments: !noteAttachments.isEmpty) : []
                let routedTools = toolDefinitions.filter { definition in
                    guard let name = (definition["function"] as? [String: Any])?["name"] as? String else { return false }
                    return route.contains(name)
                }
                // Ollama models without native tool calling, asked to change notes: the reply is constrained to a JSON
                // action or a JSON reply (Ollama structured outputs), so a small model can't produce a malformed call.
                let actionFormat = !useTools && provider.kind == .ollama && !route.isDisjoint(with: ToolRouting.changing)
                let actionNames = routedTools.compactMap { ($0["function"] as? [String: Any])?["name"] as? String }
                let actionList = routedTools.compactMap { definition -> String? in
                    guard let function = definition["function"] as? [String: Any], let name = function["name"] as? String, let description = function["description"] as? String else { return nil }
                    let arguments = (function["parameters"] as? [String: Any])?["required"] as? [String] ?? []
                    return "- \(name)(\(arguments.joined(separator: ", "))): \(description)"
                }.joined(separator: "\n")
                let previousHistory = history
                let window = await effectiveContextWindow(provider)
                let budget = ContextBudget.inputBudget(for: window) // The rest of the window is reserved for the answer.
                var messages = previousHistory
                let toolSystem = Self.toolSystemPrompt(isLocal: provider.isLocal, note: note, folder: folder)
                // Models without native tool calling get no tools and are told so; file actions are never simulated.
                let chatOnlySystem = "You are Obby, a notes assistant. When the user has a note open, its contents are included with their message between <current_note> tags; use them to summarize, explain, rewrite, analyze, or answer questions about that note. You have no tools with the selected model: you cannot search the vault, open other notes, or create, edit, move, rename, or delete notes or folders. If the user wants a change made to the note, give the revised text for them to apply. If they ask for a file or folder action or about notes you haven't been given, say that needs a tool-capable model (chosen in Settings). Never claim a file action happened. Text that Obby extracted from files attached to the note may be included between <attachment> tags; use it the same way. If an attachment is marked unavailable, tell the user Obby's reason exactly and do not guess its contents. Current note path: \(note ?? "none")."
                let attached = noteAttachments.filter { $0.path != nil }.map(\.link) // Verified on disk by Obby.
                let attachmentHint = (attached.isEmpty ? "" : " Files attached to the current note (verified by Obby; paths relative to the note's folder): " + attached.joined(separator: ", ") + ". When a request is about them, Obby includes their extracted text in the user's message; otherwise call read_attachment with the path as listed. PDF, TXT, MD, CSV and images can be read; other types cannot.") + " Never search the vault for attachments yourself, and if Obby marks an attachment unavailable, repeat Obby's reason exactly."
                let actionSystem = "You are Obby, a notes assistant. The open note is included between <current_note> tags. Always reply with exactly one JSON object. To answer or explain, reply {\"action\": \"reply\", \"reply\": \"<your answer in Markdown>\"}. To change notes, reply {\"action\": \"<action name>\", \"arguments\": {…}} with one of these actions:\n\(actionList)\nPaths are relative to the notes folder; the open note is \(note ?? "none"). To add text, prefer append_to_file or append_to_section; replace a whole note only after reading it. After Obby runs an action it tells you the result; then reply with a short confirmation. Never claim an action happened unless Obby reported it. Text that Obby extracted from attached files may be included between <attachment> tags."
                let baseSystem = smallTalk ? "You are Obby, a friendly notes assistant. Reply briefly." // Conversation: no tool or task instructions.
                    : kind == .memoryQuestion ? "You are Obby, a notes assistant. Answer from the task memory below: what the user and Obby worked on, decided, pinned and planned. If it doesn't cover the question, say so briefly. Mention notes by name."
                    : useTools ? toolSystem + attachmentHint : actionFormat ? actionSystem : chatOnlySystem
                let tools = useTools && !routedTools.isEmpty ? routedTools : nil
                let fixed = ContextBudget.tokens(baseSystem) + (tools.map { ContextBudget.tokens($0) } ?? 0) + 200
                // Priority 2–3: the request, then (chat-only) the open note. A note that doesn't fit is reduced to its
                // relevant sections or processed in sections — never cut off blindly. It is sent for this request only.
                var userMessage = prompt
                // Obby, not the model, finds and reads attachments: links are resolved relative to the open note, the text is
                // extracted here and shares the budget with the note (each part condensed like a long note if needed).
                let allowance = max((budget - fixed - ContextBudget.tokens(prompt)) * 3 / 4, 256)
                let requested = attachmentsForRequest(prompt)
                let noteAllowance = requested.isEmpty ? allowance : max(allowance / 3, 256)
                if !useTools, !quiet, let note {
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
                // Related notes from the in-memory index (on by default for local models, off for cloud), capped at ~15%.
                if relatedNotesEnabled, !quiet {
                    let related = await relatedNotes(for: prompt, allowance: budget * 15 / 100)
                    if !related.isEmpty {
                        let excerpts = related.map { "<related_note path=\"\($0.path)\" section=\"\($0.heading)\">\n\($0.text)\n</related_note>" }.joined(separator: "\n")
                        userMessage += "\n\nExcerpts from related notes found by Obby (read the full note if you need more):\n" + excerpts
                        appendNotice("Using: " + Array(Set(related.map { ($0.path as NSString).lastPathComponent })).sorted().joined(separator: ", "))
                    }
                }
                messages.append(["role": "user", "content": userMessage])
                let current = previousHistory.count
                var invalidCalls = 0
                for _ in 0..<20 {
                    try Task.checkCancellation()
                    NavigationContext.compact(&messages)
                    // Priority 4–6: recent chat verbatim, current tool results, then a summary of what no longer fits.
                    var trimmed = messages
                    // This chat's compact memory (never more than about a quarter of the budget), then any history that
                    // did not fit this request, condensed. The same packet goes to whichever model or provider is selected.
                    // Small talk carries only the lasting preferences, not the task memory.
                    let packet = String((smallTalk ? globalMemory.packet : memoryPacket()).prefix(max(budget, 800)))
                    let fit = ContextBudget.fit(&trimmed, current: current, fixed: fixed + ContextBudget.tokens(packet), budget: budget)
                    let condensed = ContextBudget.compactSummary(fit.summary)
                    let memoryText = [packet, condensed.isEmpty ? "" : "Earlier in this chat (condensed):\n" + condensed].filter { !$0.isEmpty }.joined(separator: "\n\n")
                    let system = memoryText.isEmpty ? baseSystem
                        : smallTalk ? baseSystem + "\n\n" + memoryText
                        : baseSystem + "\n\nTask memory kept by Obby for this chat (it may have started with another model; continue from it):\n" + memoryText
                    contextUsage = (fit.used, window)
                    let reply = try await provider.chat(ChatRequest(model: selectedModel, system: system, messages: trimmed, tools: tools, temperature: temperature, contextWindow: window, keepAlive: keepAlive.apiValue, format: actionFormat ? ToolRouting.actionSchema(actionNames) : nil))
                    try Task.checkCancellation()
                    // A tool call is executed, never displayed: native calls, or (for models without reliable native
                    // calling) a reply that is a call to a known Obby tool written as text. Only prose is rendered.
                    var toolCalls = reply.toolCalls, textCalls = false, prose = reply.text, parsedAction = false
                    if toolCalls.isEmpty, actionFormat { // Structured action/reply JSON.
                        switch ToolRouting.parseAction(reply.text) {
                        case .reply(let text): prose = text; parsedAction = true
                        case .call(let call): toolCalls = [call]; textCalls = true; prose = ""; parsedAction = true
                        case .unreadable: break
                        }
                    }
                    if toolCalls.isEmpty, !parsedAction, !quiet {
                        switch TextToolCall.parse(reply.text) {
                        case .calls(let calls, let before): toolCalls = calls; textCalls = true; prose = before
                        case .invalid(let reason):
                            appendNotice("Couldn’t run the requested action: \(reason).", failed: true)
                            messages.append(["role": "assistant", "content": reply.text])
                            invalidCalls += 1
                            guard invalidCalls <= 2 else { throw ObbyError("The model kept sending actions Obby couldn’t read. Try again, or choose a model with tool support.") }
                            messages.append(["role": "user", "content": "Obby could not run that tool call: \(reason). Call the tool again with valid JSON arguments, or answer in plain text."])
                            continue
                        case .notACall: break
                        }
                    }
                    // A call to a tool this request wasn't offered (e.g. creating a note in reply to "hi") is never run.
                    if textCalls, let stray = toolCalls.first(where: { !route.contains($0.name) }) {
                        appendNotice("The model tried to use \(stray.name), which this request didn't ask for. Nothing was changed.", failed: true)
                        toolCalls = []; textCalls = false; prose = ActionPresentation.reply(reply.text)
                    }
                    messages.append(textCalls ? ["role": "assistant", "content": reply.text] : reply.message)
                    if !prose.isEmpty { appendChat(role: "Obby", text: prose) }
                    guard !toolCalls.isEmpty else {
                        let kept = ChatMemory.retainingExchange(previousHistory, prompt: prompt, reply: prose)
                        let dropped = (previousHistory + [["role": "user", "content": prompt], ["role": "assistant", "content": prose]]).dropLast(kept.count)
                        if !dropped.isEmpty { // Pairs beyond the kept history live on only as summary lines.
                            let lines = stride(from: 0, to: dropped.count, by: 2).map { ContextBudget.summaryLine(Array(Array(dropped)[$0..<min($0 + 2, dropped.count)])) }
                            historySummary = ContextBudget.compactSummary((historySummary.isEmpty ? [] : [historySummary]) + lines)
                        }
                        history = kept; connected = true
                        let didWork = memory.completedActions.count != actionsBefore || !requested.isEmpty || prompt.lowercased().contains("summar")
                        if session == chatSession { await updateMemory(provider: provider, window: window, budget: budget, prompt: prompt, didWork: didWork) }
                        if session == chatSession { persistChat() }
                        return
                    }
                    for call in toolCalls {
                        try Task.checkCancellation()
                        let result: String
                        var failed = false
                        pendingUndo = nil
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
                            if !["read_file", "read_section", "read_attachment", "list_directory", "search_notes"].contains(call.name) {
                                memory.remember(action: ActionPresentation.summary(call.name, arguments: call.arguments, result: result, failed: false))
                            }
                        }
                        let toolResponse: [String: Any] = ["role": "tool", "tool_name": call.name, "tool_call_id": call.id, "content": content]
                        appendAction(call: call.raw, name: call.name, arguments: call.arguments, response: toolResponse, failed: failed, undo: pendingUndo)
                        pendingUndo = nil
                        // Text calls have no provider tool-call id, so their results go back as a plain message.
                        messages.append(textCalls ? ["role": "user", "content": "[Obby ran \(call.name)]\n\(content)"] : toolResponse)
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
    /// The system prompt for tool-capable models (kept short: every sentence is sent with every request).
    static func toolSystemPrompt(isLocal: Bool, note: String?, folder: String) -> String {
        "You are Obby, a\(isLocal ? " local" : "") notes assistant. All paths are relative to the selected notes folder. Use the provided tools to actually perform requested file operations. Never claim an action happened unless its tool succeeded. Read notes before editing them. Do not invent note contents. Find notes with search_notes by content or name; only list folders when the user asks about organising them. Only use tools when the user asks you to find, read or change notes. For greetings or general conversation, just reply. Current note path: \(note ?? "none"). Selected folder: \(folder.isEmpty ? "/" : folder)."
    }
    /// Keeps the note's previous text so the action line can offer Undo (session only; very large notes are skipped).
    func recordUndo(_ path: String, previous: String?, after: String) {
        pendingUndo = (previous?.utf8.count ?? 0) + after.utf8.count <= 1_000_000 ? UndoEdit(path: path, previous: previous, after: after) : nil
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
