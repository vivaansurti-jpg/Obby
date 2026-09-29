import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum Format: String, CaseIterable {
    case bold = "Bold", italic = "Italic", underline = "Underline", heading = "Heading 1", heading2 = "Heading 2", heading3 = "Heading 3", bullet = "Bullets", numbered = "Numbers", checkbox = "Checklist", checked = "Completed"
    struct Edit { let range: NSRange; let text: String }
    /// Edits are ordered from the end of the source to the beginning so offsets stay valid.
    func edits(in text: String, range: NSRange) -> ([Edit], NSRange) {
        let ns = text as NSString
        let safe = NSRange(location: min(range.location, ns.length), length: min(range.length, ns.length - min(range.location, ns.length)))
        if [.bold, .italic, .underline].contains(self) {
            let left = self == .bold ? "**" : self == .italic ? "*" : "<u>"
            let right = self == .underline ? "</u>" : left
            let l = (left as NSString).length, r = (right as NSString).length
            let selected = ns.substring(with: safe)
            let selectedItalic = selected.prefix { $0 == "*" }.count % 2 == 1 && selected.reversed().prefix { $0 == "*" }.count % 2 == 1
            if safe.length >= l + r, selected.hasPrefix(left), selected.hasSuffix(right), self != .italic || selectedItalic {
                return ([Edit(range: NSRange(location: NSMaxRange(safe) - r, length: r), text: ""), Edit(range: NSRange(location: safe.location, length: l), text: "")], NSRange(location: safe.location, length: safe.length - l - r))
            }
            let surroundingItalic = ns.substring(to: safe.location).reversed().prefix { $0 == "*" }.count % 2 == 1 && ns.substring(from: NSMaxRange(safe)).prefix { $0 == "*" }.count % 2 == 1
            if safe.location >= l, NSMaxRange(safe) + r <= ns.length, self != .italic || surroundingItalic,
               ns.substring(with: NSRange(location: safe.location - l, length: l)) == left,
               ns.substring(with: NSRange(location: NSMaxRange(safe), length: r)) == right {
                return ([Edit(range: NSRange(location: NSMaxRange(safe), length: r), text: ""), Edit(range: NSRange(location: safe.location - l, length: l), text: "")], NSRange(location: safe.location - l, length: safe.length))
            }
            return ([Edit(range: NSRange(location: NSMaxRange(safe), length: 0), text: right), Edit(range: NSRange(location: safe.location, length: 0), text: left)], NSRange(location: safe.location + l, length: safe.length))
        }
        let all = RichMarkdown.lines(text)
        let first = all.lastIndex { $0.range.location <= safe.location } ?? 0
        let last = all.lastIndex { $0.range.location <= max(safe.location, NSMaxRange(safe) - 1) } ?? first
        let rows = Array(all[first...last])
        let pattern: String
        switch self {
        case .heading: pattern = #"^[ \t]*(#)[ \t]+"#
        case .heading2: pattern = #"^[ \t]*(##)[ \t]+"#
        case .heading3: pattern = #"^[ \t]*(###)[ \t]+"#
        case .bullet: pattern = #"^[ \t]*([-+*])[ \t]+(?!\[)"#
        case .numbered: pattern = #"^[ \t]*([0-9]+[.)])[ \t]+"#
        case .checked: pattern = #"^[ \t]*([-+*][ \t]+\[[xX]\])[ \t]*"#
        default: pattern = #"^[ \t]*([-+*][ \t]+\[ \])[ \t]*"#
        }
        let remove = rows.allSatisfy { !RichMarkdown.matches(pattern, in: $0.body).isEmpty && (self != .bullet || RichMarkdown.matches(RichMarkdown.checkboxPattern, in: $0.body).isEmpty) }
        var edits: [Edit] = []
        for (index, line) in rows.enumerated() {
            let indent = (String(line.body.prefix { $0 == " " || $0 == "\t" }) as NSString).length
            let prefix = RichMarkdown.matches(#"^[ \t]*(?:#{1,6}[ \t]+|[-+*](?:[ \t]+\[[ xX]\])?[ \t]+|[0-9]+[.)][ \t]+)"#, in: line.body).first
            let length = max(0, (prefix?.range.length ?? indent) - indent)
            let marker: String
            switch self {
            case .heading: marker = "# "
            case .heading2: marker = "## "
            case .heading3: marker = "### "
            case .bullet: marker = "- "
            case .numbered: marker = "\(index + 1). "
            case .checked: marker = "- [x] "
            default: marker = "- [ ] "
            }
            edits.append(Edit(range: NSRange(location: line.range.location + indent, length: length), text: remove ? "" : marker))
        }
        let delta = edits.reduce(0) { $0 + ($1.text as NSString).length - $1.range.length }
        return (Array(edits.reversed()), NSRange(location: rows[0].range.location, length: max(0, NSMaxRange(rows.last!.range) - rows[0].range.location + delta)))
    }
    func apply(to text: String, range: NSRange) -> (String, NSRange) {
        let (edits, selection) = edits(in: text, range: range)
        let result = NSMutableString(string: text)
        for edit in edits { result.replaceCharacters(in: edit.range, with: edit.text) }
        return (result as String, selection)
    }
}
/// Plain GFM pipe tables: insert, find the table at the cursor, add a row or a column. Text only; nothing is re-padded.
enum MarkdownTable {
    static func make(columns: Int, rows: Int) -> String {
        let columns = min(max(columns, 1), 10), rows = min(max(rows, 1), 30)
        let header = "|" + (1...columns).map { " Column \($0) |" }.joined()
        let separator = "|" + String(repeating: " --- |", count: columns)
        let body = Array(repeating: "|" + String(repeating: "  |", count: columns), count: rows)
        return ([header, separator] + body).joined(separator: "\n")
    }
    static func isRow(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count >= 2 && trimmed.hasPrefix("|") && trimmed.hasSuffix("|")
    }
    static func cells(_ line: String) -> [String] {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return String(trimmed.dropFirst().dropLast()).components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }
    static func isSeparator(_ line: String) -> Bool {
        isRow(line) && cells(line).allSatisfy { $0.range(of: "^:?-{3,}:?$", options: .regularExpression) != nil }
    }
    static func insideFence(_ lines: [String], _ index: Int) -> Bool {
        var fence = MarkdownFence()
        for line in lines[..<index] { _ = fence.consume(line) }
        return fence.isOpen
    }
    /// The lines of the valid table containing line `index` (header, separator, body), or nil.
    static func table(in lines: [String], at index: Int) -> Range<Int>? {
        guard lines.indices.contains(index), isRow(lines[index]), !insideFence(lines, index) else { return nil }
        var start = index, end = index + 1
        while start > 0, isRow(lines[start - 1]) { start -= 1 }
        while end < lines.count, isRow(lines[end]) { end += 1 }
        guard end - start >= 2, isSeparator(lines[start + 1]) else { return nil }
        return start..<end
    }
    /// An empty row below the current one (below the separator when the cursor is in the header).
    static func addRow(_ lines: [String], at index: Int) -> [String]? {
        guard let range = table(in: lines, at: index) else { return nil }
        let count = cells(lines[range.lowerBound]).count
        var result = lines
        result.insert("|" + String(repeating: "  |", count: count), at: max(index + 1, range.lowerBound + 2))
        return result
    }
    /// An empty cell at the end of every row, and "---" in the separator.
    static func addColumn(_ lines: [String], at index: Int) -> [String]? {
        guard let range = table(in: lines, at: index) else { return nil }
        var result = lines
        for row in range {
            let trimmed = result[row].replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            result[row] = trimmed + (row == range.lowerBound + 1 ? " --- |" : "  |")
        }
        return result
    }
}
final class EditorBridge: ObservableObject {
    weak var view: NSTextView?
    /// Toolbar "Insert image": pick image files, then the same import path as drag-and-drop and paste.
    func insertImage() {
        guard let view = view as? PlainTextView, view.isEditable else { return }
        let range = view.selectedRange()
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.png, .jpeg, .gif, .webP, .heic, .tiff, .bmp]
        panel.prompt = "Insert"
        panel.message = "The images are copied into this note’s Attachments folder."
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        view.window?.makeFirstResponder(view)
        view.setSelectedRange(range) // Insert where the cursor was before the picker opened.
        view.insertAttachments(panel.urls.map { .file($0) })
    }
    /// Toolbar "Attach document": any regular file, through the same import path as images.
    func attachDocument() {
        guard let view = view as? PlainTextView, view.isEditable else { return }
        let range = view.selectedRange()
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Attach"
        panel.message = "The files are copied into this note’s Attachments folder."
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        view.window?.makeFirstResponder(view)
        view.setSelectedRange(range)
        view.insertAttachments(panel.urls.map { .file($0) })
    }
    func insertTable(columns: Int, rows: Int) {
        guard let view = view as? PlainTextView, view.isEditable else { return }
        view.window?.makeFirstResponder(view)
        view.insertBlock(MarkdownTable.make(columns: columns, rows: rows)) // One insertion, one undo step.
    }
    /// Line index of the cursor and the editor's lines.
    private func cursorLine() -> (PlainTextView, [String], Int)? {
        guard let view = view as? PlainTextView else { return nil }
        let text = view.string as NSString
        let location = min(view.selectedRange().location, text.length)
        let index = text.substring(to: location).components(separatedBy: "\n").count - 1
        return (view, view.string.components(separatedBy: "\n"), index)
    }
    var cursorInTable: Bool { cursorLine().map { MarkdownTable.table(in: $0.1, at: $0.2) != nil } ?? false }
    func addTableRow() { changeTable(MarkdownTable.addRow) }
    func addTableColumn() { changeTable(MarkdownTable.addColumn) }
    /// Replaces only the table's lines, as one undoable change.
    private func changeTable(_ change: ([String], Int) -> [String]?) {
        guard let found = cursorLine() else { return }
        let (view, lines, index) = found
        guard let range = MarkdownTable.table(in: lines, at: index), let updated = change(lines, index) else { NSSound.beep(); return }
        let start = lines[..<range.lowerBound].reduce(0) { $0 + ($1 as NSString).length + 1 }
        let old = lines[range].joined(separator: "\n")
        let added = updated.count - lines.count
        let new = updated[range.lowerBound..<(range.upperBound + added)].joined(separator: "\n")
        let caret = view.selectedRange()
        view.replace(NSRange(location: start, length: (old as NSString).length),
                     with: NSAttributedString(string: new, attributes: RichMarkdown.baseAttributes), select: NSRange(location: caret.location, length: 0))
    }
    /// Font-size changes restyle once, without changing source or undo history.
    func applyFontSize() {
        guard let view = view as? PlainTextView else { return }
        view.restyle()
    }
    func format(_ style: Format) {
        guard let view = view as? PlainTextView, view.isEditable else { return }
        let (edits, selection) = style.edits(in: view.string, range: view.selectedRange())
        view.undoManager?.beginUndoGrouping()
        for edit in edits { view.insertText(edit.text, replacementRange: edit.range) }
        view.undoManager?.endUndoGrouping()
        view.setSelectedRange(selection)
        view.window?.makeFirstResponder(view)
    }
}
/// Pastes (and drops) text exactly: the plain-text representation when there is one, otherwise plain text converted
/// from RTF/HTML. Nothing is reformatted; one paste is one edit, so autosave's debounce sees a single change.
final class PlainTextView: NSTextView {
    /// Set by MarkdownEditor: imports files into the vault and returns Markdown to insert.
    var importAttachments: (([AttachmentSource]) -> String?)?
    /// Set by MarkdownEditor: opens a clicked local link (attachment in its default app, note in Obby).
    var openLink: ((String) -> Void)?
    static let imageDataTypes: [(NSPasteboard.PasteboardType, String)] = [
        (.png, "png"), (NSPasteboard.PasteboardType("public.jpeg"), "jpg"), (NSPasteboard.PasteboardType("public.heic"), "heic"),
        (NSPasteboard.PasteboardType("com.compuserve.gif"), "gif"), (NSPasteboard.PasteboardType("org.webmproject.webp"), "webp"), (.tiff, "tiff")]
    /// Local files first (images and documents; folders are skipped). Raw image data only when no files are involved
    /// (Finder also puts icon images on the pasteboard) and, if requested, only when there is no text. URLs are never fetched.
    static func attachmentSources(from pasteboard: NSPasteboard, allowData: Bool) -> [AttachmentSource] {
        let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !files.isEmpty { return files.filter(isRegularFile).map { .file($0) } }
        guard allowData else { return [] }
        for (type, ext) in imageDataTypes {
            guard let data = pasteboard.data(forType: type) else { continue }
            if ext == "tiff", let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) { return [.data(png, "png")] }
            return [.data(data, ext)]
        }
        return []
    }
    static func isRegularFile(_ url: URL) -> Bool { (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
    static func hasAttachments(_ pasteboard: NSPasteboard) -> Bool {
        let files = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        if !files.isEmpty { return files.contains(where: isRegularFile) }
        return pasteboard.availableType(from: imageDataTypes.map { $0.0 }) != nil
    }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let operation = super.draggingEntered(sender)
        return Self.hasAttachments(sender.draggingPasteboard) ? .copy : operation
    }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        let operation = super.draggingUpdated(sender) // Keeps the drop caret following the pointer.
        return Self.hasAttachments(sender.draggingPasteboard) ? .copy : operation
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let sources = Self.attachmentSources(from: sender.draggingPasteboard, allowData: true)
        guard isEditable else { return false }
        guard !sources.isEmpty, importAttachments != nil else { return super.performDragOperation(sender) }
        let index = characterIndexForInsertion(at: convert(sender.draggingLocation, from: nil))
        setSelectedRange(NSRange(location: index, length: 0))
        insertAttachments(sources)
        window?.makeFirstResponder(self)
        return true // Never fall back to inserting the original file path.
    }
    let styler = MarkdownStyler()
    private var editedRange: NSRange?
    func loadSource(_ source: String) {
        textStorage?.setAttributedString(NSAttributedString(string: source))
        restyle()
    }
    func restyle(_ range: NSRange? = nil) {
        guard let storage = textStorage else { return }
        styler.restyle(storage, edited: range)
        typingAttributes = RichMarkdown.baseAttributes
    }
    override func shouldChangeText(in affectedCharRange: NSRange, replacementString: String?) -> Bool {
        guard isEditable, super.shouldChangeText(in: affectedCharRange, replacementString: replacementString) else { return false }
        editedRange = NSRange(location: affectedCharRange.location, length: ((replacementString ?? "") as NSString).length)
        return true
    }
    override func didChangeText() {
        restyle(editedRange ?? selectedRange())
        editedRange = nil
        super.didChangeText() // The binding receives exactly the current source string.
    }
    func replace(_ range: NSRange, with text: NSAttributedString, select: NSRange) {
        guard isEditable else { return }
        insertText(text.string, replacementRange: range) // AppKit retains the existing undo path.
        setSelectedRange(NSRange(location: min(select.location, (string as NSString).length), length: min(select.length, (string as NSString).length - min(select.location, (string as NSString).length))))
    }
    static func insideFence(_ text: NSString, before location: Int) -> Bool {
        let lines = RichMarkdown.lines(text as String), regions = RichMarkdown.regions(lines)
        let index = lines.lastIndex { $0.range.location <= location } ?? 0
        return regions[index] != .prose
    }
    /// Enter preserves the local newline spelling and inserts only the literal continuation marker.
    override func insertNewline(_ sender: Any?) {
        guard isEditable else { return }
        let caret = selectedRange(), lines = RichMarkdown.lines(string), regions = RichMarkdown.regions(lines)
        let index = lines.lastIndex { $0.range.location <= caret.location } ?? 0
        let line = lines[index]
        let newline = line.ending.isEmpty ? (lines.first { !$0.ending.isEmpty }?.ending ?? "\n") : line.ending
        var insertion = newline
        if caret.length == 0, regions[index] == .prose,
           let marker = RichMarkdown.matches(RichMarkdown.listPattern, in: line.body).first,
           caret.location >= line.range.location + NSMaxRange(marker.range) {
            let ns = line.body as NSString
            var prefix = ns.substring(with: marker.range)
            if ns.substring(from: NSMaxRange(marker.range)).trimmingCharacters(in: .whitespaces).isEmpty {
                let indent = String(prefix.prefix { $0 == " " || $0 == "\t" })
                insertText(indent, replacementRange: NSRange(location: line.range.location, length: ns.length))
                return
            }
            if let box = RichMarkdown.matches(RichMarkdown.checkboxPattern, in: prefix).first {
                prefix = (prefix as NSString).replacingCharacters(in: box.range(at: 1), with: " ")
            } else if let number = RichMarkdown.matches(#"[0-9]+(?=[.)])"#, in: prefix).first {
                let value = Int((prefix as NSString).substring(with: number.range)) ?? 0
                prefix = (prefix as NSString).replacingCharacters(in: number.range, with: String(value + 1))
            }
            insertion += prefix
        }
        insertText(insertion, replacementRange: caret)
    }
    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard selectedRange().length > 0 else { return super.writeSelection(to: pboard, types: types) }
        pboard.clearContents()
        return pboard.setString((string as NSString).substring(with: selectedRange()), forType: .string)
    }
    /// Toggle exactly the space/x inside the source checkbox; everything else stays untouched.
    func toggleCheckbox(at index: Int) -> Bool {
        guard isEditable, index >= 0, index < (string as NSString).length else { return false }
        let lines = RichMarkdown.lines(string), regions = RichMarkdown.regions(lines)
        guard let row = lines.lastIndex(where: { $0.range.location <= index }), regions[row] == .prose,
              let match = RichMarkdown.matches(RichMarkdown.checkboxPattern, in: lines[row].body).first else { return false }
        let character = lines[row].range.location + match.range(at: 1).location
        guard (character - 1...character + 1).contains(index) else { return false }
        let caret = selectedRange(), old = (string as NSString).substring(with: NSRange(location: character, length: 1))
        insertText(old == " " ? "x" : " ", replacementRange: NSRange(location: character, length: 1))
        setSelectedRange(caret)
        return true
    }
    func insertAttachments(_ sources: [AttachmentSource]) {
        guard isEditable else { return }
        if let markdown = importAttachments?(sources) { insertBlock(markdown) }
    }
    /// A plain click on a link's [title] opens it; hold Option (or any modifier) to place the cursor there instead.
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 1, let layout = layoutManager, let container = textContainer {
            let point = convert(event.locationInWindow, from: nil)
            let local = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
            let index = layout.characterIndex(for: local, in: container, fractionOfDistanceBetweenInsertionPoints: nil)
            if toggleCheckbox(at: index) { return }
        }
        if event.clickCount == 1, event.modifierFlags.intersection([.command, .option, .shift, .control]).isEmpty,
           let destination = linkDestination(at: convert(event.locationInWindow, from: nil)) {
            openLink?(destination); return
        }
        super.mouseDown(with: event)
    }
    func linkDestination(at point: NSPoint) -> String? {
        guard openLink != nil, let layout = layoutManager, let container = textContainer else { return nil }
        let local = NSPoint(x: point.x - textContainerOrigin.x, y: point.y - textContainerOrigin.y)
        let index = layout.characterIndex(for: local, in: container, fractionOfDistanceBetweenInsertionPoints: nil)
        let text = string as NSString
        guard index < text.length else { return nil }
        let glyphs = layout.glyphRange(forCharacterRange: NSRange(location: index, length: 1), actualCharacterRange: nil)
        guard layout.boundingRect(forGlyphRange: glyphs, in: container).contains(local) else { return nil }
        if let markdown = NoteLinks.links(in: string, range: text.lineRange(for: NSRange(location: index, length: 0)))
            .first(where: { NSLocationInRange(index, $0.titleRange) && NoteLinks.target($0.destination) != nil }) { return markdown.destination }
        if let wiki = WikiLinks.links(in: string).first(where: { NSLocationInRange(index, $0.range) }) { return "[[" + wiki.target + "]]" }
        if let tag = WikiLinks.tags(in: string).first(where: { NSLocationInRange(index, $0.range) }) { return "#" + tag.name }
        return nil
    }
    /// Inserts Markdown as its own block at the selection, with blank lines around it.
    func insertBlock(_ markdown: String) {
        let text = string as NSString, range = selectedRange()
        let before = text.substring(to: range.location), after = text.substring(from: NSMaxRange(range))
        let lead = before.isEmpty || before.hasSuffix("\n\n") ? "" : before.hasSuffix("\n") ? "\n" : "\n\n"
        let trail = after.isEmpty ? "\n" : after.hasPrefix("\n\n") ? "" : after.hasPrefix("\n") ? "\n" : "\n\n"
        let inserted = lead + markdown + trail
        insertText(inserted, replacementRange: range)
    }
    override func paste(_ sender: Any?) { pastePlain(from: .general) }
    override func pasteAsRichText(_ sender: Any?) { pastePlain(from: .general) }
    override func pasteAsPlainText(_ sender: Any?) { pastePlain(from: .general) }
    func pastePlain(from pasteboard: NSPasteboard) {
        guard isEditable else { return }
        // Copied files, or image data with no text alongside it, become attachments; text is never affected.
        let files = Self.attachmentSources(from: pasteboard, allowData: pasteboard.string(forType: .string) == nil)
        if !files.isEmpty, importAttachments != nil {
            insertAttachments(files)
            return
        }
        guard let text = Self.plainText(from: pasteboard) else { return super.paste(nil) }
        insertText(text, replacementRange: selectedRange()) // Registers undo and goes through the normal change path.
    }
    static func plainText(from pasteboard: NSPasteboard) -> String? {
        var text = pasteboard.string(forType: .string)
        if text == nil {
            for type in [NSPasteboard.PasteboardType.rtf, .rtfd, .html] {
                guard let data = pasteboard.data(forType: type) else { continue }
                let kind: NSAttributedString.DocumentType = type == .html ? .html : type == .rtfd ? .rtfd : .rtf
                if let rich = try? NSAttributedString(data: data, options: [.documentType: kind, .characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil) {
                    text = rich.string; break
                }
            }
        }
        return text // Literal text, including its line endings.
    }
}
struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    let bridge: EditorBridge
    var readOnly = false
    var importAttachments: (([AttachmentSource]) -> String?)? = nil
    var openLink: ((String) -> Void)? = nil
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        let size = scroll.contentSize
        let view = PlainTextView(frame: NSRect(origin: .zero, size: size))
        view.minSize = NSSize(width: 0, height: size.height)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.textContainer?.containerSize = NSSize(width: size.width, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = view
        // Markdown source is the text storage. Attributes affect display only.
        view.isRichText = true
        view.usesFontPanel = false
        view.usesRuler = false
        view.importsGraphics = false
        view.allowsUndo = true
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isAutomaticLinkDetectionEnabled = false
        view.isAutomaticDataDetectionEnabled = false
        view.isAutomaticTextCompletionEnabled = false
        view.smartInsertDeleteEnabled = false // Otherwise AppKit adds or removes spaces around pasted text.
        view.font = .systemFont(ofSize: 16)
        view.textColor = .labelColor
        view.backgroundColor = .textBackgroundColor
        view.textContainerInset = NSSize(width: 28, height: 24)
        view.autoresizingMask = [.width]
        view.textContainer?.widthTracksTextView = true
        view.delegate = context.coordinator
        view.loadSource(text)
        view.isEditable = !readOnly
        view.typingAttributes = RichMarkdown.baseAttributes
        context.coordinator.shown = text
        view.importAttachments = importAttachments
        view.openLink = openLink
        view.registerForDraggedTypes(PlainTextView.imageDataTypes.map { $0.0 }) // Image data from other apps (file URLs are already registered).
        bridge.view = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        let view = scroll.documentView as! PlainTextView
        // Only an external byte change reloads the source.
        view.isEditable = !readOnly
        if !text.utf8.elementsEqual(context.coordinator.shown.utf8) {
            context.coordinator.shown = text
            view.loadSource(text)
            view.typingAttributes = RichMarkdown.baseAttributes
            view.undoManager?.removeAllActions()
        }
        view.importAttachments = importAttachments
        view.openLink = openLink
        bridge.view = view
    }
    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownEditor
        var shown = "" // The Markdown currently in the editor, as last loaded or saved.
        init(_ parent: MarkdownEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView, let storage = view.textStorage else { return }
            shown = storage.string
            parent.text = storage.string
        }
    }
}
