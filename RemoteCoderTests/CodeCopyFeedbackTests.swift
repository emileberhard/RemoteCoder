import Testing
@testable import RemoteCoder

struct CodeCopyFeedbackTests {
    @Test func anOlderCopyResetCannotClearNewerFeedback() {
        var feedback = CodeCopyFeedback()
        feedback.show()
        let first = feedback.generation
        feedback.show()
        let second = feedback.generation

        feedback.hide(ifGeneration: first)
        #expect(feedback.isVisible)

        feedback.hide(ifGeneration: second)
        #expect(!feedback.isVisible)
    }
}
