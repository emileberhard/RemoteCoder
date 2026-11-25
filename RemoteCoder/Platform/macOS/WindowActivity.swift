#if os(macOS)
import AppKit
import SwiftUI

struct WindowActivity: ViewModifier {
    let workspace: ChatWorkspaceModel
    let window: ChatWindowModel
    @Environment(\.appearsActive) private var appearsActive

    func body(content: Content) -> some View {
        content
            .onAppear { workspace.setWindowOpen(window) }
            .onChange(of: appearsActive, initial: true) { _, isKey in
                if isKey { workspace.setWindowKey(window) }
            }
    }
}

struct WindowVisibility: ViewModifier {
    @Binding var isVisible: Bool

    func body(content: Content) -> some View {
        content.background(OcclusionObserver(isVisible: $isVisible))
    }
}

private struct OcclusionObserver: NSViewRepresentable {
    @Binding var isVisible: Bool

    func makeNSView(context: Context) -> ObservingView {
        let binding = $isVisible
        return ObservingView { visible in
            if binding.wrappedValue != visible { binding.wrappedValue = visible }
        }
    }

    func updateNSView(_ view: ObservingView, context: Context) {}

    static func dismantleNSView(_ view: ObservingView, coordinator: ()) {
        view.stopObserving()
    }

    final class ObservingView: NSView {
        private let report: (Bool) -> Void
        private var observation: (any NSObjectProtocol)?

        init(report: @escaping (Bool) -> Void) {
            self.report = report
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopObserving()
            guard let window else { report(false); return }
            observation = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.reportOcclusion() }
            }
            reportOcclusion()
        }

        func stopObserving() {
            if let observation { NotificationCenter.default.removeObserver(observation) }
            observation = nil
        }

        private func reportOcclusion() {
            report(window?.occlusionState.contains(.visible) ?? false)
        }
    }
}

struct WindowActivations: ViewModifier {
    @Binding var count: Int
    @Environment(\.appearsActive) private var appearsActive

    func body(content: Content) -> some View {
        content.onChange(of: appearsActive) { _, isKey in
            if isKey { count += 1 }
        }
    }
}
#endif
