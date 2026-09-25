import SwiftUI
import AppKit

// Chat presentation only. The model's reply stays raw Markdown in `ChatLine.text`; Obby renders it here.
// Tool activity is summarised by `ActionPresentation.summary` (Swift, deterministic) and shown compactly.
// Nothing in this file is ever sent to a model, and nothing here touches the network.

enum MarkdownBlock {
    case paragraph(String)
    case heading(Int, String)
    case bullet(Int, String)            // indent level, text
    case numbered(Int, String, String)  // indent level, marker, text
    case code(String)
    case quote(String)
    case table([String], [[String]])    // header, rows (padded to header width)
    case image(String, String)          // alt text, source as written
    case rule
}

enum ChatMarkdown {
    /// A small block parser for what chat replies actually use; inline styling is left to Foundation's Markdown parser.
    static func blocks(_ source: String) -> [MarkdownBlock] {
        let lines = source.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var code: [String]?
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))); paragraph = [] }
        }
        var index = 0
        while index < lines.count {
            let line = lines[index]
            index += 1
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if code != nil {
                if trimmed.hasPrefix("```") { blocks.append(.code(code?.joined(separator: "\n") ?? "")); code = nil }
                else { code?.append(line) }
                continue
            }
            if trimmed.hasPrefix("```") { flush(); code = []; continue }
            if trimmed.isEmpty { flush(); continue }
            // Pipe table: a header row followed by a |---|---| separator. Anything else stays plain text.
            if trimmed.contains("|"), index < lines.count, isTableSeparator(lines[index]) {
                let header = tableCells(trimmed)
                if header.count >= 2 {
                    flush()
                    index += 1 // Skip the separator.
                    var rows: [[String]] = []
                    while index < lines.count {
                        let row = lines[index].trimmingCharacters(in: .whitespaces)
                        guard !row.isEmpty, row.contains("|") else { break }
                        var cells = tableCells(row)
                        if cells.count < header.count { cells += Array(repeating: "", count: header.count - cells.count) }
                        rows.append(Array(cells.prefix(header.count)))
                        index += 1
                    }
                    blocks.append(.table(header, rows))
                    continue
                }
            }
            if let image = standaloneImage(trimmed) { flush(); blocks.append(.image(image.0, image.1)); continue }
            let leading = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            let indent = min(leading / 2, 4)
            if let marker = trimmed.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                flush()
                let level = trimmed[marker].filter { $0 == "#" }.count
                var title = String(trimmed[marker.upperBound...])
                if let closing = title.range(of: #"\s+#+\s*$"#, options: .regularExpression) { title.removeSubrange(closing) }
                blocks.append(.heading(level, title))
                continue
            }
            if trimmed.range(of: #"^([-*_])(\s*\1){2,}$"#, options: .regularExpression) != nil { flush(); blocks.append(.rule); continue }
            if let marker = trimmed.range(of: #"^[-*+]\s+"#, options: .regularExpression) {
                flush()
                var item = String(trimmed[marker.upperBound...])
                if item.hasPrefix("[ ] ") { item = "☐ " + String(item.dropFirst(4)) }
                else if item.lowercased().hasPrefix("[x] ") { item = "☑ " + String(item.dropFirst(4)) }
                blocks.append(.bullet(indent, item))
                continue
            }
            if let marker = trimmed.range(of: #"^\d{1,3}[.)]\s+"#, options: .regularExpression) {
                flush()
                let number = String(trimmed[marker].trimmingCharacters(in: .whitespaces).dropLast())
                blocks.append(.numbered(indent, number + ".", String(trimmed[marker.upperBound...])))
                continue
            }
            if trimmed.hasPrefix(">") { flush(); blocks.append(.quote(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))); continue }
            paragraph.append(trimmed)
        }
        if let code { blocks.append(.code(code.joined(separator: "\n"))) } // Unclosed fence: still show it as code.
        flush()
        return blocks
    }
    static func isTableSeparator(_ line: String) -> Bool {
        let cells = tableCells(line.trimmingCharacters(in: .whitespaces))
        return cells.count >= 2 && cells.allSatisfy { $0.range(of: #"^:?-{3,}:?$"#, options: .regularExpression) != nil }
    }
    static func tableCells(_ row: String) -> [String] {
        var body = row
        if body.hasPrefix("|") { body.removeFirst() }
        if body.hasSuffix("|") && !body.hasSuffix("\\|") { body.removeLast() }
        // Split on unescaped pipes; "\|" stays a literal pipe inside a cell.
        var cells: [String] = [], current = "", escaped = false
        for character in body {
            if escaped { current.append(character); escaped = false }
            else if character == "\\" { escaped = true }
            else if character == "|" { cells.append(current); current = "" }
            else { current.append(character) }
        }
        cells.append(current)
        return cells.map { $0.trimmingCharacters(in: .whitespaces) }
    }
    /// `![alt](source)` on a line of its own (an optional "title" is ignored).
    static func standaloneImage(_ line: String) -> (String, String)? {
        guard let regex = try? NSRegularExpression(pattern: #"^!\[([^\]]*)\]\(\s*<?([^)\s>]+)>?(?:\s+"[^"]*")?\s*\)$"#),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let alt = Range(match.range(at: 1), in: line), let source = Range(match.range(at: 2), in: line) else { return nil }
        return (String(line[alt]), String(line[source]))
    }
    /// Bold, italic, inline code, strikethrough and links. Only http(s) links stay clickable; other schemes become plain text.
    static func inline(_ text: String) -> AttributedString {
        guard var styled = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else { return AttributedString(text) }
        let unsafe = styled.runs.compactMap { run -> Range<AttributedString.Index>? in
            guard let url = run.link else { return nil }
            return isWebLink(url) ? nil : run.range
        }
        for range in unsafe { styled[range].link = nil }
        return styled
    }
    static func isWebLink(_ url: URL) -> Bool { ["http", "https"].contains(url.scheme?.lowercased() ?? "") }
}

// Where an image in a reply may come from. Remote images are never fetched.
enum ChatImageSource {
    case local(URL)
    case remote
    case unavailable
    static let formats: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "tif", "bmp"]
    static let maxBytes = 25_000_000
    /// Resolves relative to the displayed note's folder first, then the Obby root. Every candidate goes through
    /// `vault.resolve`, so absolute paths, "..", symlinks and anything outside the Obby root are rejected.
    static func resolve(_ source: String, vault: Vault?, noteFolder: String = "") -> ChatImageSource {
        let raw = source.removingPercentEncoding ?? source
        if let scheme = URLComponents(string: source)?.scheme ?? (raw.range(of: #"^[A-Za-z][A-Za-z0-9+.-]*:"#, options: .regularExpression).map { String(raw[$0].dropLast()) }) {
            return ["http", "https"].contains(scheme.lowercased()) ? .remote : .unavailable // file://, data:, custom schemes: never loaded.
        }
        guard let vault, !raw.hasPrefix("/"), formats.contains((raw as NSString).pathExtension.lowercased()) else { return .unavailable }
        for folder in noteFolder.isEmpty ? [""] : [noteFolder, ""] { // The shared attachment resolver, note folder first.
            guard let url = try? vault.resolveAttachment(source, inFolder: folder).url,
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
                  values.isRegularFile == true, (values.fileSize ?? 0) <= maxBytes else { continue }
            return .local(url)
        }
        return .unavailable
    }
}

struct ChatMarkdownView: View {
    let text: String
    var vault: Vault?
    var noteFolder = "" // Folder of the note shown in the editor; images resolve relative to it first.
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(ChatMarkdown.blocks(text).enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        // Links open in the default browser; any other scheme is ignored (no custom URL handlers or commands).
        .environment(\.openURL, OpenURLAction { url in
            guard ChatMarkdown.isWebLink(url) else { return .discarded }
            NSWorkspace.shared.open(url)
            return .handled
        })
    }
    @ViewBuilder func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let text):
            wrapped(Text(ChatMarkdown.inline(text)))
        case .heading(let level, let text):
            wrapped(Text(ChatMarkdown.inline(text)))
                .font(level == 1 ? .title3.weight(.semibold) : level == 2 ? .headline : .subheadline.weight(.semibold))
                .padding(.top, 4)
        case .bullet(let indent, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(indent == 0 ? "•" : "◦").foregroundStyle(.secondary)
                wrapped(Text(ChatMarkdown.inline(text)))
            }.padding(.leading, CGFloat(indent) * 14)
        case .numbered(let indent, let marker, let text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(marker).monospacedDigit().foregroundStyle(.secondary)
                wrapped(Text(ChatMarkdown.inline(text)))
            }.padding(.leading, CGFloat(indent) * 14)
        case .code(let code):
            Text(code)
                .font(.system(.callout, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
                .padding(8).padding(.trailing, 20) // Room for the copy button.
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .topTrailing) { CopyButton(text: code, label: "Copy code").padding(4) }
        case .quote(let text):
            HStack(alignment: .top, spacing: 8) {
                Rectangle().fill(Color.secondary.opacity(0.5)).frame(width: 2)
                wrapped(Text(ChatMarkdown.inline(text))).foregroundStyle(.secondary)
            }
        case .table(let header, let rows):
            ChatTableView(header: header, rows: rows)
        case .image(let alt, let source):
            ChatImageView(alt: alt, source: ChatImageSource.resolve(source, vault: vault, noteFolder: noteFolder))
        case .rule:
            Divider()
        }
    }
    func wrapped(_ text: Text) -> some View { text.fixedSize(horizontal: false, vertical: true) }
}

struct ChatTableView: View {
    let header: [String]
    let rows: [[String]]
    static let minColumn: CGFloat = 60, maxColumn: CGFloat = 280, cellPadding: CGFloat = 8
    /// Column widths come from the cell text itself (clamped), so every cell gets a definite width to wrap in
    /// and each row's height follows from its content. No GeometryReader, no fixed heights.
    var columnWidths: [CGFloat] {
        header.indices.map { column in
            let widest = ([Self.displayWidth(header[column], bold: true)] + rows.map { Self.displayWidth($0.indices.contains(column) ? $0[column] : "", bold: false) }).max() ?? 0
            return min(max(ceil(widest) + 2 * Self.cellPadding + 2, Self.minColumn), Self.maxColumn)
        }
    }
    /// Width of the text as displayed: the same inline parser the cell renders with, so `**Biology**` measures as
    /// "Biology" in bold, `read_file` in monospace and [OpenAI](url) as "OpenAI". Widest line if the cell has breaks.
    static func displayWidth(_ markdown: String, bold: Bool) -> CGFloat {
        let size = NSFont.systemFontSize
        let rendered = ChatMarkdown.inline(markdown)
        var widest: CGFloat = 0, line: CGFloat = 0
        for run in rendered.runs {
            let intent = run.inlinePresentationIntent ?? []
            let strong = bold || intent.contains(.stronglyEmphasized)
            let font: NSFont = intent.contains(.code) ? .monospacedSystemFont(ofSize: size, weight: strong ? .semibold : .regular)
                : strong ? .boldSystemFont(ofSize: size) : .systemFont(ofSize: size)
            for (index, piece) in String(rendered[run.range].characters).components(separatedBy: "\n").enumerated() {
                if index > 0 { widest = max(widest, line); line = 0 }
                line += (piece as NSString).size(withAttributes: [.font: font]).width
            }
        }
        return max(widest, line)
    }
    var body: some View {
        let widths = columnWidths
        ScrollView(.horizontal, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                row(header, widths: widths, isHeader: true)
                ForEach(Array(rows.enumerated()), id: \.offset) { _, cells in
                    Divider().opacity(0.6)
                    row(cells, widths: widths, isHeader: false)
                }
            }
            .fixedSize() // The table's natural size: total column width by the sum of row heights.
            .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.secondary.opacity(0.25)))
            .padding(1)
        }
        // A horizontal ScrollView has no height of its own; take the content's so later blocks sit below the table.
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 4)
    }
    func row(_ cells: [String], widths: [CGFloat], isHeader: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(widths.enumerated()), id: \.offset) { column, width in
                Text(ChatMarkdown.inline(cells.indices.contains(column) ? cells[column] : ""))
                    .fontWeight(isHeader ? .semibold : .regular)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Self.cellPadding).padding(.vertical, 5)
                    .frame(width: width, alignment: .topLeading)
            }
        }
        .background(isHeader ? Color.secondary.opacity(0.1) : Color.clear)
    }
}

/// Copies exact text (the stored Markdown, or one code block) to the general pasteboard; briefly shows a checkmark.
struct CopyButton: View {
    let text: String
    var label = "Copy response"
    @State private var copied = false
    @State private var hovering = false
    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            copied = true
            Task { @MainActor in // One short reset, no timer.
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                copied = false
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .imageScale(.small)
                .frame(minWidth: 18, minHeight: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .opacity(hovering || copied ? 1 : 0.55) // Subtle until hovered, always visible and keyboard-accessible.
        .onHover { hovering = $0 }
        .help(copied ? "Copied" : label)
        .accessibilityLabel(copied ? "Copied" : label)
    }
}

struct ChatImageView: View {
    let alt: String
    let source: ChatImageSource
    @State private var image: NSImage?
    @State private var failed = false
    var body: some View {
        switch source {
        case .remote:
            placeholder("Remote image not loaded")
        case .unavailable:
            placeholder("Image not available")
        case .local(let url):
            Group {
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: image.size.width, maxHeight: min(image.size.height, 420), alignment: .leading)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .onTapGesture { NSWorkspace.shared.open(url) } // Opens in the default viewer (usually Preview).
                        .help("Open \(url.lastPathComponent)")
                        .accessibilityLabel(alt.isEmpty ? url.lastPathComponent : alt)
                        .accessibilityAddTraits(.isButton)
                } else if failed {
                    placeholder("Image not available")
                } else {
                    ProgressView().controlSize(.small)
                }
            }
            .task(id: url) {
                // The bytes are read off the main actor (Data is Sendable); the NSImage is made here, on the main actor.
                let data = await Task.detached(priority: .utility) { try? Data(contentsOf: url) }.value
                if let data, let loaded = NSImage(data: data), loaded.isValid { image = loaded } else { failed = true }
            }
        }
    }
    func placeholder(_ message: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "photo").accessibilityHidden(true)
            Text(alt.isEmpty ? message : "\(message): \(alt)")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }
}

/// Consecutive tool actions are shown together as one compact list.
struct ChatGroup: Identifiable {
    var lines: [ChatLine]
    var id: UUID { lines.last?.id ?? UUID() } // Last line's id, so scrolling to the newest chat line lands here.
    var isActions: Bool { lines.first?.role == "Action" }
    static func groups(_ chat: [ChatLine]) -> [ChatGroup] {
        var groups: [ChatGroup] = []
        for line in chat {
            if line.role == "Action", let last = groups.last, last.isActions { groups[groups.count - 1].lines.append(line) }
            else { groups.append(ChatGroup(lines: [line])) }
        }
        return groups
    }
}

struct ActionGroupView: View {
    let lines: [ChatLine]
    let showRaw: Bool
    var onUndo: ((ChatLine) -> Void)? = nil
    var taskUndo: (count: Int, action: () -> Void)? = nil // "Undo task (N changes)", shown once per task.
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let taskUndo {
                Button { taskUndo.action() } label: { Label("Undo task (\(taskUndo.count) changes)", systemImage: "arrow.uturn.backward") }
                    .buttonStyle(.link).font(.caption).padding(.bottom, 2)
                    .help("Put back every note this request changed, created or moved, exactly as it was")
            }
            ForEach(lines) { line in
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    Image(systemName: line.unsuccessful ? "exclamationmark.circle" : line.notice ? "info.circle" : "checkmark")
                        .imageScale(.small)
                        .accessibilityHidden(true)
                    Text(line.text.hasSuffix(".") ? String(line.text.dropLast()) : line.text)
                    if let onUndo, line.undo != nil {
                        Button("Undo") { onUndo(line) }.buttonStyle(.link).help("Put the note back exactly as it was before this AI change")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityElement(children: .combine)
                if showRaw && !line.notice {
                    DisclosureGroup("Request and result (read-only)") {
                    if let raw = line.rawAction {
                    HStack { Spacer(); CopyButton(text: raw, label: "Copy action details") }
                    Text(raw)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 5))
                    } else {
                        Text("Details for this action are no longer available. Older details are removed to limit memory use.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    }.font(.caption)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The memory viewer (click "Memory · N items"): what this task remembers, editable and removable item by item.
/// Changes are saved immediately. Notes are never copied here; files are listed by path.
struct MemoryPopover: View {
    @EnvironmentObject var model: AppModel
    @State private var goal = ""
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("This task’s memory").font(.headline)
                Text("Edit the goal below or remove remembered items. Your notes are not changed.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Goal").font(.caption.weight(.semibold))
                    TextField("What this task is for", text: $goal, axis: .vertical).textFieldStyle(.roundedBorder).font(.caption)
                        .onSubmit { saveGoal() }
                    Button("Save goal") { saveGoal() }.font(.caption)
                }
                list("Pinned", \.pinned)
                if !model.memory.summary.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text("Summary").font(.caption.weight(.semibold)); Spacer(); remove { model.memory.summary = "" } }
                        Text(model.memory.summary).font(.caption).fixedSize(horizontal: false, vertical: true)
                    }
                }
                list("Decisions", \.decisions)
                list("Next steps", \.openQuestions)
                list("Preferences for this task", \.preferences)
                list("Completed", \.completedActions)
                if !model.memory.relevantFiles.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Files").font(.caption.weight(.semibold))
                        ForEach(Array(model.memory.relevantFiles.enumerated()), id: \.offset) { index, path in
                            HStack(alignment: .top) {
                                Text(path).font(.caption).strikethrough(!model.fileExists(path)).help(model.fileExists(path) ? path : "No longer exists (moved or deleted outside Obby)")
                                Spacer()
                                remove { model.memory.relevantFiles.remove(at: index) }
                            }
                        }
                    }
                }
                if !model.globalMemory.preferences.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Lasting preferences (every task)").font(.caption.weight(.semibold))
                        ForEach(model.globalMemory.preferences, id: \.self) { item in
                            HStack(alignment: .top) { Text(item).font(.caption).fixedSize(horizontal: false, vertical: true); Spacer(); remove { model.forgetGlobalPreference(item) } }
                        }
                    }
                }
                MemoryDangerZone(includeAll: false) { goal = "" }
            }
            .padding(14)
        }
        .frame(minWidth: 340, idealWidth: 340, minHeight: 300, idealHeight: 440) // Content scrolls; nothing clips with taller controls.
        .onAppear { goal = model.memory.currentGoal }
        .onDisappear { saveGoal() }
    }
    func saveGoal() {
        let trimmed = goal.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != model.memory.currentGoal else { return }
        model.memory.currentGoal = String(trimmed.prefix(240)); model.persistChat()
    }
    @ViewBuilder func list(_ title: String, _ key: WritableKeyPath<ChatRecord, [String]>) -> some View {
        let items = model.memory[keyPath: key]
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption.weight(.semibold))
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .top) {
                        Text(item).font(.caption).fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        remove { if index < model.memory[keyPath: key].count { model.memory[keyPath: key].remove(at: index) } }
                    }
                }
            }
        }
    }
    func remove(_ action: @escaping () -> Void) -> some View {
        Button("Remove") { action(); model.persistChat() }
            .buttonStyle(.borderless).help("Remove from memory")
    }
}

/// Settings → Memory → View: everything Obby remembers across tasks, editable and removable item by item.
struct MemorySettingsSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var newFact = ""
    @State private var newPreference = ""
    @State private var tasks: [ChatRecord] = []
    var body: some View {
        VStack(spacing: 0) {
            List {
                Section("About me") {
                    ForEach(model.globalMemory.aboutMe.indices, id: \.self) { index in
                        editableRow(Binding(get: { index < model.globalMemory.aboutMe.count ? model.globalMemory.aboutMe[index] : "" },
                                            set: { if index < model.globalMemory.aboutMe.count { model.globalMemory.aboutMe[index] = String($0.prefix(GlobalMemory.aboutMeLength)) } }),
                                    remove: { model.globalMemory.aboutMe.remove(at: index) })
                    }
                    addRow("Add a fact about you…", text: $newFact) {
                        model.globalMemory.aboutMe = GlobalMemory.merge(model.globalMemory.aboutMe, [newFact])
                    }
                }
                Section("Lasting preferences") {
                    ForEach(model.globalMemory.preferences.indices, id: \.self) { index in
                        editableRow(Binding(get: { index < model.globalMemory.preferences.count ? model.globalMemory.preferences[index] : "" },
                                            set: { if index < model.globalMemory.preferences.count { model.globalMemory.preferences[index] = String($0.prefix(200)) } }),
                                    remove: { model.globalMemory.preferences.remove(at: index) })
                    }
                    addRow("Add a preference…", text: $newPreference) {
                        let item = newPreference.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !item.isEmpty, !model.globalMemory.preferences.contains(item) { model.globalMemory.preferences = Array((model.globalMemory.preferences + [String(item.prefix(200))]).suffix(10)) }
                    }
                }
                Section("Folder contexts") {
                    let keys = model.globalMemory.folders.keys.sorted()
                    if keys.isEmpty { Text("None yet. Right-click a folder in the sidebar and choose Folder Context…").foregroundStyle(.secondary) }
                    ForEach(keys, id: \.self) { key in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(folderLabel(key)).font(.caption).foregroundStyle(.secondary)
                            TextField("Edit folder context", text: Binding(get: { model.globalMemory.folders[key] ?? "" }, set: { model.globalMemory.folders[key] = String($0.prefix(500)) }))
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                }
                Section("Saved tasks") {
                    if tasks.isEmpty { Text("No saved tasks for this notes folder.").foregroundStyle(.secondary) }
                    ForEach(tasks) { task in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                TextField("Task title", text: Binding(get: { tasks.first { $0.id == task.id }?.title ?? "" },
                                                                      set: { title in rename(task.id, title) }))
                                Text("Last used " + task.updatedAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                }
                Section {
                    DangerZone {
                        Text("These actions remove saved context. Your notes and attachments are kept.")
                            .font(.caption).foregroundStyle(.secondary)
                        ForEach(model.globalMemory.folders.keys.sorted(), id: \.self) { key in
                            ConfirmRemovalButton(title: "Delete context: \(folderLabel(key))", warning: "Deletes the standing instructions for this folder. The folder and its notes are kept.") {
                                model.globalMemory.folders.removeValue(forKey: key)
                            }
                        }
                        ForEach(tasks) { task in
                            ConfirmRemovalButton(title: "Forget task: \(task.title.isEmpty ? "Untitled task" : task.title)", warning: "Deletes this task's saved conversation and memory. Your notes are kept.") {
                                ChatStore.delete(task.id); reloadTasks()
                            }
                        }
                        MemoryDangerZone(includeAll: true, showHeading: false) { reloadTasks() }
                    }
                }
            }
            Divider()
            HStack {
                Text("Edits save automatically. Removing memory never deletes notes or attachments.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }.padding(12)
        }
        .frame(minWidth: 520, idealWidth: 520, minHeight: 460, idealHeight: 560) // The list scrolls; the footer always stays visible.
        .onAppear { reloadTasks() }
        .onChange(of: model.globalMemory) { memory in memory.save() } // Every edit is saved straight away.
        .onDisappear { model.globalMemory.aboutMe.removeAll { $0.trimmingCharacters(in: .whitespaces).isEmpty }; model.globalMemory.preferences.removeAll { $0.trimmingCharacters(in: .whitespaces).isEmpty }; model.reloadSavedChats() }
    }
    func editableRow(_ text: Binding<String>, remove: @escaping () -> Void) -> some View {
        HStack {
            TextField("Edit memory", text: text).textFieldStyle(.roundedBorder)
            Button("Remove", action: remove).buttonStyle(.borderless).help("Remove from memory")
        }
    }
    func addRow(_ placeholder: String, text: Binding<String>, add: @escaping () -> Void) -> some View {
        HStack {
            TextField(placeholder, text: text).onSubmit { add(); text.wrappedValue = "" }
            Button("Add") { add(); text.wrappedValue = "" }.disabled(text.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }
    func folderLabel(_ key: String) -> String {
        let parts = key.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let root = ((parts.first ?? "") as NSString).lastPathComponent
        let folder = parts.count > 1 ? parts[1] : ""
        return folder.isEmpty ? root + " (whole folder)" : root + " › " + folder
    }
    func reloadTasks() { tasks = model.vault.map { ChatStore.all(root: $0.root.path) } ?? [] }
    func rename(_ id: UUID, _ title: String) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].title = String(title.prefix(80))
        ChatStore.save(tasks[index])
        if model.memory.id == id { model.memory.title = tasks[index].title }
    }
}

/// Shared presentation for destructive settings, kept below the editing controls.
struct DangerZone<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Rectangle().fill(Color.red).frame(height: 1)
            Label("Danger zone", systemImage: "exclamationmark.triangle").font(.headline).foregroundStyle(.red)
            content
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
    }
}

struct ConfirmRemovalButton: View {
    let title: String
    let warning: String
    let action: () -> Void
    @State private var confirming = false
    var body: some View {
        Button(title, role: .destructive) { confirming = true }
            .foregroundStyle(.red)
            .alert(title + "?", isPresented: $confirming) {
                Button("Cancel", role: .cancel) {}
                Button(title, role: .destructive, action: action)
            } message: { Text(warning + " This cannot be undone.") }
    }
}

struct MemoryDangerZone: View {
    @EnvironmentObject var model: AppModel
    var includeAll: Bool
    var showHeading = true
    var didClear: () -> Void = {}
    var body: some View {
        Group {
            if showHeading { DangerZone { controls } }
            else { controls }
        }.disabled(model.busy)
    }
    var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Clearing memory also removes saved chat history. Notes and attachments are kept.")
                .font(.caption).foregroundStyle(.secondary)
            ConfirmRemovalButton(title: "Clear this task's memory", warning: "Clears the current task's conversation and memory.") {
                model.clearCurrentChatMemory(); didClear()
            }
            if includeAll {
                ConfirmRemovalButton(title: "Clear all AI memory", warning: "Clears every saved task, personal fact, preference and folder context.") {
                    model.clearAllChatMemory(); didClear()
                }
            }
        }
    }
}
