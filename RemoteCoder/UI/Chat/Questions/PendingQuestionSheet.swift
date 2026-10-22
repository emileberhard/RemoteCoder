import SwiftUI

struct PendingQuestionSheet: View {
    let screen: ChatScreenModel
    let address: QuestionAddress
    @State private var wasActionable = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                if let prompt = screen.questionPrompt(for: address) {
                    let editor = screen.questionEditor(for: address, prompt: prompt)
                    QuestionCard(prompt: prompt, editor: editor)
                        .padding(16)
                        .onChange(of: prompt, initial: true) { _, current in
                            if wasActionable && (current.isResolved || editor.wasAdmitted(in: current)) { dismiss() }
                            if current.isPending { wasActionable = true }
                        }
                } else {
                    ContentUnavailableView("Question unavailable", systemImage: "questionmark.bubble",
                        description: Text("Refresh this conversation to check its current status."))
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Question")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { HapticService.shared.play(.disclosure); dismiss() }
                        .accessibilityIdentifier("question-close")
                }
            }
        }
        .task(id: address) { await screen.refreshQuestion(address) }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}
