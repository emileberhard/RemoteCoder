import Foundation
import Testing
@testable import RemoteCoderCore

struct QuestionFlowTests {
    private let questions = [
        QuestionPrompt.Question(title: "Which approach?", options: ["Rewrite", "Patch"]),
        QuestionPrompt.Question(title: "Why?", options: []),
        QuestionPrompt.Question(title: "Ship today?", options: ["Yes", "No"]),
    ]

    @Test func recommendedOptionsArePreselectedAndFreeTextStartsEmpty() {
        let flow = QuestionFlow(questions: questions)
        #expect(flow.current == 0)
        #expect(flow.selectedOption(at: 0) == 0)
        #expect(flow.selectedOption(at: 1) == nil)
        #expect(flow.freeText(at: 1) == "")
        #expect(flow.isAnswered(0))
        #expect(!flow.isAnswered(1))
        // Preselection counts, but the free-text question still blocks Send.
        #expect(!flow.canSend)
        #expect(flow.answerTexts == nil)
    }

    @Test func typingNeverAdvancesAndWhitespaceIsNotAnAnswer() {
        var flow = QuestionFlow(questions: questions)
        flow.setFreeText("   ", at: 1)
        #expect(flow.current == 0)
        #expect(!flow.isAnswered(1))
        flow.setFreeText("Because it is smaller.", at: 1)
        #expect(flow.current == 0)
        #expect(flow.canSend)
        #expect(flow.answerTexts == ["Rewrite", "Because it is smaller.", "Yes"])
    }

    @Test func freeTextReplacesAnOptionAndClearingRestoresIt() {
        var flow = QuestionFlow(questions: questions)
        flow.select(option: 1, at: 0)
        #expect(flow.selectedOption(at: 0) == 1)
        flow.setFreeText("Neither, revert it", at: 0)
        #expect(flow.selectedOption(at: 0) == nil)
        #expect(flow.freeText(at: 0) == "Neither, revert it")
        flow.setFreeText("", at: 0)
        #expect(flow.selectedOption(at: 0) == 1)
        flow.select(option: 0, at: 0)
        #expect(flow.freeText(at: 0) == "")
    }

    @Test func navigationIsBoundedAndJumpsAnywhere() {
        var flow = QuestionFlow(questions: questions)
        flow.back()
        #expect(flow.current == 0)
        flow.advance()
        flow.advance()
        #expect(flow.isLast)
        flow.advance()
        #expect(flow.current == 2)
        flow.jump(to: 0)
        #expect(flow.isFirst)
        flow.jump(to: 7)
        #expect(flow.current == 0)
    }

    @Test func outOfRangeSelectionsAreIgnored() {
        var flow = QuestionFlow(questions: questions)
        flow.select(option: 5, at: 0)
        flow.select(option: 0, at: 1)
        flow.select(option: 0, at: 9)
        #expect(flow.selectedOption(at: 0) == 0)
        #expect(flow.selectedOption(at: 1) == nil)
    }

    @Test func singleFreeTextQuestionSendsTrimmedText() {
        var flow = QuestionFlow(questions: [QuestionPrompt.Question(title: "Name?", options: [])])
        #expect(!flow.hasSeveral)
        #expect(flow.isFirst && flow.isLast)
        flow.setFreeText("  RemoteCoder \n", at: 0)
        #expect(flow.answerTexts == ["RemoteCoder"])
    }

    @Test func optionValuesAreNotTruncatedBeforeSending() {
        let options = (0..<40).map { String(repeating: "x", count: 600) + "\($0)" }
        var flow = QuestionFlow(questions: [.init(title: "Pick", options: options)])
        flow.select(option: 39, at: 0)
        #expect(flow.answerTexts == [options[39]])
    }

    @Test func partialAnswersKeepOriginalIndicesAndEditsAcrossRefresh() throws {
        var flow = QuestionFlow(questions: questions)
        flow.setFreeText("Keep this draft", at: 1)
        flow.updateIndices([1, 2])
        #expect(flow.current == 1)
        #expect(flow.isFirst)
        flow.advance()
        #expect(flow.current == 2 && flow.isLast)
        let entries = try #require(flow.entries(itemID: "q"))
        #expect(entries.map(\.index) == [1, 2])
        #expect(entries.map(\.reply.answer) == ["Keep this draft", "Yes"])
        flow.updateIndices([1])
        #expect(flow.current == 1)
        #expect(flow.freeText(at: 1) == "Keep this draft")
        flow.updateIndices([])
        #expect(!flow.canSend)
    }
}
