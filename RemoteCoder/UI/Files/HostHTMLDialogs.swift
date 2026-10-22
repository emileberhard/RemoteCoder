import Foundation
import Observation
import OSLog
import UniformTypeIdentifiers
import WebKit

@Observable
@MainActor
final class HostHTMLDialogs: WebPage.DialogPresenting {
    enum Kind {
        case alert, confirm, prompt
        case files(multiple: Bool, directories: Bool)
    }

    struct Request {
        let id: UUID
        let kind: Kind
        let message: String
    }

    private enum Reply {
        case ok, cancel
        case text(String)
        case files([URL])
    }

    private(set) var request: Request?
    var text = ""
    var showsAlert = false
    var showsFileImporter = false
    @ObservationIgnored private var continuation: CheckedContinuation<Reply, Never>?
    @ObservationIgnored private var scopedFiles: Set<URL> = []
    @ObservationIgnored private let logger = Logger(subsystem: "RemoteCoder", category: "HostFiles")
    @ObservationIgnored private var closed = false

    deinit {
        for url in scopedFiles { url.stopAccessingSecurityScopedResource() }
    }

    var isTextPrompt: Bool {
        if case .prompt = request?.kind { return true }
        return false
    }

    var hasCancelButton: Bool {
        if case .alert = request?.kind { return false }
        return true
    }

    var allowsMultipleSelection: Bool {
        if case .files(let multiple, _) = request?.kind { return multiple }
        return false
    }

    var fileTypes: [UTType] {
        if case .files(_, true) = request?.kind { return [.folder] }
        return [.item]
    }

    func accept() { finish(isTextPrompt ? .text(text) : .ok) }
    func cancel() { finish(.cancel) }

    func close() {
        closed = true
        cancel()
        for url in scopedFiles { url.stopAccessingSecurityScopedResource() }
        scopedFiles.removeAll()
    }

    func selectedFiles(_ result: Result<[URL], any Error>) {
        guard case .files = request?.kind else { return }
        switch result {
        case .success(let urls):
            for url in urls where !scopedFiles.contains(url) {
                if url.startAccessingSecurityScopedResource() { scopedFiles.insert(url) }
            }
            finish(.files(urls))
        case .failure: cancel()
        }
    }

    func handleJavaScriptAlert(message: String, initiatedBy frame: WebPage.FrameInfo) async {
        _ = await ask(.alert, message: message)
    }

    func handleJavaScriptConfirm(message: String, initiatedBy frame: WebPage.FrameInfo) async -> WebPage.JavaScriptConfirmResult {
        if case .ok = await ask(.confirm, message: message) { return .ok }
        return .cancel
    }

    func handleJavaScriptPrompt(message: String, defaultText: String?,
                                initiatedBy frame: WebPage.FrameInfo) async -> WebPage.JavaScriptPromptResult {
        if case .text(let value) = await ask(.prompt, message: message, defaultText: defaultText ?? "") { return .ok(value) }
        return .cancel
    }

    func handleFileInputPrompt(parameters: WKOpenPanelParameters,
                               initiatedBy frame: WebPage.FrameInfo) async -> WebPage.FileInputPromptResult {
        let reply = await ask(.files(multiple: parameters.allowsMultipleSelection, directories: parameters.allowsDirectories), message: "")
        if case .files(let urls) = reply { return .selected(urls) }
        return .cancel
    }

    private func ask(_ kind: Kind, message: String, defaultText: String = "") async -> Reply {
        guard !closed else { return .cancel }
        logger.notice("html dialog requested cancelled=\(Task.isCancelled, privacy: .public)")
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                cancel()
                guard !Task.isCancelled else { continuation.resume(returning: .cancel); return }
                self.continuation = continuation
                text = defaultText
                request = Request(id: id, kind: kind, message: message)
                if case .files = kind { showsFileImporter = true }
                else { showsAlert = true }
            }
        } onCancel: { [weak self] in
            Task { @MainActor in self?.finish(.cancel, id: id) }
        }
    }

    private func finish(_ reply: Reply, id: UUID? = nil) {
        guard id == nil || request?.id == id else { return }
        let pending = continuation
        continuation = nil
        request = nil
        showsAlert = false
        showsFileImporter = false
        pending?.resume(returning: reply)
    }
}
