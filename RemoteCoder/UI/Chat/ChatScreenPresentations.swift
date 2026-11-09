import SwiftUI

struct ChatScreenPresentations: ViewModifier {
    let workspace: ChatWorkspaceModel
    let screen: ChatScreenModel
    @Binding var presentedQuestion: QuestionAddress?
    @Binding var showDirectoryPicker: Bool

    func body(content: Content) -> some View {
        content
            .sheet(item: $presentedQuestion) { address in
                // The captured host owns the sheet even if the workspace selection changes.
                if let owner = workspace.screen(for: address.conversation.hostID) {
                    PendingQuestionSheet(screen: owner, address: address)
                        .chatPresentationDiagnostics("sheet-question")
                }
            }
            .sheet(isPresented: $showDirectoryPicker) {
                WorkspaceDirectoryPicker(workspace: workspace)
                    .chromeZoomTransition("directory")
                    .chatPresentationDiagnostics("sheet-directory")
            }
            .alert("File attachments", isPresented: Binding(
                get: { screen.target.fileImports.errorMessage != nil },
                set: { if !$0 { screen.target.fileImports.dismissError() } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(screen.target.fileImports.errorMessage ?? "")
            }
            .alert(
                "Conversations",
                isPresented: Binding(
                    get: { screen.alert?.message != nil },
                    set: { if !$0 { screen.dismissAlert() } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(screen.alert?.message ?? "")
            }
    }
}
