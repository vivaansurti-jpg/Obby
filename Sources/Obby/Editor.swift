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
    func format(_ style: Format) {
        guard let view else { return }
        // Inline styles only wrap an explicit selection; with nothing selected the note is left untouched.
        if [Format.bold, .italic, .underline, .size].contains(style) && view.selectedRange().length == 0 { return }
        let (text, selection) = style.apply(to: view.string, range: view.selectedRange())
        let full = NSRange(location: 0, length: (view.string as NSString).length)
        if view.shouldChangeText(in: full, replacementString: text) {
            view.replaceCharacters(in: full, with: text)
            view.didChangeText()
            view.setSelectedRange(selection)
            view.window?.makeFirstResponder(view)
        }
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
        insertText(lead + markdown + trail, replacementRange: range)
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
        // Plain Markdown source: no rich text, images or automatic rewriting of what is typed or pasted.
        view.isRichText = false
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
        view.string = text
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
        if view.string != text { view.string = text; view.undoManager?.removeAllActions(); (view as? PlainTextView)?.highlightLinks() }
        (view as? PlainTextView)?.importAttachments = importAttachments
        (view as? PlainTextView)?.openLink = openLink
        bridge.view = view
    }
    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownEditor
        init(_ parent: MarkdownEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
            (view as? PlainTextView)?.highlightLinks()
        }
    }
}
