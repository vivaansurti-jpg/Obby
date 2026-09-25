import Foundation
import SwiftUI

extension AppModel {
    func runQuickAction(_ action: QuickAction, save: Bool) {
        guard !busy, !switchingModel, let note, !selectedModel.isEmpty, let vault else { return }
        busy = true
        appendChat(role: "You", text: "/" + action.rawValue + (save ? " save" : ""))
        let session = chatSession
        let source = text
        let modelName = selectedModel
        let prompt = "/" + action.rawValue + (save ? " save" : "")
        aiTask = Task {
            defer {
                if session == chatSession { busy = false; aiTask = nil }
                if session == chatSession { persistChat() }
                Task { await refreshModelStatus() }
            }
            do {
                try Task.checkCancellation()
                guard session == chatSession else { return }
                if provider == .ollama {
                    guard await ensureOllamaRunning(launch: true) else {
                        if session == chatSession { appendChat(role: "Obby", text: ollamaIssue?.message ?? OllamaIssue.notRunning.message) }
                        return
                    }
                }
                try Task.checkCancellation()
                guard session == chatSession else { return }
                let selectedProvider = try makeProvider()
                let window = await effectiveContextWindow(selectedProvider)
                try Task.checkCancellation()
                guard session == chatSession else { return }
                let budget = ContextBudget.inputBudget(for: window)
                if selectedProvider.kind == .ollama { usedOllamaModels.insert(modelName) }
                let content = try await condenseLongText(source, title: (note as NSString).lastPathComponent, request: action.instruction, provider: selectedProvider, window: window, allowance: budget * 3 / 4)
                try Task.checkCancellation()
                guard session == chatSession else { return }
                let reply = try await selectedProvider.chat(ChatRequest(model: modelName, system: action.instruction, messages: [["role": "user", "content": content]], tools: nil, temperature: temperature, contextWindow: window, keepAlive: keepAlive.apiValue))
                try Task.checkCancellation()
                guard session == chatSession else { return }
                appendChat(role: "Obby", text: reply.text)
                history = ChatMemory.retainingExchange(history, prompt: prompt, reply: reply.text)
                memory.remember(file: note)
                if memory.title.isEmpty { memory.title = action.title + ": " + (note as NSString).lastPathComponent }
                if save {
                    let existing = Set(flattenedPaths(try vault.tree()))
                    let path = QuickAction.noteName(for: note, action: action, existing: existing)
                    try vault.write(path, content: reply.text, create: true)
                    refresh()
                    let name = (path as NSString).lastPathComponent
                    appendNotice("Saved \(name).")
                    memory.remember(file: path)
                    memory.remember(action: "Created \(name).")
                }
            } catch is CancellationError {
                if session == chatSession { appendChat(role: "Obby", text: "Stopped.") }
            } catch {
                if session == chatSession { appendChat(role: "Obby", text: describe(error)) }
            }
        }
    }

    private func flattenedPaths(_ entries: [Entry]) -> [String] {
        entries.flatMap { [$0.path] + flattenedPaths($0.children ?? []) }
    }
}

struct QuickActionsMenu: View {
    @EnvironmentObject var model: AppModel
    @AppStorage("quickActionSave") private var save = false

    var body: some View {
        Menu {
            ForEach(QuickAction.allCases, id: \.rawValue) { action in
                Button(action.title) { model.runQuickAction(action, save: save) }
            }
            Divider()
            Toggle("Save results as a new note", isOn: $save)
        } label: {
            Image(systemName: "wand.and.stars")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Quick actions")
        .disabled(model.busy || model.note == nil || model.selectedModel.isEmpty)
    }
}
