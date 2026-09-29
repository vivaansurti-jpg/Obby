import AppKit

/// Source styling only. This type never removes markers, changes characters or serializes Markdown.
enum RichMarkdown {
    static let defaultFontSize: Double = 14
    static func clampFontSize(_ value: Double) -> Double { min(max(value.rounded(), 11), 28) }
    static var baseSize: CGFloat {
        let stored = UserDefaults.standard.double(forKey: "editorFontSize")
        return CGFloat(clampFontSize(stored == 0 ? defaultFontSize : stored))
    }
    static var baseAttributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: baseSize), .foregroundColor: NSColor.labelColor]
    }
    struct Line {
        let range: NSRange
        let body: String
        let ending: String
    }
    /// NSString ranges are UTF-16, as required by NSTextView. Separators are never normalized.
    static func lines(_ text: String) -> [Line] {
        let ns = text as NSString
        var result: [Line] = [], position = 0
        while position < ns.length {
            var start = 0, end = 0, contentsEnd = 0
            ns.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: position, length: 0))
            result.append(Line(range: NSRange(location: start, length: end - start), body: ns.substring(with: NSRange(location: start, length: contentsEnd - start)), ending: ns.substring(with: NSRange(location: contentsEnd, length: end - contentsEnd))))
            position = end
        }
        if result.isEmpty || result.last?.ending.isEmpty == false { result.append(Line(range: NSRange(location: ns.length, length: 0), body: "", ending: "")) }
        return result
    }
    enum Region: Equatable { case prose, code, frontmatter }
    static func regions(_ lines: [Line]) -> [Region] {
        var fence = MarkdownFence(), frontmatter = false
        return lines.enumerated().map { index, line in
            let value = line.body.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\u{FEFF}", with: "")
            if index == 0 && value == "---" { frontmatter = true; return .frontmatter }
            if frontmatter {
                if value == "---" || value == "..." { frontmatter = false }
                return .frontmatter
            }
            return fence.consume(line.body) ? .code : .prose
        }
    }
    static func headingLevel(_ line: String, inFence: Bool) -> Int? {
        guard !inFence, let match = matches(#"^ {0,3}(#{1,6})(?:[ \t]+|$)"#, in: line).first else { return nil }
        return match.range(at: 1).length
    }
    static func headingLevels(_ markdown: String) -> [Int?] {
        let rows = lines(markdown), states = regions(rows)
        return rows.enumerated().map { headingLevel($0.element.body, inFence: states[$0.offset] != .prose) }
    }
    static func matches(_ pattern: String, in text: String) -> [NSTextCheckingResult] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
    }
    static let listPattern = #"^([ \t]*)(?:[-+*](?:[ \t]+\[[ xX]\])?|[0-9]{1,9}[.)])[ \t]+"#
    static let checkboxPattern = #"^[ \t]*[-+*][ \t]+\[([ xX])\](?:[ \t]+|$)"#
    static func style(_ text: NSMutableAttributedString, line: Line, region: Region) {
        guard line.range.length > 0 else { return }
        text.setAttributes(baseAttributes, range: line.range)
        if region != .prose {
            text.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: baseSize, weight: .regular), range: line.range)
            return
        }
        func absolute(_ range: NSRange) -> NSRange { NSRange(location: line.range.location + range.location, length: range.length) }
        func dim(_ range: NSRange) { text.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: absolute(range)) }
        func font(_ range: NSRange, traits: NSFontTraitMask) {
            text.enumerateAttribute(.font, in: absolute(range)) { value, part, _ in
                let original = value as? NSFont ?? NSFont.systemFont(ofSize: baseSize)
                text.addAttribute(.font, value: NSFontManager.shared.convert(original, toHaveTrait: traits), range: part)
            }
        }
        if let heading = matches(#"^ {0,3}(#{1,6})(?:[ \t]+|$)"#, in: line.body).first {
            let scales: [CGFloat] = [1.6, 1.35, 1.15, 1.1, 1, 1]
            text.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: (baseSize * scales[heading.range(at: 1).length - 1]).rounded()), range: line.range)
            dim(heading.range)
        }
        if let marker = matches(listPattern, in: line.body).first { dim(marker.range) }
        let code = matches(#"(?<!`)(`+)(?!`)(.*?)(?<!`)\1(?!`)"#, in: line.body)
        func inCode(_ range: NSRange) -> Bool { code.contains { NSIntersectionRange($0.range, range).length > 0 } }
        let styles: [(String, NSFontTraitMask)] = [
            (#"(\*\*\*)(?=\S)(.+?)(?<=\S)(\*\*\*)"#, [.boldFontMask, .italicFontMask]),
            (#"(?<!\*)(\*\*)(?=\S)(.+?)(?<=\S)(\*\*)(?!\*)"#, .boldFontMask),
            (#"(?<![\w*])(\*)(?=\S)(.+?)(?<=\S)(\*)(?![\w*])"#, .italicFontMask),
            (#"(<u>)(.+?)(</u>)"#, [])]
        for (pattern, traits) in styles {
            for match in matches(pattern, in: line.body) where !inCode(match.range) {
                if traits.isEmpty { text.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: absolute(match.range(at: 2))) }
                else { font(match.range(at: 2), traits: traits) }
                dim(match.range(at: 1)); dim(match.range(at: 3))
            }
        }
        for pattern in [#"!?\[\[[^\]\r\n]+\]\]"#, #"(?<![\w#])#[\p{L}_][\p{L}\p{N}_/\-]*"#] {
            for match in matches(pattern, in: line.body) where !inCode(match.range) { text.addAttribute(.foregroundColor, value: NSColor.linkColor, range: absolute(match.range)) }
        }
        for link in NoteLinks.links(in: line.body) where !inCode(link.titleRange) {
            text.addAttribute(.foregroundColor, value: NSColor.linkColor, range: absolute(link.titleRange))
        }
        for match in code {
            text.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: baseSize, weight: .regular), range: absolute(match.range))
            dim(match.range(at: 1))
            dim(NSRange(location: NSMaxRange(match.range) - match.range(at: 1).length, length: match.range(at: 1).length))
        }
    }
}

/// Only edited paragraphs and neighbours get attributes reapplied. When a fence/frontmatter boundary
/// changes, also invalidate paragraphs whose lexical region changed; never rewrite their source.
final class MarkdownStyler {
    private var previous: [RichMarkdown.Region] = []
    private(set) var styledRanges: [NSRange] = []
    func restyle(_ storage: NSMutableAttributedString, edited: NSRange? = nil) {
        let lines = RichMarkdown.lines(storage.string), regions = RichMarkdown.regions(lines)
        let location = min(edited?.location ?? 0, storage.length)
        let end = min(NSMaxRange(edited ?? NSRange(location: 0, length: storage.length)), storage.length)
        let first = lines.lastIndex { $0.range.location <= location } ?? 0
        let last = lines.lastIndex { $0.range.location <= end } ?? first
        let delta = regions.count - previous.count
        styledRanges = []
        storage.beginEditing()
        for index in lines.indices {
            let priorIndex = index > last ? index - delta : index
            let changedRegion = !previous.indices.contains(priorIndex) || previous[priorIndex] != regions[index]
            if edited == nil || (max(0, first - 1)...min(lines.count - 1, last + 1)).contains(index) || changedRegion {
                RichMarkdown.style(storage, line: lines[index], region: regions[index])
                styledRanges.append(lines[index].range)
            }
        }
        storage.endEditing()
        previous = regions
    }
}
