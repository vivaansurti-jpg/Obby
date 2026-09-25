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
