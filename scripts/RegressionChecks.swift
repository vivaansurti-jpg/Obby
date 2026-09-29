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
        check(memoryRequests.contains { $0.contains("Procedural History retrieved") && $0.contains("Created Revision.md") }, "actual activity request receives retrieved records")
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
        check(RichMarkdown.serialize(RichMarkdown.parse(fenced)) == fenced, "editor preserves mixed-fence code exactly")
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
