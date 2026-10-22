import SwiftUI

/// Only the illustration is asynchronous; source/copy remain usable in every state.
struct MermaidDiagramView: View {
    let source: String
    let isComplete: Bool
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.visualsVisible) private var visualsVisible
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.transcriptRowVisibility) private var rowVisibility
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsSpinner = false
    @State private var localShowSource = false
    @Environment(\.transcriptRowPresentation) private var rowPresentation
    @Environment(\.transcriptBlockIndex) private var blockIndex

    private var showSource: Bool {
        get {
            guard let rowPresentation, let blockIndex else { return localShowSource }
            return rowPresentation.mermaidSource[blockIndex] ?? localShowSource
        }
        nonmutating set {
            if let rowPresentation, let blockIndex { rowPresentation.mermaidSource[blockIndex] = newValue }
            else { localShowSource = newValue }
        }
    }
    @State private var copied = false
    @State private var retry = 0
    @State private var width: CGFloat = 340
    @State private var measuredAspect: (request: MermaidRequest, value: CGFloat)?
    @State private var diagram: MermaidDiagram?
    @State private var image: DecodedImage?
    @State private var failure: Failure?
    @State private var preparedFor: RenderIdentity?
    @State private var viewer: MermaidViewerItem?

    private var request: MermaidRequest {
        MermaidRequest(source: source, isDark: colorScheme == .dark, highContrast: contrast == .increased)
    }
    // An existing row can receive new source before its task restarts. Never
    // pair a previous illustration with the new source or appearance.
    private var isCurrent: Bool { isComplete && preparedFor == RenderIdentity(request: request, retry: retry) }
    private var currentDiagram: MermaidDiagram? { isCurrent ? diagram : nil }
    private var currentImage: DecodedImage? { isCurrent ? image : nil }
    private var currentFailure: Failure? { isCurrent ? failure : nil }

    private var identity: RenderIdentity {
        RenderIdentity(request: rowVisibility?.isVisible == true && isComplete && visualsVisible
            && scenePhase != .background && !showSource ? request : nil, retry: retry)
    }
    private var aspectRatio: CGFloat {
        if measuredAspect?.request == request, let measuredAspect { return measuredAspect.value }
        return MermaidRenderer.shared.aspectRatio(for: request) ?? 2
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            content
        }
        .transcriptContentCard()
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
        .task(id: identity) { await prepare() }
        .task(id: identity) {
            showsSpinner = false
            guard identity.request != nil else { return }
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            guard !Task.isCancelled, currentImage == nil, currentFailure == nil else { return }
            showsSpinner = true
        }
        .onChange(of: source) { copied = false }
        .task(id: copied) {
            guard copied else { return }
            do { try await Task.sleep(for: .seconds(2)); copied = false }
            catch { } // The feedback belongs to this view's lifetime.
        }
        .onChange(of: viewer != nil) { _, presented in
            if let blockIndex { rowPresentation?.setPinned(presented, for: .mermaid(blockIndex)) }
        }
        .onDisappear {
            if let blockIndex { rowPresentation?.setPinned(false, for: .mermaid(blockIndex)) }
        }
        .appFullScreenCover(item: $viewer) { item in
            MermaidViewer(diagram: item.diagram, source: item.source)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("mermaid-card")
    }

    private var header: some View {
        HStack(spacing: 0) {
            Label("Mermaid", systemImage: "point.3.connected.trianglepath.dotted")
                .scaledFont(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.leading, 14)
            Spacer(minLength: 2)
            Button { showSource.toggle() } label: {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .foregroundStyle(showSource ? .primary : .secondary)
                    .scaledFrame(width: ControlMetrics.minimumTarget, height: ControlMetrics.minimumTarget)
            }
            .appIconButtonFeedback()
            .accessibilityLabel(showSource ? "Show diagram" : "Show Mermaid source")
            .accessibilityIdentifier("mermaid-source-toggle")
            Button {
                HapticService.shared.copy(source)
                copied = true
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .scaledFrame(width: ControlMetrics.minimumTarget, height: ControlMetrics.minimumTarget)
            }
            .appIconButtonFeedback()
            .accessibilityLabel(copied ? "Mermaid source copied" : "Copy Mermaid source")
            .accessibilityIdentifier("mermaid-copy")
            Button { open() } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .scaledFrame(width: ControlMetrics.minimumTarget, height: ControlMetrics.minimumTarget)
            }
            .appIconButtonFeedback()
            .disabled(currentDiagram == nil)
            .accessibilityLabel("Expand diagram")
            .accessibilityIdentifier("mermaid-expand")
        }
        .scaledFont(.subheadline)
        .foregroundStyle(.secondary)
        .padding(.trailing, 4)
    }

    @ViewBuilder private var content: some View {
        if showSource {
            MermaidSourceView(source: source)
                .frame(height: 240)
        } else if let failure = currentFailure {
            VStack(alignment: .leading, spacing: 10) {
                Label(failure.title, systemImage: "exclamationmark.triangle")
                    .scaledFont(.subheadline.weight(.medium))
                Text(failure.message).scaledFont(.caption).foregroundStyle(.secondary).lineLimit(5)
                Button("Try again") {
                    MermaidRenderer.shared.invalidate(request)
                    retry += 1
                }
                .appButtonFeedback()
                .accessibilityIdentifier("mermaid-retry")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            MermaidSourceView(source: source).frame(height: 180)
        } else {
            Button { open() } label: {
                Group {
                    if let image = currentImage {
                        Image(decoded: image)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .padding(12)
                            .transition(.opacity)
                    } else if isComplete {
                        if showsSpinner {
                            ProgressView("Rendering diagram…").scaledFont(.caption)
                        } else {
                            Color.clear
                        }
                    } else {
                        Label("Diagram is being written…", systemImage: "pencil.and.outline")
                            .scaledFont(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                .animation(reduceMotion ? nil : .smooth(duration: 0.2), value: currentImage != nil)
                .frame(maxWidth: .infinity)
                .frame(height: min(320, max(140, (width - 24) / aspectRatio + 24)))
                .contentShape(Rectangle())
            }
            .appButtonFeedback()
            .disabled(currentDiagram == nil)
            .accessibilityLabel(currentDiagram?.title ?? (isComplete ? "Rendering Mermaid diagram" : "Diagram is being written"))
            .accessibilityValue(currentDiagram?.summary ?? "")
            .accessibilityHint(currentDiagram == nil ? "" : "Opens a full-screen diagram with pinch to zoom and source text")
            .accessibilityIdentifier("mermaid-preview")
            if isComplete {
                Text(expandHint)
                    .scaledFont(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 12)
                    .opacity(currentDiagram == nil ? 0 : 1)
                    .accessibilityHidden(true)
            }
        }
    }

    private var expandHint: LocalizedStringKey {
        #if os(macOS)
        "Click to expand"
        #else
        "Tap to expand · Pinch to explore"
        #endif
    }

    private func open() {
        guard let diagram = currentDiagram else { return }
        viewer = MermaidViewerItem(diagram: diagram, source: source)
    }

    private func prepare() async {
        let preparation = identity
        guard !Task.isCancelled else { return }
        guard let input = preparation.request else {
            diagram = nil
            image = nil
            return
        }
        if preparedFor == preparation, image != nil || failure != nil { return }
        diagram = nil
        image = nil
        failure = nil
        preparedFor = nil
        do {
            let result = try await MermaidRenderer.shared.diagram(for: input)
            try Task.checkCancellation()
            guard let prepared = await DecodedImage.prepared(from: result.preview) else {
                throw MermaidFailure(message: "The diagram preview could not be decoded.")
            }
            try Task.checkCancellation()
            preparedFor = preparation
            diagram = result
            image = prepared
            measuredAspect = (input, result.size.width / result.size.height)
        } catch is CancellationError {
            // A new source/appearance or an offscreen row owns the next result.
        } catch MermaidAdmissionError.busy {
            guard !Task.isCancelled else { return }
            preparedFor = preparation
            failure = .busy
        } catch {
            guard !Task.isCancelled else { return }
            preparedFor = preparation
            failure = .rendering(error.localizedDescription)
        }
    }

    private enum Failure {
        case busy
        case rendering(String)

        var title: String {
            switch self {
            case .busy: "Diagram renderer busy"
            case .rendering: "Couldn't render this diagram"
            }
        }

        var message: String {
            switch self {
            case .busy: "Other diagrams are being rendered. Try again."
            case .rendering(let message): message
            }
        }
    }

    private struct RenderIdentity: Equatable {
        let request: MermaidRequest?
        let retry: Int
    }
}

struct MermaidSourceView: View {
    let source: String
    var body: some View {
        ScrollView([.horizontal, .vertical]) {
            Text(source)
                .scaledFont(.system(.callout, design: .monospaced))
                .transcriptPerfFeature("textSelection") { $0.textSelection(.enabled) }
                .fixedSize(horizontal: true, vertical: true)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(16)
        }
        .accessibilityLabel("Mermaid source")
        .accessibilityIdentifier("mermaid-source")
    }
}

private struct MermaidViewerItem: Identifiable {
    let id = UUID()
    let diagram: MermaidDiagram
    let source: String
}
