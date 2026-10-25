import SwiftUI
import WebKit
#if DEBUG
import OSLog
#endif

struct HTMLVisualSource: Equatable {
    let hostID: UUID
    let documents: HTMLVisualDocumentStore
    let renderer: HTMLVisualRenderer
    let preparation: HTMLVisualPreparation

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.hostID == rhs.hostID && lhs.documents === rhs.documents && lhs.renderer === rhs.renderer
            && lhs.preparation === rhs.preparation
    }
}

extension EnvironmentValues {
    @Entry var htmlVisualSource: HTMLVisualSource?
    @Entry var htmlVisualSnapshotsOnly = false
}

struct HTMLVisualInline: View {
    #if DEBUG
    private static let keepsLiveSurfaceDuringMotion = ProcessInfo.processInfo.arguments.contains("-html-visual-fixture-live-during-motion")
    private static let probesBlank = ProcessInfo.processInfo.arguments.contains("-html-visual-fixture-probe")
    private static let keepsBaseRaster = ProcessInfo.processInfo.arguments.contains("-html-visual-fixture-base-raster")
    private static let logger = AppLogger(category: "HTMLVisual")
    #else
    private static let keepsLiveSurfaceDuringMotion = false
    private static let keepsBaseRaster = false
    #endif
    let url: URL
    let title: String
    @Environment(\.htmlVisualSource) private var source
    @Environment(\.htmlVisualTheme) private var theme
    @Environment(\.htmlVisualCaptureAllowed) private var captureAllowed
    @Environment(\.htmlVisualSnapshotsOnly) private var snapshotsOnly
    @Environment(\.appEnergyPolicy) private var energyPolicy
    @Environment(\.interfaceScale) private var interfaceScale
    @Environment(\.displayScale) private var displayScale
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.visualsVisible) private var visible
    @Environment(\.transcriptRowVisibility) private var rowVisibility
    @Environment(\.transcriptRowPresentation) private var rowPresentation
    @Environment(\.transcriptBlockIndex) private var blockIndex
    #if DEBUG
    @Environment(\.markdownBlockBodyCounter) private var bodyCounter
    #endif
    @Environment(\.openURL) private var openURL
    @Environment(\.chatImageSource) private var files
    @State private var instance = HTMLVisualInstance(surface: .inline)
    @State private var inlineAnchor = HTMLVisualFrameAnchor()
    @State private var expandedAnchor = HTMLVisualFrameAnchor()
    @State private var expandedScope = UUID()
    @State private var width: CGFloat = 360
    @State private var layoutWidth: Int?
    @State private var pendingWidth: Int?
    @State private var presented = PresentedRaster()
    @State private var retry = 0
    @State private var expansionRetry = 0
    @State private var inlineSnapshot: HTMLVisualSnapshot?
    @State private var presentation: Presentation = .inline
    private var expansion: HTMLVisualInstance? {
        switch presentation {
        case .inline: nil
        case .expanded(let expansion), .dismissing(let expansion): expansion
        }
    }
    private var presentedExpansion: Binding<HTMLVisualInstance?> {
        Binding(get: {
            if case .expanded(let expansion) = presentation { return expansion }
            return nil
        }, set: { value in
            if value == nil, case .expanded(let expansion) = presentation { presentation = .dismissing(expansion) }
        })
    }

    private var reference: HTMLVisualReference? { HTMLVisualReference(url: url) }
    private var key: HTMLVisualLayoutKey? {
        guard let reference, let theme, let width = layoutWidth ?? source?.preparation.layoutContext.width else { return nil }
        return HTMLVisualLayoutKey(digest: reference.digest, width: width, theme: theme)
    }
    private var frameWidth: CGFloat {
        if layoutWidth == nil, let width = source?.preparation.layoutContext.width { return CGFloat(width) }
        return width
    }

    private static let activationSettle = Duration.milliseconds(150)

    private var active: Bool {
        (rowVisibility?.isVisible == true || instance.pinned) && visible && scenePhase == .active && (!snapshotsOnly || instance.userSelected)
            && (rowVisibility?.isScrolling != true || instance.pinned || instance.status == .live)
    }
    private var showsLivePage: Bool {
        rowVisibility?.isMoving != true || instance.pinned || Self.keepsLiveSurfaceDuringMotion
            || instance.isResizing || currentSnapshot?.captureID == nil || currentSnapshot?.captureID != currentCapture?.id
    }
    private var showsContent: Bool {
        currentSnapshot != nil || (instance.page != nil && instance.measured && showsLivePage)
    }
    private var reveal: Animation? { rowVisibility?.isVisible == true ? .easeOut(duration: 0.2) : nil }
    private var loadsAutomatically: Bool {
        let automatic = !snapshotsOnly || instance.userSelected
        switch instance.status {
        case .idle: return automatic
        case .loading, .live: return true
        case .suspended: return automatic && !active
        case .waiting, .unavailable: return false
        }
    }
    private var currentSnapshot: PreparedSnapshot? {
        if let snapshot = presented.snapshot, snapshot.key == key { return snapshot }
        guard let renderer = source?.renderer else { return nil }
        if let capture = currentCapture,
           let prepared = renderer.presentableRaster(for: capture, displayScale: displayScale) {
            return PreparedSnapshot(prepared: prepared, captureID: capture.id)
        }
        return key.flatMap { renderer.presentableRaster(for: $0, displayScale: displayScale) }
            .map { PreparedSnapshot(prepared: $0, captureID: nil) }
    }
    private var currentCapture: HTMLVisualCapturedImage? {
        guard let captured = instance.capturedImage, captured.key == key else { return nil }
        return captured
    }
    private var identity: Identity {
        Identity(url: url, source: source.map { ObjectIdentifier($0.documents) }, active: active && key != nil, retry: retry)
    }
    private var measuredHeight: Double {
        if instance.page != nil, instance.measured { return instance.height }
        return inlineSnapshot?.height ?? key.flatMap { source?.renderer.height(for: $0) } ?? 180
    }
    private var inlineHeight: Double { min(HTMLVisualInlineHeight.limit(interfaceScale: interfaceScale), max(1, measuredHeight)) }
    private var canCapture: Bool {
        captureAllowed && !instance.isResizing && rowVisibility?.isScrolling != true && visible && scenePhase == .active
    }
    private var imageIdentity: ImageIdentity {
        ImageIdentity(key: key, revision: currentCapture == nil ? inlineSnapshot?.revision ?? 0 : 0,
            captureID: currentCapture?.id, displayScale: displayScale,
            needed: visible && scenePhase == .active && rowVisibility?.isVisible == true)
    }

    private var sharpIdentity: SharpIdentity {
        SharpIdentity(base: currentSnapshot.map { ObjectIdentifier($0.prepared) }, displayScale: displayScale,
            kept: visible && scenePhase == .active && rowVisibility?.isVisible == true && !energyPolicy.conservesEnergy
                && !Self.keepsBaseRaster,
            settled: rowVisibility?.isScrolling != true)
    }

    private func sharpImage(for snapshot: PreparedSnapshot) -> DecodedImage? {
        guard let sharp = presented.sharp, sharp.sharpens(snapshot.prepared) else { return nil }
        return sharp.image
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    if let snapshot = currentSnapshot {
                        Image(decoded: sharpImage(for: snapshot) ?? snapshot.image).resizable().interpolation(.high)
                            .frame(width: frameWidth, height: snapshot.height, alignment: .topLeading)
                            .opacity(instance.page == nil || !instance.measured || !showsLivePage ? 1 : 0)
                            .accessibilityHidden(true)
                            .allowsHitTesting(false)
                    }
                    if let page = instance.page {
                        web(page, anchor: inlineAnchor)
                            .scrollBounceBehavior(.basedOnSize, axes: [.horizontal, .vertical])
                            .frame(width: width, height: inlineHeight, alignment: .topLeading)
                            .opacity(instance.measured && showsLivePage ? 1 : 0)
                            .allowsHitTesting(instance.measured && showsLivePage)
                            .accessibilityHidden(!instance.measured || !showsLivePage)
                    }
                }
                .animation(reveal) { $0.opacity(showsContent ? 1 : 0) }
                if !showsContent {
                    inlinePlaceholder.transition(.opacity.animation(reveal))
                }
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .topLeading)
            .frame(height: inlineHeight, alignment: .topLeading)
            #if DEBUG
            .background { if Self.probesBlank && !showsContent { Color(red: 1, green: 0, blue: 1) } }
            #endif
            .clipped()
            .contentShape(Rectangle())
            .overlay {
                if instance.page == nil && currentSnapshot != nil {
                    Button {
                        source?.renderer.promote(instance)
                        retry += instance.requestID == nil ? 1 : 0
                    } label: {
                        Color.clear.contentShape(Rectangle())
                    }
                    .appButtonFeedback()
                    .accessibilityLabel("Interact with \(title)")
                }
            }
            if measuredHeight > inlineHeight {
                Button("Expand") {
                    if case .inline = presentation { presentation = .expanded(HTMLVisualInstance(surface: .expanded)) }
                }
                .scaledFont(.caption)
                .appButtonFeedback()
                .frame(minHeight: ControlMetrics.minimumTarget * interfaceScale)
                .accessibilityLabel("Expand \(title)")
            }
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) {
            width = max(1, $0)
            let next = max(1, Int(width.rounded()))
            if layoutWidth == nil { layoutWidth = next }
            else if next != layoutWidth {
                pendingWidth = next
                source?.renderer.beginResize(instance)
            } else {
                pendingWidth = nil
                if instance.isResizing, let key { source?.renderer.finishResize(instance, key: key) }
            }
        }
        .task(id: pendingWidth) {
            guard let pendingWidth else { return }
            do { try await Task.sleep(for: .milliseconds(150)) }
            catch { return }
            layoutWidth = pendingWidth
            if let reference, let theme {
                source?.renderer.finishResize(instance,
                    key: HTMLVisualLayoutKey(digest: reference.digest, width: pendingWidth, theme: theme))
            }
        }
        .task(id: imageIdentity) {
            guard imageIdentity.needed, let key, let source else {
                presented.snapshot = nil
                return
            }
            if presented.snapshot?.key != key { presented.snapshot = nil }
            if let captured = currentCapture {
                guard let prepared = await source.renderer.preparedRaster(for: captured, displayScale: displayScale),
                      !Task.isCancelled else { return }
                presented.snapshot = PreparedSnapshot(prepared: prepared, captureID: captured.id)
                return
            }
            let prepared = await source.renderer.preparedRaster(for: key, displayScale: displayScale)
            guard !Task.isCancelled else { return }
            inlineSnapshot = source.renderer.snapshot(for: key)
            if let prepared { presented.snapshot = PreparedSnapshot(prepared: prepared, captureID: nil) }
        }
        .task(id: sharpIdentity) {
            guard sharpIdentity.kept, let snapshot = currentSnapshot, let source else {
                presented.sharp = nil
                return
            }
            if presented.sharp?.sharpens(snapshot.prepared) == true { return }
            presented.sharp = nil
            guard sharpIdentity.settled,
                  let sharp = await source.renderer.sharpRaster(for: snapshot.prepared, capture: currentCapture,
                      displayScale: displayScale),
                  !Task.isCancelled, rowVisibility?.isVisible == true, rowVisibility?.isScrolling != true,
                  presented.snapshot.map({ $0.prepared === snapshot.prepared }) != false
            else { return }
            presented.sharp = sharp
        }
        .task(id: PrefetchIdentity(url: url, source: source.map { ObjectIdentifier($0.documents) })) {
            guard let reference, let source else { return }
            await source.documents.prefetch(reference)
        }
        #if DEBUG
        .onChange(of: captureAllowed, initial: true) { _, value in
            bodyCounter?.recordCapturePermission(index: blockIndex ?? -1, captureAllowed: value)
        }
        .onChange(of: rowVisibility?.isVisible == true) { _, visible in
            guard visible, let reference else { return }
            let ready = currentSnapshot != nil ? "decoded" : (instance.page != nil && instance.measured ? "live" : "none")
            Self.logger.notice("html visual visible ready=\(ready) digest=\(reference.digest.prefix(8)) scrolling=\(rowVisibility?.isScrolling == true)")
        }
        #endif
        .onChange(of: canCapture, initial: true) { _, value in source?.renderer.setCaptureAllowed(instance, value) }
        .onChange(of: energyPolicy, initial: true) { _, value in source?.renderer.setEnergyPolicy(value) }
        .onChange(of: interfaceScale, initial: true) { _, scale in
            instance.inlineHeightLimit = HTMLVisualInlineHeight.limit(interfaceScale: scale)
        }
        .onChange(of: key, initial: true) { _, value in
            guard let value else { return }
            inlineSnapshot = source?.renderer.snapshot(for: value)
            source?.renderer.update(instance, key: value)
            if let expansion { source?.renderer.update(expansion, key: value) }
        }
        .onChange(of: instance.snapshot.map(ObjectIdentifier.init)) { _, _ in
            if instance.key == key { inlineSnapshot = instance.snapshot }
        }
        .task(id: identity) {
            guard active, let reference, let key, let source else { return }
            try? await Task.sleep(for: Self.activationSettle)
            guard !Task.isCancelled else { return }
            let presentation = rowPresentation
            let index = blockIndex
            await source.renderer.run(instance, reference: reference, key: key,
                document: { try await source.documents.document(reference) },
                open: { [inlineAnchor] in open($0, anchor: inlineAnchor, scope: nil) },
                onPinChange: { [weak presentation] pinned in
                    if let index { presentation?.setPinned(pinned, for: .htmlVisual(index)) }
                })
        }
        .task(id: ExpansionIdentity(expansion: expansion.map(ObjectIdentifier.init), active: visible && scenePhase == .active,
            retry: expansionRetry)) {
            guard visible, scenePhase == .active, let expansion, let reference, let key, let source else { return }
            await source.renderer.run(expansion, reference: reference, key: key,
                document: { try await source.documents.document(reference) },
                open: { [expandedAnchor, expandedScope] in open($0, anchor: expandedAnchor, scope: expandedScope) },
                onPinChange: { _ in })
        }
        .onChange(of: expansion != nil) { _, expanded in
            if let blockIndex { rowPresentation?.setPinned(expanded, for: .htmlVisualExpansion(blockIndex)) }
        }
        .onDisappear {
            if expansion == nil, let blockIndex { rowPresentation?.setPinned(false, for: .htmlVisual(blockIndex)) }
        }
        .sheet(item: presentedExpansion, onDismiss: {
            if case .dismissing = presentation { presentation = .inline }
        }) { expansion in
            expanded(expansion).modifier(HostFileNestedPresentation(opener: files?.fileOpener, scope: expandedScope))
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("html-visual")
    }

    private func expanded(_ expansion: HTMLVisualInstance) -> some View {
        NavigationStack {
            Group {
                if let page = expansion.page {
                    web(page, anchor: expandedAnchor).opacity(expansion.status == .live ? 1 : 0)
                } else { placeholder(for: expansion) { expansionRetry += 1 } }
            }
            .navigationTitle(title)
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", systemImage: "xmark") { presentation = .dismissing(expansion) }
                        .labelStyle(.iconOnly).appIconButtonFeedback()
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 640 * interfaceScale, minHeight: 480 * interfaceScale)
        #endif
    }

    private func web(_ page: WebPage, anchor: HTMLVisualFrameAnchor) -> some View {
        WebView(page)
            .webViewContentBackground(.hidden)
            .webViewBackForwardNavigationGestures(.disabled)
            .webViewMagnificationGestures(.disabled)
            .webViewLinkPreviews(.disabled)
            .webViewTextSelection(.enabled)
            .htmlVisualFrameAnchor(anchor)
    }

    private func open(_ request: HTMLVisualOpenRequest, anchor: HTMLVisualFrameAnchor, scope: UUID?) {
        switch request {
        case .link(let url):
            if url.isFileURL, let files { files.open(url, transition: nil, presentationScope: scope) } else { openURL(url) }
        case .embedded(let file, let frame):
            files?.open(file, frame: anchor.transitionFrame(for: frame), presentationScope: scope)
        }
    }

    @ViewBuilder private var inlinePlaceholder: some View {
        if reference == nil || source == nil || !loadsAutomatically {
            placeholder(for: instance) { retry += 1 }
        } else {
            RoundedRectangle(cornerRadius: 12)
                .fill(.quaternary)
                .overlay {
                    if rowVisibility?.isVisible == true && visible && scenePhase == .active { ProgressView() }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Loading \(title)")
        }
    }

    @ViewBuilder private func placeholder(for instance: HTMLVisualInstance, retry: @escaping () -> Void) -> some View {
        if reference == nil || source == nil {
            Label("HTML visual unavailable", systemImage: "exclamationmark.triangle")
                .scaledFont(.caption).foregroundStyle(.secondary)
        } else if let failure = instance.failure {
            VStack(alignment: .leading, spacing: 8) {
                Text("HTML visual unavailable").scaledFont(.caption)
                Text(failure).scaledFont(.caption).foregroundStyle(.secondary)
                Button("Try again", action: retry).appButtonFeedback()
            }
        } else if instance.waiting || instance.status == .suspended {
            Button("Load \(title)") {
                source?.renderer.promote(instance)
                if instance.requestID == nil { retry() }
            }
            .scaledFont(.caption).appButtonFeedback()
        } else {
            Color.clear.accessibilityLabel("Loading \(title)")
        }
    }

    @Observable
    @MainActor
    final class PresentedRaster {
        var snapshot: PreparedSnapshot?
        var sharp: HTMLVisualPreparedRaster?
    }

    struct PreparedSnapshot {
        let prepared: HTMLVisualPreparedRaster
        let captureID: UUID?

        var image: DecodedImage { prepared.image }
        var height: Double { prepared.raster.displayHeight }
        var key: HTMLVisualLayoutKey { prepared.key }
    }

    private struct ImageIdentity: Equatable {
        let key: HTMLVisualLayoutKey?
        let revision: Int
        let captureID: UUID?
        let displayScale: Double
        let needed: Bool
    }

    private struct SharpIdentity: Equatable {
        let base: ObjectIdentifier?
        let displayScale: Double
        let kept: Bool
        let settled: Bool
    }

    private struct PrefetchIdentity: Equatable {
        let url: URL
        let source: ObjectIdentifier?
    }

    private struct ExpansionIdentity: Equatable {
        let expansion: ObjectIdentifier?
        let active: Bool
        let retry: Int
    }

    private enum Presentation {
        case inline
        case expanded(HTMLVisualInstance)
        case dismissing(HTMLVisualInstance)
    }

    private struct Identity: Equatable {
        let url: URL
        let source: ObjectIdentifier?
        let active: Bool
        let retry: Int
    }
}

