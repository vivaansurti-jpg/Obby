import Foundation
import Darwin
import ImageIO
import UniformTypeIdentifiers
import PDFKit
import Vision

struct Entry: Identifiable, Hashable {
    var path: String
    var isDirectory: Bool
    var children: [Entry]?
    var id: String { path }
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
}
struct ObbyError: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
final class Vault {
    let root: URL
    let fm = FileManager.default
    private let identity: UInt64?
    init(_ root: URL) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.identity = Self.directoryIdentity(self.root)
    }
    private static func directoryIdentity(_ url: URL) -> UInt64? {
        var info = stat()
        guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return nil }
        return UInt64(info.st_ino)
    }
    var rootExists: Bool { identity != nil && Self.directoryIdentity(root) == identity }

    func resolve(_ path: String, allowRoot: Bool = false) throws -> URL {
        guard rootExists else { throw ObbyError("The Obby folder is no longer available.") }
        guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { throw ObbyError("Use a relative path inside the Obby folder.") }
        let url = root.appendingPathComponent(path).standardizedFileURL
        let resolved = url.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(root.path + "/") || (allowRoot && resolved == root) else { throw ObbyError("Access outside the Obby folder is blocked.") }
        // Reject symlink components, including dangling links, rather than following them.
        var cursor = root
        for component in path.split(separator: "/") {
            cursor.appendPathComponent(String(component))
            if let attrs = try? fm.attributesOfItem(atPath: cursor.path), attrs[.type] as? FileAttributeType == .typeSymbolicLink { throw ObbyError("Symbolic links are not accessible in Obby.") }
        }
        return url
    }
    func entries(_ path: String = "") throws -> [Entry] {
        let url = try resolve(path, allowRoot: true)
        return try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]).compactMap { child in
            let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { return nil }
            let directory = values.isDirectory == true
            guard directory || child.pathExtension.lowercased() == "md" else { return nil }
            return Entry(path: path.isEmpty ? child.lastPathComponent : path + "/" + child.lastPathComponent, isDirectory: directory)
        }.sorted { $0.isDirectory != $1.isDirectory ? $0.isDirectory : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    func tree(_ path: String = "") throws -> [Entry] {
        try entries(path).map { entry in
            var e = entry
            if e.isDirectory { e.children = try tree(e.path) }
            return e
        }
    }
    func markdown(_ path: String) throws -> URL {
        let url = try resolve(path)
        guard url.pathExtension.lowercased() == "md" else { throw ObbyError("Only Markdown (.md) files can be read or written.") }
        return url
    }
    func read(_ path: String) throws -> String { try String(contentsOf: markdown(path), encoding: .utf8) }
    func write(_ path: String, content: String, create: Bool = false) throws {
        let url = try markdown(path)
        if create && fm.fileExists(atPath: url.path) { throw ObbyError("A file already exists at \(path).") }
        if !create && !fm.fileExists(atPath: url.path) { throw ObbyError("The note no longer exists.") }
        let name = url.lastPathComponent, parent = (path as NSString).deletingLastPathComponent
        do {
            if create && !parent.isEmpty { try mkdir(parent) } // Missing parent folders, through resolve() like any folder.
            try atomicWrite(Data(content.utf8), to: url, create: create)
        } catch let error as ObbyError { throw error } catch { throw Self.saveError(name, error) }
    }
    /// "Couldn’t save <name>." plus a short reason; never a temporary file name or a full path.
    static func saveError(_ name: String, _ error: Error) -> ObbyError {
        let reason: String
        switch (error as? CocoaError)?.code {
        case .fileWriteNoPermission?, .fileReadNoPermission?: reason = "Obby doesn’t have permission to write there."
        case .fileWriteOutOfSpace?: reason = "The disk is full."
        case .fileWriteVolumeReadOnly?: reason = "The disk is read-only."
        case .fileWriteFileExists?: reason = "A file with that name already exists."
        case .fileNoSuchFile?, .fileReadNoSuchFile?: reason = "Its folder doesn’t exist."
        default: reason = "The file couldn’t be written."
        }
        return ObbyError("Couldn’t save \(name). \(reason)")
    }
    /// Safe save: write a temporary file beside the note, confirm its size, then atomically move it into place (or
    /// replace the old version). If anything fails the previous version is untouched and the temporary file is removed.
    func atomicWrite(_ data: Data, to url: URL, create: Bool) throws {
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).obby-tmp-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: temp) } // Gone already after a successful move; removed if anything failed.
        try data.write(to: temp, options: .withoutOverwriting)
        guard (try? fm.attributesOfItem(atPath: temp.path)[.size] as? NSNumber)?.intValue == data.count else {
            throw ObbyError("The note couldn’t be saved completely. The previous version was kept.")
        }
        if create { try fm.moveItem(at: temp, to: url) } // Never replaces an existing file.
        else { _ = try fm.replaceItemAt(url, withItemAt: temp) }
    }
    /// Removes temporary files left by an interrupted save or import (for example after a crash).
    func removeStaleTemporaryFiles() {
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsPackageDescendants]) else { return }
        for case let url as URL in walker {
            let name = url.lastPathComponent
            guard name.hasPrefix("."), name.contains(".obby-tmp-") || name.hasPrefix(".obby-import-"),
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            try? fm.removeItem(at: url)
        }
    }
    func mkdir(_ path: String) throws { try fm.createDirectory(at: resolve(path), withIntermediateDirectories: true) }
    func validateMove(_ old: String, _ new: String, checkConflict: Bool = true) throws {
        let source = try resolve(old), destination = try resolve(new)
        guard source != destination else { throw ObbyError("This item is already in that folder.") }
        let values = try source.resourceValues(forKeys: [.isDirectoryKey])
        if values.isDirectory == true {
            guard !destination.path.hasPrefix(source.path + "/") else {
                throw ObbyError("A folder cannot be moved into itself or one of its subfolders.")
            }
        } else { _ = try markdown(old); _ = try markdown(new) }
        let parent = destination.deletingLastPathComponent()
        guard try parent.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw ObbyError("Choose an existing destination folder.")
        }
        if checkConflict && fm.fileExists(atPath: destination.path) {
            throw ObbyError("An item named \(destination.lastPathComponent) already exists in that folder. Nothing was moved. Rename the item or choose another folder.")
        }
    }
    func move(_ old: String, _ new: String) throws {
        try validateMove(old, new)
        try fm.moveItem(at: resolve(old), to: resolve(new))
    }
    func delete(_ path: String) throws {
        let url = try resolve(path)
        let values = try url.resourceValues(forKeys: [.isDirectoryKey])
        if values.isDirectory != true { _ = try markdown(path) }
        try fm.trashItem(at: url, resultingItemURL: nil)
    }
    // Search locally without constructing a tree or exposing it to the model.
    func searchPage(_ query: String, folder: String = "", offset: Int = 0, limit: Int = 50) throws -> [Entry] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ObbyError("Provide a specific search term.") }
        _ = try resolve(folder, allowRoot: true)
        var pending = [folder]
        var matches: [Entry] = []
        var skipped = 0
        while let path = pending.popLast() {
            for entry in try entries(path) {
                if entry.isDirectory { pending.append(entry.path) }
                let match = entry.path.localizedCaseInsensitiveContains(query) || (!entry.isDirectory && ((try? read(entry.path))?.localizedCaseInsensitiveContains(query) == true))
                if match {
                    if skipped < offset { skipped += 1 }
                    else { matches.append(entry); if matches.count >= limit { return matches } }
                }
            }
        }
        return matches
    }
    func search(_ query: String) throws -> [Entry] {
        func walk(_ entries: [Entry]) -> [Entry] { entries.flatMap { [$0] + walk($0.children ?? []) } }
        return try walk(tree()).filter { $0.path.localizedCaseInsensitiveContains(query) || (!$0.isDirectory && ((try? read($0.path))?.localizedCaseInsensitiveContains(query) == true)) }
    }
}

/// A file (or pasted image data with its extension) being attached to a note.
enum AttachmentSource {
    case file(URL)
    case data(Data, String)
}

extension Vault {
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp"]
    static let maxImageBytes = 50_000_000
    static let maxAttachmentBytes = 500_000_000
    static func isImage(_ ext: String) -> Bool { imageExtensions.contains(ext) && UTType(filenameExtension: ext)?.conforms(to: .image) == true }
    /// The one import path for images and documents (drop, paste, toolbar): copies the file into
    /// `<noteFolder>/Attachments/` inside the vault and returns its note-relative path ("Attachments/name.ext").
    /// Bytes are copied (never linked or referenced in place); existing files are never overwritten.
    func importAttachment(_ source: AttachmentSource, noteFolder: String) throws -> String {
        let ext: String, base: String, write: (URL) throws -> Void, expected: Int?
        switch source {
        case .file(let url):
            let file = url.standardizedFileURL.resolvingSymlinksInPath()
            ext = file.pathExtension.lowercased()
            let image = Self.isImage(ext)
            let limit = image ? Self.maxImageBytes : Self.maxAttachmentBytes
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, (values.fileSize ?? 0) <= limit else {
                throw ObbyError("\(url.lastPathComponent) can’t be attached (not a regular file, or larger than \(limit / 1_000_000) MB).")
            }
            let stem = file.deletingPathExtension().lastPathComponent
            if image {
                let data = try Data(contentsOf: file)
                try Self.validateImage(data)
                base = Self.attachmentStem(stem)
                write = { try data.write(to: $0, options: .withoutOverwriting) }
                expected = data.count
            } else {
                base = Self.documentStem(stem)
                write = { try FileManager.default.copyItem(at: file, to: $0) } // Reads the original; never changes it.
                expected = values.fileSize
            }
        case .data(let bytes, let type):
            try Self.validateImage(bytes)
            ext = type.lowercased(); base = "pasted-image"
            write = { try bytes.write(to: $0, options: .withoutOverwriting) }
            expected = bytes.count
        }
        let folder = noteFolder.isEmpty ? "Attachments" : noteFolder + "/Attachments"
        try mkdir(folder) // Through resolve(): stays inside the vault and refuses a symlinked Attachments folder.
        // Copy into a temporary file first and check it, then move it to a free name. The Markdown link is only
        // inserted after this returns, and an existing attachment is never overwritten.
        let temp = try resolve(folder + "/.obby-import-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: temp) }
        do { try write(temp) } catch { throw Self.saveError(base + (ext.isEmpty ? "" : "." + ext), error) }
        let copied = (try? fm.attributesOfItem(atPath: temp.path)[.size] as? NSNumber)?.intValue
        guard copied != nil, expected == nil || copied == expected else { throw ObbyError("The file couldn’t be copied completely. Nothing was added.") }
        let suffix = ext.isEmpty ? "" : "." + ext
        for number in 1...9_999 {
            let name = number == 1 ? base + suffix : "\(base)-\(number)" + suffix
            let target = try resolve(folder + "/" + name)
            if fm.fileExists(atPath: target.path) { continue }
            do { try fm.moveItem(at: temp, to: target) } // Fails rather than replace a file created meanwhile.
            catch let error as CocoaError where error.code == .fileWriteFileExists { continue }
            catch { throw Self.saveError(name, error) }
            guard fm.fileExists(atPath: target.path) else { throw ObbyError("The file couldn’t be added.") }
            return "Attachments/" + name
        }
        throw ObbyError("Too many attachments with that name.")
    }
    static func validateImage(_ data: Data) throws {
        guard data.count <= maxImageBytes, let reader = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(reader) > 0 else {
            throw ObbyError("That image couldn’t be read.")
        }
    }
    /// A readable document name that is still safe in a Markdown link: keeps spaces and letters, drops
    /// brackets, parentheses, slashes and other link-breaking characters.
    static func documentStem(_ stem: String) -> String {
        let unsafe = CharacterSet(charactersIn: "[]()<>/\\:#%`|*?\"").union(.controlCharacters).union(.newlines)
        let cleaned = String(stem.unicodeScalars.map { unsafe.contains($0) ? " " : Character($0) })
        let result = cleaned.split(whereSeparator: \.isWhitespace).joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: ". -"))
        return result.isEmpty ? "attachment" : String(result.prefix(100))
    }

    // MARK: Readable attachments (text extraction for the AI; no OCR, no Office formats)

    static let readableAttachmentExtensions: Set<String> = Set(["pdf", "txt", "md", "markdown", "csv"]).union(imageExtensions)
    static let maxRecognizedPages = 50
    static let maxExtractedCharacters = 400_000
    /// Plain text of a PDF (selectable text via PDFKit), TXT, MD or CSV file inside the vault.
    func attachmentText(_ path: String) throws -> String {
        let url = try resolve(path)
        let name = url.lastPathComponent, ext = url.pathExtension.lowercased()
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true else { throw ObbyError("\(path) was not found.") }
        guard Self.readableAttachmentExtensions.contains(ext) else {
            throw ObbyError("Obby can read PDF, TXT, MD, CSV and image attachments. \(name) can be opened in its own app, but not read.")
        }
        if Self.isImage(ext) { // Text in a photo or screenshot, recognised on this Mac with Apple's Vision framework.
            guard (values?.fileSize ?? 0) <= Self.maxImageBytes, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw ObbyError("\(name) couldn’t be opened as an image.") }
            let text = try Self.recognizeText(in: image)
            guard !text.isEmpty else { throw ObbyError("\(name) contains no recognisable text.") }
            return "[Text recognised in \(name)]\n" + text
        }
        guard ext == "pdf" else {
            guard (values?.fileSize ?? 0) <= 20_000_000 else { throw ObbyError("\(name) is too large to read.") }
            guard let text = String(data: try Data(contentsOf: url), encoding: .utf8) else { throw ObbyError("\(name) isn’t UTF-8 text.") }
            return text.count > Self.maxExtractedCharacters ? String(text.prefix(Self.maxExtractedCharacters)) + "\n\n[Only the first part of \(name) was read.]" : text
        }
        guard let document = PDFDocument(url: url) else { throw ObbyError("\(name) couldn’t be opened as a PDF.") }
        guard !document.isLocked else { throw ObbyError("\(name) is password-protected.") }
        var parts: [String] = [], size = 0, pagesRead = 0, recognized = 0
        for index in 0..<document.pageCount where size < Self.maxExtractedCharacters {
            pagesRead = index + 1
            guard let page = document.page(at: index) else { continue }
            var text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            var label = "[Page \(index + 1)]"
            if text.isEmpty, recognized < Self.maxRecognizedPages, let image = Self.render(page) { // Scanned page: recognise its text.
                recognized += 1
                text = (try? Self.recognizeText(in: image)) ?? ""
                label = "[Page \(index + 1), recognised text]"
            }
            guard !text.isEmpty else { continue }
            parts.append(label + "\n" + text); size += text.count
        }
        guard !parts.isEmpty else { throw ObbyError("\(name) contains no selectable or recognisable text.") }
        var result = parts.joined(separator: "\n\n")
        if pagesRead < document.pageCount { result += "\n\n[Obby read the first \(pagesRead) of \(document.pageCount) pages.]" }
        if recognized == Self.maxRecognizedPages { result += "\n\n[Text recognition stops after \(Self.maxRecognizedPages) scanned pages.]" }
        return result
    }
    /// On-device text recognition (Vision). No network, no extra dependencies; printed and handwritten text.
    static func recognizeText(in image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// A scanned PDF page as an image (2x, white background) for text recognition.
    static func render(_ page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox), scale: CGFloat = 2
        let width = Int(bounds.width * scale), height = Int(bounds.height * scale)
        guard width > 0, height > 0, width * height <= 40_000_000,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        return context.makeImage()
    }
}

/// Markdown links in note text (`[title](path)` and `![alt](path)`), used for clickable attachments and for
/// finding a note's attachments. The note file itself stays plain Markdown.
enum NoteLinks {
    struct Link { let isImage: Bool; let titleRange: NSRange; let destination: String }
    static let pattern = try! NSRegularExpression(pattern: "(!?)(\\[[^\\]\\n]*\\])\\(([^)\\n]+)\\)")
    static func links(in text: String, range: NSRange? = nil) -> [Link] {
        let source = text as NSString
        return pattern.matches(in: text, range: range ?? NSRange(location: 0, length: source.length)).map { match in
            Link(isImage: match.range(at: 1).length > 0, titleRange: match.range(at: 2), destination: source.substring(with: match.range(at: 3)))
        }
    }
    /// A local, relative link target (percent-escapes and <…> removed), or nil for web links, anchors and absolute paths.
    static func target(_ destination: String) -> String? {
        var value = destination.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("<"), value.hasSuffix(">") { value = String(value.dropFirst().dropLast()) }
        value = value.removingPercentEncoding ?? value
        guard !value.isEmpty, !value.hasPrefix("/"), !value.hasPrefix("#"), !value.hasPrefix("~"), !value.contains("://"),
              !value.lowercased().hasPrefix("mailto:"), !value.split(separator: "/").contains("..") else { return nil }
        let parts = value.split(separator: "/").filter { $0 != "." }
        return parts.isEmpty ? nil : parts.joined(separator: "/")
    }
}

extension Vault {
    /// THE attachment resolver, used for AI reading (tool and chat-only), clicks, chat images and attachment lists.
    /// Resolves `link` (as written in a note) relative to `folder` (the note's parent folder, "" for the root),
    /// through `resolve`, so absolute paths, "..", symlinks and anything outside the Obby root are rejected, and
    /// confirms a file exists there. Returns the Obby-relative path and file URL.
    func resolveAttachment(_ link: String, inFolder folder: String) throws -> (path: String, url: URL) {
        guard let target = NoteLinks.target(link) else {
            throw ObbyError("\((link as NSString).lastPathComponent) isn’t a file inside the Obby folder.")
        }
        let name = (target as NSString).lastPathComponent
        let path = folder.isEmpty ? target : folder + "/" + target
        let url = try resolve(path)
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            let place = (target as NSString).deletingLastPathComponent
            throw ObbyError(place == "Attachments" ? "Couldn’t find \(name) in this note’s Attachments folder." : "Couldn’t find \(name) at \(target), relative to this note.")
        }
        return (path, url)
    }
}

extension Vault {
    /// A filename stem that is safe in Markdown links: letters, digits, "-", "_" and "."; everything else becomes "-".
    static func attachmentStem(_ stem: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
        var result = String(stem.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        while result.contains("--") { result = result.replacingOccurrences(of: "--", with: "-") }
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return result.isEmpty ? "image" : String(result.prefix(80))
    }
}

/// Section-level Markdown edits, done by Obby rather than by asking a model to rewrite a whole note.
/// Headings are ATX lines ("#".."######") outside fenced code blocks; a section runs until the next heading of the
/// same or a higher level.
enum MarkdownSections {
    struct Heading { let line: Int; let level: Int; let title: String }
    static func headings(_ lines: [String]) -> [Heading] {
        var result: [Heading] = [], inFence = false
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { inFence.toggle(); continue }
            guard !inFence, trimmed.hasPrefix("#") else { continue }
            let level = trimmed.prefix(while: { $0 == "#" }).count
            let rest = trimmed.dropFirst(level)
            guard level <= 6, rest.isEmpty || rest.first == " " else { continue }
            result.append(Heading(line: index, level: level, title: rest.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#")).trimmingCharacters(in: .whitespaces)))
        }
        return result
    }
    static func normalise(_ heading: String) -> String {
        heading.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "#"))).trimmingCharacters(in: CharacterSet(charactersIn: ":")).lowercased()
    }
    /// The section for `heading`: exact (case-insensitive) title first, otherwise a unique partial match.
    static func locate(_ lines: [String], heading: String, note: String) throws -> (start: Int, end: Int) {
        let all = headings(lines), wanted = normalise(heading)
        var matches = all.filter { normalise($0.title) == wanted }
        if matches.isEmpty, !wanted.isEmpty { matches = all.filter { normalise($0.title).contains(wanted) } }
        guard !matches.isEmpty else {
            let list = all.prefix(12).map { $0.title }.joined(separator: ", ")
            throw ObbyError(all.isEmpty ? "\(note) has no headings." : "\(note) has no section called “\(heading)”. Its headings are: \(list).")
        }
        guard matches.count == 1 else { throw ObbyError("\(note) has more than one section called “\(heading)”. Use the exact heading.") }
        let found = matches[0]
        let end = all.first { $0.line > found.line && $0.level <= found.level }?.line ?? lines.count
        return (found.line, end)
    }
    static func read(_ text: String, heading: String, note: String) throws -> String {
        let lines = text.components(separatedBy: "\n"), range = try locate(lines, heading: heading, note: note)
        return lines[range.start..<range.end].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
    /// Replaces the body under the heading (the heading line itself is kept). A repeated heading line at the start of
    /// `content` is dropped so the heading is not duplicated.
    static func replace(_ text: String, heading: String, with content: String, note: String) throws -> String {
        var lines = text.components(separatedBy: "\n")
        let range = try locate(lines, heading: heading, note: note)
        var body = content.trimmingCharacters(in: .newlines).components(separatedBy: "\n")
        if let first = body.first, first.trimmingCharacters(in: .whitespaces).hasPrefix("#"), normalise(first) == normalise(lines[range.start]) { body.removeFirst() }
        while body.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { body.removeFirst() }
        let tail = range.end < lines.count ? [""] : []
        lines.replaceSubrange((range.start + 1)..<range.end, with: [""] + body + tail)
        return lines.joined(separator: "\n")
    }
    /// Adds `content` at the end of the section, keeping what is already there.
    static func append(_ text: String, heading: String, content: String, note: String) throws -> String {
        var lines = text.components(separatedBy: "\n")
        let range = try locate(lines, heading: heading, note: note)
        var end = range.end
        while end > range.start + 1, lines[end - 1].trimmingCharacters(in: .whitespaces).isEmpty { end -= 1 }
        let addition = content.trimmingCharacters(in: .newlines).components(separatedBy: "\n")
        let tail = range.end < lines.count ? [""] : []
        lines.replaceSubrange(end..<range.end, with: [""] + addition + tail)
        return lines.joined(separator: "\n")
    }
    /// Replaces one exact passage; refuses if it is missing or appears more than once.
    static func replaceText(_ text: String, find: String, with replacement: String, note: String) throws -> String {
        guard !find.isEmpty else { throw ObbyError("Say which text to replace.") }
        let count = text.components(separatedBy: find).count - 1
        guard count == 1 else { throw ObbyError(count == 0 ? "That text isn’t in \(note). Read the note and copy the passage exactly." : "That text appears \(count) times in \(note). Include more of the surrounding text so it matches once.") }
        return text.replacingOccurrences(of: find, with: replacement)
    }
}

