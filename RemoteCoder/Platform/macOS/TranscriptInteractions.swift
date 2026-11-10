#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers

extension EnvironmentValues {
    @Entry var transcriptTextSelectionEnabled = true
}

struct ChatBubbleMenu: View {
    let message: ChatMessage
    let rendered: RenderedMessage?
    let onFork: ((ChatMessage) -> Void)?
    let onEditAsFork: ((ChatMessage) -> Void)?
    let onCountChanges: ((ChatMessage) -> Void)?
    let deliveryActions: MessageDeliveryActions?
    let onSelectText: ((String) -> Void)?

    var body: some View {
        if let deliveryActions {
            if message.delivery == .queued, let sendNow = deliveryActions.sendNow {
                Button("Send Now") { sendNow(message) }
            }
            if message.delivery == .queued, message.restorableComposerContent != nil {
                Button("Edit") { deliveryActions.edit(message) }
            }
            Button(message.delivery == .queued ? "Remove from Queue" : "Remove", role: .destructive) {
                deliveryActions.remove(message)
            }
            Divider()
        }
        Button("Copy") { HapticService.shared.copy(rendered?.plainText ?? message.inlineContent?.plainText ?? message.text) }
        if rendered != nil {
            Button("Copy as Markdown") { HapticService.shared.copy(message.markdownSource(rendered: rendered)) }
        }
        ShareLink(item: message.markdownSource(rendered: rendered)) {
            Label("Share", systemImage: "square.and.arrow.up")
        }
        if onFork != nil || onEditAsFork != nil || onCountChanges != nil {
            Divider()
        }
        if let onFork {
            Button("Fork from Here") { onFork(message) }
        }
        if let onEditAsFork {
            Button("Edit as Fork") { onEditAsFork(message) }
        }
        if let onCountChanges {
            Button("Count Changes from Here") { onCountChanges(message) }
        }
    }
}

struct FileAttachmentMenu: View {
    let file: UploadedFile
    @Environment(\.openURL) private var openURL

    var body: some View {
        if HostFilePreviewPolicy.permitsQuickLook(file.name), !HostFilePreviewPolicy.isMarkdown(file.name) {
            Button("Quick Look") { openURL(URL(fileURLWithPath: file.path)) }
        }
        Button("Copy Path") { HapticService.shared.copy(file.path) }
    }
}

extension View {
    func codeCopyButtonStyle() -> some View { buttonStyle(.borderless) }

    func transcriptHorizontalScrollIndicators() -> some View { scrollIndicators(.automatic) }

    func codeBlockActions(code: String, language: String?) -> some View {
        modifier(CodeBlockActions(code: code, language: language))
    }

    func codeBlockDragSource(_ code: String) -> some View {
        transcriptPerfFeature("codeDragSources") { $0.contentShape(.rect).draggable(code) }
    }

    func transcriptTextSelection() -> some View {
        modifier(TranscriptTextSelectionModifier())
    }

    func transcriptCodeExportPresentation() -> some View {
        modifier(TranscriptCodeExportPresentation())
    }

    func transcriptCodeExportPresentation(presenter: TranscriptCodeExportPresenter) -> some View {
        modifier(TranscriptCodeExportPresentation(presenter: presenter))
    }
}

private struct TranscriptTextSelectionModifier: ViewModifier {
    @Environment(\.transcriptTextSelectionEnabled) private var isEnabled

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content.transcriptPerfFeature("textSelection") { $0.textSelection(.enabled) }
        } else {
            content.textSelection(.disabled)
        }
    }
}

private struct CodeBlockActions: ViewModifier {
    let code: String
    let language: String?
    @Environment(TranscriptCodeExportPresenter.self) private var presenter

    func body(content: Content) -> some View {
        content
            .transcriptPerfFeature("contextMenu") { view in
                view.contextMenu {
                    Button("Copy Code") { HapticService.shared.copy(code) }
                    Button("Save As…") { presenter.save(code: code, language: language) }
                }
            }
    }
}

private struct TranscriptCodeExportPresentation: ViewModifier {
    @State private var presenter: TranscriptCodeExportPresenter

    init() { _presenter = State(initialValue: TranscriptCodeExportPresenter()) }

    init(presenter: TranscriptCodeExportPresenter) { _presenter = State(initialValue: presenter) }

    func body(content: Content) -> some View {
        @Bindable var presenter = presenter
        content
            .environment(presenter)
            .transcriptPerfFeature("codePresentations") { view in
                view
                    .fileExporter(isPresented: $presenter.isPresented, item: presenter.request,
                                  defaultFilename: presenter.request?.suggestedFilename) { result in
                        presenter.complete(result)
                    } onCancellation: {
                        presenter.cancel()
                    }
                    .alert("Couldn't save the code", isPresented: Binding(
                        get: { presenter.failure != nil },
                        set: { if !$0 { presenter.dismissFailure() } }
                    )) {
                        Button("OK", role: .cancel) {}
                    } message: {
                        Text(presenter.failure ?? "")
                    }
            }
    }
}

@MainActor
@Observable
final class TranscriptCodeExportPresenter {
    fileprivate private(set) var request: CodeExportRequest?
    var isPresented = false
    private(set) var failure: String?

    func save(code: String, language: String?) {
        guard request == nil else { return }
        request = CodeExportRequest(code: code, suggestedFilename: CodeSnippetFile.defaultFilename(language: language))
        isPresented = true
    }

    func complete(_ result: Result<URL, any Error>) {
        request = nil
        if case .failure(let error) = result { failure = error.localizedDescription }
    }

    func cancel() { request = nil }

    func dismissFailure() { failure = nil }
}

fileprivate struct CodeExportRequest: Transferable {
    let code: String
    let suggestedFilename: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .data) { Data($0.code.utf8) }
    }
}

#endif
