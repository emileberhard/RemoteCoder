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
            .sheet(isPresented: $isReviewingChanges, onDismiss: { changeReview?.stop() }) {
                if let changeReview {
                    ChangeReviewSheet(model: changeReview, remoteHomePath: screen.target.remoteHomePath,
                                      canAddComments: screen.acceptsReviewComments, onAddComments: onAddReviewComments)
                        .chatPresentationDiagnostics("sheet-changes")
                }
            }
    }
}

private struct ChangeReviewSheet: View {
    let model: ChangeReviewModel
    let remoteHomePath: String?
    let canAddComments: Bool
    let onAddComments: (String) -> Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ChangeReviewView(model: model, remoteHomePath: remoteHomePath, canAddComments: canAddComments,
                             onAddComments: onAddComments)
                .navigationTitle("Changes")
                .inlineNavigationTitle()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close", systemImage: "xmark") {
                            HapticService.shared.play(.disclosure)
                            dismiss()
                        }
                        .accessibilityIdentifier("change-review-close")
                    }
                }
        }
    }
}
