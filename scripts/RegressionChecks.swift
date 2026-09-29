import Foundation
import AppKit

@MainActor enum RegressionChecks {
    static func run() async throws -> Int {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("obby-regressions-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let priorStore = ChatStore.rootOverride
        ChatStore.rootOverride = root.appendingPathComponent("memory")
        let defaults = UserDefaults.standard.dictionaryRepresentation()
        defer {
            ChatStore.rootOverride = priorStore
            for key in UserDefaults.standard.dictionaryRepresentation().keys where defaults[key] == nil { UserDefaults.standard.removeObject(forKey: key) }
            for (key, value) in defaults { UserDefaults.standard.set(value, forKey: key) }
            try? fm.removeItem(at: root)
        }
        var count = 0
        func check(_ value: Bool, _ label: String) { precondition(value, label); count += 1; print("PASS regression: \(label)") }
        func rejected(_ label: String, _ work: () throws -> Void) {
            do { try work(); preconditionFailure(label) } catch { count += 1; print("PASS regression: \(label)") }
        }
        for path in [".note.md.obby-tmp-123", ".obby-import-123", ".hidden.md", ".DS_Store", "nested/.hidden/note.md", "nested/.note.md.obby-tmp-123"] {
            check(!FolderEventDebounce.accepts("/notes/" + path, root: "/notes"), "watch filter ignores " + path)
        }
        check(FolderEventDebounce.accepts("/notes/nested/deeper/note.md", root: "/notes"), "watch filter accepts nested notes")
        check(!FolderEventDebounce.accepts("/notes-other/note.md", root: "/notes"), "watch filter excludes other roots")
        var debounce = FolderEventDebounce()
        var scheduled = 0
        for event in 0..<20 { if debounce.enqueue(now: Double(event) * 0.01) { scheduled += 1 } }
        check(scheduled == 1 && !debounce.fire(now: 0.29) && debounce.fire(now: 0.3) && !debounce.fire(now: 0.4), "twenty events coalesce into one refresh")
        check(debounce.enqueue(now: 0.4) && debounce.fire(now: 0.7), "debouncer accepts the next window")
        check(Vault.isRecentWrite(10, now: 10.9) && !Vault.isRecentWrite(10, now: 11), "self-save suppression lasts one second")
        let vault = Vault(root)
        let model = AppModel(restoreState: false)
        model.vault = vault; model.rememberChats = false; model.relatedNotesLocal = false
        model.provider = .ollama; model.selectedModel = "test"; model.streamReplies = false; model.connected = true
        model.planOverride = { _ in true }

        model.globalMemory = GlobalMemory()
        model.pinFromRequest("Remember that Biology is my priority.")
        model.memory.currentGoal = "ordinary task goal"
        model.memory.summary = "compressed active context"
        model.memory.decisions = ["task decision"]
        model.memory.keyPoints = ["temporary detail"]
        model.history = [["role": "user", "content": "ordinary conversation"]]
        let firstChat = model.memory.id
        _ = try model.executeTool("create_file", arguments: ["path": "History/Revision.md", "content": "PRIVATE NOTE CONTENT"])
        check(try ProcedureStore.load().last?.action == "create_file", "successful tool actions enter Procedural History")
        check(model.resetChat(), "New Chat completes durable writes before reset")
        check(model.memory.id != firstChat && model.history.isEmpty && model.chat.isEmpty && model.memory.packet.isEmpty, "ordinary context, compressed summary, decisions and recent messages are wiped")
        check(GlobalMemory.load().remembered.contains("Biology is my priority."), "explicit permanent information survives New Chat on disk")
        check(try ProcedureStore.load().count == 1, "Procedural History survives New Chat")
        check(!model.memoryPacket().contains("Created Revision.md") && model.procedurePacket(for: "Find notes about plants").isEmpty, "ordinary memory packet excludes Procedural History")
        check(model.procedurePacket(for: "What happened in that chat?").contains("Created Revision.md"), "explicit previous-chat question retrieves relevant actions")
        var memoryRequests: [String] = []
        model.requestOverride = { route, body in
            if route == "/api/show" { return ["capabilities": ["completion", "tools"]] }
            if route == "/api/chat" { memoryRequests.append(String(describing: body ?? [:])); return ["message": ["role": "assistant", "content": "Noted."]] }
            return [:]
        }
        model.send("Find notes about plants")
        while model.busy { try await Task.sleep(nanoseconds: 10_000_000) }
        check(!memoryRequests.isEmpty && memoryRequests.allSatisfy { !$0.contains("Procedural History retrieved") && !$0.contains("Created Revision.md") }, "actual ordinary AI requests contain zero procedural history")
        memoryRequests = []
        model.send("What happened in that chat?")
        while model.busy { try await Task.sleep(nanoseconds: 10_000_000) }
        check(memoryRequests.isEmpty && model.chat.last?.role == "Obby" && model.chat.last!.text.contains("Created Revision.md") && model.chat.last!.text.contains("From Obby's activity history"), "activity answer renders records directly without a model request")
        _ = model.resetChat()
        _ = try model.executeTool("move_path", arguments: ["oldPath": "History/Revision.md", "newPath": "History/Renamed.md"])
        check(try ProcedureStore.load().first?.paths == ["History/Renamed.md"], "procedural references follow a renamed note")
        let encodedHistory = try String(contentsOf: ProcedureStore.file, encoding: .utf8)
        check(!encodedHistory.contains("PRIVATE NOTE CONTENT") && !encodedHistory.contains("Find notes about plants") && !encodedHistory.contains("Noted.") && !encodedHistory.contains("content"), "procedural schema excludes note contents, full prompts, responses and raw payloads")
        check(model.clearProceduralHistory(), "procedural clearing succeeds independently")
        check(try ProcedureStore.load().isEmpty && vault.read("History/Renamed.md") == "PRIVATE NOTE CONTENT" && !GlobalMemory.load().remembered.isEmpty, "clearing history preserves notes and Permanent Memory")
        model.recordProcedure("read_file", arguments: ["path": "History/Renamed.md", "content": "NEVER STORE THIS"])
        check(model.clearPermanentMemory(), "permanent clearing succeeds independently")
        check(try ProcedureStore.load().count == 1 && GlobalMemory.load().packet.isEmpty, "clearing Permanent Memory preserves procedures")

        // A directory at the destination makes the atomic write fail without touching real user storage.
        try fm.createDirectory(at: GlobalMemory.file, withIntermediateDirectories: true)
        model.memory.summary = "preserve on failure"
        let blockedChat = model.memory.id
        model.pinFromRequest("Save this to memory: Use concise answers.")
        check(!model.resetChat() && model.memory.id == blockedChat && model.memory.summary == "preserve on failure" && !model.memory.pendingPermanentItems.isEmpty, "failed permanent promotion blocks reset before active context is erased")
        try fm.removeItem(at: GlobalMemory.file)
        check(model.resetChat() && GlobalMemory.load().remembered.contains("Use concise answers."), "retry stores pending Permanent Memory before resetting")
        try fm.removeItem(at: ProcedureStore.file)
        try fm.createDirectory(at: ProcedureStore.file, withIntermediateDirectories: true)
        model.memory.summary = "keep after history failure"
        model.recordProcedure("read_file", arguments: ["path": "History/Renamed.md"])
        check(!model.resetChat() && model.memory.summary == "keep after history failure" && GlobalMemory.load().remembered.contains("Use concise answers."), "history failure keeps active state and cannot corrupt Permanent Memory")
        try fm.removeItem(at: ProcedureStore.file)
        check(model.resetChat() && (try? ProcedureStore.load().count) == 1, "history retry finalizes pending actions")
        let seed = try ProcedureStore.load()[0]
        var repeated = seed; repeated.id = UUID()
        let duplicates = (0..<1500).map { _ -> ProcedureRecord in var value = repeated; value.id = UUID(); return value }
        let collapsed = ProcedureStore.merge(duplicates, into: [])
        check(collapsed.count == 1 && collapsed[0].repetitions == 1500, "repetitive actions are deduplicated")
        let distinct = (0..<1500).map { index -> ProcedureRecord in var value = seed; value.id = UUID(); value.paths = ["file-\(index).md"]; return value }
        check(ProcedureStore.merge(distinct, into: []).count == ProcedureStore.limit, "procedural retention is bounded for distinct actions")
        let otherRoot = ProcedureRecord(chatID: UUID(), notesRoot: "different root", action: "read_file", paths: ["private.md"], description: "Read private.md")
        check(ProcedureStore.retrieve([otherRoot], prompt: "What did Obby do yesterday?", root: root.path, current: model.memory.id).isEmpty, "retrieval does not cross notes folders")
        _ = model.clearProceduralHistory(); _ = model.clearPermanentMemory(); _ = model.resetChat()
        model.error = nil; model.requestOverride = nil

        // History recall uses deterministic dates and temporary roots, never the user's stored history.
        let now = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 29, hour: 18))!
        let start = Calendar.current.startOfDay(for: now)
        let chatID = UUID()
        let first = ProcedureRecord(timestamp: start.addingTimeInterval(9 * 3600 + 2 * 60), chatID: chatID, notesRoot: root.path, action: "create_file", paths: ["History/Renamed.md"], description: "Created First.md.", actor: "Obby", chatTitle: "Biology revision")
        let second = ProcedureRecord(timestamp: start.addingTimeInterval(14 * 3600 + 32 * 60), chatID: chatID, notesRoot: root.path, action: "rename_path", paths: ["History/Renamed.md"], description: "You renamed First.md to Second.md.", actor: "you", chatTitle: "Biology revision")
        var yesterday = first; yesterday.id = UUID(); yesterday.timestamp = Calendar.current.date(byAdding: .day, value: -1, to: first.timestamp)!
        for question in ["what did you do today", "what have you done", "what did you change", "what did Obby do yesterday", "summary of today", "this week", "earlier", "so far", "what have we been doing", "what have you worked on"] {
            check(ToolRouting.classify(question) == .memoryQuestion && !ProcedureStore.retrieve([first, yesterday], prompt: question, root: root.path, current: chatID, now: now).isEmpty, "history recalled for: " + question)
        }
        for greeting in ["hi", "thanks", "how are you", "how have you been doing?"] {
            check(ToolRouting.classify(greeting) != .memoryQuestion && model.procedurePacket(for: greeting).isEmpty && ProcedureStore.retrieve([first], prompt: greeting, root: root.path, current: chatID, now: now).isEmpty, "small talk never retrieves history: " + greeting)
        }
        check(!ProcedureStore.isActivityQuestion("Can you create a note about this enzyme?"), "work command stays out of direct history answers")
        check(!model.procedurePacket(for: "remind me").isEmpty, "all memory questions retrieve history, beyond activity patterns")
        let alias = root.appendingPathComponent("root-alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: root)
        check(ProcedureStore.retrieve([first], prompt: "what have you done", root: alias.path + "/./", current: chatID, now: now).count == 1, "history matches standardized symlink-equivalent roots")
        var legacy = first; legacy.notesRoot = root.appendingPathComponent("old-location").path
        check(ProcedureStore.retrieve([legacy], prompt: "what have you done", root: root.path, current: chatID, now: now).count == 1, "legacy unmatched root falls back to existing paths")
        legacy.paths = ["../outside.md"]
        check(ProcedureStore.retrieve([legacy], prompt: "what have you done", root: root.path, current: chatID, now: now).isEmpty, "legacy fallback rejects paths outside the vault")
        let answer = ProcedureStore.answer([second, first, first], prompt: "what did you do today", root: root.path, current: chatID, now: now)
        check(answer.contains("## Today") && answer.contains("### Biology revision") && answer.contains("09:02 · Obby: Created First.md.") && answer.contains("14:32 · You: renamed First.md to Second.md."), "direct answer has day, chat title, time and both actor labels")
        check(answer.range(of: "09:02")!.lowerBound < answer.range(of: "14:32")!.lowerBound && answer.components(separatedBy: "Created First.md.").count == 2, "direct answer sorts oldest first and deduplicates retries")
        let oldRecords = (1...7).map { index -> ProcedureRecord in
            var record = yesterday; record.id = UUID(); record.timestamp = yesterday.timestamp.addingTimeInterval(Double(index * 60)); record.description = "Action \(index)"; return record
        }
        let fallback = ProcedureStore.answer(oldRecords, prompt: "what did you do today", root: root.path, current: chatID, now: now)
        check(fallback.contains("Nothing recorded for today") && fallback.contains("2026-09-28") && !fallback.contains("Action 2") && fallback.contains("Action 3") && fallback.contains("Action 7"), "empty day lists five most recent dated actions")
        check(ProcedureStore.answer([], prompt: "what did you do today", root: root.path, current: chatID, now: now) == "Nothing recorded for today", "empty history is explicit")
        let encoded = try JSONEncoder().encode(first)
        var legacyObject = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]
        for key in ["actor", "chatTitle", "rootIdentity"] { legacyObject.removeValue(forKey: key) }
        let decodedLegacy = try JSONDecoder().decode(ProcedureRecord.self, from: JSONSerialization.data(withJSONObject: legacyObject))
        check(decodedLegacy.actorLabel == "Obby", "old procedural records decode with Obby as actor")
        var sameAction = first; sameAction.id = UUID(); sameAction.actor = "you"
        check(ProcedureStore.merge([sameAction], into: [first]).count == 2, "deduplication keeps different actors separate")

        let originalFolder = root.appendingPathComponent("original-vault")
        let movedFolder = root.appendingPathComponent("moved-vault")
        try fm.createDirectory(at: originalFolder, withIntermediateDirectories: true)
        var movedRecord = first; movedRecord.notesRoot = originalFolder.path; movedRecord.rootIdentity = ProcedureStore.identity(originalFolder)
        let originalIdentity = movedRecord.rootIdentity
        try fm.moveItem(at: originalFolder, to: movedFolder)
        let migrated = ProcedureStore.migrate([movedRecord, otherRoot], to: movedFolder.path, identity: ProcedureStore.identity(movedFolder))
        check(originalIdentity != nil && migrated[0].notesRoot == ProcedureStore.canonicalRoot(movedFolder.path) && migrated[1] == otherRoot, "same directory identity migrates moved roots and preserves unrelated records")
        var bookmarkRecord = movedRecord; bookmarkRecord.rootIdentity = nil
        check(ProcedureStore.migrate([bookmarkRecord], to: movedFolder.path, identity: ProcedureStore.identity(movedFolder), bookmarkRoot: originalFolder.path)[0].notesRoot == ProcedureStore.canonicalRoot(movedFolder.path), "resolved bookmark migrates legacy records without identity")
        check(ProcedureStore.migrate([movedRecord], to: root.path, identity: ProcedureStore.identity(root))[0] == movedRecord, "unrelated folder selection retains old records")

        let storedBeforeSidebar = try ProcedureStore.load()
        try ProcedureStore.write([movedRecord, otherRoot])
        let reopened = AppModel(restoreState: false)
        reopened.openVault(movedFolder)
        check(try ProcedureStore.load().first?.notesRoot == ProcedureStore.canonicalRoot(movedFolder.path), "opening moved notes folder persists identity-based migration")
        reopened.clearVault()
        try ProcedureStore.write(storedBeforeSidebar)
        model.memory.title = "Sidebar work"
        try model.createSidebarItem("User folder", directory: true)
        try model.createSidebarItem("User note.md", directory: false)
        check(model.renameNote("User note.md", to: "User renamed"), "user inline rename succeeds")
        let drag = model.beginSidebarDrag("User renamed.md")!
        check(model.moveSidebarItem(drag, to: "User folder"), "user sidebar move succeeds")
        model.deleteOverride = { _ in true }
        model.remove("User folder/User renamed.md")
        let userRecords = try ProcedureStore.load().filter { $0.actor == "you" }
        check(Set(userRecords.map(\.action)).isSuperset(of: ["create_directory", "create_file", "rename_path", "move_path", "delete_path"]) && userRecords.allSatisfy { $0.description.hasPrefix("You ") }, "user sidebar creates, rename, move and Trash are recorded as You")
        check(model.activityAnswer(for: "what did you do today").contains("You: renamed User note.md to User renamed.md."), "user actions appear labelled in direct answers")
        let countBeforeFailure = try ProcedureStore.load().count
        rejected("failed sidebar creation is rejected") { try model.createSidebarItem("User folder", directory: true) }
        check(try ProcedureStore.load().count == countBeforeFailure, "failed sidebar action creates no history")
        model.selectedModel = ""; model.connected = false; memoryRequests = []
        model.send("what have you done")
        check(!model.busy && memoryRequests.isEmpty && model.chat.last!.text.contains("From Obby's activity history") && model.chat.last!.text.contains("You:"), "offline activity answer needs no selected model")
        let longActivity = String(repeating: "09:02 · Obby: Created a note.\n", count: 250)
        model.appendChat(role: "Obby", text: longActivity, fromActivityHistory: true)
        model.appendChat(role: "You", text: "thanks")
        check(model.chat.dropLast().last?.text == longActivity, "latest activity answer keeps every line beyond the ordinary display cap")
        model.selectedModel = "test"; model.connected = true
        try ProcedureStore.write(storedBeforeSidebar)

        let sharingContainer = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800))
        let headerContainer = NSView(frame: NSRect(x: 250, y: 600, width: 650, height: 60))
        let shareAnchor = NSButton(frame: NSRect(x: 550, y: 10, width: 26, height: 24))
        shareAnchor.identifier = NoteShareButton.identifier
        sharingContainer.addSubview(headerContainer); headerContainer.addSubview(shareAnchor)
        check(NoteShareButton.anchor(in: sharingContainer) === shareAnchor, "File Share resolves the actual header button through nested view coordinates")
        check(NotePDF.render("# Plain note\n\nA note without attachments.", vault: vault, folder: "").string.contains("A note without attachments."), "PDF export renders Markdown without attachments")

        check(String(ChatMarkdown.paragraph("a\nb").characters) == "a\nb", "single paragraph newline renders literally")
        check(ChatMarkdown.blocks("\n\na\n\n\n\nb\n\n").count == 2, "blank lines collapse and outer blank lines disappear")
        if case .code(let code) = ChatMarkdown.blocks("```\na\n\n\n\nb\n```").first! {
            check(code == "a\n\n\n\nb", "fenced code retains every newline")
        } else { preconditionFailure("missing code block") }
        var remembered = ChatRecord()
        remembered.pinned = ["Pinned constraint"]
        remembered.decisions = ["Decision to preserve"]
        var longHistory: [[String: Any]] = [["role": "user", "content": "Use Early.md with 42 entries by May 2027. Don't rename the folder Archive.\n**Important phrase**\n" + String(repeating: "context ", count: 1500)]]
        longHistory += (0..<39).map { _ in ["role": "assistant", "content": String(repeating: "ordinary prose ", count: 1500)] }
        longHistory.append(["role": "user", "content": "Continue the note"])
        _ = ContextBudget.fit(&longHistory, current: 40, fixed: 0, budget: 2000, beforeDropping: { remembered.captureKeyPoints($0) })
        check(remembered.packet.contains("Early.md") && remembered.packet.contains("42") && remembered.packet.contains("Don't rename") && remembered.packet.contains("May 2027"), "forty long messages retain early filenames, dates, numbers and instructions in request memory")
        check(remembered.packet.contains("Pinned constraint") && remembered.packet.contains("Decision to preserve"), "protected memory survives history compression")
        remembered.captureKeyPoints([["role": "user", "content": "**Duplicate** **duplicate**"]])
        check(remembered.keyPoints.filter { $0.lowercased() == "duplicate" }.count == 1, "key points deduplicate case-insensitively")
        for index in 0..<40 { remembered.captureKeyPoints([["role": "assistant", "content": "**item \(index)**"]]) }
        check(remembered.keyPoints.count == 30 && remembered.keyPoints.last == "item 39" && !remembered.keyPoints.contains("item 0"), "key points retain newest thirty")
        check(ContextBudget.keyPoints([["role": "user", "content": "Hello there"], ["role": "assistant", "content": "Thanks, have a lovely day!"]]).isEmpty, "small talk creates no key points")
        check(try JSONDecoder().decode(ChatRecord.self, from: JSONEncoder().encode(remembered)).keyPoints == remembered.keyPoints, "key points persist")
        remembered.removeKeyPoint("item 39")
        remembered.captureKeyPoints([["role": "assistant", "content": "**item 39**"]])
        check(!remembered.keyPoints.contains("item 39"), "removed key points are not reintroduced by later compaction")
        try vault.mkdir("Nested/Deep")
        let attachmentSource = root.appendingPathComponent("source.pdf")
        try Data("sample document".utf8).write(to: attachmentSource)
        let imported = try vault.importAttachment(.file(attachmentSource), noteFolder: "Nested/Deep")
        check(imported == "../../Attachments/source.pdf", "nested import points to root attachments")
        check(try vault.importAttachment(.file(attachmentSource), noteFolder: "Nested/Deep") == "../../Attachments/source-2.pdf", "root imports are collision safe")
        try vault.write("Nested/Deep/import.md", content: "[paper](\(imported))", create: true)
        try vault.move("Nested/Deep/import.md", "import.md")
        let movedAttachment = NoteLinks.links(in: try vault.read("import.md")).first!.destination
        check(try vault.resolveAttachment(movedAttachment, inFolder: "").path == "Attachments/source.pdf", "moving a nested note preserves its root attachment")

        try vault.write("draft.md", content: "before", create: true)
        model.openNote("draft.md"); model.text = "unsaved changes"
        let movedRoot = root.appendingPathExtension("moved")
        try fm.moveItem(at: root, to: movedRoot)
        model.refresh()
        check(model.dirty && model.text == "unsaved changes" && !model.save(), "disconnect preserves the only unsaved copy and blocks quit/save")
        try fm.moveItem(at: movedRoot, to: root)
        check(try model.save() && vault.read("draft.md") == "unsaved changes", "reconnected folder can save the retained draft")
        model.closeNote()

        model.guardWrites = true
        _ = try model.executeTool("read_file", arguments: ["path": "draft.md"])
        try vault.write("draft.md", content: "newer user edits")
        rejected("stale AI replacement cannot overwrite newer edits") {
            _ = try model.executeTool("write_file", arguments: ["path": "draft.md", "content": "stale answer"])
        }
        _ = try model.executeTool("read_file", arguments: ["path": "draft.md"])
        _ = try model.executeTool("write_file", arguments: ["path": "draft.md", "content": "merged answer"])
        check(try vault.read("draft.md") == "merged answer", "rereading allows a fresh AI replacement")
        model.guardWrites = false

        model.requestOverride = { route, _ in
            if route == "/api/show" { return ["capabilities": ["tools"]] }
            if route == "/api/chat" {
                return ["message": ["role": "assistant", "tool_calls": [["function": ["name": "create_file", "arguments": ["path": "unrequested.md", "content": "bad"]]]]]]
            }
            return [:]
        }
        model.send("hi"); await model.aiTask?.value
        check(!fm.fileExists(atPath: root.appendingPathComponent("unrequested.md").path), "native calls obey the request allowlist")

        try vault.write("A/note.md", content: "[paper](Attachments/paper.txt)", create: true)
        try vault.write("B/note.md", content: "[paper](Attachments/paper.txt)", create: true)
        try vault.mkdir("A/Attachments"); try vault.mkdir("B/Attachments")
        try Data("document A".utf8).write(to: vault.resolve("A/Attachments/paper.txt"))
        try Data("document B".utf8).write(to: vault.resolve("B/Attachments/paper.txt"))
        model.openNote("A/note.md")
        var round = 0
        model.requestOverride = { route, _ in
            if route == "/api/show" { return ["capabilities": ["tools"]] }
            if route == "/api/chat" {
                round += 1
                if round == 1 {
                    model.openNote("B/note.md")
                    return ["message": ["role": "assistant", "tool_calls": [["function": ["name": "read_attachment", "arguments": ["path": "Attachments/paper.txt"]]]]]]
                }
                return ["message": ["role": "assistant", "content": "Done"]]
            }
            return [:]
        }
        model.clearChat(); model.send("Read the attachment"); await model.aiTask?.value
        check(model.chat.contains { $0.rawAction?.contains("document A") == true } && !model.chat.contains { $0.rawAction?.contains("document B") == true }, "navigation during a request cannot substitute another note's attachment")
        model.closeNote()

        try vault.write("linker.md", content: "[note](A/note.md#section)", create: true)
        try vault.move("A/note.md", "B/moved.md")
        check(NoteLinks.links(in: "`[example](B/moved.md)`\n~~~\n[example](B/moved.md)\n~~~").isEmpty, "code examples are not treated as links")
        let movedText = try vault.read("B/moved.md")
        let movedLink = NoteLinks.links(in: movedText)[0].destination
        check(try vault.resolveAttachment(movedLink, inFolder: "B").path == "A/Attachments/paper.txt", "moving a note retains its original attachment even with a name collision")
        check(try vault.read("linker.md") == "[note](B/moved.md#section)", "incoming note links and anchors follow a move")
        try vault.move("B", "C")
        check(try vault.read("linker.md") == "[note](C/moved.md#section)", "incoming links follow a folder rename")
        rejected("parent links cannot escape the vault") { _ = try vault.resolveAttachment("../../outside.txt", inFolder: "C") }
        try fm.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: root.deletingLastPathComponent())
        rejected("symlink plus parent traversal is blocked") { _ = try vault.linkPath("escape/../draft.md", inFolder: "") }

        let fenced = "# Real\n~~~~\n```\n# Fake\n* literal\n```\n~~~~\n# End\nend"
        check(MarkdownSections.headings(fenced.components(separatedBy: "\n")).map(\.title) == ["Real", "End"], "mixed code fences cannot create fake sections")
        let fencedSource = NSMutableAttributedString(string: fenced)
        MarkdownStyler().restyle(fencedSource)
        check(Data(fencedSource.string.utf8) == Data(fenced.utf8), "editor preserves mixed-fence code exactly")
        let longFence = "````\n```\n# Still code\n````\n# Real"
        check(MarkdownSections.headings(longFence.components(separatedBy: "\n")).map(\.title) == ["Real"], "shorter fences do not close a longer fence")
        check(MarkdownTable.table(in: ["~~~", "| a |", "| --- |", "~~~"], at: 1) == nil, "table commands ignore tilde-fenced code")

        model.clearChat()
        model.chat = [ChatLine(role: "Action", text: "edit", undo: UndoEdit(path: "draft.md", previous: "before", after: "merged answer"))]
        try vault.move("draft.md", "renamed.md"); model.didMove("draft.md", "renamed.md")
        check(model.chat.first?.undo?.path == "renamed.md", "undo follows a manual rename")
        try model.applyUndo(model.chat[0].undo!, vault: vault)
        check((try vault.read("renamed.md")) == "before" && !fm.fileExists(atPath: root.appendingPathComponent("draft.md").path), "undo restores renamed note without recreating old filename")

        let fresh = root.appendingPathComponent(".a.md.obby-tmp-\(UUID().uuidString)")
        let stale = root.appendingPathComponent(".obby-import-\(UUID().uuidString)")
        let unrelated = root.appendingPathComponent(".important.obby-tmp-not-a-uuid")
        for url in [fresh, stale, unrelated] { try Data("keep".utf8).write(to: url) }
        for url in [stale, unrelated] { try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-172_800)], ofItemAtPath: url.path) }
        vault.removeStaleTemporaryFiles()
        check(fm.fileExists(atPath: fresh.path) && !fm.fileExists(atPath: stale.path) && fm.fileExists(atPath: unrelated.path), "cleanup removes only old, recognized temporary files")

        model.query = "document"; model.search(); model.query = "merged"; model.search(); model.query = ""; model.search()
        try await Task.sleep(nanoseconds: 300_000_000)
        check(model.results.isEmpty && model.searchTask == nil, "clearing search cancels stale debounced results")
        model.refresh()
        while let refresh = model.refreshTask { await refresh.value }
        check(model.tree.contains { $0.path == "renamed.md" }, "background refresh publishes the latest tree")

        let blockedStore = root.appendingPathComponent("blocked-store")
        try Data("file, not directory".utf8).write(to: blockedStore)
        ChatStore.rootOverride = blockedStore
        var record = ChatRecord(); record.title = "test"; record.notesRoot = root.path
        check(!ChatStore.save(record) && !GlobalMemory().save(), "memory save errors are returned")
        await Task.yield(); await Task.yield()
        check(model.error?.contains("Couldn’t") == true, "memory failures reach the user-facing error state")
        ChatStore.rootOverride = root.appendingPathComponent("memory")
        check(ChatStore.save(record) && ChatStore.delete(record.id) && ChatStore.delete(record.id), "memory writes and idempotent deletions succeed after storage recovers")
        model.refreshTask?.cancel(); model.searchTask?.cancel(); model.clearChat()
        return count
    }
}
