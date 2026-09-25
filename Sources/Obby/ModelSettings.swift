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

/// A saved OpenAI-compatible endpoint (DeepSeek, OpenRouter, Groq, a VPS…). Only name, URL and the tools
/// flag are stored in UserDefaults; the API key lives in the Keychain under "custom.<id>".
struct CustomProvider: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var baseURL: String
    var tools = true
    var keychainAccount: String { "custom." + id.uuidString }
    var modelKey: String { "model.custom." + id.uuidString }
    static func loadAll() -> [CustomProvider] {
        UserDefaults.standard.data(forKey: "customProviders").flatMap { try? JSONDecoder().decode([CustomProvider].self, from: $0) } ?? []
    }
    static func saveAll(_ list: [CustomProvider]) { UserDefaults.standard.set(try? JSONEncoder().encode(list), forKey: "customProviders") }
    /// The saved provider in use at launch (only when the stored provider is OpenAI-compatible and it still exists).
    static var launchActiveID: UUID? {
        guard ProviderKind.stored == .openAI, let id = UserDefaults.standard.string(forKey: "activeCustomProvider").flatMap(UUID.init(uuidString:)) else { return nil }
        return loadAll().contains { $0.id == id } ? id : nil
    }
    static var launchModelKey: String {
        guard let id = launchActiveID else { return ProviderKind.stored.modelKey }
        return "model.custom." + id.uuidString
    }
    /// Form presets: they only fill in the name and base URL.
    static let presets: [(name: String, url: String)] = [
        ("Custom or own server", ""),
        ("DeepSeek", "https://api.deepseek.com/v1"),
        ("OpenRouter", "https://openrouter.ai/api/v1"),
        ("Groq", "https://api.groq.com/openai/v1"),
        ("Mistral", "https://api.mistral.ai/v1"),
        ("Together AI", "https://api.together.xyz/v1"),
        ("LM Studio (this Mac)", "http://localhost:1234/v1"),
    ]
}

extension AppModel {
    var activeCustom: CustomProvider? { provider == .openAI ? customProviders.first { $0.id == activeCustomID } : nil }
    /// Display name for the active provider: a saved provider's own name, otherwise the built-in label.
    var providerName: String { activeCustom?.name ?? provider.label }
    var activeModelKey: String { activeCustom?.modelKey ?? provider.modelKey }
    var activeBaseURL: String { activeCustom?.baseURL ?? openAIBaseURL }
    var activeTools: Bool { activeCustom?.tools ?? openAITools }
    var activeKeyAccount: String { activeCustom?.keychainAccount ?? provider.rawValue }
    /// Saves a new OpenAI-compatible provider (key to Keychain only) and switches to it.
    func addCustomProvider(name: String, baseURL: String, key: String, tools: Bool) async throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ObbyError("Enter a name for the provider.") }
        let url = try RemoteHTTP.validatedBase(baseURL).absoluteString
        let entry = CustomProvider(name: name, baseURL: url, tools: tools)
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { try Keychain.save(key, account: entry.keychainAccount) }
        customProviders.append(entry); CustomProvider.saveAll(customProviders)
        await switchProvider(.openAI, custom: entry.id)
    }
    /// Removes a saved provider and its Keychain key. If it is in use, Obby switches back to Ollama first.
    func removeCustomProvider(_ entry: CustomProvider) async {
        guard !busy, !switchingModel else { return }
        if activeCustom?.id == entry.id { await switchProvider(.ollama) }
        Keychain.delete(entry.keychainAccount)
        UserDefaults.standard.removeObject(forKey: entry.modelKey)
        customProviders.removeAll { $0.id == entry.id }; CustomProvider.saveAll(customProviders)
    }
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
            if provider != .openAI && !hasAPIKey { return "\(provider.label): API key needed" }
            guard !selectedModel.isEmpty else { return "\(provider.label): No model selected" }
            return "\(selectedModel): \(connected ? "Ready" : "Not verified")"
        }
        if startingOllama { return "Starting Ollama…" }
        guard connected else { return autoStartOllama && ollamaIssue == nil && !selectedModel.isEmpty ? "Ollama starts when needed" : "Ollama is offline" }
        guard !selectedModel.isEmpty else { return "Ollama: No model selected" }
        return "\(selectedModel): \(loadedModels.contains(selectedModel) ? "Loaded" : "Unloaded")"
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
    var isLocalProvider: Bool { provider == .ollama || (provider == .openAI && RemoteHTTP.isLoopback(activeBaseURL)) }
    /// True when quitting should unload the active Ollama model: the setting is on and this session actually used it.
    var needsUnloadOnQuit: Bool { unloadOnQuit && provider == .ollama && !selectedModel.isEmpty && usedOllamaModels.contains(selectedModel) }
    /// One unload request (keep_alive 0) when Obby terminates. Short timeout; Ollama itself keeps running.
    func unloadForQuit() async {
        guard needsUnloadOnQuit else { return }
        let model = selectedModel
        stopStatusTimers()
        _ = try? await request("/api/generate", body: ["model": model, "keep_alive": 0, "stream": false], timeout: 2)
        usedOllamaModels.remove(model); loadedModels.remove(model)
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
            return "The server at \(activeBaseURL) is unavailable."
        }
        return error.localizedDescription
    }

    /// Read-only load state from /api/ps (never /api/chat or /api/generate, never loads or unloads a model).
    /// Called on Obby's own events (launch, becoming active, menus opening, requests, switches, unloads), at the
    /// loaded model's keep-alive expiry, and by the slow fallback check below.
    func refreshModelStatus() async {
        guard provider == .ollama else { return } // Only Ollama has load state; cloud providers are never polled.
        let address = endpoint
        do {
            let response = try await request("/api/ps")
            guard address == endpoint, provider == .ollama else { return }
            let running = response["models"] as? [[String: Any]] ?? []
            loadedModels = Set(running.flatMap { item in [item["name"] as? String, item["model"] as? String].compactMap { $0 } })
            connected = true
            if loadedModels.contains(selectedModel) { modelLoading = false }
            let current = running.first { ($0["name"] as? String) == selectedModel || ($0["model"] as? String) == selectedModel }
            scheduleExpiryCheck(Self.expiry(current?["expires_at"] as? String))
        } catch {
            guard address == endpoint, provider == .ollama else { return }
            connected = false; loadedModels = []; modelLoading = false
            expiryCheck?.cancel(); expiryCheck = nil
        }
    }
    /// Ollama's expires_at (ISO 8601, often with more than three fractional digits).
    static func expiry(_ text: String?) -> Date? {
        guard let text else { return nil }
        let trimmed = text.replacingOccurrences(of: "(\\.\\d{3})\\d+", with: "$1", options: .regularExpression)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: trimmed) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: trimmed)
    }
    /// One check shortly after the model is due to unload. "Keep loaded" (far-future expiry) schedules nothing.
    func scheduleExpiryCheck(_ expiry: Date?) {
        expiryCheck?.cancel(); expiryCheck = nil
        guard let expiry else { return }
        let wait = expiry.timeIntervalSinceNow + 2
        guard wait < 24 * 3600 else { return }
        expiryCheck = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(wait, 1) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.refreshModelStatus()
        }
    }
    /// Fallback while Obby is active and the AI panel is visible: a /api/ps check every 25 seconds. Stopped when the
    /// app goes to the background, the panel closes, or Obby quits.
    func startStatusPoll() {
        guard statusPoll == nil else { return }
        statusPoll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 25_000_000_000)
                guard !Task.isCancelled, let self else { return }
                if self.provider == .ollama, NSApp?.isActive != false, !self.busy { await self.refreshModelStatus() }
            }
        }
    }
    func stopStatusPoll() { statusPoll?.cancel(); statusPoll = nil }
    func stopStatusTimers() { stopStatusPoll(); expiryCheck?.cancel(); expiryCheck = nil }
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
                usedOllamaModels.remove(previous); loadedModels.remove(previous) // Shown as unloaded at once.
            } catch { modelSettingsError = "Could not unload the previous model: \(error.localizedDescription)" }
        }
        await refreshModelStatus()
    }

    // MARK: Providers

    func makeProvider() throws -> AIProvider {
        switch provider {
        case .ollama: return OllamaProvider(send: { try await self.request($0, body: $1) }, stream: { self.streamLines($0, body: $1) })
        case .openAI:
            if let custom = activeCustom { return OpenAICompatibleProvider(base: try RemoteHTTP.validatedBase(custom.baseURL), apiKey: Keychain.read(custom.keychainAccount), toolsEnabled: custom.tools) }
            return OpenAICompatibleProvider(base: try RemoteHTTP.validatedBase(openAIBaseURL), apiKey: apiKey(for: .openAI), toolsEnabled: openAITools)
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
        if kind == .openAI { toolsAvailable = activeTools; return }
        let key = kind.rawValue + "/" + model
        if let cached = toolSupport[key] { toolsAvailable = cached; return }
        guard let current = try? makeProvider() else { return }
        let supported = await current.supportsTools(model)
        toolSupport[key] = supported
        if kind == provider && model == selectedModel { toolsAvailable = supported }
    }
    /// Switches provider live. Leaving Ollama honours "unload previous model when switching".
    /// `custom` picks a saved OpenAI-compatible provider; nil means the built-in provider.
    func switchProvider(_ next: ProviderKind, custom: UUID? = nil) async {
        let customID = next == .openAI ? custom : nil
        guard !busy, !switchingModel, next != provider || customID != activeCustom?.id else { return }
        switchingModel = true
        if provider == .ollama && unloadPrevious && !selectedModel.isEmpty {
            if (try? await request("/api/generate", body: ["model": selectedModel, "keep_alive": 0, "stream": false])) != nil { usedOllamaModels.remove(selectedModel); loadedModels.remove(selectedModel) }
        }
        persistSettings()
        provider = next; activeCustomID = customID
        selectedModel = UserDefaults.standard.string(forKey: activeModelKey) ?? ""
        models = []; connected = false; loadedModels = []; modelSettingsError = nil; ollamaIssue = nil
        // The chat and its memory belong to Obby, not the model: they carry over to the new model or provider.
        hasAPIKey = next == .ollama ? false : Keychain.exists(activeKeyAccount)
        persistSettings()
        switchingModel = false
        await connect()
    }
}
