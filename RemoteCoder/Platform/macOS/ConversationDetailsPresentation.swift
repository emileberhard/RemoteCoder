#if os(macOS)
import SwiftUI

struct ConversationDetailsPresentation: ViewModifier {
    let workspace: ChatWorkspaceModel
    let screen: ChatScreenModel
    @Binding var isInspectorPresented: Bool
    let changeReview: ChangeReviewModel?
    @Binding var isReviewingChanges: Bool
    let onAddReviewComments: (String) -> Bool

    func body(content: Content) -> some View {
        content
            .inspector(isPresented: $isInspectorPresented) {
                if isReviewingChanges, let changeReview {
                    ChangeReviewView(model: changeReview, remoteHomePath: screen.target.remoteHomePath,
                                     canAddComments: screen.acceptsReviewComments, onAddComments: onAddReviewComments)
                        .inspectorColumnWidth(min: 360, ideal: 560, max: 1_000)
                        .onDisappear { changeReview.stop() }
                } else {
                    ConversationInspector(workspace: workspace, screen: screen)
                        .inspectorColumnWidth(min: 240, ideal: 300, max: 420)
                }
            }
    }
}

private struct ConversationInspector: View {
    let workspace: ChatWorkspaceModel
    let screen: ChatScreenModel

    var body: some View {
        NavigationStack {
            Form {
                Section("Conversation") {
                    LabeledContent("Host", value: workspace.conversationTargetName(of: screen))
                    LabeledContent("Folder") {
                        Text(folder).textSelection(.enabled)
                    }
                    LabeledContent("Model", value: settings.model)
                    LabeledContent("Reasoning", value: settings.reasoning)
                    LabeledContent("Context", value: context)
                }
            }
            .formStyle(.grouped)
        }
    }

    private var folder: String {
        guard let path = screen.workingDirectory else { return "Not chosen" }
        return WorkingDirectoryPathFormatter.displayPath(path, remoteHomePath: screen.target.remoteHomePath)
    }

    private var settings: (model: String, reasoning: String) {
        if screen.isLoadingConversationSettings { return ("Loading…", "Loading…") }
        guard screen.areConversationSettingsReady, let model = screen.selectedModel else { return ("Unknown", "Unknown") }
        return (model.displayName, screen.reasoningSelection.label)
    }

    private var context: String {
        guard let usage = screen.contextWindowUsage else { return "Unknown" }
        return "\(usage.usedPercent)% · \(usage.tokensText)"
    }
}
#endif
