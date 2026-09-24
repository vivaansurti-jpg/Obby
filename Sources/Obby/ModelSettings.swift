import SwiftUI
import AppKit

enum OllamaIssue: Equatable {
    case notInstalled, notRunning, didNotStart
    var message: String {
        switch self {
        case .notInstalled: return "Ollama isn’t installed."
        case .notRunning: return "Ollama isn’t running. Open Ollama to use local AI."
        case .didNotStart: return "Ollama didn’t start in time. Open Ollama, then try again."
        }
    }
    static let downloadURL = URL(string: "https://ollama.com/download")!
}

enum ModelKeepAlive: String, CaseIterable {
    case immediately = "0", oneMinute = "1m", fiveMinutes = "5m", forever = "-1"
    var label: String {
        switch self {
        case .immediately: return "Unload immediately"
        case .oneMinute: return "1 minute"
        case .fiveMinutes: return "5 minutes"
        case .forever: return "Keep loaded"
        }
    }
    var apiValue: Any {
        switch self { case .immediately: return 0; case .forever: return -1; default: return rawValue }
    }
}

extension AppModel {
    var modelSelection: Binding<String> {
        Binding(get: { self.selectedModel }, set: { value in
            guard !self.busy, !self.switchingModel, value != self.selectedModel else { return }
            self.switchingModel = true
            Task { await self.selectModel(value); await self.refreshToolSupport(); await self.refreshContextCap() }
        })
    }
    /// Models for pickers; a manually entered model stays visible even if the provider didn't list it.
    var modelChoices: [String] { selectedModel.isEmpty || models.contains(selectedModel) ? models : [selectedModel] + models }
    var modelStatus: String {
        guard provider == .ollama else {
            if provider != .openAI && !hasAPIKey { return "\(provider.label) · API key needed" }
            guard !selectedModel.isEmpty else { return "\(provider.label) · No model selected" }
            return "\(selectedModel) · \(connected ? "Ready" : "Not verified")"
        }
        if startingOllama { return "Starting Ollama…" }
        guard connected else { return autoStartOllama && ollamaIssue == nil && !selectedModel.isEmpty ? "Ollama · Starts when needed" : "Ollama · Offline" }
        guard !selectedModel.isEmpty else { return "Ollama · No model selected" }
        return "\(selectedModel) · \(loadedModels.contains(selectedModel) ? "Loaded" : "Unloaded")"
    }
    /// Whether AI is usable right now; notes never depend on this.
    var aiConfigured: Bool {
        guard !selectedModel.isEmpty else { return false }
        switch provider {
        case .ollama: return true // Ollama is checked (and started if allowed) when a request is made.
        case .openAI: return true // The key is optional for local OpenAI-compatible servers.
        case .anthropic, .gemini: return hasAPIKey
        }
    }
    var isLocalProvider: Bool { provider == .ollama || (provider == .openAI && RemoteHTTP.isLoopback(openAIBaseURL)) }
    var providerBadge: String { "\(isLocalProvider ? "Local" : "Cloud") · \(provider.label)" }
    /// True when quitting should unload the active Ollama model: the setting is on and this session actually used it.
    var needsUnloadOnQuit: Bool { unloadOnQuit && provider == .ollama && !selectedModel.isEmpty && usedOllamaModels.contains(selectedModel) }
    /// One unload request (keep_alive 0) when Obby terminates. Short timeout; Ollama itself keeps running.
    func unloadForQuit() async {
        guard needsUnloadOnQuit else { return }
        let model = selectedModel
        _ = try? await request("/api/generate", body: ["model": model, "keep_alive": 0, "stream": false], timeout: 2)
        usedOllamaModels.remove(model)
    }
    // MARK: Ollama startup (native, no shell, no polling beyond one bounded wait after a launch)

    /// The installed Ollama app, if any: Launch Services lookup first, then the usual Applications folders.
    var ollamaAppURL: URL? {
        for id in ["com.electron.ollama", "ai.ollama.app", "com.ollama.app"] {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { return url }
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [URL(fileURLWithPath: "/Applications/Ollama.app"), home.appendingPathComponent("Applications/Ollama.app")]
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }
    /// One lightweight API check (`/api/version`). Loads no model.
    func ollamaReachable() async -> Bool { (try? await request("/api/version", timeout: 2)) != nil }
    /// Ensures the local Ollama API answers. If it doesn't and `launch` is allowed with the setting on, opens Ollama.app
    /// via NSWorkspace (in the background, never a shell) and waits up to 20 s for the API. Never loads a model.
    func ensureOllamaRunning(launch: Bool) async -> Bool {
        guard provider == .ollama else { return true }
        if await ollamaReachable() { ollamaIssue = nil; return true }
        guard let app = ollamaAppURL else { ollamaIssue = .notInstalled; return false }
        guard autoStartOllama else { ollamaIssue = .notRunning; return false }
        guard launch else { ollamaIssue = nil; return false } // Started later, when AI is actually used.
        if let pending = ollamaLaunch { return await pending.value } // One launch at a time.
        let task = Task { () -> Bool in
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false; config.addsToRecentItems = false
            do { _ = try await NSWorkspace.shared.openApplication(at: app, configuration: config) }
            catch { return false }
            let deadline = Date().addingTimeInterval(20)
            while Date() < deadline {
                if await ollamaReachable() { return true }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            return false
        }
        ollamaLaunch = task; startingOllama = true
        let ready = await task.value
        ollamaLaunch = nil; startingOllama = false
        ollamaIssue = ready ? nil : .didNotStart
        return ready
    }
    /// Plain wording for an unreachable OpenAI-compatible server; Obby never tries to start those.
    func describe(_ error: Error) -> String {
        if provider == .openAI, let failure = error as? URLError,
           [.cannotConnectToHost, .cannotFindHost, .timedOut, .networkConnectionLost, .notConnectedToInternet, .dnsLookupFailed].contains(failure.code) {
            return "The server at \(openAIBaseURL) is unavailable."
        }
        return error.localizedDescription
    }

    /// Event-driven only (launch check, after a request, model switch, unload, failure). Nothing polls this.
    func refreshModelStatus() async {
        guard provider == .ollama else { return } // Only Ollama has load state; cloud providers are never polled.
        let address = endpoint
        do {
            let response = try await request("/api/ps")
            guard address == endpoint, provider == .ollama else { return }
            loadedModels = Set((response["models"] as? [[String: Any]] ?? []).flatMap { item in
                [item["name"] as? String, item["model"] as? String].compactMap { $0 }
            })
            connected = true
        } catch {
            guard address == endpoint, provider == .ollama else { return }
            connected = false; loadedModels = []
        }
    }
    func selectModel(_ next: String) async {
        defer { switchingModel = false }
        guard !busy, next != selectedModel else { return }
        let previous = selectedModel
        selectedModel = next
        // The chat and its memory belong to Obby, not the model: they carry over to the new model or provider.
        persistSettings()
        modelSettingsError = nil
        if provider == .ollama && unloadPrevious && !previous.isEmpty {
            do {
                // An empty generate request with keep_alive zero unloads; never preload next.
                _ = try await request("/api/generate", body: ["model": previous, "keep_alive": 0, "stream": false])
                usedOllamaModels.remove(previous)
            } catch { modelSettingsError = "Could not unload the previous model: \(error.localizedDescription)" }
        }
        await refreshModelStatus()
    }

    // MARK: Providers

    func makeProvider() throws -> AIProvider {
        switch provider {
        case .ollama: return OllamaProvider(send: { try await self.request($0, body: $1) })
        case .openAI: return OpenAICompatibleProvider(base: try RemoteHTTP.validatedBase(openAIBaseURL), apiKey: apiKey(for: .openAI), toolsEnabled: openAITools)
        case .anthropic:
            guard let key = apiKey(for: .anthropic) else { throw ObbyError("Add an Anthropic API key in Settings.") }
            return AnthropicProvider(apiKey: key)
        case .gemini:
            guard let key = apiKey(for: .gemini) else { throw ObbyError("Add a Gemini API key in Settings.") }
            return GeminiProvider(apiKey: key)
        }
    }
    func apiKey(for kind: ProviderKind) -> String? {
        if let cached = apiKeys[kind] { return cached }
        let stored = Keychain.read(kind.rawValue)
        apiKeys[kind] = stored
        return stored
    }
    func saveAPIKey(_ value: String) {
        let key = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, provider != .ollama else { return }
        do {
            try Keychain.save(key, account: provider.rawValue)
            apiKeys[provider] = key; hasAPIKey = true; modelSettingsError = nil
            Task { await connect() }
        } catch { modelSettingsError = error.localizedDescription }
    }
    func removeAPIKey() {
        Keychain.delete(provider.rawValue)
        apiKeys[provider] = nil; hasAPIKey = false; connected = false; models = []
    }
    /// Checks (once per session and model) whether the model supports native tool calling.
    func refreshToolSupport() async {
        let kind = provider, model = selectedModel
        guard !model.isEmpty else { toolsAvailable = true; return }
        if kind == .openAI { toolsAvailable = openAITools; return }
        let key = kind.rawValue + "/" + model
        if let cached = toolSupport[key] { toolsAvailable = cached; return }
        guard let current = try? makeProvider() else { return }
        let supported = await current.supportsTools(model)
        toolSupport[key] = supported
        if kind == provider && model == selectedModel { toolsAvailable = supported }
    }
    /// Switches provider live. Leaving Ollama honours "unload previous model when switching".
    func switchProvider(_ next: ProviderKind) async {
        guard !busy, !switchingModel, next != provider else { return }
        switchingModel = true
        if provider == .ollama && unloadPrevious && !selectedModel.isEmpty {
            if (try? await request("/api/generate", body: ["model": selectedModel, "keep_alive": 0, "stream": false])) != nil { usedOllamaModels.remove(selectedModel) }
        }
        persistSettings()
        provider = next
        selectedModel = UserDefaults.standard.string(forKey: next.modelKey) ?? ""
        models = []; connected = false; loadedModels = []; modelSettingsError = nil; ollamaIssue = nil
        // The chat and its memory belong to Obby, not the model: they carry over to the new model or provider.
        hasAPIKey = next == .ollama ? false : Keychain.exists(next.rawValue)
        persistSettings()
        switchingModel = false
        await connect()
    }
}
