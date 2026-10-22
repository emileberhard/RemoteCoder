#if os(macOS)
import AppKit
import OSLog
import SwiftUI

struct TranscriptHostEnvironment: Equatable {
    let interfaceScale: CGFloat
    let dynamicTypeSize: DynamicTypeSize
    let colorScheme: ColorScheme
    let colorSchemeContrast: ColorSchemeContrast
    let displayScale: CGFloat
    let layoutDirection: LayoutDirection
    let locale: Locale
    let scenePhase: ScenePhase
    let visualsVisible: Bool
    let energyPolicy: AppEnergyPolicy
    let reduceMotion: Bool
    let reduceTransparency: Bool
    let differentiateWithoutColor: Bool
    let isEnabled: Bool
    let imageSource: ChatImageSource?
    let htmlVisualSource: HTMLVisualSource?
    let htmlVisualTheme: HTMLVisualTheme?
    let htmlVisualCaptureAllowed: Bool
    let htmlVisualSnapshotsOnly: Bool
    let siteIcons: ObjectIdentifier?
    let themeStore: ObjectIdentifier
    let codeExportPresenter: ObjectIdentifier

    @MainActor init(_ environment: EnvironmentValues, themeStore: AppThemeStore, codeExportPresenter: TranscriptCodeExportPresenter) {
        interfaceScale = environment.interfaceScale
        dynamicTypeSize = environment.dynamicTypeSize
        colorScheme = environment.colorScheme
        colorSchemeContrast = environment.colorSchemeContrast
        displayScale = environment.displayScale
        layoutDirection = environment.layoutDirection
        locale = environment.locale
        scenePhase = environment.scenePhase
        visualsVisible = environment.visualsVisible
        energyPolicy = environment.appEnergyPolicy
        reduceMotion = environment.accessibilityReduceMotion
        reduceTransparency = environment.accessibilityReduceTransparency
        differentiateWithoutColor = environment.accessibilityDifferentiateWithoutColor
        isEnabled = environment.isEnabled
        imageSource = environment.chatImageSource
        htmlVisualSource = environment.htmlVisualSource
        htmlVisualTheme = environment.htmlVisualTheme
        htmlVisualCaptureAllowed = environment.htmlVisualCaptureAllowed
        htmlVisualSnapshotsOnly = environment.htmlVisualSnapshotsOnly
        siteIcons = environment.siteIcons.map(ObjectIdentifier.init)
        self.themeStore = ObjectIdentifier(themeStore)
        self.codeExportPresenter = ObjectIdentifier(codeExportPresenter)
    }

    func readingLayout(columnWidth: CGFloat) -> TranscriptReadingLayout {
        TranscriptReadingLayout(columnWidth: columnWidth, interfaceScale: interfaceScale,
            dynamicTypeSize: String(describing: dynamicTypeSize), localeIdentifier: locale.identifier,
            isRightToLeft: layoutDirection == .rightToLeft)
    }

    func reflows(comparedTo previous: Self) -> Bool {
        interfaceScale != previous.interfaceScale || dynamicTypeSize != previous.dynamicTypeSize
            || layoutDirection != previous.layoutDirection || locale != previous.locale
    }
}

@MainActor
final class TranscriptLogicalRow {
    var inputs: TranscriptRowInputs
    let presentation: TranscriptRowPresentation
    var height: CGFloat

    init(inputs: TranscriptRowInputs, presentations: TranscriptRowPresentations, rendered: RenderedMessage?,
         width: CGFloat, scale: CGFloat, htmlVisualTheme: HTMLVisualTheme?, htmlVisualRenderer: HTMLVisualRenderer?) {
        self.inputs = inputs
        presentation = TranscriptRowPresentation(store: presentations, rowID: inputs.row.id)
        if let message = inputs.row.message {
            let charactersPerLine = max(24, width / (7 * scale))
            height = min(1_600 * scale, max(48 * scale,
                ceil(CGFloat(message.text.utf8.count) / charactersPerLine) * 18 * scale + 32 * scale))
            if let rendered {
                var visualBytes = 0
                var visualHeight: CGFloat = 0
                for block in rendered.blocks {
                    guard case .htmlVisual(let url, let title) = block.content,
                          let reference = HTMLVisualReference(url: url), let htmlVisualTheme else { continue }
                    let key = HTMLVisualLayoutKey(digest: reference.digest, width: max(1, Int(width.rounded())), theme: htmlVisualTheme)
                    visualBytes += url.absoluteString.utf8.count + title.utf8.count + 6
                    visualHeight += min(HTMLVisualInlineHeight.limit(interfaceScale: scale), CGFloat(htmlVisualRenderer?.height(for: key) ?? 180))
                        + MarkdownBlockView.spacing * scale
                }
                if visualHeight > 0 {
                    let textLines = ceil(CGFloat(max(0, message.text.utf8.count - visualBytes)) / charactersPerLine)
                    height = max(32 * scale, textLines * 18 * scale + 32 * scale) + visualHeight
                }
            }
            height += CGFloat(message.attachments.count) * (ComposerMetrics.attachmentTileHeight * scale + 12)
        } else {
            switch inputs.row.kind {
            case .activity: height = 56 * scale
            case .content(.question): height = 260 * scale
            case .content(.viewedMedia): height = 240 * scale
            case .content(.publishedVisual(let visual)):
                if let htmlVisualTheme {
                    let key = HTMLVisualLayoutKey(digest: visual.publication.reference.digest,
                        width: max(1, Int(width.rounded())), theme: htmlVisualTheme)
                    height = min(HTMLVisualInlineHeight.limit(interfaceScale: scale), CGFloat(htmlVisualRenderer?.height(for: key) ?? 180))
                } else { height = 180 }
            default: height = 40 * scale
            }
        }
    }
}

@MainActor
final class TranscriptRowHost {
    private static let logger = Logger(subsystem: "RemoteCoder", category: "Transcript")
    let view: NSHostingView<AnyView>
    weak var surfaceActivity: TranscriptSurfaceActivity?
    private(set) var hitRevision = 0
    private(set) var inputs: TranscriptRowInputs
    private(set) var measurement: CGSize?
    private var revision = 0
    #if RC_PERF_HARNESS
    struct AdmissionForBench {
        let row: CGRect
        let viewport: CGRect
        let required: Bool
    }

    struct WorkForBench {
        weak var view: NSView?
        var rootRevision: Int
        var measureRequests: Int
        var measurement: CGSize?
        var acceptedMeasurementChanges: Int
        var rowFrame: CGRect?
        let admission: AdmissionForBench?
    }

    var admissionForBench: AdmissionForBench?
    private var measureRequestsForBench = 0
    private var acceptedMeasurementChangesForBench = 0

    func workForBench(rowFrame: CGRect?) -> WorkForBench {
        WorkForBench(view: view, rootRevision: revision, measureRequests: measureRequestsForBench,
            measurement: measurement, acceptedMeasurementChanges: acceptedMeasurementChangesForBench,
            rowFrame: rowFrame, admission: admissionForBench)
    }
    #endif
    var onMeasurement: () -> Void = {}

    init(inputs: TranscriptRowInputs) {
        self.inputs = inputs
        let hostingView = TranscriptHostingView(rootView: AnyView(EmptyView()))
        view = hostingView
        hostingView.onLayout = { [weak self] in self?.hitRevision += 1 }
        hostingView.onDetachedLayout = { [weak self] in
            if self?.surfaceActivity?.state == .detached { PerfBuild.count("native.detachedLayout") }
        }
        view.translatesAutoresizingMaskIntoConstraints = false
        view.sizingOptions = []
        view.safeAreaRegions = []
        view.autoresizingMask = []
        view.alphaValue = 0
        PerfBuild.count("native.rowHostCreated")
    }

    func update<Content: View>(inputs: TranscriptRowInputs, content: Content,
                               environment: EnvironmentValues) {
        let span = PerfBuild.span("native.rowHostUpdate"); defer { span.end() }
        PerfBuild.count("native.rowHostUpdated")
        self.inputs = inputs
        revision += 1
        hitRevision += 1
        let revision = revision
        measurement = nil
        view.rootView = AnyView(
            content
                .environment(\.self, environment)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: TranscriptHostedRowMeasurement.self, of: {
                    TranscriptHostedRowMeasurement(revision: revision, size: $0.size)
                }) { [weak self] measurement in
                    self?.receive(measurement)
                }
        )
        view.needsLayout = true
    }

    func propose(width: CGFloat) {
        guard view.frame.width != width else { return }
        measurement = nil
        let span = PerfBuild.span("native.rowHostResize"); defer { span.end() }
        let resizeSpan = PerfBuild.span("native.hostResize"); defer { resizeSpan.end() }
        PerfBuild.count("native.rowWidthChanged")
        view.setFrameSize(CGSize(width: width, height: max(view.frame.height, 1)))
    }

    static func acceptsWidth(_ width: CGFloat, proposed: CGFloat) -> Bool {
        abs(width - proposed) < 0.5
    }

    func hasMeasurement(for width: CGFloat) -> Bool {
        measurement.map { Self.acceptsWidth($0.width, proposed: width) } == true
    }

    func layoutIfNeeded() {
        let span = PerfBuild.span("native.rowMeasure"); defer { span.end() }
        PerfBuild.count("native.rowMeasureRequested")
        #if RC_PERF_HARNESS
        measureRequestsForBench += 1
        #endif
        view.layoutSubtreeIfNeeded()
    }

    private func receive(_ value: TranscriptHostedRowMeasurement) {
        guard value.revision == revision else {
            PerfBuild.count("native.rowMeasurementStale")
            return
        }
        let size = value.size
        guard size.width.isFinite, size.width >= 0, size.height.isFinite, size.height >= 0 else {
            PerfBuild.count("native.rowMeasurementRejected")
            Self.logger.error("Rejected nonfinite or negative transcript row measurement")
            return
        }
        guard size.width > 0 else { return }
        guard Self.acceptsWidth(size.width, proposed: view.frame.width) else {
            PerfBuild.count("native.rowMeasurementStale")
            return
        }
        guard measurement != size else { return }
        PerfBuild.count("native.rowMeasured")
        #if RC_PERF_HARNESS
        acceptedMeasurementChangesForBench += 1
        #endif
        measurement = size
        onMeasurement()
    }

    func place(in frame: CGRect) {
        guard view.frame != frame || view.alphaValue == 0 else { return }
        let span = PerfBuild.span("native.rowPlacement"); defer { span.end() }
        hitRevision += 1
        if view.frame.size != frame.size {
            let resizeSpan = PerfBuild.span("native.rowHostResize")
            let hostResizeSpan = PerfBuild.span("native.hostResize")
            PerfBuild.count("native.rowSizeChanged")
            view.setFrameSize(frame.size)
            hostResizeSpan.end()
            resizeSpan.end()
        }
        if view.frame.origin != frame.origin {
            PerfBuild.count("native.rowOriginChanged")
            view.setFrameOrigin(frame.origin)
        }
        if view.alphaValue == 0 { view.alphaValue = 1 }
    }

    func remove() {
        revision += 1
        onMeasurement = {}
        view.removeFromSuperview()
        PerfBuild.count("native.rowHostRemoved")
    }
}

private struct TranscriptHostedRowMeasurement: Equatable, Sendable {
    let revision: Int
    let size: CGSize
}

private final class TranscriptHostingView: NSHostingView<AnyView> {
    var onLayout: () -> Void = {}
    var onDetachedLayout: () -> Void = {}

    override func layout() {
        let span = PerfBuild.span("native.rowLayout"); defer { span.end() }
        PerfBuild.count("native.rowLayouts")
        onDetachedLayout()
        super.layout()
        onLayout()
    }
}
#endif
