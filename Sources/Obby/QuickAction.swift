import Foundation

enum QuickAction: String, CaseIterable {
    case summarise, flashcards, quiz, outline, revisionNotes
    var title: String { [ .summarise: "Summarise", .flashcards: "Flashcards", .quiz: "Quiz", .outline: "Outline", .revisionNotes: "Revision notes" ][self]! }
    var symbol: String { [ .summarise: "text.alignleft", .flashcards: "rectangle.on.rectangle", .quiz: "questionmark.circle", .outline: "list.bullet.indent", .revisionNotes: "checklist" ][self]! }
    var fileSuffix: String { [ .summarise: "Summary", .flashcards: "Flashcards", .quiz: "Quiz", .outline: "Outline", .revisionNotes: "Revision Notes" ][self]! }
    var instruction: String {
        let format: String
        switch self {
        case .summarise: format = "Write 5-8 concise bullets."
        case .flashcards: format = "Write Q: … then A: … pairs, separated by blank lines."
        case .quiz: format = "Write numbered multiple-choice questions with options A-D. End with an Answers heading and the answers."
        case .outline: format = "Write nested bullets."
        case .revisionNotes: format = "Use Markdown headings and concise bullets."
        }
        return "Use only the entire note's content. \(format) No preamble. Markdown output only."
    }
    static func parse(_ prompt: String) -> (action: QuickAction, save: Bool)? {
        let parts = prompt.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().split(whereSeparator: \.isWhitespace)
        guard let command = parts.first, parts.count <= 2, parts.dropFirst().allSatisfy({ $0 == "save" }) else { return nil }
        let action: QuickAction?
        switch command { case "/summarise", "/summarize": action = .summarise; case "/flashcards": action = .flashcards; case "/quiz": action = .quiz; case "/outline": action = .outline; case "/revision": action = .revisionNotes; default: action = nil }
        return action.map { ($0, parts.count == 2) }
    }
    static func noteName(for notePath: String, action: QuickAction, existing: Set<String>) -> String {
        let folder = (notePath as NSString).deletingLastPathComponent
        let stem = ((notePath as NSString).lastPathComponent as NSString).deletingPathExtension
        var number = 1
        while true {
            let suffix = number == 1 ? "" : " \(number)"
            let name = "\(stem) \(action.fileSuffix)\(suffix).md"
            let path = folder.isEmpty ? name : folder + "/" + name
            if !existing.contains(path) { return path }
            number += 1
        }
    }
}
