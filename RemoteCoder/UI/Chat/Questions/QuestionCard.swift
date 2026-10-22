import SwiftUI

/// Transcript and sheet share this form, its captured editor, and host facts.
struct QuestionCard: View {
    let prompt: QuestionPrompt
    @Bindable var editor: QuestionEditor
    @State private var localExpandedFreeText: Set<Int> = []
    @State private var localExpandedOptions: Set<Int> = []
    @State private var localResendID: UUID?
    @Environment(\.transcriptRowPresentation) private var rowPresentation

    private var expandedFreeText: Set<Int> {
        get { rowPresentation?.questionExpandedFreeText ?? localExpandedFreeText }
        nonmutating set {
            if let rowPresentation { rowPresentation.questionExpandedFreeText = newValue }
            else { localExpandedFreeText = newValue }
        }
    }

    private var expandedOptions: Set<Int> {
        get { rowPresentation?.questionExpandedOptions ?? localExpandedOptions }
        nonmutating set {
            if let rowPresentation { rowPresentation.questionExpandedOptions = newValue }
            else { localExpandedOptions = newValue }
        }
    }

    private var resendID: UUID? {
        get { rowPresentation?.questionResendID ?? localResendID }
        nonmutating set {
            if let rowPresentation { rowPresentation.questionResendID = newValue }
            else { localResendID = newValue }
        }
    }
    @State private var movesForward = true
    @FocusState private var freeTextFocused: Bool
    @AccessibilityFocusState private var titleFocused: Bool
    @Environment(AppThemeStore.self) private var themeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(prompt.isPending ? "Codex is asking" : "Codex asked", systemImage: "questionmark.bubble")
                .scaledFont(.caption.weight(.semibold)).foregroundStyle(.secondary)
            resolvedSummary
            if !prompt.isCurrent {
                ForEach(prompt.questions.indices.filter { prompt.record?.questions[$0].resolution == .pending || prompt.record == nil }, id: \.self) {
                    Text(prompt.questions[$0].title).scaledFont(.headline)
                }
                Text(prompt.statusReason ?? "Question status needs refreshing").scaledFont(.footnote).foregroundStyle(.secondary)
                Button("Refresh status") { editor.checkStatus() }.frame(minHeight: ControlMetrics.minimumTarget)
            } else {
                deliveryStatus
                if !editor.flow.indices.isEmpty {
                    interactiveBody
                } else if prompt.record?.questions.contains(where: { $0.resolution == .dismissed || $0.resolution == .superseded }) == true,
                          !prompt.deliveries.contains(where: \.preventsSend) {
                    Button("Answer anyway") {
                        editor.answerAnyway(prompt)
                        HapticService.shared.play(.disclosure)
                    }.frame(minHeight: ControlMetrics.minimumTarget)
                }
                if prompt.record?.isPending == true, !prompt.deliveries.contains(where: \.preventsSend) {
                    Button("Dismiss question") {
                        freeTextFocused = false
                        editor.dismissQuestion()
                    }
                    .buttonStyle(.borderless)
                    .frame(minHeight: ControlMetrics.minimumTarget)
                    .accessibilityHint("Stops asking for attention without sending an answer or stopping Codex")
                    .accessibilityIdentifier("question-dismiss")
                }
            }
            if let error = editor.error {
                Text(error).scaledFont(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("question-error")
            }
        }
        .padding(14)
        .themedSurface(cornerRadius: 18)
        .disabled(editor.isBusy)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("question-card-\(prompt.itemID)")
        .onChange(of: prompt, initial: true) { _, current in editor.reconcile(current) }
        .onChange(of: freeTextFocused) { _, focused in rowPresentation?.setPinned(focused, for: .questionFocus) }
        .onChange(of: resendID, initial: true) { _, id in rowPresentation?.setPinned(id != nil, for: .questionConfirmation) }
        .onDisappear {
            rowPresentation?.setPinned(false, for: .questionFocus)
            rowPresentation?.setPinned(false, for: .questionConfirmation)
        }
        .confirmationDialog("An earlier answer may still arrive. Sending again can create a duplicate.", isPresented: Binding(
            get: { resendID != nil }, set: { if !$0 { resendID = nil } }), titleVisibility: .visible) {
                if let id = resendID {
                    Button("Allow another answer") { editor.authorizeResend(id); resendID = nil }
                }
                Button("Cancel", role: .cancel) { resendID = nil }
        }
    }

    @ViewBuilder private var resolvedSummary: some View {
        if let record = prompt.record {
            ForEach(record.questions.filter { $0.resolution != .pending }, id: \.index) { slot in
                VStack(alignment: .leading, spacing: 4) {
                    Text(slot.title).scaledFont(.subheadline).foregroundStyle(.secondary)
                    if let answer = slot.answer {
                        Label(answer.text, systemImage: "checkmark").scaledFont(.body)
                    } else {
                        Text(slot.resolution == .dismissed ? "Dismissed" : "The conversation moved on")
                            .scaledFont(.caption).foregroundStyle(.secondary)
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityElement(children: .combine)
            }
        }
    }

    @ViewBuilder private var deliveryStatus: some View {
        ForEach(prompt.deliveries, id: \.id) { delivery in
            VStack(alignment: .leading, spacing: 4) {
                Text(delivery.description).scaledFont(.footnote).foregroundStyle(.secondary)
                if delivery.status == .uncertain || delivery.status == .accepted {
                    Button("Check delivery") { editor.checkStatus() }.frame(minHeight: ControlMetrics.minimumTarget)
                    Button("Send again…") { resendID = delivery.id }.frame(minHeight: ControlMetrics.minimumTarget)
                }
            }.accessibilityIdentifier("question-delivery-\(delivery.status.rawValue)")
        }
    }

    private var interactiveBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            if editor.flow.hasSeveral {
                Text("Question \((editor.flow.indices.firstIndex(of: editor.flow.current) ?? 0) + 1) of \(editor.flow.count)")
                    .scaledFont(.caption).monospacedDigit().foregroundStyle(.secondary)
                QuestionProgressDots(flow: editor.flow, onSelect: move(to:))
            }
            questionPane(index: editor.flow.current)
                .id(editor.flow.current)
                .transition(reduceMotion ? .opacity : .push(from: movesForward ? .trailing : .leading))
            ViewThatFits(in: .horizontal) {
                HStack { backButton; Spacer(minLength: 8); primaryButton }
                VStack(alignment: .leading, spacing: 8) { backButton; primaryButton }
            }
        }
    }

    private func questionPane(index: Int) -> some View {
        let question = editor.flow.questions[index]
        let shown = expandedOptions.contains(index) ? question.options.count : min(question.options.count, 6)
        return VStack(alignment: .leading, spacing: 10) {
            Text(question.title).scaledFont(.headline).fixedSize(horizontal: false, vertical: true)
                .accessibilityFocused($titleFocused)
            ForEach(0..<shown, id: \.self) { option in
                QuestionOptionRow(title: question.options[option], isSelected: editor.flow.selectedOption(at: index) == option,
                                  isSuggested: option == 0) {
                    if editor.flow.select(option: option, at: index) { HapticService.shared.play(.selection) }
                    expandedFreeText.remove(index)
                    freeTextFocused = false
                }
                .accessibilityIdentifier("question-option-\(index)-\(option)")
            }
            if shown < question.options.count {
                Button("Show all \(question.options.count) options") { expandedOptions.insert(index) }.frame(minHeight: ControlMetrics.minimumTarget)
            }
            QuestionFreeTextRow(
                text: Binding(get: { editor.flow.freeText(at: index) }, set: { editor.flow.setFreeText($0, at: index) }),
                isExpanded: question.options.isEmpty || expandedFreeText.contains(index) || !editor.flow.freeText(at: index).isEmpty,
                isLastQuestion: editor.flow.isLast, focus: $freeTextFocused,
                accessibilityIdentifier: "question-free-text-\(index)",
                onExpand: { expandedFreeText.insert(index); freeTextFocused = true },
                onSubmit: { if editor.flow.isLast { freeTextFocused = false } else { move(forward: true) } })
        }
    }

    @ViewBuilder private var backButton: some View {
        if !editor.flow.isFirst {
            Button("Back", systemImage: "chevron.left") { move(forward: false) }
                .buttonStyle(.bordered).controlSize(.large).accessibilityIdentifier("question-back")
        }
    }

    @ViewBuilder private var primaryButton: some View {
        if editor.flow.isLast {
            Button {
                freeTextFocused = false
                editor.send(prompt)
            } label: {
                ZStack {
                    Text(editor.flow.hasSeveral ? "Send answers" : "Send answer")
                        .opacity(editor.isBusy ? 0 : 1)
                    if editor.isBusy { ProgressView().controlSize(.small) }
                }
            }
            .accessibilityLabel(editor.isBusy ? "Updating question" : editor.flow.hasSeveral ? "Send answers" : "Send answer")
            .buttonStyle(.borderedProminent).controlSize(.large)
            .tint(themeStore.theme.colors.accentTint)
            .foregroundStyle(themeStore.theme.filledAccentForeground(for: colorScheme))
            .disabled(!editor.flow.canSend)
            .accessibilityIdentifier("question-send")
        } else {
            Button("Next", systemImage: "chevron.right") { move(forward: true) }
                .buttonStyle(.bordered).controlSize(.large).accessibilityIdentifier("question-next")
        }
    }

    private func move(forward: Bool) {
        let current = editor.flow.current
        movesForward = forward
        withAnimation(.smooth(duration: 0.3)) {
            if forward { editor.flow.advance() } else { editor.flow.back() }
        }
        if editor.flow.current != current { didMove() }
    }

    private func move(to index: Int) {
        guard index != editor.flow.current, editor.flow.indices.contains(index) else { return }
        movesForward = index > editor.flow.current
        withAnimation(.smooth(duration: 0.3)) {
            _ = editor.flow.jump(to: index)
        }
        didMove()
    }
    private func didMove() {
        freeTextFocused = false
        titleFocused = true
        HapticService.shared.play(.selection)
    }
}

struct ConversationQuestionView: View {
    let screen: ChatScreenModel
    let prompt: QuestionPrompt

    var body: some View {
        if let address = screen.questionAddress(itemID: prompt.itemID) {
            QuestionCard(prompt: prompt, editor: screen.questionEditor(for: address, prompt: prompt))
        }
    }
}
