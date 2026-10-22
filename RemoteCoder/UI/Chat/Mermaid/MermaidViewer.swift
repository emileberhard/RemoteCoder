import CoreTransferable
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// A single vector web view, only while expanded. No Mermaid runtime, scripts,
/// credentials, website storage, subresources, links or popups are enabled here.
struct MermaidViewer: View {
    let diagram: MermaidDiagram
    let source: String
    @Environment(\.dismiss) private var dismiss
    @State private var showSource = false
    @State private var reset = 0
    @State private var loading = true
    @State private var failure: String?
    @State private var page: WebPage = {
        var configuration = MermaidWebContent.configuration()
        configuration.defaultNavigationPreferences.allowsContentJavaScript = false
        return WebPage(configuration: configuration, navigationDecider: MermaidWebContent())
    }()

    var body: some View {
        NavigationStack {
            ZStack {
                WebView(page)
                    .webViewBackForwardNavigationGestures(.disabled)
                    .webViewLinkPreviews(.disabled)
                    .webViewMagnificationGestures(.enabled)
                    .webViewContentBackground(.hidden)
                    .opacity(showSource ? 0 : 1)
                    .accessibilityHidden(showSource)
                    .accessibilityIdentifier("mermaid-vector")
                if showSource {
                    MermaidSourceView(source: source)
                        .background(.background)
                } else if let failure {
                    ContentUnavailableView("Couldn't open the diagram", systemImage: "exclamationmark.triangle",
                                           description: Text(failure))
                } else if loading {
                    ProgressView("Opening diagram…")
                        .accessibilityIdentifier("mermaid-viewer-loading")
                }
            }
            .navigationTitle("Diagram")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .appLeading) {
                    Button("Done", systemImage: "xmark", role: .close) { dismiss() }
                        .appIconButtonFeedback()
                        .tooltip("Done")
                        .accessibilityIdentifier("mermaid-close")
                }
                ToolbarItemGroup(placement: .appTrailing) {
                    Button(showSource ? "Show diagram" : "Show source",
                           systemImage: "chevron.left.forwardslash.chevron.right") { showSource.toggle() }
                        .appIconButtonFeedback()
                        .tooltip(showSource ? "Show diagram" : "Show source")
                        .accessibilityIdentifier("mermaid-viewer-source")
                    ShareLink(item: MermaidShareImage(data: diagram.preview),
                              preview: SharePreview(diagram.title)) {
                        Label("Share diagram", systemImage: "square.and.arrow.up")
                    }
                    .appIconButtonFeedback()
                    .tooltip("Share diagram")
                    .accessibilityIdentifier("mermaid-share")
                }
                ToolbarItemGroup(placement: .appBottom) {
                    Button("Copy source", systemImage: "doc.on.doc") { HapticService.shared.copy(source) }
                        .appButtonFeedback()
                    Spacer()
                    Button("Fit diagram", systemImage: "arrow.down.right.and.arrow.up.left") {
                        showSource = false
                        reset += 1
                    }
                    .appButtonFeedback()
                    .accessibilityIdentifier("mermaid-fit")
                }
            }
            .task(id: reset) {
                loading = true
                failure = nil
                do {
                    for try await _ in page.load(html: html, baseURL: MermaidWebContent.baseURL) {
                        try Task.checkCancellation()
                    }
                    loading = false
                } catch {
                    guard !Task.isCancelled else { return }
                    loading = false
                    failure = error.localizedDescription
                }
            }
            .onDisappear { page.stopLoading() }
        }
    }

    private var html: String {
        """
        <!doctype html><html lang="en"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=12, user-scalable=yes">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">
        <style>
        html,body{margin:0;padding:0;background:\(diagram.background);width:100%;height:100%;}
        main{box-sizing:border-box;width:100%;height:100%;padding:20px;display:flex;align-items:center;justify-content:center;}
        main>svg{width:100%!important;height:100%!important;max-width:none!important;}
        </style></head><body><main>\(diagram.svg)</main></body></html>
        """
    }
}

private struct MermaidShareImage: Transferable {
    let data: Data
    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .png) { $0.data }
            .suggestedFileName("Diagram.png")
    }
}
