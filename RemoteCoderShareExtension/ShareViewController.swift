import OSLog
import SwiftUI
import UIKit

final class ShareViewController: UIViewController {
    private let progress = ShareProgress()
    private var share: SharedItemsInbox.Share?
    private var items = SharedItemsInbox.Items()
    private var collecting: Task<Void, Never>?
    private let logger = Logger(subsystem: "RemoteCoder", category: "ShareExtension")

    override func viewDidLoad() {
        super.viewDidLoad()
        let content = UIHostingController(rootView: ShareView(
            progress: progress,
            cancel: { [weak self] in self?.cancel() },
            addReadable: { [weak self] in self?.handOff() }
        ))
        addChild(content)
        content.view.frame = view.bounds
        content.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(content.view)
        content.didMove(toParent: self)
        collecting = Task { await collect() }
    }

    private func collect() async {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        guard !providers.isEmpty else { return fail("No shared items were provided.") }
        guard providers.count <= SharedItemsInbox.maximumItemCount else {
            return fail("Share at most \(SharedItemsInbox.maximumItemCount) items at once.")
        }
        let share: SharedItemsInbox.Share
        do {
            guard let inbox = FileManager.default
                .containerURL(forSecurityApplicationGroupIdentifier: RemoteCoderAppGroup.identifier)
                .map(SharedItemsInbox.init(appGroupContainer:)) else { return fail("RemoteCoder's shared storage is unavailable.") }
            share = try inbox.begin(now: .now)
        } catch {
            return fail(error.localizedDescription)
        }
        self.share = share
        var failed = 0
        var remainingBytes = SharedItemsInbox.maximumBytes
        for (index, provider) in providers.enumerated() {
            progress.phase = .adding(completed: index, total: providers.count)
            do {
                let item = try await provider.loadSharedItem(into: share, maximumBytes: remainingBytes)
                try Task.checkCancellation()
                switch item {
                case .file(let path):
                    let values = try share.folder.appending(path: path).resourceValues(forKeys: [.fileSizeKey])
                    guard let size = values.fileSize, size <= remainingBytes else { throw CocoaError(.fileReadTooLarge) }
                    remainingBytes -= size
                    items.files.append(path)
                case .text(let text):
                    guard text.utf8.count <= remainingBytes else { throw CocoaError(.fileReadTooLarge) }
                    remainingBytes -= text.utf8.count
                    items.text.append(text)
                }
            } catch CocoaError.fileReadTooLarge {
                return fail("Shared items exceed the 128 MiB limit.")
            } catch is CancellationError {
                share.discard()
                return
            } catch {
                failed += 1
                logger.error("Could not read a shared item: \(error.localizedDescription, privacy: .public)")
            }
            if Task.isCancelled { share.discard(); return }
        }
        if failed == providers.count {
            fail("RemoteCoder couldn't read the shared items.")
        } else if failed > 0 {
            progress.phase = .partial(failed: failed, total: providers.count)
        } else {
            handOff()
        }
    }

    private func handOff() {
        guard let share else { return }
        self.share = nil
        do {
            try share.publish(items)
        } catch {
            share.discard()
            return fail(error.localizedDescription)
        }
        Task {
            if await openApp(RemoteCoderDeepLinks.url(forSharedItems: share.id)) {
                extensionContext?.completeRequest(returningItems: nil)
            } else {
                share.discard()
                fail("Couldn't open RemoteCoder.")
            }
        }
    }

    private func openApp(_ url: URL) async -> Bool {
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication { return await application.open(url) }
            responder = current.next
        }
        return false
    }

    private func fail(_ message: String) {
        share?.discard()
        share = nil
        progress.phase = .failed(message)
    }

    private func cancel() {
        collecting?.cancel()
        share?.discard()
        share = nil
        extensionContext?.cancelRequest(withError: CocoaError(.userCancelled))
    }
}
