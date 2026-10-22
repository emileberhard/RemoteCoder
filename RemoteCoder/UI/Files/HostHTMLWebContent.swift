import Foundation
import UniformTypeIdentifiers
import WebKit

enum HostHTMLWebContent {
    @MainActor
    static func page(file: OpenedHostFile, document: HostHTMLDocument, dialogs: HostHTMLDialogs = HostHTMLDialogs(),
                     willNavigate: @escaping @MainActor (URL) -> Void = { _ in },
                     openLink: @escaping @MainActor (URL) -> Void) throws -> WebPage {
        guard let scheme = URLScheme(HostHTMLDocument.scheme) else { throw HostFileError.invalidPath }
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.addUserScript(WKUserScript(source: """
            if (location.protocol === '\(HostHTMLDocument.scheme):') {
                const normalize = link => {
                    let destination;
                    try { destination = new URL(link.getAttribute('href'), document.baseURI); }
                    catch { return; }
                    if (destination.protocol !== 'file:' || !['', 'localhost'].includes(destination.hostname)) return;
                    link.setAttribute('href', location.protocol + '//' + location.host + destination.pathname + destination.search + destination.hash);
                };
                const scan = node => {
                    if (!(node instanceof Element)) return;
                    if (node.matches('a[href],area[href]')) normalize(node);
                    node.querySelectorAll('a[href],area[href]').forEach(normalize);
                };
                new MutationObserver(changes => {
                    for (const change of changes) {
                        if (change.type === 'attributes') scan(change.target);
                        else change.addedNodes.forEach(scan);
                    }
                }).observe(document, {subtree:true, childList:true, attributes:true, attributeFilter:['href']});
                document.addEventListener('click', event => {
                    const link = event.composedPath().find(node => node instanceof Element && node.matches('a[href],area[href]'));
                    if (link) normalize(link);
                }, true);
            }
            """, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: .defaultClient))
        configuration.urlSchemeHandlers[scheme] = HostHTMLSchemeHandler(file: file, document: document)
        let navigation = HostHTMLNavigation(document: document, willNavigate: willNavigate, openLink: openLink)
        let page = WebPage(configuration: configuration, navigationDecider: navigation, dialogPresenter: dialogs)
        navigation.page = page
        return page
    }
}

@MainActor
private final class HostHTMLNavigation: WebPage.NavigationDeciding {
    let document: HostHTMLDocument
    let willNavigate: @MainActor (URL) -> Void
    let openLink: @MainActor (URL) -> Void
    weak var page: WebPage?

    init(document: HostHTMLDocument, willNavigate: @escaping @MainActor (URL) -> Void,
         openLink: @escaping @MainActor (URL) -> Void) {
        self.document = document
        self.willNavigate = willNavigate
        self.openLink = openLink
    }

    func decidePolicy(for action: WebPage.NavigationAction,
                              preferences: inout WebPage.NavigationPreferences) async -> WKNavigationActionPolicy {
        guard let url = action.request.url else { return .allow }
        let fileURL = document.remoteFileURL(for: url)
        if url.scheme == HostHTMLDocument.scheme && fileURL == nil { return .cancel }
        if url.isFileURL && document.previewURL(for: url) == nil { return .cancel }
        if action.navigationType == .linkActivated, action.source.isMainFrame,
           let fileURL, !document.contains(url),
           !["html", "htm", "xhtml"].contains(fileURL.pathExtension.lowercased()) {
            openLink(fileURL)
            return .cancel
        }
        if ["mailto", "tel"].contains(url.scheme?.lowercased() ?? "") {
            openLink(url)
            return .cancel
        }
        var request = action.request
        if let previewURL = document.previewURL(for: url) {
            request.url = previewURL
            if action.target == nil || action.target?.isMainFrame == true {
                willNavigate(previewURL)
                page?.load(request)
                return .cancel
            }
            preferences.alternateRequest = request
        }
        if action.target == nil || action.target?.isMainFrame == true, let destination = request.url {
            willNavigate(destination)
        }
        if action.target == nil {
            page?.load(request)
            return .cancel
        }
        return .allow
    }
}

private struct HostHTMLSchemeHandler: URLSchemeHandler {
    let file: OpenedHostFile
    let document: HostHTMLDocument
    let admission = HostFilePathAdmission(maximumWaiters: 128)

    func reply(for request: URLRequest) -> some AsyncSequence<URLSchemeTaskResult, any Error> {
        let resource = HostHTMLResource(file: file, document: document, request: request, admission: admission)
        return AsyncThrowingStream(unfolding: { try await resource.next() })
    }
}

private actor HostHTMLResource {
    private let file: OpenedHostFile
    private let document: HostHTMLDocument
    private let request: URLRequest
    private let admission: HostFilePathAdmission
    private var resourceFile: OpenedHostFile?
    private var handle: FileHandle?
    private var sentResponse = false
    private var remaining: Int64

    init(file: OpenedHostFile, document: HostHTMLDocument, request: URLRequest, admission: HostFilePathAdmission) {
        self.file = file
        self.document = document
        self.request = request
        self.admission = admission
        remaining = file.lease.metadata.bytes
    }

    deinit { try? handle?.close() }

    func next() async throws -> URLSchemeTaskResult? {
        do {
            try Task.checkCancellation()
            if !sentResponse {
                guard let url = request.url,
                      let fileURL = document.remoteFileURL(for: url),
                      let reference = try HostFileReference.resolve(url: fileURL, hostID: file.lease.reference.hostID,
                                                                    relativeTo: nil) else { throw URLError(.unsupportedURL) }
                let opened: OpenedHostFile
                if document.contains(url) { opened = file }
                else {
                    try await admission.acquire(file.lease.reference.path)
                    do { opened = try await file.openResource(reference, containingDirectory: document.directory) }
                    catch {
                        await admission.release(file.lease.reference.path)
                        throw error
                    }
                    await admission.release(file.lease.reference.path)
                }
                try Task.checkCancellation()
                resourceFile = opened
                remaining = opened.lease.metadata.bytes
                guard let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [
                    "Content-Type": Self.mimeType(opened.lease.metadata.name),
                    "Content-Length": String(remaining)
                ]) else { throw URLError(.badServerResponse) }
                handle = try FileHandle(forReadingFrom: opened.lease.url)
                sentResponse = true
                return .response(response)
            }
            guard let handle else { return nil }
            guard let data = try handle.read(upToCount: 65_536), !data.isEmpty else {
                try handle.close()
                self.handle = nil
                resourceFile = nil
                guard remaining == 0 else { throw HostFileError.invalidResponse }
                return nil
            }
            guard data.count <= remaining else { throw HostFileError.invalidResponse }
            remaining -= Int64(data.count)
            return .data(data)
        } catch {
            try? handle?.close()
            handle = nil
            resourceFile = nil
            throw error
        }
    }

    private static func mimeType(_ name: String) -> String {
        let pathExtension = (name as NSString).pathExtension.lowercased()
        return switch pathExtension {
        case "html", "htm": "text/html"
        case "xhtml": "application/xhtml+xml"
        case "js", "mjs": "text/javascript"
        case "css": "text/css"
        case "wasm": "application/wasm"
        default: UTType(filenameExtension: pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        }
    }
}
