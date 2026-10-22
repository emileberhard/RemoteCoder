import SwiftUI
import WebKit

struct HostHTMLPreview: View {
    let file: OpenedHostFile
    @Binding var showsFind: Bool
    @Environment(\.openURL) private var openURL
    @State private var browser: HostHTMLBrowser

    init(file: OpenedHostFile, showsFind: Binding<Bool>) {
        self.file = file
        _showsFind = showsFind
        _browser = State(initialValue: HostHTMLBrowser(file: file))
    }

    var body: some View {
        @Bindable var dialogs = browser.dialogs
        ZStack {
            if let page = browser.page {
                WebView(page)
                    .webViewBackForwardNavigationGestures(.enabled)
                    .webViewLinkPreviews(.enabled)
                    .webViewMagnificationGestures(.enabled)
                    .webViewTextSelection(.enabled)
                    .findNavigator(isPresented: $showsFind)
                    .accessibilityIdentifier("host-html-preview")
            }
            if let failure = browser.failure {
                ContentUnavailableView {
                    Label("Couldn’t preview HTML", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(failure)
                } actions: {
                    Button("Try Again", systemImage: "arrow.clockwise", action: browser.retry)
                }
                .background(Color.appSystemBackground)
            } else if browser.loading || browser.page?.isLoading == true {
                ProgressView("Opening HTML…")
            }
        }
        .alert(file.lease.metadata.name, isPresented: $dialogs.showsAlert) {
            if dialogs.isTextPrompt { TextField("Response", text: $dialogs.text) }
            if dialogs.hasCancelButton { Button("Cancel", role: .cancel) { dialogs.cancel() } }
            Button("OK") { dialogs.accept() }
        } message: {
            Text(dialogs.request?.message ?? "")
        }
        .fileImporter(isPresented: $dialogs.showsFileImporter, allowedContentTypes: dialogs.fileTypes,
                      allowsMultipleSelection: dialogs.allowsMultipleSelection,
                      onCompletion: dialogs.selectedFiles, onCancellation: dialogs.cancel)
        .task(id: browser.retryGeneration) {
            await browser.run { [openURL] in openURL($0) }
        }
        .onDisappear(perform: browser.stop)
    }
}
