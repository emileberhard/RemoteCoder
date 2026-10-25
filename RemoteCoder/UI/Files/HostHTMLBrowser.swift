import Foundation
import Observation
import OSLog
import WebKit

@Observable
@MainActor
final class HostHTMLBrowser {
    private(set) var page: WebPage?
    private(set) var loading = true
    private(set) var failure: String?
    private(set) var retryGeneration = 0
    private(set) var dialogs = HostHTMLDialogs()
    @ObservationIgnored private let file: OpenedHostFile
    @ObservationIgnored private var destination: URL?
    @ObservationIgnored private let logger = AppLogger(category: "HostFiles")

    init(file: OpenedHostFile) { self.file = file }

    func retry() { retryGeneration += 1 }

    func stop() {
        page?.stopLoading()
        dialogs.close()
    }

    func run(openLink: @escaping @MainActor (URL) -> Void) async {
        stop()
        dialogs = HostHTMLDialogs()
        loading = true
        failure = nil
        page = nil
        do {
            let document = try HostHTMLDocument(lease: file.lease)
            let prepared = try HostHTMLWebContent.page(file: file, document: document, dialogs: dialogs,
                willNavigate: { [weak self] in self?.destination = $0 }, openLink: openLink)
            let presenter = dialogs
            try Task.checkCancellation()
            page = prepared
            defer {
                prepared.stopLoading()
                presenter.close()
            }
            var events = prepared.navigations
            prepared.load(destination ?? document.url)
            while !Task.isCancelled {
                do {
                    for try await event in events {
                        try Task.checkCancellation()
                        guard page === prepared else { return }
                        switch event {
                        case .startedProvisionalNavigation:
                            loading = true
                            failure = nil
                        case .finished:
                            loading = false
                        default: break
                        }
                    }
                    return
                } catch {
                    guard !Task.isCancelled, page === prepared else { return }
                    loading = false
                    report(error)
                    events = prepared.navigations
                }
            }
        } catch {
            guard !Task.isCancelled else { return }
            loading = false
            report(error)
        }
    }

    private func report(_ error: any Error) {
        let reason: any Error
        if case WebPage.NavigationError.failedProvisionalNavigation(let underlying) = error { reason = underlying }
        else { reason = error }
        guard (reason as? URLError)?.code != .cancelled else { return }
        failure = reason.localizedDescription
        logger.error("html preview failed file=\(self.file.id.uuidString.prefix(8)) reason=\(reason.diagnosticReason)")
    }
}
