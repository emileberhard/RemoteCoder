import Foundation

/// The step-through state of one question card, kept pure so its rules are
/// testable without a view: preselection, advancing, navigation, and when
/// Send becomes available.
struct QuestionFlow: Equatable {
    enum Answer: Equatable {
        case option(Int)
        case freeText(String)
    }

    let questions: [QuestionPrompt.Question]
    private(set) var answers: [Answer?]
    private(set) var indices: [Int]
    private(set) var current: Int
    /// The option a question had before free text replaced it; restored when the text is cleared.
    private var previousOptions: [Int?]

    init(questions: [QuestionPrompt.Question]) {
        self.questions = questions
        indices = Array(questions.indices)
        // The tool contract preselects the recommended (first) option; free text starts empty.
        answers = questions.map { $0.options.isEmpty ? nil : .option(0) }
        previousOptions = answers.map { answer in
            if case .option(let index) = answer { return index }
            return nil
        }
        current = 0
    }

    var count: Int { indices.count }
    var hasSeveral: Bool { indices.count > 1 }
    var isFirst: Bool { current == indices.first }
    var isLast: Bool { current == indices.last }

    func selectedOption(at index: Int) -> Int? {
        if case .option(let option) = answers[index] { return option }
        return nil
    }

    func freeText(at index: Int) -> String {
        if case .freeText(let text) = answers[index] { return text }
        return ""
    }

    func isAnswered(_ index: Int) -> Bool {
        switch answers[index] {
        case .option: return true
        case .freeText(let text): return !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case nil: return false
        }
    }

    /// Preselected options count; a free-text question needs non-whitespace text.
    var canSend: Bool { !indices.isEmpty && indices.allSatisfy(isAnswered) }

    /// Every answer as text in question order; nil until `canSend`.
    var answerTexts: [String]? {
        guard canSend else { return nil }
        return indices.map { index in
            switch answers[index] {
            case .option(let option): return questions[index].options[option]
            case .freeText(let text): return text.trimmingCharacters(in: .whitespacesAndNewlines)
            case nil: return ""
            }
        }
    }

    mutating func updateIndices(_ active: [Int]) {
        indices = active.filter { questions.indices.contains($0) }
        if !indices.contains(current) { current = indices.first ?? 0 }
    }

    func entries(itemID: String) -> [QuestionReplyEnvelope.Entry]? {
        guard let texts = answerTexts else { return nil }
        return zip(indices, texts).map { index, answer in
            .init(itemID: itemID, index: index, reply: .init(question: questions[index].title, answer: answer))
        }
    }

    @discardableResult
    mutating func select(option: Int, at index: Int) -> Bool {
        guard questions.indices.contains(index), questions[index].options.indices.contains(option) else { return false }
        let changed = answers[index] != .option(option)
        answers[index] = .option(option)
        previousOptions[index] = option
        return changed
    }

    /// Typed text replaces the option; clearing it restores the option the question had.
    mutating func setFreeText(_ text: String, at index: Int) {
        guard questions.indices.contains(index) else { return }
        answers[index] = text.isEmpty ? previousOptions[index].map(Answer.option) : .freeText(text)
    }

    mutating func advance() {
        if let offset = indices.firstIndex(of: current), offset + 1 < count { current = indices[offset + 1] }
    }

    mutating func back() {
        if let offset = indices.firstIndex(of: current), offset > 0 { current = indices[offset - 1] }
    }

    @discardableResult
    mutating func jump(to index: Int) -> Bool {
        guard indices.contains(index), current != index else { return false }
        current = index
        return true
    }
}
