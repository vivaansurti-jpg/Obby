import SwiftUI
import AppKit
import UniformTypeIdentifiers

enum Format: String, CaseIterable {
    case bold = "Bold", italic = "Italic", underline = "Underline", heading = "Heading 1", heading2 = "Heading 2", heading3 = "Heading 3", bullet = "Bullets", numbered = "Numbers", checkbox = "Checklist", checked = "Completed", size = "Large text"
    func apply(to text: String, range: NSRange) -> (String, NSRange) {
        let source = text as NSString
        let safe = NSRange(location: min(range.location, source.length), length: min(range.length, source.length - min(range.location, source.length)))
        var affected = safe
        var replacement: String
        switch self {
        case .bold, .italic, .underline, .size:
            let markers: (String, String)
            switch self { case .bold: markers = ("**", "**"); case .italic: markers = ("*", "*"); case .underline: markers = ("<u>", "</u>"); default: markers = ("<span style=\"font-size:18px\">", "</span>") }
            let selected = source.substring(with: safe)
            replacement = markers.0 + selected + markers.1
            return (source.replacingCharacters(in: safe, with: replacement), NSRange(location: safe.location + (markers.0 as NSString).length, length: safe.length))
        default:
            var adjusted = safe
            if adjusted.length > 0 && source.substring(with: NSRange(location: NSMaxRange(adjusted) - 1, length: 1)) == "\n" { adjusted.length -= 1 }
            affected = source.lineRange(for: adjusted)
            let original = source.substring(with: affected)
            let trailing = original.hasSuffix("\n")
            var lines = original.components(separatedBy: "\n")
            if trailing { lines.removeLast() }
            replacement = lines.enumerated().map { index, line in
                let prefix: String
                switch self { case .heading: prefix = "# "; case .heading2: prefix = "## "; case .heading3: prefix = "### "; case .bullet: prefix = "- "; case .numbered: prefix = "\(index + 1). "; case .checked: prefix = "- [x] "; default: prefix = "- [ ] " }
                let clean = line.replacingOccurrences(of: "^(#{1,6} |[-*] (\\[[ xX]\\] )?|[0-9]+\\. )", with: "", options: .regularExpression)
                return prefix + clean
            }.joined(separator: "\n") + (trailing ? "\n" : "")
        }
        return (source.replacingCharacters(in: affected, with: replacement), NSRange(location: affected.location, length: (replacement as NSString).length))
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
        guard let view = view as? PlainTextView else { return }
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
        guard let view = view as? PlainTextView else { return }
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
        guard let view = view as? PlainTextView else { return }
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
    /// Editor text size changed: restyle the whole note once.
    func applyFontSize() {
        guard let view = view as? PlainTextView, let storage = view.textStorage else { return }
        RichMarkdown.style(storage, range: NSRange(location: 0, length: storage.length))
        view.typingAttributes = RichMarkdown.baseAttributes
        view.highlightLinks()
    }
    /// True toggles on the formatted text (never by wrapping the selection in more Markdown characters).
    func format(_ style: Format) {
        guard let view = view as? PlainTextView, let storage = view.textStorage else { return }
        let selection = view.selectedRange()
        let inlineKey: NSAttributedString.Key?
        switch style {
        case .bold: inlineKey = .obbyBold
        case .italic: inlineKey = .obbyItalic
        case .underline: inlineKey = .obbyUnderline
        case .size: inlineKey = .obbyLarge
        default: inlineKey = nil
        }
        if let key = inlineKey {
            if selection.length == 0 { // No selection: the next typed text starts or stops using the style.
                var typing = view.typingAttributes
                typing[key] = typing[key] == nil ? true : nil
                let paragraph = (storage.string as NSString).paragraphRange(for: selection)
                view.typingAttributes = RichMarkdown.visual(typing, block: RichMarkdown.block(in: storage, paragraph: paragraph))
            } else {
                let changed = NSMutableAttributedString(attributedString: storage.attributedSubstring(from: selection))
                RichMarkdown.toggleInline(changed, range: NSRange(location: 0, length: changed.length), key: key)
                view.replace(selection, with: changed, select: selection)
            }
        } else if let result = RichMarkdown.toggleBlock(storage, range: selection, format: style) {
            view.replace(result.0, with: result.1, select: NSRange(location: result.0.location + result.1.length, length: 0))
        }
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
        guard !sources.isEmpty, importAttachments != nil else { return super.performDragOperation(sender) }
        let index = characterIndexForInsertion(at: convert(sender.draggingLocation, from: nil))
        setSelectedRange(NSRange(location: index, length: 0))
        insertAttachments(sources)
        window?.makeFirstResponder(self)
        return true // Never fall back to inserting the original file path.
    }
    /// The one path for drop, paste and both toolbar buttons: import into Attachments, insert the Markdown reference.
    /// One undoable replacement of formatted text, restyled and followed by the normal change notification.
    func replace(_ range: NSRange, with text: NSAttributedString, select: NSRange) {
        guard let storage = textStorage, shouldChangeText(in: range, replacementString: text.string) else { return }
        isNormalizing = true
        storage.replaceCharacters(in: range, with: text)
        RichMarkdown.style(storage, range: NSRange(location: range.location, length: text.length))
        didChangeText()
        isNormalizing = false
        setSelectedRange(NSRange(location: min(select.location, storage.length), length: min(select.length, storage.length - min(select.location, storage.length))))
    }
    var isNormalizing = false
    /// After an edit: Markdown typed into these paragraphs ("**bold**", "# ", "- ", "1. ", "- [ ] ") becomes
    /// formatting, damaged list markers turn back into plain lines, and fonts are refreshed. Text is re-read through the
    /// same parser used when a note opens, so the result always matches the saved Markdown.
    func normalize(_ range: NSRange) {
        guard let storage = textStorage, !isNormalizing, storage.length > 0 else { return }
        let ns = storage.string as NSString
        let safe = NSRange(location: min(range.location, ns.length), length: min(range.length, ns.length - min(range.location, ns.length)))
        let fromEnd = ns.length - selectedRange().location
        var paragraphs: [NSRange] = []
        ns.enumerateSubstrings(in: ns.paragraphRange(for: safe), options: [.byParagraphs, .substringNotRequired]) { _, content, _, _ in paragraphs.append(content) }
        var fence = MarkdownFence()
        for line in ns.substring(to: paragraphs.first?.location ?? 0).components(separatedBy: "\n").dropLast() { _ = fence.consume(line) }
        let editable = paragraphs.filter { !fence.consume(ns.substring(with: $0)) }
        var changed = false
        for paragraph in editable.reversed() {
            let current = storage.attributedSubstring(from: paragraph)
            let fresh = RichMarkdown.parse(RichMarkdown.serialize(current))
            guard fresh.string != current.string, shouldChangeText(in: paragraph, replacementString: fresh.string) else { continue }
            isNormalizing = true
            storage.replaceCharacters(in: paragraph, with: fresh)
            didChangeText()
            isNormalizing = false
            changed = true
        }
        RichMarkdown.style(storage, range: NSRange(location: safe.location, length: min(storage.length - min(safe.location, storage.length), safe.length + 1)))
        if changed { setSelectedRange(NSRange(location: max(0, storage.length - fromEnd), length: 0)) }
    }
    static func insideFence(_ text: NSString, before location: Int) -> Bool {
        var fence = MarkdownFence()
        for line in text.substring(to: location).components(separatedBy: "\n").dropLast() { _ = fence.consume(line) }
        return fence.isOpen
    }
    /// Return in a list continues it (numbers count up, done items continue as open ones); Return on an empty item
    /// ends the list; Return after a heading continues in normal text.
    override func insertNewline(_ sender: Any?) {
        guard let storage = textStorage else { return super.insertNewline(sender) }
        let ns = storage.string as NSString, caret = selectedRange()
        var paragraph = ns.paragraphRange(for: NSRange(location: caret.location, length: 0))
        if paragraph.length > 0, ns.character(at: NSMaxRange(paragraph) - 1) == 10 { paragraph.length -= 1 }
        guard caret.length == 0, let block = RichMarkdown.block(in: storage, paragraph: paragraph) else { return super.insertNewline(sender) }
        if block.hasPrefix("h") { super.insertNewline(sender); typingAttributes = RichMarkdown.baseAttributes; return }
        var markerEnd = paragraph.location
        while markerEnd < NSMaxRange(paragraph), storage.attribute(.obbyMarker, at: markerEnd, effectiveRange: nil) != nil { markerEnd += 1 }
        if markerEnd == NSMaxRange(paragraph) { // Empty item: end the list.
            replace(paragraph, with: NSAttributedString(string: "", attributes: RichMarkdown.baseAttributes), select: NSRange(location: paragraph.location, length: 0))
            typingAttributes = RichMarkdown.baseAttributes
            return
        }
        let next = block == "done" ? "todo" : block
        let current = ns.substring(with: NSRange(location: paragraph.location, length: markerEnd - paragraph.location))
        let number = block == "number" ? String((Int(current.trimmingCharacters(in: CharacterSet(charactersIn: ". "))) ?? 0) + 1) : nil
        let item = NSMutableAttributedString(string: "\n")
        item.append(NSAttributedString(string: RichMarkdown.marker(next, number: number) ?? "", attributes: [.obbyMarker: true, .obbyBlock: next]))
        replace(caret, with: item, select: NSRange(location: caret.location + item.length, length: 0))
        typingAttributes = RichMarkdown.visual([.obbyBlock: next], block: next)
    }
    /// Copy and drag give Markdown, so pasting elsewhere (or back into Obby) keeps the formatting.
    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard let storage = textStorage, selectedRange().length > 0 else { return super.writeSelection(to: pboard, types: types) }
        pboard.clearContents()
        return pboard.setString(RichMarkdown.serialize(storage.attributedSubstring(from: selectedRange())), forType: .string)
    }
    /// A click on a checkbox ticks or unticks it.
    func toggleCheckbox(at index: Int) -> Bool {
        guard let storage = textStorage, index < storage.length, storage.attribute(.obbyMarker, at: index, effectiveRange: nil) != nil,
              let block = storage.attribute(.obbyBlock, at: index, effectiveRange: nil) as? String, block == "todo" || block == "done" else { return false }
        let ns = storage.string as NSString
        var paragraph = ns.paragraphRange(for: NSRange(location: index, length: 0))
        if paragraph.length > 0, ns.character(at: NSMaxRange(paragraph) - 1) == 10 { paragraph.length -= 1 }
        let markdown = RichMarkdown.serialize(storage.attributedSubstring(from: paragraph))
        let flipped = block == "todo" ? "- [x] " + markdown.dropFirst(6) : "- [ ] " + markdown.dropFirst(6)
        replace(paragraph, with: RichMarkdown.parse(flipped), select: selectedRange())
        return true
    }
    func insertAttachments(_ sources: [AttachmentSource]) {
        if let markdown = importAttachments?(sources) { insertBlock(markdown) }
    }
    /// Shows local links' titles in the link colour (display only; the note text is unchanged).
    func highlightLinks() {
        guard let layout = layoutManager else { return }
        let full = NSRange(location: 0, length: (string as NSString).length)
        layout.removeTemporaryAttribute(.foregroundColor, forCharacterRange: full)
        layout.removeTemporaryAttribute(.underlineStyle, forCharacterRange: full)
        for link in NoteLinks.links(in: string) where NoteLinks.target(link.destination) != nil {
            layout.addTemporaryAttributes([.foregroundColor: NSColor.linkColor, .underlineStyle: NSUnderlineStyle.single.rawValue], forCharacterRange: link.titleRange)
        }
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
        return NoteLinks.links(in: string, range: text.lineRange(for: NSRange(location: index, length: 0)))
            .first { NSLocationInRange(index, $0.titleRange) && NoteLinks.target($0.destination) != nil }?.destination
    }
    /// Inserts Markdown as its own block at the selection, with blank lines around it.
    func insertBlock(_ markdown: String) {
        let text = string as NSString, range = selectedRange()
        let before = text.substring(to: range.location), after = text.substring(from: NSMaxRange(range))
        let lead = before.isEmpty || before.hasSuffix("\n\n") ? "" : before.hasSuffix("\n") ? "\n" : "\n\n"
        let trail = after.isEmpty ? "\n" : after.hasPrefix("\n\n") ? "" : after.hasPrefix("\n") ? "\n" : "\n\n"
        let inserted = lead + markdown + trail
        insertText(inserted, replacementRange: range)
        normalize(NSRange(location: range.location, length: (inserted as NSString).length))
    }
    override func paste(_ sender: Any?) { pastePlain(from: .general) }
    override func pasteAsRichText(_ sender: Any?) { pastePlain(from: .general) }
    override func pasteAsPlainText(_ sender: Any?) { pastePlain(from: .general) }
    func pastePlain(from pasteboard: NSPasteboard) {
        // Copied files, or image data with no text alongside it, become attachments; text is never affected.
        let files = Self.attachmentSources(from: pasteboard, allowData: pasteboard.string(forType: .string) == nil)
        if !files.isEmpty, importAttachments != nil {
            insertAttachments(files)
            return
        }
        guard let text = Self.plainText(from: pasteboard) else { return super.paste(nil) }
        let start = selectedRange().location
        insertText(text, replacementRange: selectedRange()) // Registers undo and goes through the normal change path.
        normalize(NSRange(location: start, length: (text as NSString).length)) // Pasted Markdown shows formatted.
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
        // Only line endings are normalised (Windows/old-Mac to \n) so the .md file stays consistent.
        return text?.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }
}
struct MarkdownEditor: NSViewRepresentable {
    @Binding var text: String
    let bridge: EditorBridge
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
        // Formatted display of the note's Markdown (see RichMarkdown); pasted rich text still arrives as plain text.
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
        view.textStorage?.setAttributedString(RichMarkdown.parse(text))
        view.typingAttributes = RichMarkdown.baseAttributes
        context.coordinator.shown = text
        view.importAttachments = importAttachments
        view.openLink = openLink
        view.highlightLinks()
        view.registerForDraggedTypes(PlainTextView.imageDataTypes.map { $0.0 }) // Image data from other apps (file URLs are already registered).
        bridge.view = view
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        let view = scroll.documentView as! NSTextView
        // Only a change from outside the editor (opening a note, an AI edit) reloads; it goes through the same parser.
        if text != context.coordinator.shown {
            context.coordinator.shown = text
            view.textStorage?.setAttributedString(RichMarkdown.parse(text))
            view.typingAttributes = RichMarkdown.baseAttributes
            view.undoManager?.removeAllActions(); (view as? PlainTextView)?.highlightLinks()
        }
        (view as? PlainTextView)?.importAttachments = importAttachments
        (view as? PlainTextView)?.openLink = openLink
        bridge.view = view
    }
    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownEditor
        var shown = "" // The Markdown currently in the editor, as last loaded or saved.
        init(_ parent: MarkdownEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView, let storage = view.textStorage else { return }
            if let plain = view as? PlainTextView, !plain.isNormalizing {
                plain.normalize(NSRange(location: min(view.selectedRange().location, storage.length), length: 0))
            }
            let markdown = RichMarkdown.serialize(storage)
            shown = markdown
            parent.text = markdown
            (view as? PlainTextView)?.highlightLinks()
        }
    }
}
