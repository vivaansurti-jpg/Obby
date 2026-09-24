import SwiftUI
import AppKit

// First-run setup: intro → notes folder → AI provider → provider details → done. Shown only when Obby has never
// been configured (no saved folder and setup not completed). AI steps can be skipped; notes never depend on AI.

extension AppModel {
    static let newNotesFolderName = "Obby Main Notes"
    /// "Create New Obby Folder": pick a location (Documents recommended); Obby creates `<location>/Obby Main Notes` and
    /// uses it directly as the notes root. Picking a folder already named that uses it (no extra nesting).
    func createObbyFolder() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
        panel.prompt = "Create Obby Folder Here"
        panel.message = "Choose where to create your “Obby Main Notes” folder. Documents is recommended, but any location works."
        guard panel.runModal() == .OK, let location = panel.url else { return }
        let name = AppModel.newNotesFolderName
        let folder = location.lastPathComponent == name ? location : location.appendingPathComponent(name)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            openVault(folder)
        } catch { self.error = error.localizedDescription }
    }
    /// "Use Existing Notes Folder": the chosen folder is the notes root, loaded exactly as it is.
    func useExistingNotesFolder() {
        guard !busy else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.prompt = "Use This Folder"
        panel.message = "Choose the folder that holds your notes. Nothing in it is moved or renamed."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        openVault(url)
    }
    /// What the chosen folder already holds, from the tree Obby just loaded.
    var notesFolderSummary: String {
        func count(_ entries: [Entry]) -> (folders: Int, notes: Int) {
            entries.reduce((0, 0)) { total, entry in
                let inner = count(entry.children ?? [])
                return (total.0 + (entry.isDirectory ? 1 : 0) + inner.0, total.1 + (entry.isDirectory ? 0 : 1) + inner.1)
            }
        }
        let found = count(tree)
        func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }
        if found.folders + found.notes == 0 { return "No notes here yet. Obby will keep your notes in this folder." }
        return "Existing notes found: \(plural(found.notes, "note")) in \(plural(found.folders, "folder"))."
    }
    func finishOnboarding() {
        UserDefaults.standard.set(true, forKey: "onboardingDone")
        showOnboarding = false
        refresh() // The chosen folder's notes are in the sidebar straight away.
    }
}

struct OnboardingView: View {
    @EnvironmentObject var model: AppModel
    @State private var step = 0
    @State private var apiKey = ""
    @State private var baseURL = ""
    @State private var modelName = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if step > 0 { Text("Step \(step) of 4").font(.caption).foregroundStyle(.secondary) }
            Group {
                switch step {
                case 0: introStep
                case 1: folderStep
                case 2: providerStep
                case 3: setupStep
                default: doneStep
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Spacer(minLength: 0)
            HStack {
                if step == 1 { Button("Skip Setup") { model.finishOnboarding() }.buttonStyle(.link) }
                if step > 1 && step < 4 { Button("Back") { step -= 1 } }
                Spacer()
                if step == 2 || step == 3 { Button("Set Up AI Later") { step = 4 } }
                switch step {
                case 0: Button("Get Started") { step = 1 }.keyboardShortcut(.defaultAction)
                case 1: Button("Continue") { step = 2 }.keyboardShortcut(.defaultAction).disabled(model.vault == nil)
                case 2: Button("Continue") { step = 3; syncFields(); Task { await model.connect(launch: true) } }.keyboardShortcut(.defaultAction).disabled(model.switchingModel)
                case 3: Button("Continue") { applyFields(); step = 4 }.keyboardShortcut(.defaultAction)
                default: Button("Open Obby") { model.finishOnboarding() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(36)
        .frame(maxWidth: 580, maxHeight: 500)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    var introStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Obby").font(.largeTitle.weight(.semibold))
            Text("Simple Markdown notes with AI.").font(.title3).foregroundStyle(.secondary)
            Text("Obby is a lightweight macOS notes app built around normal folders and .md files. There is no special note database. Your notes stay as ordinary files you can open in Finder, VS Code, Obsidian, or any Markdown editor.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Obby’s AI assistant can:")
            VStack(alignment: .leading, spacing: 3) {
                ForEach(["summarize your notes", "answer questions about them", "help organize folders", "create and edit notes", "search through your notes", "work with local Ollama models or supported cloud providers"], id: \.self) { item in
                    Text("•  " + item)
                }
            }
            .foregroundStyle(.secondary)
        }
    }

    var folderStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose where your notes live.").font(.title3)
            Text("Recommended: Documents/Obby Main Notes").foregroundStyle(.secondary)
            Text("All notes are stored as normal .md files inside this folder. Images and other supported attachments are also kept alongside your notes inside this folder.")
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Create New Obby Folder…") { model.createObbyFolder() }
                Button("Use Existing Notes Folder…") { model.useExistingNotesFolder() }
            }
            if let vault = model.vault {
                VStack(alignment: .leading, spacing: 4) {
                    Label(vault.root.path, systemImage: "folder").lineLimit(2)
                    Text(model.notesFolderSummary).foregroundStyle(.secondary)
                }
                .font(.caption)
            }
        }
    }

    var providerStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choose an AI provider.").font(.title3)
            Text("AI is optional. Obby works as a normal notes app without it.").foregroundStyle(.secondary)
            Picker("AI provider", selection: Binding(get: { model.provider }, set: { next in Task { await model.switchProvider(next); syncFields() } })) {
                ForEach(ProviderKind.allCases) { kind in
                    Text(kind == .ollama ? "Ollama (Local)" : kind.label).tag(kind)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            .disabled(model.switchingModel)
            Text(model.provider == .ollama ? "Runs AI models locally on your Mac. Obby can start Ollama automatically when you use AI." : "No local server is required. Relevant note content may be sent to your selected provider when you ask Obby to work with it.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder var setupStep: some View {
        if model.provider == .ollama {
            VStack(alignment: .leading, spacing: 12) {
                Text("Set up Ollama.").font(.title3)
                if model.startingOllama {
                    Text("Starting Ollama…").foregroundStyle(.secondary)
                } else if model.ollamaIssue == .notInstalled {
                    OllamaIssueView(issue: .notInstalled)
                } else if !model.connected {
                    Text("Obby can’t reach Ollama at \(model.endpoint). Open the Ollama app, then check again.").foregroundStyle(.secondary)
                } else if model.models.isEmpty {
                    Text("Ollama is running, but no models are installed. Install a model in the Ollama app, then check again.").foregroundStyle(.secondary)
                } else {
                    Picker("Model", selection: model.modelSelection) {
                        ForEach(model.models, id: \.self) { Text($0).tag($0) }
                    }
                    .frame(maxWidth: 360)
                    Text("Ollama runs models locally on your Mac.").font(.caption).foregroundStyle(.secondary)
                }
                Button("Check Again") { Task { await model.connect(launch: true) } }.disabled(model.startingOllama)
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("Set up \(model.provider.label).").font(.title3)
                if model.provider == .openAI {
                    TextField("Base URL", text: $baseURL, prompt: Text("https://api.openai.com/v1"))
                }
                SecureField("API key", text: $apiKey, prompt: Text(model.hasAPIKey ? "Saved in Keychain" : (model.provider == .openAI ? "Optional for local servers" : "API key")))
                TextField("Model", text: $modelName, prompt: Text("Model name"))
                if !model.models.isEmpty {
                    Menu("Choose a model") { ForEach(model.models, id: \.self) { name in Button(name) { modelName = name } } }.fixedSize()
                }
                if let error = model.modelSettingsError { Text(error).font(.caption).foregroundStyle(.red) }
                Text("Your API key is stored in the macOS Keychain. Relevant note content may be sent to \(model.provider.label) when you ask Obby to work with it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .textFieldStyle(.roundedBorder)
            .frame(maxWidth: 420)
        }
    }

    var doneStep: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("You’re ready.").font(.title3)
            Text("Your notes are normal Markdown files.")
            Text("Your AI provider can be changed anytime in Settings.")
            if let vault = model.vault { Label(vault.root.path, systemImage: "folder").font(.caption).foregroundStyle(.secondary).lineLimit(2) }
        }
    }

    func syncFields() { baseURL = model.openAIBaseURL; modelName = model.selectedModel; apiKey = "" }
    func applyFields() {
        guard model.provider != .ollama else { return }
        let url = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if model.provider == .openAI, !url.isEmpty, (try? RemoteHTTP.validatedBase(url)) != nil { model.openAIBaseURL = url; model.persistSettings() }
        if !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { model.saveAPIKey(apiKey); apiKey = "" }
        let name = modelName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { model.modelSelection.wrappedValue = name }
    }
}
