import OSLog
import QuickLook
import SwiftUI
import UIKit

extension HostFileOpener {
    static func quickLookCanPreview(_ url: URL) -> Bool {
        QLPreviewController.canPreview(url as NSURL)
    }
}

struct HostFilePresentation: ViewModifier {
    let opener: HostFileOpener
    let isBlocked: Bool
    let scope: UUID?

    func body(content: Content) -> some View {
        content.background {
            HostFilePresentationAnchor(opener: opener, isBlocked: isBlocked, scope: scope)
                .id(ObjectIdentifier(opener))
        }
    }
}

private struct HostFilePresentationAnchor: View {
    @Bindable var opener: HostFileOpener
    let isBlocked: Bool
    let scope: UUID?

    var body: some View {
        let shows = !isBlocked && opener.presents(in: scope)
        HostFileQuickLook(file: shows ? opener.quickLook : nil,
            onDismiss: opener.presentationDismissed, onUnavailable: opener.quickLookUnavailable)
            .frame(width: 0, height: 0)
            .onChange(of: isBlocked, initial: true) { _, blocked in
                if blocked, opener.presents(in: scope) { opener.suspendPresentation() }
            }
            .sheet(item: Binding(get: { shows ? opener.sheet : nil }, set: { opener.sheet = $0 }),
                   onDismiss: opener.presentationDismissed) { item in
                HostFileSheetView(item: item, opener: opener)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
            }
    }
}

private struct HostFileQuickLook: UIViewControllerRepresentable {
    let file: OpenedFile?
    let onDismiss: () -> Void
    let onUnavailable: (UUID) -> Void

    func makeUIViewController(context: Context) -> Host { Host() }
    func updateUIViewController(_ host: Host, context: Context) {
        host.onDismiss = onDismiss
        host.onUnavailable = onUnavailable
        host.update(file)
    }
    static func dismantleUIViewController(_ host: Host, coordinator: ()) {
        host.stop()
    }

    final class Host: UIViewController, QLPreviewControllerDelegate {
        private let logger = AppLogger(category: "HostFiles")
        var onDismiss: (() -> Void)?
        var onUnavailable: ((UUID) -> Void)?
        private var desired: OpenedFile?
        private var preview: Preview?
        private var isDismissing = false

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            reconcile()
        }

        func update(_ file: OpenedFile?) {
            desired = file
            reconcile()
        }

        func stop() {
            onDismiss = nil
            onUnavailable = nil
            desired = nil
            let presentedPreview = preview
            preview = nil
            isDismissing = false
            presentedPreview?.dismiss(animated: false)
        }

        private func reconcile() {
            guard !isDismissing else { return }
            if let preview {
                guard desired?.id != preview.file.id else { return }
                logger.notice("quick look dismissing file=\(preview.file.id.uuidString.prefix(8)) reason=\(self.desired == nil ? "cleared" : "replaced")")
                isDismissing = true
                preview.dismiss(animated: true) { [weak self] in self?.finished() }
            } else if let desired, viewIfLoaded?.window != nil {
                var ancestor: UIViewController? = self
                while let controller = ancestor {
                    if controller.presentedViewController != nil || controller.isBeingDismissed {
                        logger.notice("quick look blocked by another presentation file=\(desired.id.uuidString.prefix(8))")
                        self.desired = nil
                        let onUnavailable = onUnavailable
                        Task { @MainActor in onUnavailable?(desired.id) }
                        return
                    }
                    ancestor = controller.parent
                }
                let preview = Preview(file: desired)
                self.preview = preview
                preview.delegate = self
                preview.modalPresentationStyle = .overFullScreen
                logger.notice("quick look presenting file=\(desired.id.uuidString.prefix(8)) zoom=\(desired.transition != nil)")
                present(preview, animated: true)
            }
        }

        func previewControllerDidDismiss(_ controller: QLPreviewController) {
            logger.notice("quick look dismissed file=\(self.preview?.file.id.uuidString.prefix(8) ?? "none")")
            finished()
        }

        func previewController(_ controller: QLPreviewController, frameFor item: any QLPreviewItem,
                               inSourceView view: AutoreleasingUnsafeMutablePointer<UIView?>) -> CGRect {
            guard let transition = (controller as? Preview)?.file.transition, let window = viewIfLoaded?.window else {
                return .zero
            }
            view.pointee = window
            return transition.frame()
        }

        func previewController(_ controller: QLPreviewController, transitionImageFor item: any QLPreviewItem,
                               contentRect: UnsafeMutablePointer<CGRect>) -> UIImage? {
            (controller as? Preview)?.file.transition?.image
        }
        func previewController(_ controller: QLPreviewController, editingModeFor previewItem: any QLPreviewItem) -> QLPreviewItemEditingMode { .disabled }

        private func finished() {
            guard preview != nil else { return }
            preview = nil
            desired = nil
            isDismissing = false
            onDismiss?()
        }
    }

    final class Preview: QLPreviewController, QLPreviewControllerDataSource {
        let file: OpenedFile
        init(file: OpenedFile) {
            self.file = file
            super.init(nibName: nil, bundle: nil)
            dataSource = self
        }
        required init?(coder: NSCoder) { return nil }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> any QLPreviewItem {
            file.url as NSURL
        }
    }
}
