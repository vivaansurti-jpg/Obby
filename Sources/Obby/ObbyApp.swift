import SwiftUI
import AppKit
import Speech
import AVFoundation
import UniformTypeIdentifiers

@main struct ObbyApp: App {
    @StateObject var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup("Obby") {
            ContentView().frame(minWidth: 920, minHeight: 580)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        SettingsGear()
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button { model.showAI.toggle() } label: { Image(systemName: "sidebar.right") }
                            .help("Show/Hide AI (⇧⌘A)").accessibilityLabel(model.showAI ? "Hide AI" : "Show AI")
                    }
                }
                .onAppear { delegate.model = model; NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true) }
                .sheet(isPresented: $model.showSettings) { SettingsSheet().environmentObject(model) }
                .environmentObject(model) // Last, so the toolbar (settings gear) and sheet can use it too.
        }
        .defaultSize(width: 1200, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Note") { model.create(directory: false) }.keyboardShortcut("n").disabled(model.vault == nil)
                Button("New Folder") { model.create(directory: true) }.keyboardShortcut("n", modifiers: [.command, .shift]).disabled(model.vault == nil)
                Button("Choose Notes Folder…") { model.chooseFolder() }.keyboardShortcut("o").disabled(model.busy)
            }
            CommandGroup(replacing: .appSettings) { Button("Settings…") { model.showSettings = true }.keyboardShortcut(",") }
            CommandGroup(replacing: .saveItem) {
                Button("Save") { model.save() }.keyboardShortcut("s")
                Button("Save Recovery Copy…") { model.saveRecoveryCopy() }.disabled(!model.dirty)
            }
            CommandGroup(after: .sidebar) {
                Button(model.showAI ? "Hide AI" : "Show AI") { model.showAI.toggle() }.keyboardShortcut("a", modifiers: [.command, .shift])
                Divider()
                // Editor text size only (not the sidebar, the AI panel, or saved files).
                Button("Bigger") { model.editorFontSize += 1 }.keyboardShortcut("+").disabled(model.editorFontSize >= 28)
                Button("Smaller") { model.editorFontSize -= 1 }.keyboardShortcut("-").disabled(model.editorFontSize <= 11)
                Button("Actual Size") { model.editorFontSize = RichMarkdown.defaultFontSize }.keyboardShortcut("0")
            }
            CommandGroup(after: .textEditing) { Button("Find in Notes") { NotificationCenter.default.post(name: .init("ObbyFind"), object: nil) }.keyboardShortcut("f") }
        }
    }
}
/// Settings as a sheet attached to the Obby window; Done or Escape returns straight to Obby.
struct SettingsSheet: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            SettingsView()
            Divider()
            HStack {
                Spacer()
                // Escape also closes; Return is left to the text fields (API key, base URL…).
                Button("Done") { model.showSettings = false }.keyboardShortcut(.cancelAction)
            }.padding(12)
        }
        // One fixed size for every tab, small enough to stay inside the main window (minimum 920 × 580).
        .frame(width: 600, height: 540)
    }
}
/// Reads the file URLs of a drop; only Markdown files are accepted.
enum MarkdownDrop {
    static func load(_ providers: [NSItemProvider], _ done: @escaping ([URL]) -> Void) -> Bool {
        let items = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !items.isEmpty else { return false }
        var urls: [URL] = []
        let group = DispatchGroup()
        for item in items {
            group.enter()
            item.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { value, _ in
                if let data = value as? Data, let url = URL(dataRepresentation: data, relativeTo: nil) { DispatchQueue.main.async { urls.append(url) } }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let markdown = urls.filter { ["md", "markdown"].contains($0.pathExtension.lowercased()) }
            if !markdown.isEmpty { done(markdown) }
        }
        return true
    }
}
struct SettingsGear: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Button { model.showSettings = true } label: { Image(systemName: "gearshape") }
        .help("Settings (⌘,)")
        .accessibilityLabel("Settings")
    }
}

/// Replies to a deferred termination exactly once (unload finished or the time limit passed, whichever is first).
final class QuitReply {
    private var done = false
    func finish() { guard !done else { return }; done = true; NSApp.reply(toApplicationShouldTerminate: true) }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            guard let model else { return .terminateNow }
            if model.save() == false { return .terminateCancel }
            model.persistChat() // Saved only when "Remember AI tasks between launches" is on.
            model.stopStatusTimers() // No status checks keep running once Obby quits.
            model.clearChat()
            guard model.needsUnloadOnQuit else { return .terminateNow }
            // Unload the active Ollama model once, then quit. Never hold shutdown for more than ~3 seconds.
            let once = QuitReply()
            Task { @MainActor in await model.unloadForQuit(); once.finish() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { once.finish() }
            return .terminateLater
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @StateObject var bridge = EditorBridge()
    @FocusState var searchFocused: Bool
    @State private var showTableSheet = false
    @State private var tableColumns = 3
    @State private var tableRows = 3
    var body: some View {
        Group {
            if model.showOnboarding {
                OnboardingView()
            } else if model.vault == nil {
                VStack(spacing: 18) { Image(systemName: "folder").font(.system(size: 44)).foregroundStyle(.secondary); Text("Choose your notes folder").font(.title2); Text("Choose the folder that holds your notes, or an empty folder.").foregroundStyle(.secondary); Button("Choose Folder…") { model.chooseFolder() }.keyboardShortcut(.defaultAction) }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    sidebar.frame(minWidth: 180, idealWidth: 220, maxWidth: 400)
                        .onDrop(of: [.fileURL], isTargeted: nil) { MarkdownDrop.load($0) { model.importNotes($0) } }
                    VStack(spacing: 0) {
                        if let note = model.note {
                            HStack { NoteTitleField(path: note); Spacer() }.padding(.horizontal).padding(.vertical, 20)
                            HStack(spacing: 12) {
                                Button { bridge.format(.bold) } label: { Image(systemName: "bold") }.help("Bold").keyboardShortcut("b")
                                Button { bridge.format(.italic) } label: { Image(systemName: "italic") }.help("Italic").keyboardShortcut("i")
                                Menu("Text") {
                                    Button("Underline") { bridge.format(.underline) }.keyboardShortcut("u")
                                    Divider()
                                    ForEach([Format.heading, .heading2, .heading3, .size], id: \.self) { style in Button(style.rawValue) { bridge.format(style) } }
                                    Divider()
                                    Button("Insert Table…") { showTableSheet = true }
                                    Button("Add Row") { bridge.addTableRow() }.disabled(!bridge.cursorInTable)
                                    Button("Add Column") { bridge.addTableColumn() }.disabled(!bridge.cursorInTable)
                                }.fixedSize()
                                Menu("List") {
                                    Button("Bullets") { bridge.format(.bullet) }
                                    Button("Numbers") { bridge.format(.numbered) }
                                    Button("Checklist") { bridge.format(.checkbox) }
                                    Button("Mark done") { bridge.format(.checked) }
                                }.fixedSize()
                                Menu("Insert") {
                                    Button("Image…") { bridge.insertImage() }
                                    Button("Document…") { bridge.attachDocument() }
                                    Button("Table…") { showTableSheet = true }
                                }.fixedSize().disabled(model.note == nil)
                                .sheet(isPresented: $showTableSheet) {
                                    VStack(alignment: .leading, spacing: 12) {
                                        Text("Insert Table").font(.headline)
                                        Stepper("Columns: \(tableColumns)", value: $tableColumns, in: 1...10)
                                        Stepper("Rows: \(tableRows)", value: $tableRows, in: 1...30)
                                        HStack {
                                            Spacer()
                                            Button("Cancel") { showTableSheet = false }.keyboardShortcut(.cancelAction)
                                            Button("Insert") { showTableSheet = false; bridge.insertTable(columns: tableColumns, rows: tableRows) }.keyboardShortcut(.defaultAction)
                                        }
                                    }.padding(20).frame(width: 260)
                                }
                                Spacer()
                            }.buttonStyle(.borderless).padding(.horizontal).padding(.bottom, 10)
                            Divider()
                            MarkdownEditor(text: $model.text, bridge: bridge, importAttachments: { model.importAttachments($0) }, openLink: { model.openLink($0) }).id(note)
                                .onReceive(NotificationCenter.default.publisher(for: .init("ObbyEditorFontSize"))) { _ in bridge.applyFontSize() }
                            if !model.backlinks.isEmpty { // Notes that link here; click to open.
                                Divider()
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 10) {
                                        Label("Linked from", systemImage: "link").foregroundStyle(.secondary)
                                        ForEach(model.backlinks, id: \.self) { path in
                                            Button(((path as NSString).lastPathComponent as NSString).deletingPathExtension) { model.openNote(path) }
                                                .buttonStyle(.link).help(path)
                                        }
                                    }.font(.caption).padding(.horizontal, 28).padding(.vertical, 6)
                                }
                            }
                        } else {
                            // Folder selected (or nothing/root): neutral state; nothing is created until New Note.
                            VStack(spacing: 8) {
                                Text(model.folder.isEmpty ? "Obby" : (model.folder.split(separator: "/").last.map(String.init) ?? "Obby")).font(.title2)
                                Text("No note selected").foregroundStyle(.secondary)
                                Button("New Note") { model.create(directory: false) }.padding(.top, 6)
                                Text("Or drop Markdown files here to add them.").font(.caption).foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                            .onDrop(of: [.fileURL], isTargeted: nil) { MarkdownDrop.load($0) { model.importNotes($0) } }
                        }
                        Divider(); HStack { Text(model.status).lineLimit(2); Spacer() }.font(.caption).foregroundStyle(.secondary).padding(8)
                    }.frame(minWidth: 380, idealWidth: 650, maxWidth: .infinity)
                    if model.showAI { // Hidden = not in the view tree at all, so it does no rendering or refresh work.
                        AIView().frame(minWidth: 260, idealWidth: 300, maxWidth: 500)
                    }
                }
            }
        }
        .background(WindowCloseGuard(model: model))
        .alert("Obby", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            if model.saveConflict {
                Button("Overwrite Note") { model.error = nil; model.save(overwriteConflict: true) }
                Button("Reload from Disk", role: .destructive) { model.error = nil; model.reloadAfterConflict() }
                Button("Keep Editing", role: .cancel) { model.error = nil }
            } else { Button("OK") { model.error = nil } }
        } message: { Text(model.error ?? "") }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in model.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: .init("ObbyFind"))) { _ in searchFocused = true }
    }
    var sidebar: some View {
        VStack(spacing: 0) {
            HStack { Spacer(); Menu { Button("New Note") { model.create(directory: false) }; Button("New Folder") { model.create(directory: true) }; Divider(); Button("Choose Notes Folder…") { model.chooseFolder() }.disabled(model.busy) } label: { Image(systemName: "plus") }.menuStyle(.borderlessButton).fixedSize().help("New note or folder") }.padding()
            TextField("Search notes", text: $model.query).textFieldStyle(.roundedBorder).focused($searchFocused).padding(.horizontal).padding(.bottom, 8).onChange(of: model.query) { _ in model.search() }
            NativeFileSidebar(model: model)
        }
    }
}

// Finder-style inline rename: click the title, Enter or click away commits, Escape cancels.
struct NoteTitleField: View {
    @EnvironmentObject var model: AppModel
    let path: String
    @State private var editing = false
    @State private var draft = ""
    @State private var editingPath: String?
    var title: String { ((path.split(separator: "/").last.map(String.init) ?? "") as NSString).deletingPathExtension }
    var body: some View {
        Group {
            if editing {
                InlineTitleEditor(text: $draft, onCommit: commit, onCancel: cancel)
            } else {
                // A tap gesture (not a Button, which reclaims focus from the new field); the accessibility action lets VoiceOver rename too.
                Text(title).font(.headline).lineLimit(1)
                    .contentShape(Rectangle())
                    .onTapGesture { begin() }
                    .help("Click to rename")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Note title: \(title)")
                    .accessibilityHint("Rename this note")
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction { begin() }
            }
        }
        // If another note opens mid-edit, commit against the note that was being renamed.
        .onChange(of: path) { _ in if editing { commit() } }
    }
    func begin() {
        editingPath = path; draft = title; editing = true
    }
    func cancel() { editing = false; editingPath = nil; draft = "" }
    func commit() {
        guard editing, let target = editingPath else { return }
        editing = false; editingPath = nil
        model.renameNote(target, to: draft)
    }
}

final class AutoFocusTextField: NSTextField {
    private var focused = false
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window, !focused else { return }
        focused = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            window.makeFirstResponder(self)
            self.currentEditor()?.selectAll(nil)
        }
    }
}

// Native field so Escape (cancelOperation) is caught reliably; ending editing (Enter or focus loss) commits.
struct InlineTitleEditor: NSViewRepresentable {
    @Binding var text: String
    var onCommit: () -> Void
    var onCancel: () -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSTextField {
        let field = AutoFocusTextField(string: text)
        field.isBordered = false; field.drawsBackground = false; field.focusRingType = .none
        field.font = .preferredFont(forTextStyle: .headline)
        field.usesSingleLineMode = true; field.lineBreakMode = .byTruncatingTail; field.cell?.isScrollable = true
        field.delegate = context.coordinator
        field.setAccessibilityLabel("Note title")
        // Focus is taken in viewDidMoveToWindow; re-check once the click that started editing has finished.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak field] in
            guard let field else { return }
            if field.currentEditor() == nil { field.window?.makeFirstResponder(field) }
            field.currentEditor()?.selectAll(nil)
        }
        // Escape can be swallowed before it reaches the field editor, so watch for it while this field is editing.
        let coordinator = context.coordinator
        coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak field] event in
            guard event.keyCode == 53, let field, field.currentEditor() != nil, !coordinator.finished else { return event }
            coordinator.finished = true
            coordinator.parent.onCancel()
            return nil
        }
        return field
    }
    func updateNSView(_ field: NSTextField, context: Context) { context.coordinator.parent = self }
    static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) {
        if let monitor = coordinator.monitor { NSEvent.removeMonitor(monitor); coordinator.monitor = nil }
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: InlineTitleEditor
        var finished = false
        var monitor: Any?
        init(_ parent: InlineTitleEditor) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSTextField { parent.text = field.stringValue }
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            finished = true; parent.onCancel(); return true
        }
        func controlTextDidEndEditing(_ notification: Notification) {
            guard !finished else { return }
            finished = true
            if let field = notification.object as? NSTextField { parent.text = field.stringValue }
            parent.onCommit()
        }
    }
}

private struct PromptHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

struct AIView: View {
    @EnvironmentObject var model: AppModel
    @State var prompt = ""
    @State var showMemory = false
    @State private var showProviders = false
    @FocusState private var promptFocused: Bool
    @StateObject private var speech = SpeechInput()
    @State private var atBottom = true // The end of the chat is on screen; streamed text is followed only then.
    @State private var promptHeight: CGFloat = 36
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Obby AI").font(.headline).fixedSize()
                Spacer(minLength: 0)
                Menu {
                    Button {
                        DispatchQueue.main.async { showMemory = true } // After the menu closes, so the popover can open.
                    } label: { Label("Memory (\(model.memory.itemCount + model.globalMemory.preferences.count) items)…", systemImage: "brain") }
                    Button { model.clearChat() } label: { Label("New Chat", systemImage: "square.and.pencil") }
                    if !model.savedChats.isEmpty {
                        Menu {
                            ForEach(model.savedChats) { record in
                                Button("\(record.title.isEmpty ? "Untitled chat" : record.title) (\(record.updatedAt.formatted(date: .abbreviated, time: .shortened)))") { model.openChat(record) }
                                    .disabled(record.id == model.memory.id)
                            }
                        } label: { Label("Chat History", systemImage: "clock.arrow.circlepath") }.disabled(model.busy)
                    }
                    if model.showTechnical {
                        Divider()
                        Toggle(isOn: $model.showRawActions) { Label("Show technical action details", systemImage: "curlybraces") }
                            .help("Shows the request and result for each action. This does not change your notes or what the AI can do.")
                    }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("More").accessibilityLabel("More")
                    .popover(isPresented: $showMemory, arrowEdge: .bottom) { MemoryPopover().environmentObject(model) }
            }
            // Provider control: "Ollama ● Connected ▾". The whole row is one button that opens a native menu
            // drop-down anchored under the row, so the coloured dot can be shown and every part of the row is clickable.
            Button { showProviders.toggle() } label: {
                HStack(spacing: 6) {
                    Text(model.providerName).lineLimit(1)
                    Circle().fill(model.connected ? Color.green : Color.secondary).frame(width: 7, height: 7)
                    Text(model.startingOllama ? "Connecting…" : model.connected ? "Connected" : "Not connected")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                }.contentShape(Rectangle())
            }
            .buttonStyle(.plain).fixedSize()
            .popover(isPresented: $showProviders, arrowEdge: .bottom) {
                ProviderMenu(close: { showProviders = false }).environmentObject(model)
            }
            .accessibilityLabel("\(model.providerName), \(model.connected ? "connected" : "not connected")")
            .help("Choose AI provider")
            if model.provider == .ollama, let issue = model.ollamaIssue { OllamaIssueView(issue: issue) }
            if !model.toolsAvailable && !model.selectedModel.isEmpty {
                Text("Chat only: can work with the current note, but cannot use vault tools").font(.caption).foregroundStyle(.secondary)
            }
            if model.showRawActions {
                HStack(alignment: .top) {
                    Text("Technical details are on. Expand an action below to see its request and result.").font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Button("Hide details") { model.showRawActions = false }.buttonStyle(.link).font(.caption)
                }
            }
            if model.showTechnical, let usage = model.contextUsage {
                Text("Context: \(ContextBudget.label(usage.used)) / \(ContextBudget.windowLabel(usage.window))").font(.caption2).foregroundStyle(.secondary)
                    .help("Estimated size of the last request. Part of the window is always kept free for the answer.")
            }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if model.chat.isEmpty && !model.aiConfigured {
                            HStack(spacing: 6) { Text("Set up AI in Settings.").foregroundStyle(.secondary); SettingsGear() }.padding(.top, 12)
                        } else if model.chat.isEmpty, let related = model.relatedTask {
                            Button("Continue: \(related.title.isEmpty ? "earlier task" : related.title)") { model.openChat(related) }
                                .buttonStyle(.link).font(.caption).padding(.top, 12).help("Reopen the earlier task that worked on this note")
                        } else if model.chat.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(model.isLocalProvider ? "Tell Obby what to do with your notes. It uses your local \(model.providerName) model." : "Tell Obby what to do with your notes. It uses \(model.providerName); only what a request needs is sent.").foregroundStyle(.secondary)
                                // Examples fill the message box (never send by themselves), so they can be edited first.
                                ForEach(Self.examples, id: \.self) { example in
                                    Button { prompt = example; promptFocused = true } label: {
                                        Label(example.hasSuffix(" ") ? example + "…" : example, systemImage: "text.bubble").frame(maxWidth: .infinity, alignment: .leading)
                                    }.buttonStyle(.plain).padding(.horizontal, 8).padding(.vertical, 5)
                                    .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                                }
                            }.padding(.top, 12)
                        }
                        // Presentation only: Obby renders the model's Markdown and its own action summaries; nothing here goes back to the model.
                        ForEach(ChatGroup.groups(model.chat)) { group in
                            if group.isActions {
                                ActionGroupView(lines: group.lines, showRaw: model.showRawActions, onUndo: { model.undoAIEdit($0) },
                                                taskUndo: model.taskUndo(for: group.lines).map { task in (count: task.count, action: { model.undoTask(task.id) }) }).id(group.id)
                            } else if let line = group.lines.first {
                                let displayed = line.role == "Obby" ? ActionPresentation.reply(line.text) : line.text
                                if !displayed.isEmpty {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(line.role).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                        if line.role == "Obby" { ChatMarkdownView(text: displayed, vault: model.vault, noteFolder: model.note.map { ($0 as NSString).deletingLastPathComponent } ?? "")
                                            // Copy Response: the stored reply exactly as the model wrote it (no display cleanup).
                                            HStack { Spacer(); CopyButton(text: line.text) } // The original stored reply, byte for byte; action lines are separate chat lines.
                                        }
                                        else { Text(displayed).textSelection(.enabled) }
                                    }.frame(maxWidth: .infinity, alignment: .leading).id(group.id)
                                    .contextMenu { Button("Pin to Memory") { model.pin(line.text) } }
                                }
                            }
                        }
                        Color.clear.frame(height: 1).id("chatEnd")
                            .onAppear { atBottom = true }.onDisappear { atBottom = false }
                    }
                }.onChange(of: model.chat.last?.id) { _ in proxy.scrollTo("chatEnd", anchor: .bottom) }
                // A streamed reply grows in place; follow it unless the user has scrolled up to read.
                .onChange(of: model.chat.last?.text) { _ in if atBottom { proxy.scrollTo("chatEnd", anchor: .bottom) } }
                .onAppear { // Shown again: return to the latest message of the same chat.
                    DispatchQueue.main.async { proxy.scrollTo("chatEnd", anchor: .bottom) }
                }
                .overlay(alignment: .bottomTrailing) {
                    if !atBottom && !model.chat.isEmpty {
                        Button { withAnimation { proxy.scrollTo("chatEnd", anchor: .bottom) } } label: {
                            Image(systemName: "arrow.down.circle.fill").font(.title2).foregroundStyle(.secondary)
                        }.buttonStyle(.plain).padding(6).help("Scroll to latest").accessibilityLabel("Scroll to latest")
                    }
                }
            }
            if model.busy { HStack { ProgressView().controlSize(.small); Text(model.isLocalProvider ? "Working locally…" : "Working…").font(.caption); Spacer(); Button("Stop") { model.aiTask?.cancel() } } }
            Divider()
            // Thin model row above the composer: model menu on the left, read-only load status on the right.
            HStack(spacing: 8) {
                Menu {
                    ForEach(model.modelChoices, id: \.self) { name in
                        Button { model.modelSelection.wrappedValue = name } label: {
                            let shown = model.showTechnical && model.provider == .ollama && model.loadedModels.contains(name) ? "\(name)  (loaded)" : name
                            if name == model.selectedModel { Label(shown, systemImage: "checkmark") }
                            else { Text(shown) }
                        }.disabled(model.busy || model.switchingModel)
                    }
                    if model.modelChoices.isEmpty { Text("No models found. Refresh the connection.") }
                    Color.clear.frame(width: 0, height: 0).onAppear { Task { await model.refreshModelStatus() } } // Menu opened: refresh once.
                    Divider()
                    Button("Refresh models") { Task { await model.connect(launch: true) } }
                        .disabled(model.busy || model.switchingModel)
                    Text(model.modelStatus)
                    if model.busy { Text("Stop the current response to switch models.") }
                    if model.switchingModel { Text("Switching model. Please wait.") }
                } label: {
                    Text(model.selectedModel.isEmpty ? "Choose a model" : shortModelName(model.selectedModel))
                        .lineLimit(1)
                }.menuStyle(.borderlessButton).menuIndicator(.visible).font(.caption).foregroundStyle(.secondary).fixedSize().help("Choose AI model") // Hugs the name, so the chevron sits right beside it.
                Spacer(minLength: 8)
                // Read-only status from the existing /api/ps check; updating it never loads or unloads a model.
                if let status = modelLoadStatus {
                    HStack(spacing: 4) {
                        Image(systemName: status == "Loaded" ? "circle.fill" : status == "Loading" ? "circle.dotted" : status == "Offline" ? "circle.slash" : "circle")
                            .font(.system(size: 7, weight: .semibold)).foregroundStyle(status == "Loaded" ? Color.green : Color.secondary)
                        Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }.fixedSize()
                    .help(status == "Offline" ? "Ollama is not reachable" : "Model is \(status.lowercased()) in memory")
                    .accessibilityElement(children: .combine)
                }
            }
            if speech.listening {
                Label("Listening… click the microphone or pause to stop", systemImage: "waveform").font(.caption).foregroundStyle(.red)
            }
            HStack(alignment: .bottom, spacing: 11) {
                // The prompt grows to about seven lines, then scrolls; text added at the end (typing, dictation) stays in view.
                ScrollViewReader { promptProxy in
                    ScrollView(.vertical) {
                        VStack(spacing: 0) {
                            TextField("Ask Obby…", text: $prompt, axis: .vertical).lineLimit(2...).textFieldStyle(.plain).focused($promptFocused).onSubmit { submit() }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(GeometryReader { Color.clear.preference(key: PromptHeightKey.self, value: $0.size.height) })
                            Color.clear.frame(height: 1).id("promptEnd")
                        }
                    }
                    .frame(maxWidth: .infinity).frame(height: min(max(promptHeight, 24), 140))
                    .onPreferenceChange(PromptHeightKey.self) { promptHeight = $0 }
                    .onChange(of: prompt) { [prompt] new in
                        if new.count > prompt.count, new.hasPrefix(prompt) { promptProxy.scrollTo("promptEnd", anchor: .bottom) }
                    }
                }.frame(maxWidth: .infinity).layoutPriority(1) // The prompt takes all remaining width; the controls stay fixed.
                // In-app speech input (on-device when available): live text, Obby's own indicator, no system chime.
                // Falls back to macOS Dictation if speech or microphone access is declined or unavailable.
                Button {
                    promptFocused = true
                    speech.toggle(current: prompt, update: { prompt = $0 }, fallback: {
                        DispatchQueue.main.async { NSApp.sendAction(Selector(("startDictation:")), to: nil, from: nil) }
                    })
                } label: {
                    Image(systemName: speech.listening ? "mic.fill" : "mic")
                        .foregroundStyle(speech.listening ? Color.red : Color.secondary)
                        .scaleEffect(speech.listening ? 1 + CGFloat(speech.level) * 0.4 : 1)
                        .animation(.easeOut(duration: 0.1), value: speech.level)
                }
                .buttonStyle(.borderless).help(speech.listening ? "Stop dictation" : "Dictate")
                .accessibilityLabel(speech.listening ? "Stop dictation" : "Dictate").disabled(model.busy && !speech.listening)
                .fixedSize()
                QuickActionsMenu().fixedSize()
                Button { submit() } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .buttonStyle(.plain).fixedSize().help("Send").accessibilityLabel("Send")
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.busy || model.switchingModel || model.selectedModel.isEmpty || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }.padding(.horizontal, 14).padding(.vertical, 12).background(.background, in: RoundedRectangle(cornerRadius: 9))
                .overlay { RoundedRectangle(cornerRadius: 9).strokeBorder(.separator) }
        }.padding(14)
        // Markdown files dropped on the AI panel are added as notes, opened, and named in the message box to work on.
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            MarkdownDrop.load(providers) { urls in
                let added = model.importNotes(urls)
                guard !added.isEmpty else { return }
                let names = added.map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
                prompt = (prompt.isEmpty ? "" : prompt + "\n") + "Work with \(names): "
                promptFocused = true
            }
        }
        .onAppear { prompt = model.aiDraft; Task { await model.refreshModelStatus() }; model.startStatusPoll() } // Draft survives hiding the panel.
        .onDisappear { model.aiDraft = prompt; speech.stop(); model.stopStatusPoll() }
        // Load state follows Obby's own events; the slow fallback check runs only while Obby is in front.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.refreshModelStatus() }; model.startStatusPoll()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in model.stopStatusPoll() }
    }
    /// "Loaded" / "Unloaded" for Ollama, "Offline" when the provider can't be reached; nil when there is nothing to show.
    static let examples = ["Organise my loose notes into folders", "Make flashcards from this note", "Summarise this note in five bullet points", "Find everything I wrote about "]
    /// Ollama only (cloud providers have no load state; their connection shows in the provider row).
    var modelLoadStatus: String? {
        guard model.provider == .ollama, !model.selectedModel.isEmpty, !model.startingOllama else { return nil }
        if !model.connected { return "Offline" } // Always shown: without it nothing works.
        guard model.showTechnical else { return nil } // Loading / Loaded / Unloaded are technical details.
        if model.modelLoading { return "Loading" }
        return model.loadedModels.contains(model.selectedModel) ? "Loaded" : "Unloaded"
    }
    /// Keeps very long model names compact by shortening the middle; the full name is in the menu.
    func shortModelName(_ name: String) -> String {
        guard name.count > 32 else { return name }
        return String(name.prefix(18)) + "…" + String(name.suffix(12))
    }
    func submit() {
        guard !model.busy, !model.switchingModel, !model.selectedModel.isEmpty else { return }
        speech.stop()
        if let quick = QuickAction.parse(prompt) { model.runQuickAction(quick.action, save: quick.save); prompt = ""; return } // "/flashcards", "/quiz save"…
        model.send(prompt); prompt = ""
    }
}
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State var showMemory = false
    @State var url = ""
    @State var baseURL = ""
    @State var apiKey = ""
    @State var manualModel = ""
    @State private var presetIndex = 0
    @State private var newName = ""
    @State private var newURL = ""
    @State private var newKey = ""
    @State private var newTools = true
    @State private var addError: String?
    @State private var settingsTab = "Notes"
    static let tabs = [("Notes", "folder"), ("AI", "sparkles"), ("Memory", "brain"), ("Advanced", "slider.horizontal.3")]
    var providerSelection: Binding<ProviderKind> {
        Binding(get: { model.provider }, set: { next in Task { await model.switchProvider(next); syncDrafts() } })
    }
    var body: some View {
        // Icon tabs like the former Settings window (a TabView inside a sheet shows text-only tabs).
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(Self.tabs, id: \.0) { name, icon in
                    Button { settingsTab = name } label: {
                        VStack(spacing: 3) {
                            Image(systemName: icon).font(.system(size: 20)).frame(height: 24)
                            Text(name).font(.caption)
                        }.frame(width: 76, height: 50)
                        .foregroundStyle(settingsTab == name ? Color.accentColor : Color.secondary)
                        .background(settingsTab == name ? Color.secondary.opacity(0.15) : Color.clear, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                    }.buttonStyle(.plain).accessibilityLabel(name)
                }
            }.padding(.vertical, 8)
            Divider()
            Group {
                switch settingsTab {
                case "AI": aiTab
                case "Memory": memoryTab
                case "Advanced": advancedTab
                default: generalTab
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity) // Each tab's Form scrolls inside the fixed sheet size.
        }
            .sheet(isPresented: $showMemory) { MemorySettingsSheet().environmentObject(model) }
            .task { syncDrafts(); await model.connect() }
            .onChange(of: model.selectedModel) { value in manualModel = value }
    }
    var generalTab: some View {
        Form {
            Section("Storage") {
                // Obby does not own your content: notes and attachments are ordinary files in this folder.
                LabeledContent("Notes location") {
                    Text(model.vault.map { ($0.root.path as NSString).abbreviatingWithTildeInPath } ?? "No folder chosen")
                        .textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                }
                HStack {
                    Button("Show in Finder") { if let root = model.vault?.root { NSWorkspace.shared.activateFileViewerSelecting([root]) } }.disabled(model.vault == nil)
                    Button("Change Folder…") { model.chooseFolder() }.disabled(model.busy)
                }
                Text("Your notes and attachments stay as ordinary files in this folder.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Editor") {
                Stepper("Editor text size: \(Int(model.editorFontSize)) pt", value: $model.editorFontSize, in: 11...28, step: 1)
                Text("Changes only how notes look in the editor (also View → Bigger, Smaller, Actual Size). Saved files are unchanged.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
    var aiTab: some View {
        Form {
            Section("AI Provider") {
                Picker("AI provider", selection: providerSelection) {
                    ForEach(ProviderKind.allCases) { Text($0.label).tag($0) }
                }.disabled(model.busy || model.switchingModel)
                Text(model.isLocalProvider ? "\(model.providerName) runs on this Mac." : "Relevant notes may be sent to \(model.providerName).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            savedProvidersSection
            Section("Model") {
                if model.provider == .ollama {
                    Picker("Selected model", selection: model.modelSelection) {
                        Text("Select a model").tag("")
                        ForEach(model.modelChoices, id: \.self) { Text($0).tag($0) }
                    }.disabled(model.busy || model.switchingModel)
                } else {
                    HStack {
                        TextField("Model", text: $manualModel, prompt: Text("Type or choose a model")).onSubmit { applyModel() }
                        if !model.models.isEmpty {
                            Menu("Choose") { ForEach(model.models, id: \.self) { name in Button(name) { manualModel = name; applyModel() } } }.fixedSize()
                        }
                        Button("Apply") { applyModel() }.disabled(model.busy || model.switchingModel)
                    }
                }
                if model.provider == .openAI && model.activeCustom == nil {
                    Toggle("Model supports tool calling", isOn: $model.openAITools)
                        .onChange(of: model.openAITools) { _ in model.persistSettings(); Task { await model.refreshToolSupport() } }
                }
                Text(model.modelStatus + (model.toolsAvailable || model.selectedModel.isEmpty ? "" : " (chat only)")).font(.caption).foregroundStyle(.secondary)
            }
            Section("Context") {
                Toggle("Include related notes automatically", isOn: model.isLocalProvider ? $model.relatedNotesLocal : $model.relatedNotesCloud)
                    .onChange(of: model.relatedNotesLocal) { _ in model.persistSettings() }
                    .onChange(of: model.relatedNotesCloud) { _ in model.persistSettings() }
                    .help("Adds short excerpts from relevant notes. Off by default for cloud providers.")
                Picker("Context window", selection: $model.contextWindow) {
                    ForEach(ContextWindow.allCases) { Text($0.label).tag($0) }
                }.onChange(of: model.contextWindow) { _ in model.persistSettings() }
                    .help(contextNote)
            }
        }.formStyle(.grouped)
    }
    var memoryTab: some View {
        Form {
            Section("View and edit") {
                LabeledContent("Saved facts and preferences", value: "\(model.globalMemory.aboutMe.count + model.globalMemory.preferences.count)")
                Button("View and edit memory…") { showMemory = true }.buttonStyle(.link)
            }
            Section("Remembering") {
                Toggle("Learn about me from chats", isOn: $model.learnAboutMe)
                    .onChange(of: model.learnAboutMe) { _ in model.persistSettings() }
                Toggle("Remember AI tasks between launches", isOn: $model.rememberChats)
                    .onChange(of: model.rememberChats) { on in model.persistSettings(); if on { model.persistChat() }; model.reloadSavedChats() }
            }
            Section { MemoryDangerZone(includeAll: true) }
        }.formStyle(.grouped)
    }
    var advancedTab: some View {
        Form {
            if model.provider == .ollama { ollamaSection } else { cloudSection }
            Section("Technical details") {
                Toggle("Show technical details", isOn: $model.showTechnical)
                Text("Shows model memory status (Loading, Loaded, Unloaded), context size, and the option to see each action's request and result. Off by default; it only changes the display.")
                    .font(.caption).foregroundStyle(.secondary)
                if model.showTechnical {
                    Toggle("Show technical action details", isOn: $model.showRawActions)
                }
            }
            if model.provider != .ollama, model.activeCustom == nil, model.hasAPIKey {
                Section {
                    DangerZone {
                        ConfirmRemovalButton(title: "Remove API key", warning: "Removes the saved key for \(model.provider.label). You will need to add it again to use this provider.") { model.removeAPIKey() }
                    }
                }
            }
        }.formStyle(.grouped)
    }
    /// Saved OpenAI-compatible providers: each has its own name, base URL and Keychain key, and appears in the AI panel's provider menu.
    var savedProvidersSection: some View {
        Section("Saved Providers") {
            ForEach(model.customProviders) { entry in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name)
                        Text(entry.baseURL).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    if model.activeCustom?.id == entry.id { Text("In use").font(.caption).foregroundStyle(.secondary) }
                    else { Button("Use") { Task { await model.switchProvider(.openAI, custom: entry.id); syncDrafts() } } }
                    Button("Remove", role: .destructive) { Task { await model.removeCustomProvider(entry); syncDrafts() } }
                }.disabled(model.busy || model.switchingModel)
            }
            Picker("Service", selection: $presetIndex) {
                ForEach(CustomProvider.presets.indices, id: \.self) { Text(CustomProvider.presets[$0].name).tag($0) }
            }.onChange(of: presetIndex) { index in
                let preset = CustomProvider.presets[index]
                newName = index == 0 ? "" : preset.name; newURL = preset.url
            }
            TextField("Name", text: $newName, prompt: Text("For example, My Server"))
            TextField("Base URL", text: $newURL, prompt: Text("https://your-server.com/v1"))
            SecureField("API key", text: $newKey, prompt: Text("Optional for servers without a key"))
            Toggle("Model supports tool calling", isOn: $newTools)
            HStack {
                Spacer()
                Button("Add Provider") { addProvider() }
                    .disabled(model.busy || model.switchingModel || newName.trimmingCharacters(in: .whitespaces).isEmpty || newURL.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let addError { Text(addError).foregroundStyle(.red) }
            Text("Add any OpenAI-compatible service, such as DeepSeek, OpenRouter, Groq or Mistral, or your own server. Each provider keeps its own API key in your macOS Keychain.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
    func addProvider() {
        let (name, url, key, tools) = (newName, newURL, newKey, newTools)
        Task {
            do {
                try await model.addCustomProvider(name: name, baseURL: url, key: key, tools: tools)
                addError = nil; presetIndex = 0; newName = ""; newURL = ""; newKey = ""; newTools = true
                syncDrafts()
            } catch { addError = error.localizedDescription }
        }
    }
    var cloudSection: some View {
        Section(model.providerName) {
            if let custom = model.activeCustom {
                Text(custom.baseURL).font(.caption).foregroundStyle(.secondary)
                Text("This is a saved provider. To change it, remove it and add it again under Saved Providers.").font(.caption).foregroundStyle(.secondary)
                if let error = model.modelSettingsError { Text(error).foregroundStyle(.red) }
            } else { builtInCloudFields }
        }
    }
    @ViewBuilder var builtInCloudFields: some View {
        Group {
            if model.provider == .openAI {
                HStack {
                    TextField("Base URL", text: $baseURL).onSubmit { applyBaseURL() }
                    Button("Apply") { applyBaseURL() }
                }
            }
            HStack {
                SecureField("API key", text: $apiKey, prompt: Text(model.hasAPIKey ? "Saved in Keychain" : (model.provider == .openAI ? "Optional for local servers" : "Required")))
                    .onSubmit { saveKey() }
                Button("Save") { saveKey() }.disabled(apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let error = model.modelSettingsError { Text(error).foregroundStyle(.red) }
            Text("API keys are stored in your macOS Keychain.").font(.caption).foregroundStyle(.secondary)
        }
    }
    var contextNote: String {
        let chosen = model.contextWindow.rawValue, effective = model.effectiveWindow
        let using = effective < chosen
            ? "This model supports up to \(ContextBudget.windowLabel(effective)), so requests use \(ContextBudget.windowLabel(effective))."
            : "Requests use \(ContextBudget.windowLabel(chosen))."
        return using + " Part of the window is always kept free for the answer."
    }
    func syncDrafts() { url = model.endpoint; baseURL = model.openAIBaseURL; manualModel = model.selectedModel; apiKey = "" }
    func saveKey() { model.saveAPIKey(apiKey); apiKey = "" }
    func applyModel() {
        let name = manualModel.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        model.modelSelection.wrappedValue = name
    }
    func applyBaseURL() {
        do {
            _ = try RemoteHTTP.validatedBase(baseURL)
            model.openAIBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            model.modelSettingsError = nil
            Task { await model.connect() }
        } catch { model.modelSettingsError = error.localizedDescription }
    }
    var ollamaSection: some View {
        Section("Ollama") {
            Toggle("Unload previous model when switching", isOn: $model.unloadPrevious)
                .onChange(of: model.unloadPrevious) { _ in model.persistSettings() }
            Toggle("Unload model when Obby closes", isOn: $model.unloadOnQuit)
                .onChange(of: model.unloadOnQuit) { _ in model.persistSettings() }
            Toggle("Stream replies", isOn: $model.streamReplies)
                .onChange(of: model.streamReplies) { _ in model.persistSettings() }
            Toggle("Start Ollama automatically when needed", isOn: $model.autoStartOllama)
                .onChange(of: model.autoStartOllama) { _ in model.persistSettings() }
            if let issue = model.ollamaIssue { OllamaIssueView(issue: issue) }
            Picker("Model keep-alive", selection: $model.keepAlive) {
                ForEach(ModelKeepAlive.allCases, id: \.self) { Text($0.label).tag($0) }
            }.onChange(of: model.keepAlive) { _ in model.persistSettings() }
            HStack {
                TextField("Ollama URL", text: $url).onSubmit { reconnect() }
                Button("Apply") { reconnect() }.disabled(model.busy || model.switchingModel)
            }.disabled(model.busy || model.switchingModel)
            if let error = model.modelSettingsError { Text(error).foregroundStyle(.red) }
        }
    }
    func reconnect() {
        model.endpoint = url.trimmingCharacters(in: .whitespacesAndNewlines)
        Task { await model.connect(launch: true) }
    }
}

/// "Ollama isn't installed." (with a Get Ollama link) or "Ollama isn't running…".
struct OllamaIssueView: View {
    let issue: OllamaIssue
    var body: some View {
        HStack(spacing: 8) {
            Text(issue.message)
            if issue == .notInstalled { Link("Get Ollama", destination: OllamaIssue.downloadURL) }
        }
        .font(.caption).foregroundStyle(.secondary)
    }
}

// Intercept close before the editor disappears; preserve SwiftUI's window delegate.
struct WindowCloseGuard: NSViewRepresentable {
    let model: AppModel
    func makeCoordinator() -> Coordinator { Coordinator(model) }
    func makeNSView(context: Context) -> NSView {
        let view = AttachmentView()
        view.attach = { window in context.coordinator.attach(to: window) }
        return view
    }
    func updateNSView(_ view: NSView, context: Context) { context.coordinator.attach(to: view.window) }
    final class AttachmentView: NSView {
        var attach: ((NSWindow?) -> Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); attach?(window) }
    }
    @MainActor final class Coordinator: NSObject, NSWindowDelegate {
        let model: AppModel
        weak var original: NSWindowDelegate?
        init(_ model: AppModel) { self.model = model }
        func attach(to window: NSWindow?) {
            guard let window, window.delegate !== self else { return }
            original = window.delegate; window.delegate = self
        }
        func windowShouldClose(_ sender: NSWindow) -> Bool {
            guard model.save() else { return false }
            guard original?.windowShouldClose?(sender) ?? true else { return false }
            if model.rememberChats { model.persistChat() } else { model.clearChat() } // Remembered chats stay open.
            return true
        }
        override func responds(to selector: Selector!) -> Bool { super.responds(to: selector) || (original?.responds(to: selector) ?? false) }
        override func forwardingTarget(for selector: Selector!) -> Any? { original }
    }
}

/// Speech-to-text for the AI prompt with Apple's Speech framework: starts instantly, shows words as you speak, and uses
/// on-device recognition when the language supports it (audio then never leaves the Mac). Obby keeps no audio.
/// Stops on a second click, on Send, or after about 2.5 seconds of silence. Nothing runs while it isn't listening.
@MainActor final class SpeechInput: ObservableObject {
    @Published var listening = false
    @Published var level: Float = 0 // 0…1 input level, for the pulsing microphone.
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silence: Task<Void, Never>?

    func toggle(current: String, update: @escaping (String) -> Void, fallback: @escaping () -> Void) {
        if listening { stop(); return }
        // On-device only: if this Mac can't recognise speech locally, use macOS Dictation instead, so no audio goes to a server.
        guard let recognizer = SFSpeechRecognizer(), recognizer.supportsOnDeviceRecognition else { fallback(); return }
        Task { @MainActor in
            let speechAllowed = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
                SFSpeechRecognizer.requestAuthorization { done.resume(returning: $0 == .authorized) }
            }
            let micAllowed = speechAllowed ? await AVCaptureDevice.requestAccess(for: .audio) : false
            guard speechAllowed, micAllowed, recognizer.isAvailable else { fallback(); return }
            start(recognizer, current: current, update: update, fallback: fallback)
        }
    }
    private func start(_ recognizer: SFSpeechRecognizer, current: String, update: @escaping (String) -> Void, fallback: () -> Void) {
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true // Never sent to Apple's servers.
        let input = engine.inputNode
        var buffers = 0
        input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { [weak self] buffer, _ in
            request.append(buffer)
            buffers += 1
            guard buffers % 3 == 0, let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            var sum: Float = 0
            for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
            let level = min(1, sqrt(sum / Float(buffer.frameLength)) * 20)
            Task { @MainActor [weak self] in self?.level = level }
        }
        engine.prepare()
        do { try engine.start() } catch { input.removeTap(onBus: 0); fallback(); return }
        var committed = current.isEmpty || current.hasSuffix(" ") || current.hasSuffix("\n") ? current : current + " "
        var last = ""
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let text = result?.bestTranscription.formattedString, finished = error != nil || result?.isFinal == true
            Task { @MainActor [weak self] in
                guard let self, self.listening else { return }
                if let text {
                    // After a pause, on-device recognition starts a new phrase and its transcript no longer includes
                    // the earlier words. Keep what was already said instead of replacing it.
                    if SpeechInput.startsNewPhrase(previous: last, next: text) { committed += last + " " }
                    last = text
                    update(committed + text); self.armSilenceStop()
                }
                if finished { self.stop() }
            }
        }
        self.request = request
        listening = true
        armSilenceStop()
    }
    /// True when the recogniser has dropped the earlier words (a new phrase), rather than revising the current one.
    nonisolated static func startsNewPhrase(previous: String, next: String) -> Bool {
        guard !previous.isEmpty, !next.isEmpty else { return false }
        let first = { (text: String) in text.split(separator: " ").first.map { $0.lowercased() } ?? "" }
        return next.count < previous.count && first(next) != first(previous)
    }
    private func armSilenceStop() {
        silence?.cancel()
        silence = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }
    func stop() {
        silence?.cancel(); silence = nil
        guard listening else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio(); task?.finish()
        request = nil; task = nil
        listening = false; level = 0
    }
}

/// Provider drop-down: providers that are ready to use (Ollama, or a cloud provider with a saved key).
/// Switching uses the existing switchProvider logic. With nothing else set up, it points to Settings.
struct ProviderMenu: View {
    @EnvironmentObject var model: AppModel
    var close: () -> Void
    var available: [ProviderKind] {
        ProviderKind.allCases.filter { kind in
            switch kind {
            case .ollama: return true
            case .openAI: return (model.provider == .openAI && model.activeCustom == nil) || Keychain.exists(kind.rawValue)
                || model.openAIBaseURL != "https://api.openai.com/v1" // A keyless local server counts as set up.
            default: return kind == model.provider || Keychain.exists(kind.rawValue)
            }
        }
    }
    /// One clearly separate action row: icon, label, and a light rounded background.
    func actionLabel(_ title: String, systemImage: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage).frame(width: 14)
            Text(title)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        .contentShape(RoundedRectangle(cornerRadius: 6))
    }
    func row(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button { close(); action() } label: {
            HStack(spacing: 6) {
                Image(systemName: "checkmark").opacity(selected ? 1 : 0)
                Text(title)
                Spacer(minLength: 0)
            }.contentShape(Rectangle()).padding(.vertical, 3)
        }.buttonStyle(.plain)
    }
    var body: some View {
        let locked = model.busy || model.switchingModel
        VStack(alignment: .leading, spacing: 2) {
            ForEach(available) { provider in
                row(provider.label, selected: provider == model.provider && model.activeCustom == nil) {
                    Task { await model.switchProvider(provider) }
                }.disabled(locked)
            }
            ForEach(model.customProviders) { entry in
                row(entry.name, selected: model.activeCustom?.id == entry.id) {
                    Task { await model.switchProvider(.openAI, custom: entry.id) }
                }.disabled(locked)
            }
            if available.count + model.customProviders.count <= 1 {
                Text("No other providers are available.").font(.caption).foregroundStyle(.secondary).padding(.top, 4)
            }
            Divider().padding(.vertical, 4)
            VStack(alignment: .leading, spacing: 6) {
                Button { close(); Task { await model.connect(launch: true) } } label: {
                    actionLabel("Refresh connection and models", systemImage: "arrow.clockwise")
                }.buttonStyle(.plain).disabled(locked)
                Button {
                    close()
                    DispatchQueue.main.async { model.showSettings = true } // After the drop-down closes.
                } label: { actionLabel("Set up another provider in Settings…", systemImage: "gearshape") }
                .buttonStyle(.plain)
            }
            if model.busy { Text("Stop the current response to switch providers.").font(.caption).foregroundStyle(.secondary) }
            if model.switchingModel { Text("Switching model. Please wait.").font(.caption).foregroundStyle(.secondary) }
        }.padding(10).frame(minWidth: 230, alignment: .leading)
        .onAppear { Task { await model.refreshModelStatus() } } // Menu opened: refresh once.
    }
}
