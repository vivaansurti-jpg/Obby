import SwiftUI
import AppKit

@main struct ObbyApp: App {
    @StateObject var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup("Obby") {
            ContentView().environmentObject(model).frame(minWidth: 920, minHeight: 580)
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
        }
        .defaultSize(width: 1200, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Note") { model.create(directory: false) }.keyboardShortcut("n").disabled(model.vault == nil)
                Button("New Folder") { model.create(directory: true) }.keyboardShortcut("n", modifiers: [.command, .shift]).disabled(model.vault == nil)
                Button("Choose Notes Folder…") { model.chooseFolder() }.keyboardShortcut("o").disabled(model.busy)
            }
            CommandGroup(replacing: .saveItem) { Button("Save") { model.save() }.keyboardShortcut("s") }
            CommandGroup(after: .sidebar) { Button(model.showAI ? "Hide AI" : "Show AI") { model.showAI.toggle() }.keyboardShortcut("a", modifiers: [.command, .shift]) }
            CommandGroup(after: .textEditing) { Button("Find in Notes") { NotificationCenter.default.post(name: .init("ObbyFind"), object: nil) }.keyboardShortcut("f") }
        }
        Settings { SettingsView().environmentObject(model) }
    }
}
struct SettingsGear: View {
    var body: some View {
        Group {
            if #available(macOS 14.0, *) {
                SettingsLink { Image(systemName: "gearshape") }
            } else {
                Button {
                    NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                } label: { Image(systemName: "gearshape") }
            }
        }
        .help("Settings")
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
    var body: some View {
        Group {
            if model.showOnboarding {
                OnboardingView()
            } else if model.vault == nil {
                VStack(spacing: 18) { Image(systemName: "folder").font(.system(size: 44)).foregroundStyle(.secondary); Text("Choose your notes folder").font(.title2); Text("Choose the folder that holds your notes, or an empty folder.").foregroundStyle(.secondary); Button("Choose Folder…") { model.chooseFolder() }.keyboardShortcut(.defaultAction) }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    sidebar.frame(minWidth: 180, idealWidth: 220, maxWidth: 400)
                    VStack(spacing: 0) {
                        if let note = model.note {
                            HStack { NoteTitleField(path: note); Spacer() }.padding()
                            HStack(spacing: 12) {
                                Button { bridge.format(.bold) } label: { Image(systemName: "bold") }.help("Bold").keyboardShortcut("b")
                                Button { bridge.format(.italic) } label: { Image(systemName: "italic") }.help("Italic").keyboardShortcut("i")
                                Button { bridge.format(.underline) } label: { Image(systemName: "underline") }.help("Underline").keyboardShortcut("u")
                                Menu("Text") { ForEach([Format.heading, .heading2, .heading3, .size], id: \.self) { style in Button(style.rawValue) { bridge.format(style) } } }.fixedSize()
                                Button { bridge.format(.bullet) } label: { Image(systemName: "list.bullet") }.help("Bullets")
                                Button { bridge.format(.numbered) } label: { Image(systemName: "list.number") }.help("Numbered list")
                                Button { bridge.format(.checkbox) } label: { Image(systemName: "checklist") }.help("Checkboxes")
                                Button { bridge.format(.checked) } label: { Image(systemName: "checkmark.square") }.help("Mark selected lines completed")
                                Button { bridge.insertImage() } label: { Image(systemName: "photo") }.help("Insert image").accessibilityLabel("Insert image").disabled(model.note == nil)
                                Button { bridge.attachDocument() } label: { Image(systemName: "paperclip") }.help("Attach document").accessibilityLabel("Attach document").disabled(model.note == nil)
                                Spacer()
                            }.buttonStyle(.borderless).padding(.horizontal).padding(.bottom, 10)
                            Divider()
                            MarkdownEditor(text: $model.text, bridge: bridge, importAttachments: { model.importAttachments($0) }, openLink: { model.openLink($0) }).id(note)
                        } else {
                            // Folder selected (or nothing/root): neutral state; nothing is created until New Note.
                            VStack(spacing: 8) {
                                Text(model.folder.isEmpty ? "Obby" : (model.folder.split(separator: "/").last.map(String.init) ?? "Obby")).font(.title2)
                                Text("No note selected").foregroundStyle(.secondary)
                                Button("New Note") { model.create(directory: false) }.padding(.top, 6)
                            }.frame(maxWidth: .infinity, maxHeight: .infinity)
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
            HStack { Text(model.folderTitle).font(.headline).lineLimit(1); Spacer(); Menu { Button("New Note") { model.create(directory: false) }; Button("New Folder") { model.create(directory: true) }; Divider(); Button("Choose Notes Folder…") { model.chooseFolder() }.disabled(model.busy) } label: { Image(systemName: "plus") }.menuStyle(.borderlessButton).fixedSize() }.padding()
            TextField("Search notes", text: $model.query).textFieldStyle(.roundedBorder).focused($searchFocused).padding(.horizontal).padding(.bottom, 8).onChange(of: model.query) { _ in model.search() }
            NativeFileSidebar(model: model)
            HStack { Button("Root Folder") { model.selectFolder(nil) }; Spacer() }.buttonStyle(.borderless).font(.caption).padding(10)
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

struct AIView: View {
    @EnvironmentObject var model: AppModel
    @State var prompt = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack { Text("Obby AI").font(.headline); Text(model.providerBadge).font(.caption).foregroundStyle(.secondary).help(model.isLocalProvider ? "Requests stay on this Mac." : "Requests are sent to this cloud provider."); Spacer()
                Toggle(isOn: $model.showRawActions) { Image(systemName: "chevron.left.forwardslash.chevron.right") }
                    .toggleStyle(.button).help("Show raw actions").accessibilityLabel("Show raw actions")
                if !model.savedChats.isEmpty {
                    Menu {
                        ForEach(model.savedChats) { record in
                            Button("\(record.title.isEmpty ? "Untitled chat" : record.title) · \(record.updatedAt.formatted(date: .abbreviated, time: .shortened))") { model.openChat(record) }
                                .disabled(record.id == model.memory.id)
                        }
                    } label: { Image(systemName: "clock") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().disabled(model.busy)
                    .help("Chat history").accessibilityLabel("Chat history")
                }
                Button { model.clearChat() } label: { Image(systemName: "square.and.pencil") }.help("New chat").accessibilityLabel("New chat") }
            HStack { Circle().fill(model.connected ? .green : .secondary).frame(width: 6, height: 6); Text(model.modelStatus).font(.caption); Spacer(); Button { Task { await model.connect(launch: true) } } label: { Image(systemName: "arrow.clockwise") }.disabled(model.busy).help("Refresh").accessibilityLabel("Refresh") }
            Picker("Model", selection: model.modelSelection) { Text("Select a model").tag(""); ForEach(model.modelChoices, id: \.self) { Text($0).tag($0) } }.disabled(model.busy || model.switchingModel)
            if model.provider == .ollama, let issue = model.ollamaIssue { OllamaIssueView(issue: issue) }
            if !model.toolsAvailable && !model.selectedModel.isEmpty {
                Text("Chat only · can work with the current note, but cannot use vault tools").font(.caption).foregroundStyle(.secondary)
            }
            if model.memory.itemCount + model.globalMemory.preferences.count > 0 {
                Text("Memory · \(model.memory.itemCount + model.globalMemory.preferences.count) items").font(.caption2).foregroundStyle(.secondary)
                    .help([model.globalMemory.packet, model.memory.packet].filter { !$0.isEmpty }.joined(separator: "\n\n"))
            }
            if let usage = model.contextUsage {
                Text("Context: \(ContextBudget.label(usage.used)) / \(ContextBudget.windowLabel(usage.window))").font(.caption2).foregroundStyle(.secondary)
                    .help("Estimated size of the last request. Part of the window is always kept free for the answer.")
            }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 18) {
                        if model.chat.isEmpty && !model.aiConfigured {
                            HStack(spacing: 6) { Text("Set up AI in Settings.").foregroundStyle(.secondary); SettingsGear() }.padding(.top, 12)
                        } else if model.chat.isEmpty { Text(model.isLocalProvider ? "Ask a question, summarize a note, or organize your folders. Obby uses your local \(model.provider.label) model." : "Ask a question, summarize a note, or organize your folders. Obby uses \(model.provider.label); only what a request needs is sent.").foregroundStyle(.secondary).padding(.top, 12) }
                        // Presentation only: Obby renders the model's Markdown and its own action summaries; nothing here goes back to the model.
                        ForEach(ChatGroup.groups(model.chat)) { group in
                            if group.isActions {
                                ActionGroupView(lines: group.lines, showRaw: model.showRawActions).id(group.id)
                            } else if let line = group.lines.first {
                                let displayed = line.role == "Obby" && !model.showRawActions ? ActionPresentation.reply(line.text) : line.text
                                if !displayed.isEmpty {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(line.role).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                                        if line.role == "Obby" { ChatMarkdownView(text: displayed, vault: model.vault, noteFolder: model.note.map { ($0 as NSString).deletingLastPathComponent } ?? "")
                                            // Copy Response: the stored reply exactly as the model wrote it (no display cleanup).
                                            HStack { Spacer(); CopyButton(text: line.text) } // The original stored reply, byte for byte; action lines are separate chat lines.
                                        }
                                        else { Text(displayed).textSelection(.enabled) }
                                    }.frame(maxWidth: .infinity, alignment: .leading).id(group.id)
                                }
                            }
                        }
                    }
                }.onChange(of: model.chat.last?.id) { _ in if let id = model.chat.last?.id { proxy.scrollTo(id, anchor: .bottom) } }
                .onAppear { // Shown again: return to the latest message of the same chat.
                    DispatchQueue.main.async { if let id = model.chat.last?.id { proxy.scrollTo(id, anchor: .bottom) } }
                }
            }
            if model.busy { HStack { ProgressView().controlSize(.small); Text(model.isLocalProvider ? "Working locally…" : "Working…").font(.caption); Spacer(); Button("Stop") { model.aiTask?.cancel() } } }
            Divider()
            TextField("Ask Obby…", text: $prompt, axis: .vertical).lineLimit(2...6).textFieldStyle(.roundedBorder).onSubmit { submit() }
            HStack { Text("Only your Obby folder").font(.caption2).foregroundStyle(.secondary); Spacer(); Button("Send") { submit() }.keyboardShortcut(.return, modifiers: .command).disabled(model.busy || model.switchingModel || model.selectedModel.isEmpty || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.padding(14)
        .onAppear { prompt = model.aiDraft } // An unsent draft survives hiding the panel.
        .onDisappear { model.aiDraft = prompt }
    }
    func submit() { guard !model.busy, !model.switchingModel, !model.selectedModel.isEmpty else { return }; model.send(prompt); prompt = "" }
}
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State var url = ""
    @State var baseURL = ""
    @State var apiKey = ""
    @State var manualModel = ""
    var providerSelection: Binding<ProviderKind> {
        Binding(get: { model.provider }, set: { next in Task { await model.switchProvider(next); syncDrafts() } })
    }
    var body: some View {
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
                Text("Notes, images and documents are normal files in this folder, so they stay usable from Finder and can be backed up with Time Machine, iCloud Drive, Dropbox or Git. Changing the folder never moves or deletes anything.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("AI Provider") {
                Picker("AI provider", selection: providerSelection) {
                    ForEach(ProviderKind.allCases) { Text($0.label).tag($0) }
                }.disabled(model.busy || model.switchingModel)
                Text(model.providerBadge).font(.caption.weight(.semibold))
                Text(model.isLocalProvider ? "Your AI requests stay on this Mac." : "Relevant note or attachment content may be sent to this provider when you ask Obby to work with it.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Context window", selection: $model.contextWindow) {
                    ForEach(ContextWindow.allCases) { Text($0.label).tag($0) }
                }.onChange(of: model.contextWindow) { _ in model.persistSettings() }
                Text(contextNote).font(.caption).foregroundStyle(.secondary)
            }
            if model.provider == .ollama { ollamaSection } else { cloudSection }
            Section("Memory") {
                Toggle("Remember AI tasks between launches", isOn: $model.rememberChats)
                    .onChange(of: model.rememberChats) { on in model.persistSettings(); if on { model.persistChat() }; model.reloadSavedChats() }
                HStack {
                    Button("Clear current task memory") { model.clearCurrentChatMemory() }.disabled(model.busy)
                    Button("Clear all AI memory") { model.clearAllChatMemory() }.disabled(model.busy)
                }
                ForEach(model.globalMemory.preferences, id: \.self) { item in // Durable preferences you stated ("from now on…").
                    HStack { Text(item).font(.caption).lineLimit(2); Spacer(); Button { model.forgetGlobalPreference(item) } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless).help("Forget this preference") }
                }
                Text("Task memory is a short summary kept on this Mac, separate from your notes. Clearing it never deletes notes or attachments.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).frame(width: 520, height: 600)
            .task { syncDrafts(); await model.connect() }
            .onChange(of: model.selectedModel) { value in manualModel = value }
    }
    var cloudSection: some View {
        Section(model.provider.label) {
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
                if model.hasAPIKey { Button("Remove") { model.removeAPIKey() } }
            }
            HStack {
                TextField("Model", text: $manualModel, prompt: Text("Type or choose a model")).onSubmit { applyModel() }
                if !model.models.isEmpty {
                    Menu("Choose") { ForEach(model.models, id: \.self) { name in Button(name) { manualModel = name; applyModel() } } }.fixedSize()
                }
                Button("Apply") { applyModel() }.disabled(model.busy || model.switchingModel)
            }
            if model.provider == .openAI {
                Toggle("Model supports tool calling", isOn: $model.openAITools)
                    .onChange(of: model.openAITools) { _ in model.persistSettings(); Task { await model.refreshToolSupport() } }
            }
            Text(model.modelStatus + (model.toolsAvailable || model.selectedModel.isEmpty ? "" : " · Chat only")).font(.caption).foregroundStyle(.secondary)
            if let error = model.modelSettingsError { Text(error).font(.caption).foregroundStyle(.red) }
            Text("Privacy: \(model.isLocalProvider ? "this server runs on your Mac" : "your messages go to \(model.provider.label)"). Obby sends only your message, recent chat, the open note when the model works with it, and any notes or search results its tools read for that request, never your whole vault. API keys are stored in your macOS Keychain.")
                .font(.caption).foregroundStyle(.secondary)
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
        Section("Ollama / Model") {
            Picker("Selected model", selection: model.modelSelection) {
                Text("Select a model").tag("")
                ForEach(model.models, id: \.self) { Text($0).tag($0) }
            }.disabled(model.busy || model.switchingModel)
            Toggle("Unload previous model when switching", isOn: $model.unloadPrevious)
                .onChange(of: model.unloadPrevious) { _ in model.persistSettings() }
            Toggle("Unload model when Obby closes", isOn: $model.unloadOnQuit)
                .onChange(of: model.unloadOnQuit) { _ in model.persistSettings() }
            Toggle("Start Ollama automatically when needed", isOn: $model.autoStartOllama)
                .onChange(of: model.autoStartOllama) { _ in model.persistSettings() }
            if let issue = model.ollamaIssue { OllamaIssueView(issue: issue) }
            Picker("Model keep-alive", selection: $model.keepAlive) {
                ForEach(ModelKeepAlive.allCases, id: \.self) { Text($0.label).tag($0) }
            }.onChange(of: model.keepAlive) { _ in model.persistSettings() }
            Text(model.modelStatus).font(.caption).foregroundStyle(.secondary)
            HStack {
                TextField("Ollama URL", text: $url).onSubmit { reconnect() }
                Button("Apply") { reconnect() }.disabled(model.busy || model.switchingModel)
            }.disabled(model.busy || model.switchingModel)
            if let error = model.modelSettingsError { Text(error).font(.caption).foregroundStyle(.red) }
            if !model.toolsAvailable && !model.selectedModel.isEmpty { Text("Chat only · can work with the current note, but cannot use vault tools.").font(.caption).foregroundStyle(.secondary) }
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
