import AppKit

/// Obby's editor shows supported Markdown as formatted text and saves it back as plain Markdown.
/// Supported: **bold**, *italic*, <u>underline</u>, large text, # / ## / ### headings, - bullets, 1. numbers,
/// - [ ] / - [x] checkboxes. Everything else (links, images, code, tables…) stays as literal text.
/// The file on disk is always Markdown: `parse` runs when a note is loaded, `serialize` whenever it changes.
extension NSAttributedString.Key {
    static let obbyBlock = NSAttributedString.Key("obby.block")        // "h1" "h2" "h3" "bullet" "number" "todo" "done"
    static let obbyBold = NSAttributedString.Key("obby.bold")
    static let obbyItalic = NSAttributedString.Key("obby.italic")
    static let obbyUnderline = NSAttributedString.Key("obby.underline")
    static let obbyLarge = NSAttributedString.Key("obby.large")
    static let obbyMarker = NSAttributedString.Key("obby.marker")      // The visible "• ", "1. ", "☐ " in place of "- ", "1. ", "- [ ] "
}

enum RichMarkdown {
    /// Editor text size (display only): View → Bigger / Smaller / Actual Size, or Settings → Notes. 11–28 pt, default 14.
    static let defaultFontSize: Double = 14
    static func clampFontSize(_ value: Double) -> Double { min(max(value.rounded(), 11), 28) }
    static var baseSize: CGFloat {
        let stored = UserDefaults.standard.double(forKey: "editorFontSize")
        return CGFloat(clampFontSize(stored == 0 ? defaultFontSize : stored))
    }
    /// ATX heading level of a line (1–6), or nil: "#hashtag" (no space) is not a heading, nor is anything in a code fence.
    static func headingLevel(_ line: String, inFence: Bool) -> Int? {
        guard !inFence, let match = line.range(of: "^#{1,6}(?= |$)", options: .regularExpression) else { return nil }
        return line.distance(from: match.lowerBound, to: match.upperBound)
    }
    /// Heading levels for every line of a note, tracking ``` fences.
    static func headingLevels(_ markdown: String) -> [Int?] {
        var inFence = false
        return markdown.components(separatedBy: "\n").map { line in
            if line.hasPrefix("```") { inFence.toggle(); return nil }
            return headingLevel(line, inFence: inFence)
        }
    }
    static var baseAttributes: [NSAttributedString.Key: Any] { visual([:], block: nil) }

    // MARK: Markdown → formatted text

    static func parse(_ markdown: String) -> NSMutableAttributedString {
        let out = NSMutableAttributedString()
        var inFence = false
        for (index, line) in markdown.components(separatedBy: "\n").enumerated() {
            if index > 0 { out.append(NSAttributedString(string: "\n")) }
            if line.hasPrefix("```") { inFence.toggle(); out.append(NSAttributedString(string: line)); continue }
            out.append(inFence ? NSAttributedString(string: line) : parseLine(line))
        }
        style(out, range: NSRange(location: 0, length: out.length))
        return out
    }
    static let blockPatterns: [(NSRegularExpression, String)] = [
        ("^### (.+)$", "h3"), ("^## (.+)$", "h2"), ("^# (.+)$", "h1"),
        ("^- \\[[xX]\\] (.*)$", "done"), ("^- \\[ \\] (.*)$", "todo"), ("^[-*] (.*)$", "bullet"), ("^([0-9]{1,9})\\. (.*)$", "number"),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }
    static func parseLine(_ line: String) -> NSMutableAttributedString {
        let ns = line as NSString
        for (pattern, block) in blockPatterns {
            guard let match = pattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) else { continue }
            let result = NSMutableAttributedString()
            if let marker = marker(block, number: block == "number" ? ns.substring(with: match.range(at: 1)) : nil) {
                result.append(NSAttributedString(string: marker, attributes: [.obbyMarker: true]))
            }
            result.append(parseInline(ns.substring(with: match.range(at: match.numberOfRanges - 1)), [:]))
            result.addAttribute(.obbyBlock, value: block, range: NSRange(location: 0, length: result.length))
            return result
        }
        return parseInline(line, [:])
    }
    static func marker(_ block: String, number: String? = nil) -> String? {
        switch block {
        case "bullet": return "• "
        case "number": return (number ?? "1") + ". "
        case "todo": return "☐ "
        case "done": return "☑ "
        default: return nil
        }
    }
    /// Inline styles, innermost first by position; `code` spans are kept exactly as written.
    static let inlinePatterns: [(NSRegularExpression, [NSAttributedString.Key])] = ([
        ("`[^`]+`", []),
        ("\\*\\*\\*(?=\\S)(.+?)(?<=\\S)\\*\\*\\*", [.obbyBold, .obbyItalic]),
        ("\\*\\*(?=\\S)(.+?)(?<=\\S)\\*\\*", [.obbyBold]),
        ("<u>(.+?)</u>", [.obbyUnderline]),
        ("<span style=\"font-size:18px\">(.+?)</span>", [.obbyLarge]),
        ("(?<![*\\w])\\*(?=[^\\s*])(.+?)(?<=[^\\s*])\\*(?![*\\w])", [.obbyItalic]),
    ] as [(String, [NSAttributedString.Key])]).map { (try! NSRegularExpression(pattern: $0.0), $0.1) }
    static func parseInline(_ text: String, _ attributes: [NSAttributedString.Key: Any]) -> NSMutableAttributedString {
        let out = NSMutableAttributedString(), ns = text as NSString
        var position = 0
        while position < ns.length {
            var best: (NSTextCheckingResult, [NSAttributedString.Key])?
            for (pattern, keys) in inlinePatterns {
                if let match = pattern.firstMatch(in: text, range: NSRange(location: position, length: ns.length - position)),
                   best == nil || match.range.location < best!.0.range.location { best = (match, keys) }
            }
            guard let found = best else { break }
            let (match, keys) = found
            out.append(NSAttributedString(string: ns.substring(with: NSRange(location: position, length: match.range.location - position)), attributes: attributes))
            if keys.isEmpty {
                out.append(NSAttributedString(string: ns.substring(with: match.range), attributes: attributes))
            } else {
                var inner = attributes
                for key in keys { inner[key] = true }
                out.append(parseInline(ns.substring(with: match.range(at: 1)), inner))
            }
            position = NSMaxRange(match.range)
        }
        if position < ns.length { out.append(NSAttributedString(string: ns.substring(from: position), attributes: attributes)) }
        return out
    }

    // MARK: Formatted text → Markdown

    static func serialize(_ text: NSAttributedString) -> String {
        var location = 0
        return text.string.components(separatedBy: "\n").map { line in
            let length = (line as NSString).length
            defer { location += length + 1 }
            return serializeLine(text, NSRange(location: location, length: length))
        }.joined(separator: "\n")
    }
    static func serializeLine(_ text: NSAttributedString, _ range: NSRange) -> String {
        guard range.length > 0 else { return "" }
        var contentStart = range.location
        while contentStart < NSMaxRange(range), text.attribute(.obbyMarker, at: contentStart, effectiveRange: nil) != nil { contentStart += 1 }
        let markerText = (text.string as NSString).substring(with: NSRange(location: range.location, length: contentStart - range.location))
        let inline = serializeInline(text, NSRange(location: contentStart, length: NSMaxRange(range) - contentStart))
        guard let block = text.attribute(.obbyBlock, at: range.location, effectiveRange: nil) as? String else { return inline }
        switch block {
        case "h1": return inline.isEmpty ? "" : "# " + inline
        case "h2": return inline.isEmpty ? "" : "## " + inline
        case "h3": return inline.isEmpty ? "" : "### " + inline
        case "bullet": return markerText == "• " ? "- " + inline : inline
        case "todo": return markerText == "☐ " ? "- [ ] " + inline : inline
        case "done": return markerText == "☑ " ? "- [x] " + inline : inline
        case "number": return markerText.range(of: "^[0-9]{1,9}\\. $", options: .regularExpression) != nil ? markerText + inline : inline
        default: return inline // A damaged list marker (e.g. half deleted) leaves a plain line.
        }
    }
    static let inlineOrder: [NSAttributedString.Key] = [.obbyLarge, .obbyUnderline, .obbyBold, .obbyItalic]
    static func serializeInline(_ text: NSAttributedString, _ range: NSRange) -> String {
        guard range.length > 0 else { return "" }
        var out = "", open: [NSAttributedString.Key] = []
        func opening(_ key: NSAttributedString.Key) -> String {
            switch key { case .obbyLarge: return "<span style=\"font-size:18px\">"; case .obbyUnderline: return "<u>"; case .obbyBold: return "**"; default: return "*" }
        }
        func closing(_ key: NSAttributedString.Key) -> String {
            switch key { case .obbyLarge: return "</span>"; case .obbyUnderline: return "</u>"; case .obbyBold: return "**"; default: return "*" }
        }
        func closeAll() { // Trailing spaces go after the closing markers, as Markdown requires.
            guard !open.isEmpty else { return }
            let trimmed = out.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
            let spaces = String(out.dropFirst(trimmed.count))
            out = trimmed + open.reversed().map(closing).joined() + spaces
            open = []
        }
        text.enumerateAttributes(in: range) { attributes, run, _ in
            guard attributes[.obbyMarker] == nil else { return }
            let piece = (text.string as NSString).substring(with: run)
            if piece.trimmingCharacters(in: .whitespaces).isEmpty { out += piece; return } // Spaces keep the current style.
            let want = inlineOrder.filter { attributes[$0] != nil }
            if want != open {
                closeAll()
                let body = piece.replacingOccurrences(of: "^\\s+", with: "", options: .regularExpression)
                out += String(piece.dropLast(body.count)) + want.map(opening).joined()
                open = want
                out += body
            } else { out += piece }
        }
        closeAll()
        return out
    }

    // MARK: Appearance

    static func visual(_ attributes: [NSAttributedString.Key: Any], block: String?) -> [NSAttributedString.Key: Any] {
        let isMarker = attributes[.obbyMarker] != nil
        var size = baseSize, bold = attributes[.obbyBold] != nil, italic = attributes[.obbyItalic] != nil
        switch block {
        case "h1": size = (baseSize * 1.6).rounded(); bold = true
        case "h2": size = (baseSize * 1.35).rounded(); bold = true
        case "h3": size = (baseSize * 1.15).rounded(); bold = true
        default: if attributes[.obbyLarge] != nil { size = (baseSize * 1.15).rounded() }
        }
        if isMarker { size = baseSize; bold = false; italic = false }
        var font = NSFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
        if italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        let done = block == "done" && !isMarker
        var result = attributes
        result[.font] = font
        result[.foregroundColor] = isMarker || done ? NSColor.secondaryLabelColor : NSColor.labelColor
        result[.underlineStyle] = attributes[.obbyUnderline] != nil ? NSUnderlineStyle.single.rawValue : 0
        result[.strikethroughStyle] = done ? NSUnderlineStyle.single.rawValue : 0
        return result
    }
    static func block(in text: NSAttributedString, paragraph: NSRange) -> String? {
        guard paragraph.length > 0, paragraph.location < text.length else { return nil }
        return text.attribute(.obbyBlock, at: paragraph.location, effectiveRange: nil) as? String
    }
    /// Fonts, colours and indents from Obby's own attributes, for every paragraph touching `range`.
    static func style(_ text: NSMutableAttributedString, range: NSRange) {
        let ns = text.string as NSString
        guard ns.length > 0 else { return }
        let whole = ns.paragraphRange(for: NSRange(location: min(range.location, ns.length), length: min(range.length, ns.length - min(range.location, ns.length))))
        text.beginEditing()
        ns.enumerateSubstrings(in: whole, options: [.byParagraphs, .substringNotRequired]) { _, content, enclosing, _ in
            let kind = Self.block(in: text, paragraph: content.length > 0 ? content : enclosing)
            let paragraph = NSMutableParagraphStyle()
            if let kind, let shown = Self.marker(kind, number: "1") {
                paragraph.headIndent = (shown as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: baseSize)]).width
                    + (kind == "number" ? 6 : 0)
            }
            if kind?.hasPrefix("h") == true { paragraph.paragraphSpacingBefore = 6 }
            text.enumerateAttributes(in: enclosing) { attributes, run, _ in text.setAttributes(visual(attributes, block: kind), range: run) }
            text.addAttribute(.paragraphStyle, value: paragraph, range: enclosing)
        }
        text.endEditing()
    }

    // MARK: Toggles

    /// Bold / italic / underline / large: removed if the whole selection already has it, otherwise applied.
    static func toggleInline(_ text: NSMutableAttributedString, range: NSRange, key: NSAttributedString.Key) {
        guard range.length > 0 else { return }
        var all = true
        text.enumerateAttributes(in: range) { attributes, run, stop in
            guard attributes[.obbyMarker] == nil,
                  !(text.string as NSString).substring(with: run).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            if attributes[key] == nil { all = false; stop.pointee = true }
        }
        if all { text.removeAttribute(key, range: range) } else { text.addAttribute(key, value: true, range: range) }
        style(text, range: range)
    }
    static func blockName(_ format: Format) -> String? {
        switch format {
        case .heading: return "h1"; case .heading2: return "h2"; case .heading3: return "h3"
        case .bullet: return "bullet"; case .numbered: return "number"; case .checkbox: return "todo"; case .checked: return "done"
        default: return nil
        }
    }
    /// Headings, lists and checkboxes for the lines touching `range`: removed if every line already has it, otherwise
    /// applied. Returns the replaced range and its new formatted text. Works through Markdown, so inline styles stay.
    static func toggleBlock(_ text: NSAttributedString, range: NSRange, format: Format) -> (NSRange, NSMutableAttributedString)? {
        guard let target = blockName(format) else { return nil }
        let ns = text.string as NSString
        var selection = NSRange(location: min(range.location, ns.length), length: min(range.length, ns.length - min(range.location, ns.length)))
        if selection.length > 0, ns.character(at: NSMaxRange(selection) - 1) == 10 { selection.length -= 1 }
        var lines = ns.lineRange(for: selection)
        if lines.length > 0, ns.character(at: NSMaxRange(lines) - 1) == 10 { lines.length -= 1 }
        let markdown = serialize(text.attributedSubstring(from: lines))
        let current = markdown.components(separatedBy: "\n").map { line -> String? in
            let parsed = parseLine(line)
            return parsed.length > 0 ? parsed.attribute(.obbyBlock, at: 0, effectiveRange: nil) as? String : nil
        }
        let prefixes = "^(#{1,3} |- \\[[ xX]\\] |[-*] |[0-9]{1,9}\\. )"
        let updated: String
        if current.allSatisfy({ $0 == target }) {
            updated = target == "done"
                ? markdown.replacingOccurrences(of: "(?m)^- \\[[xX]\\] ", with: "- [ ] ", options: .regularExpression) // Mark done again: back to open.
                : markdown.replacingOccurrences(of: "(?m)" + prefixes, with: "", options: .regularExpression)
        } else {
            updated = format.apply(to: markdown, range: NSRange(location: 0, length: (markdown as NSString).length)).0
        }
        return (lines, parse(updated))
    }
}
