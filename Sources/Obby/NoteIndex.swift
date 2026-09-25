import Foundation

struct NoteSnippet: Equatable {
    let path: String
    let heading: String
    let text: String
    let score: Double
}

actor NoteIndex {
    private struct Chunk {
        let path: String
        let heading: String
        let text: String
        let terms: [String: Int]
        let titleTerms: Set<String>
        let length: Int
    }
    private var chunks: [Chunk] = []
    private var modified: [String: Date] = [:]
    private var indexedRoot: URL?

    private func selectVault(_ vault: Vault) {
        if indexedRoot != vault.root {
            chunks.removeAll(); modified.removeAll(); indexedRoot = vault.root
        }
    }

    func rebuild(vault: Vault) async {
        selectVault(vault)
        let paths = flatten((try? vault.tree()) ?? []).filter { $0.lowercased().hasSuffix(".md") && !hasAttachmentsComponent($0) }
        let wanted = Set(paths)
        chunks.removeAll { !wanted.contains($0.path) }
        modified = modified.filter { wanted.contains($0.key) }
        for path in paths.sorted() {
            let date = try? vault.resolve(path).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            if date == nil || modified[path] != date { read(vault: vault, path: path) }
        }
    }

    func update(vault: Vault, paths: [String]) async {
        selectVault(vault)
        for path in Set(paths).sorted() { read(vault: vault, path: path) }
    }

    private func read(vault: Vault, path: String) {
        chunks.removeAll { $0.path == path }; modified[path] = nil
        guard !hasAttachmentsComponent(path), let url = try? vault.resolve(path),
              let content = try? vault.read(path) else { return }
        let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let available = max(0, 20_000 - chunks.count)
        let fresh = makeChunks(path: path, content: content)
        chunks.append(contentsOf: fresh.prefix(available))
        if fresh.count <= available { modified[path] = date }
    }

    func search(_ query: String, limit: Int = 3, excluding: Set<String> = []) -> [NoteSnippet] {
        let queryTerms = tokens(query)
        guard !queryTerms.isEmpty, limit > 0, !chunks.isEmpty else { return [] }
        let total = Double(chunks.count)
        let average = max(1, Double(chunks.reduce(0) { $0 + $1.length }) / total)
        var documentFrequency: [String: Int] = [:]
        for term in Set(queryTerms) { documentFrequency[term] = chunks.reduce(0) { $0 + ($1.terms[term] == nil ? 0 : 1) } }
        let qf = Dictionary(grouping: queryTerms, by: { $0 }).mapValues(\.count)
        let ranked = chunks.compactMap { chunk -> NoteSnippet? in
            guard !excluding.contains(chunk.path) else { return nil }
            var score = 0.0
            for (term, count) in qf {
                guard let frequency = chunk.terms[term], let df = documentFrequency[term], df > 0 else { continue }
                let idf = log(1 + (total - Double(df) + 0.5) / (Double(df) + 0.5))
                let denominator = Double(frequency) + 1.2 * (1 - 0.75 + 0.75 * Double(chunk.length) / average)
                let boost = chunk.titleTerms.contains(term) ? 2.0 : 1.0
                score += Double(count) * idf * (Double(frequency) * 2.2 / denominator) * boost
            }
            return score > 0 ? NoteSnippet(path: chunk.path, heading: chunk.heading, text: chunk.text, score: score) : nil
        }.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.path != $1.path { return $0.path < $1.path }
            if $0.heading != $1.heading { return $0.heading < $1.heading }
            return $0.text < $1.text
        }

        var result: [NoteSnippet] = []
        var bestByPath: [String: Double] = [:]
        var counts: [String: Int] = [:]
        for item in ranked {
            if counts[item.path, default: 0] >= 2 { continue }
            if let best = bestByPath[item.path], item.score < best * 0.8 { continue }
            if bestByPath[item.path] == nil { bestByPath[item.path] = item.score }
            result.append(item)
            counts[item.path, default: 0] += 1
            if result.count == limit { break }
        }
        return result
    }

    private func flatten(_ entries: [Entry]) -> [String] { entries.flatMap { $0.isDirectory ? flatten($0.children ?? []) : [$0.path] } }
    private func hasAttachmentsComponent(_ path: String) -> Bool { path.split(separator: "/").contains { $0.caseInsensitiveCompare("Attachments") == .orderedSame } }
    private func makeChunks(path: String, content: String) -> [Chunk] {
        var sections: [(heading: String, body: String)] = []
        var headings: [(level: Int, text: String)] = [], body: [String] = []
        var fence: (marker: Character, count: Int)?
        func finish() { if !body.isEmpty { sections.append((headings.map(\.text).joined(separator: " › "), body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))); body = [] } }
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let marker = trimmed.first, marker == "`" || marker == "~" {
                let count = trimmed.prefix { $0 == marker }.count
                if let open = fence {
                    if marker == open.marker, count >= open.count,
                       trimmed.dropFirst(count).trimmingCharacters(in: .whitespaces).isEmpty { fence = nil }
                } else if count >= 3, line.prefix(while: { $0 == " " }).count <= 3 {
                    fence = (marker, count)
                }
                body.append(line); continue
            }
            if fence == nil, let heading = headingLine(line) {
                finish(); while let last = headings.last, last.level >= heading.level { headings.removeLast() }; headings.append(heading); body.append(line); continue
            }
            body.append(line)
        }
        finish()
        if sections.isEmpty { sections = [("", content)] }
        let fileTitle = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        return sections.flatMap { section in split(section.body, limit: 1_200).compactMap { text in
            let allTerms = tokens(text + " " + fileTitle + " " + section.heading)
            guard !allTerms.isEmpty else { return nil }
            return Chunk(path: path, heading: section.heading.isEmpty ? fileTitle : section.heading, text: text, terms: Dictionary(grouping: allTerms, by: { $0 }).mapValues(\.count), titleTerms: Set(tokens(fileTitle + " " + section.heading)), length: allTerms.count)
        } }
    }
    private func headingLine(_ line: String) -> (level: Int, text: String)? {
        guard line.prefix(while: { $0 == " " }).count <= 3, !line.hasPrefix("\t") else { return nil }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let hashes = trimmed.prefix { $0 == "#" }
        guard !hashes.isEmpty, hashes.count <= 6, trimmed.dropFirst(hashes.count).first?.isWhitespace == true else { return nil }
        let text = trimmed.dropFirst(hashes.count).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: #"\s+#+$"#, with: "", options: .regularExpression)
        return text.isEmpty ? nil : (hashes.count, text)
    }
    private func split(_ text: String, limit: Int) -> [String] {
        guard text.count > limit else { return text.isEmpty ? [] : [text] }
        var result: [String] = [], current = ""
        for paragraph in text.components(separatedBy: "\n\n") {
            if !current.isEmpty, current.count + paragraph.count + 2 > limit { result.append(current); current = "" }
            if paragraph.count <= limit { current += (current.isEmpty ? "" : "\n\n") + paragraph }
            else { for piece in stride(from: 0, to: paragraph.count, by: limit) { let start = paragraph.index(paragraph.startIndex, offsetBy: piece); let end = paragraph.index(start, offsetBy: min(limit, paragraph.distance(from: start, to: paragraph.endIndex))); result.append(String(paragraph[start..<end])) } }
        }
        if !current.isEmpty { result.append(current) }; return result
    }
    private func tokens(_ text: String) -> [String] {
        let stop: Set<String> = ["a", "an", "and", "are", "as", "at", "be", "by", "for", "from", "in", "is", "it", "of", "on", "or", "that", "the", "this", "to", "with"]
        return text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).compactMap { raw in
            guard !raw.isEmpty, !stop.contains(raw) else { return nil }; return stem(raw)
        }
    }
    private func stem(_ word: String) -> String {
        for suffix in ["ing", "ed", "es", "s"] where word.hasSuffix(suffix) {
            let value = String(word.dropLast(suffix.count)); if value.count >= 4 { return value }
        }; return word
    }
}
