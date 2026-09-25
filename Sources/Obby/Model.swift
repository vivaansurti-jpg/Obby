import SwiftUI
import AppKit

@MainActor final class AppModel: ObservableObject {
    @Published var vault: Vault?
    @Published var tree: [Entry] = []
    @Published var selection: String?
    @Published var note: String? 
    @Published var text = "" { didSet { if !loading && text != oldValue { dirty = true; scheduleSave() } } }
    @Published var dirty = false
    @Published var status = ""
    @Published var error: String?
    @Published var saveConflict = false
    @Published var query = ""
    @Published var results: [Entry] = []
    @Published var chat: [ChatLine] = []
    @Published var showRawActions = UserDefaults.standard.bool(forKey: "showRawActions") {
        didSet { UserDefaults.standard.set(showRawActions, forKey: "showRawActions") }
    }
    @Published var models: [String] = []
    @Published var connected = false
    @Published var busy = false
    @Published var switchingModel = false
    @Published var loadedModels: Set<String> = []
    @Published var modelSettingsError: String?
    @Published var unloadPrevious = UserDefaults.standard.object(forKey: "unloadPrevious") as? Bool ?? true
    @Published var keepAlive = ModelKeepAlive(rawValue: UserDefaults.standard.string(forKey: "keepAlive") ?? "5m") ?? .fiveMinutes
    @Published var unloadOnQuit = UserDefaults.standard.object(forKey: "unloadOnQuit") as? Bool ?? true
    @Published var autoStartOllama = UserDefaults.standard.object(forKey: "autoStartOllama") as? Bool ?? true
    @Published var ollamaIssue: OllamaIssue?
    @Published var startingOllama = false
    var ollamaLaunch: Task<Bool, Never>?
    var usedOllamaModels: Set<String> = [] // Ollama models this Obby session sent chat requests to.
    var requestOverride: ((String, [String: Any]?) async throws -> [String: Any])?

    @Published var endpoint: String = UserDefaults.standard.string(forKey: "ollamaURL") ?? "http://localhost:11434"
    @Published var provider = ProviderKind.stored
    @Published var selectedModel: String = UserDefaults.standard.string(forKey: ProviderKind.stored.modelKey) ?? ""
    @Published var openAIBaseURL = UserDefaults.standard.string(forKey: "openAIBaseURL") ?? "https://api.openai.com/v1"
    @Published var openAITools = UserDefaults.standard.object(forKey: "openAITools") as? Bool ?? true
    @Published var toolsAvailable = true
    @Published var hasAPIKey = false
    var toolSupport: [String: Bool] = [:] // Session cache: provider/model -> native tool calling
    var apiKeys: [ProviderKind: String] = [:] // In-memory copy of Keychain values; never persisted elsewhere
    @Published var temperature = UserDefaults.standard.object(forKey: "temperature") as? Double ?? 0.3
    @Published var contextWindow = ContextWindow.stored
    /// First run only: no notes folder was ever chosen and setup was never completed or skipped.
    @Published var showOnboarding = !UserDefaults.standard.bool(forKey: "onboardingDone") && UserDefaults.standard.data(forKey: "bookmark") == nil
    @Published var contextUsage: (used: Int, window: Int)? // Last request's estimate, for the small indicator.
    @Published var contextCap: Int? // Max context the selected model reports (nil = unknown); shown in Settings
    var contextLimits: [String: Int] = [:] // provider/model -> reported max context (0 = unknown), cached per session
    /// The current chat's compact memory (summary, goal, decisions, files, actions, open questions). Belongs to the
    /// chat, not the model: switching model or provider keeps it; it is saved locally when remembering is on.
    @Published var memory = ChatRecord()
    @Published var savedChats: [ChatRecord] = [] // This notes folder's remembered chats, newest first (for the history menu).
    @Published var rememberChats = UserDefaults.standard.object(forKey: "rememberChats") as? Bool ?? true
    @Published var globalMemory = GlobalMemory.load() // Durable, explicitly stated preferences shared by every task.
    /// The AI panel's visibility (View → Show/Hide AI, Cmd+Shift+A). Hiding only removes the panel from view: the chat,
    /// its memory, the provider/model and any running request are untouched.
    @Published var showAI = UserDefaults.standard.object(forKey: "showAI") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showAI, forKey: "showAI") }
    }
    var aiDraft = "" // Unsent text in the AI prompt field, kept while the panel is hidden (not published: no redraws).
    var pendingUndo: UndoEdit? // Set by executeTool for the action line it is about to produce.
    var readThisRequest: Set<String> = [] // Notes the model has read (or was given) during the current AI request.
    var shrinkOverride: ((String) -> Bool)? // The checks answer the shrink question without a dialog.
    var guardWrites = false // True during an AI request: whole-note rewrites require the note to have been read first.
    let noteIndex = NoteIndex() // In-memory keyword index for "related notes" (never written to disk).
    @Published var relatedNotesLocal = UserDefaults.standard.object(forKey: "relatedNotesLocal") as? Bool ?? true
    @Published var relatedNotesCloud = UserDefaults.standard.object(forKey: "relatedNotesCloud") as? Bool ?? false
    var historySummary: String { get { memory.summary } set { memory.summary = newValue } }
    var loading = false
    var diskText = ""
    var saveTask: Task<Void, Never>?
    var aiTask: Task<Void, Never>?
    var timer: Timer?
    var sidebarDrag: SidebarDrag?
    var scopedURL: URL?
    var rootWatcher: DispatchSourceFileSystemObject?
    var chatSession = UUID()
    var history: [[String: Any]] = []
    var directoryResults: [String: (Date?, String)] = [:]
    init(restoreState: Bool = true) {
        guard restoreState else { return }
        restoreSavedFolder()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in Task { @MainActor in self?.refresh() } }
        Task { await connect() } // One read-only status check at launch; no repeating AI timers (the 1.5 s timer above only watches note files).
    }
    var folderTitle: String { "Obby" }
    func restoreSavedFolder() {
        guard let data = UserDefaults.standard.data(forKey: "bookmark") else { clearVault(); return }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI, .withoutMounting], bookmarkDataIsStale: &stale) else { clearVault(); return }
        // Bookmarks can follow moved folders. Only reopen the originally selected location.
        if let savedPath = UserDefaults.standard.string(forKey: "rootPath") {
            guard url.standardizedFileURL.resolvingSymlinksInPath().path == savedPath else { clearVault(); return }
        } else if stale { clearVault(); return }
        // Setups from before the notes-folder change (notes nested in `<folder>/Obby`) are forgotten; choose the folder again.
        guard UserDefaults.standard.bool(forKey: "rootIsNotesFolder") else { clearVault(); return }
        openVault(url)
    }
    @discardableResult func validateRoot() -> Bool {
        if vault?.rootExists == true { return true }
        if vault != nil { clearVault() } // The notes folder disappeared: forget it rather than recreate it.
        return false
    }
    func clearVault() {
        sidebarDrag = nil
        rootWatcher?.cancel(); rootWatcher = nil
        saveTask?.cancel(); saveTask = nil
        clearChat()
        vault = nil; tree = []; results = []; query = ""; selection = nil; note = nil
        loading = true; text = ""; loading = false
        diskText = ""; dirty = false; status = ""; error = nil; saveConflict = false
        scopedURL?.stopAccessingSecurityScopedResource(); scopedURL = nil
        for key in ["bookmark", "rootPath", "lastNote", "rootIsNotesFolder"] { UserDefaults.standard.removeObject(forKey: key) }
    }
    func watchRoot() {
        rootWatcher?.cancel(); rootWatcher = nil
        func watch(_ target: Vault) -> DispatchSourceFileSystemObject? {
            let descriptor = open(target.root.path, O_EVTONLY)
            guard descriptor >= 0 else { return nil }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.delete, .rename, .write, .attrib, .revoke], queue: .main)
            source.setEventHandler { [weak self] in
                Task { @MainActor [weak self] in self?.refresh() }
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            return source
        }
        if let vault { rootWatcher = watch(vault) }
    }
    func perform(_ action: () throws -> Void) { do { try action() } catch { self.error = error.localizedDescription } }
    func chooseFolder() {
        guard !busy else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true; panel.prompt = "Use This Folder"; panel.message = "Choose the folder that holds your notes (or an empty folder). Obby uses it as is."
        if panel.runModal() == .OK, let url = panel.url { openVault(url) }
    }
    /// Opens a notes folder: the folder itself is the notes root, and existing notes load as they are.
    func openVault(_ url: URL) {
        _ = validateRoot()
        guard save() else { return }
        scopedURL?.stopAccessingSecurityScopedResource()
        _ = url.startAccessingSecurityScopedResource(); scopedURL = url
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            clearVault(); return
        }
        let chosen = Vault(url)
        guard chosen.rootExists else { clearVault(); self.error = "That folder can’t be used for notes."; return }
        vault = chosen
        note = nil; selection = nil; loading = true; text = ""; loading = false; dirty = false
        clearChat()
        restoreLatestChat() // Continue this folder's most recent chat (when remembering is on).
        Task.detached(priority: .background) { chosen.removeStaleTemporaryFiles() } // Leftovers from an interrupted save or import, if any.
        if UserDefaults.standard.string(forKey: "rootPath") != chosen.root.path { UserDefaults.standard.removeObject(forKey: "lastNote") } // A different notes folder.
        UserDefaults.standard.set(chosen.root.path, forKey: "rootPath")
        UserDefaults.standard.set(true, forKey: "rootIsNotesFolder")
        watchRoot()
        if let bookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) { UserDefaults.standard.set(bookmark, forKey: "bookmark") }
        refresh()
        if let path = UserDefaults.standard.string(forKey: "lastNote"), (try? vault?.read(path)) != nil { openNote(path) }
    }
    func refresh() {
        guard validateRoot(), let vault else { return }
        do {
            let fresh = try vault.tree(); if fresh != tree { tree = fresh }
            if !query.isEmpty { results = try vault.search(query) }
            if let note, !dirty {
                if let freshText = try? vault.read(note) {
                    if freshText != diskText { loading = true; text = freshText; loading = false; diskText = freshText; status = "Updated from disk" }
                } else { self.note = nil; loading = true; text = ""; loading = false; status = "Note moved or removed outside Obby" }
            }
        } catch { status = error.localizedDescription }
    }
    func openNote(_ path: String) {
        guard path != note, save(), let vault else { return }
        perform {
            let content = try vault.read(path)
            loading = true; text = content; loading = false; diskText = content; note = path; dirty = false
            UserDefaults.standard.set(path, forKey: "lastNote")
        }
    }
    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { try? await Task.sleep(nanoseconds: 600_000_000); guard !Task.isCancelled else { return }; _ = save() }
    }
    @discardableResult func save(overwriteConflict: Bool = false) -> Bool {
        saveTask?.cancel()
        saveTask = nil
        guard validateRoot() else { return true }
        guard dirty, let note, let vault else { return true }
        do {
            let current = try vault.read(note)
            if current != diskText && !overwriteConflict {
                saveConflict = true
                throw ObbyError("This note changed outside Obby. Your unsaved edits remain in the editor. Overwrite the Markdown file with your edits, or reload its current contents.")
            }
            try vault.write(note, content: text)
            saveConflict = false
            diskText = text; dirty = false; return true
        } catch { self.error = error.localizedDescription; return false }
    }
    func reloadAfterConflict() {
        guard let note, let vault else { return }
        perform {
            let content = try vault.read(note)
            saveTask?.cancel(); saveTask = nil
            loading = true; text = content; loading = false
            diskText = content; dirty = false; saveConflict = false
        }
    }
    var folder: String {
        guard let selection else { return "" }
        if (try? vault?.resolve(selection).resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { return selection }
        return selection.split(separator: "/").dropLast().joined(separator: "/")
    }
    func input(_ title: String, value: String = "", help: String = "") -> String? {
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = help
        let field = NSTextField(string: value); field.frame = NSRect(x: 0, y: 0, width: 340, height: 24); alert.accessoryView = field
        alert.addButton(withTitle: "OK"); alert.addButton(withTitle: "Cancel"); alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }
    func create(directory: Bool) {
        guard let vault, let name = input(directory ? "New folder" : "New note", value: directory ? "Untitled" : "Untitled.md"), !name.isEmpty else { return }
        perform {
            let filename: String
            if directory {
                guard !name.contains("/"), name != ".", name != ".." else { throw ObbyError("Enter a name without slashes.") }
                filename = name
            } else {
                // A "/" typed in a note title becomes "／" in the filename; it never creates folders.
                let stem = Self.filenameStem(forTitle: name.lowercased().hasSuffix(".md") ? String(name.dropLast(3)) : name)
                try Self.validateNoteName(stem)
                filename = stem + ".md"
            }
            let path = folder.isEmpty ? filename : folder + "/" + filename
            if directory { try vault.mkdir(path) } else { try vault.write(path, content: "", create: true) }
            refresh(); selection = path; if !directory { openNote(path) }
        }
    }
    func relocate(_ path: String, rename: Bool) {
        guard save(), let vault else { return }
        let pieces = path.split(separator: "/"); let parent = pieces.dropLast().joined(separator: "/")
        guard let value = input(rename ? "Rename" : "Move to folder", value: rename ? String(pieces.last ?? "") : parent, help: rename ? "" : "Enter a folder path relative to your Obby folder. Leave empty for the root.") else { return }
        perform {
            var value = value
            if rename && path.lowercased().hasSuffix(".md") {
                // Notes: same title rules as inline rename ("/" becomes "／"); ".md" is optional in the field.
                let stem = Self.filenameStem(forTitle: value.lowercased().hasSuffix(".md") ? String(value.dropLast(3)) : value)
                try Self.validateNoteName(stem)
                value = stem + ".md"
            } else if rename && (value.isEmpty || value.contains("/")) { throw ObbyError("Enter a single name.") }
            let destination = rename ? (parent.isEmpty ? value : parent + "/" + value) : (value.isEmpty ? String(pieces.last!) : value + "/" + String(pieces.last!))
            try vault.move(path, destination); didMove(path, destination); refresh()
        }
    }
    func didMove(_ old: String, _ new: String) {
        if let note, note == old || note.hasPrefix(old + "/") { self.note = new + note.dropFirst(old.count); UserDefaults.standard.set(self.note, forKey: "lastNote") }
        selection = new
        memoryDidMove(old, new) // Task memories and folder context follow the note or folder.
    }
    /// Drop/paste/toolbar attachments for the open note: copies files into the note's Attachments folder and returns
    /// the Markdown to insert (`![name](…)` for images, `[name](…)` for documents), or nil if nothing was imported.
    func importAttachments(_ sources: [AttachmentSource]) -> String? {
        guard let vault, let note else { return nil }
        let folder = (note as NSString).deletingLastPathComponent
        var references: [String] = []
        for source in sources {
            do {
                let path = try vault.importAttachment(source, noteFolder: folder)
                let title = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
                references.append(Vault.isImage((path as NSString).pathExtension.lowercased()) ? "![\(title)](\(path))" : "[\(title)](\(path))")
            } catch { self.error = error.localizedDescription }
        }
        if !references.isEmpty { refresh() }
        return references.isEmpty ? nil : references.joined(separator: "\n\n")
    }
    /// The open note's folder ("" at the root). Attachment links are relative to it.
    var noteFolder: String { note.map { ($0 as NSString).deletingLastPathComponent } ?? "" }
    /// A link from the open note, resolved by the one attachment resolver (`Vault.resolveAttachment`).
    func resolveAttachment(_ link: String) throws -> (path: String, url: URL) {
        guard let vault else { throw ObbyError("Choose an Obby folder first.") }
        return try vault.resolveAttachment(link, inFolder: noteFolder)
    }
    /// Clicked link in the editor: a note opens in Obby; any other file opens in its default macOS app.
    func openLink(_ destination: String) {
        guard NoteLinks.target(destination) != nil else { return }
        do {
            let found = try resolveAttachment(destination)
            if found.url.pathExtension.lowercased() == "md" { openNote(found.path) } else { NSWorkspace.shared.open(found.url) }
        } catch { self.error = error.localizedDescription }
    }
    /// Inline title rename. Goes through the same Vault move validation as the sidebar and AI tools.
    @discardableResult func renameNote(_ path: String, to rawName: String) -> Bool {
        let name = Self.filenameStem(forTitle: rawName)
        let pieces = path.split(separator: "/").map(String.init)
        guard let vault, let current = pieces.last else { return false }
        let parent = pieces.dropLast().joined(separator: "/")
        let currentName = (current as NSString).deletingPathExtension
        if name == currentName { return true }
        do {
            try Self.validateNoteName(name)
            let destination = (parent.isEmpty ? "" : parent + "/") + name + ".md"
            guard save() else { return false }
            if name.lowercased() == currentName.lowercased() {
                // Case-only rename: step through a unique hidden name so case-insensitive volumes don't report a conflict.
                let temporary = (parent.isEmpty ? "" : parent + "/") + ".obby-rename-\(UUID().uuidString).md"
                try vault.move(path, temporary)
                do { try vault.move(temporary, destination) } catch { try? vault.move(temporary, path); throw error }
            } else {
                let target = try vault.resolve(destination)
                if FileManager.default.fileExists(atPath: target.path) {
                    throw ObbyError("A note named “\(name)” already exists in this folder. Nothing was renamed.")
                }
                try vault.move(path, destination)
            }
            directoryResults.removeAll()
            didMove(path, destination)
            refresh()
            return true
        } catch { self.error = error.localizedDescription; return false }
    }
    /// Note title → filename stem. "/" is the path separator, so a slash typed in a title is stored as the
    /// full-width slash "／" (U+FF0F), which looks the same in the title and sidebar and stays in the current folder.
    static func filenameStem(forTitle title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "\u{FF0F}")
    }
    static func validateNoteName(_ name: String) throws {
        guard !name.isEmpty else { throw ObbyError("A note title can’t be empty.") }
        guard !name.contains("/"), !name.contains(":"), !name.hasPrefix("."), name.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw ObbyError("Note titles can’t contain :, start with a dot, or include control characters.")
        }
        guard (name + ".md").utf8.count <= 255 else { throw ObbyError("That title is too long.") }
    }
    /// Selecting a folder (nil = root) closes the open note and makes that folder the creation destination.
    func selectFolder(_ path: String?) {
        guard note != nil else { selection = path; return }
        guard save() else { selection = note; return } // Keep unsaved edits visible until the save error is resolved.
        selection = path
        closeNote()
    }
    func closeNote() {
        saveTask?.cancel(); saveTask = nil
        note = nil; loading = true; text = ""; loading = false
        diskText = ""; dirty = false; saveConflict = false
        UserDefaults.standard.removeObject(forKey: "lastNote")
    }
    func confirmDelete(_ path: String) -> Bool {
        let alert = NSAlert(); alert.alertStyle = .warning; alert.messageText = "Move \(path) to Trash?"; alert.informativeText = "Folders and everything inside them will be moved to the Trash."; alert.addButton(withTitle: "Move to Trash"); alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
    func remove(_ path: String) { guard save(), confirmDelete(path) else { return }; perform { try vault?.delete(path); memoryDidDelete(path); refresh() } }
    /// Asked before the AI replaces a substantial note with something much shorter.
    func confirmShrink(_ path: String, from old: Int, to new: Int) -> Bool {
        if let shrinkOverride { return shrinkOverride(path) }
        let alert = NSAlert(); alert.alertStyle = .warning
        alert.messageText = "Replace \((path as NSString).lastPathComponent) with a much shorter version?"
        alert.informativeText = "The AI wants to replace this note (\(old) characters) with \(new) characters. You can undo it afterwards from the chat."
        alert.addButton(withTitle: "Replace"); alert.addButton(withTitle: "Keep Current Note")
        return alert.runModal() == .alertFirstButtonReturn
    }
    /// The Undo button on an AI edit: restores the note exactly as it was (or moves an AI-created note to the Trash).
    /// If the note changed after the AI edit, asks first so later work isn't lost silently.
    func undoAIEdit(_ line: ChatLine) {
        guard let edit = line.undo, let vault, !busy, save() else { return }
        let name = (edit.path as NSString).lastPathComponent
        do {
            let current = try? vault.read(edit.path)
            if current != edit.after {
                let alert = NSAlert(); alert.alertStyle = .warning
                alert.messageText = "\(name) changed after the AI edit."
                alert.informativeText = "Undoing replaces those later changes with the version from before the AI edit."
                alert.addButton(withTitle: "Undo Anyway"); alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
            }
            if let previous = edit.previous { try vault.write(edit.path, content: previous, create: current == nil) }
            else if current != nil { try vault.delete(edit.path) }
            if let index = chat.firstIndex(where: { $0.id == line.id }) { chat[index].undo = nil }
            appendNotice("Undid the AI change to \(name).")
            memory.remember(action: "Undid the AI change to \(name).")
            persistChat(); refresh()
        } catch { self.error = error.localizedDescription }
    }
    func search() { perform { results = try vault?.search(query) ?? [] } }
    func persistSettings() { UserDefaults.standard.set(unloadPrevious, forKey: "unloadPrevious"); UserDefaults.standard.set(unloadOnQuit, forKey: "unloadOnQuit"); UserDefaults.standard.set(autoStartOllama, forKey: "autoStartOllama"); UserDefaults.standard.set(keepAlive.rawValue, forKey: "keepAlive"); UserDefaults.standard.set(endpoint, forKey: "ollamaURL"); UserDefaults.standard.set(selectedModel, forKey: provider.modelKey); UserDefaults.standard.set(provider.rawValue, forKey: "aiProvider"); UserDefaults.standard.set(openAIBaseURL, forKey: "openAIBaseURL"); UserDefaults.standard.set(openAITools, forKey: "openAITools"); UserDefaults.standard.set(temperature, forKey: "temperature"); UserDefaults.standard.set(contextWindow.rawValue, forKey: "contextWindow"); UserDefaults.standard.set(rememberChats, forKey: "rememberChats") }
}
struct ChatLine: Identifiable { let id = UUID(); var role: String; var text: String; var rawAction: String? = nil; var unsuccessful = false; var notice = false; var undo: UndoEdit? = nil }
/// How to undo one AI change to a note (session only, kept in memory): the text before and after the change.
/// `previous == nil` means the AI created the note, so undo moves it to the Trash.
struct UndoEdit { let path: String; let previous: String?; let after: String }
