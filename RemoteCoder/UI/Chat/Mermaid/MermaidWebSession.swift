import Foundation
import WebKit

extension MermaidRenderer {
    static let shared = MermaidRenderer()

    convenience init() {
        self.init(cacheLimit: 32, byteLimit: 24 * 1_024 * 1_024, makeRender: {
            let session = MermaidWebSession()
            return { try await session.render($0) }
        })
    }
}

/// WebPage is main-actor controlled, but layout/JavaScript run in WebKit's process.
/// Resource reads are concurrent; no user text enters an executable string.
@MainActor
private final class MermaidWebSession {
    private var page: WebPage?

    func render(_ request: MermaidRequest) async throws -> MermaidDiagram {
        let page = try await preparedPage()
        let value = try await page.callJavaScript(
            "return await renderRemoteCoderDiagram(source, dark, highContrast);",
            arguments: ["source": request.source, "dark": request.isDark, "highContrast": request.highContrast],
            contentWorld: .page
        )
        guard let output = value as? [String: Any],
              let svg = output["svg"] as? String,
              let width = output["width"] as? Double,
              let height = output["height"] as? Double,
              width.isFinite, height.isFinite, width > 0, height > 0,
              width <= 20_000, height <= 20_000,
              let title = output["title"] as? String,
              let summary = output["description"] as? String,
              let background = output["background"] as? String else {
            throw MermaidFailure(message: "The diagram renderer returned an invalid image.")
        }
        // Bound BOTH dimensions, including very tall sequence diagrams. WebKit
        // chooses device pixel density; the snapshot's longest side is 640 points.
        let snapshotWidth = min(640, 640 * width / height)
        let preview = try await page.exported(as: .image(
            region: .rect(CGRect(x: 0, y: 0, width: width, height: height)),
            snapshotWidth: snapshotWidth
        ))
        return MermaidDiagram(svg: svg, preview: preview, size: CGSize(width: width, height: height),
                              title: title, summary: summary, background: background)
    }

    private func preparedPage() async throws -> WebPage {
        if let page { return page }
        let resources = try await Self.resources()
        let configuration = MermaidWebContent.configuration()
        // The unmodified distribution is a global script, not a function body.
        // WKUserScript also avoids relaxing the document's script-src 'none' CSP.
        configuration.userContentController.addUserScript(WKUserScript(
            source: resources.library + "\n" + resources.bridge,
            injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .page
        ))
        let page = WebPage(configuration: configuration, navigationDecider: MermaidWebContent())
        for try await _ in page.load(html: resources.html, baseURL: MermaidWebContent.baseURL) { }
        self.page = page
        return page
    }

    @concurrent
    private static func resources() async throws -> (html: String, library: String, bridge: String) {
        func read(_ name: String, _ ext: String) throws -> String {
            guard let url = Bundle.main.url(forResource: name, withExtension: ext) else {
                throw MermaidFailure(message: "The bundled diagram renderer is missing. Please update the app.")
            }
            return try String(contentsOf: url, encoding: .utf8)
        }
        return try (read("MermaidHost", "html"), read("mermaid-12.0.0.min", "js"), read("MermaidHost", "js"))
    }
}

/// Both rendering and viewing are offline, ephemeral, and navigation-disabled.
struct MermaidWebContent: WebPage.NavigationDeciding {
    static let baseURL = URL(filePath: "/remotecoder-mermaid/")

    @MainActor static func configuration() -> WebPage.Configuration {
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.loadsSubresources = false
        #if os(iOS)
        configuration.dataDetectorTypes = []
        #endif
        return configuration
    }

    func decidePolicy(for action: WebPage.NavigationAction,
                      preferences: inout WebPage.NavigationPreferences) async -> WKNavigationActionPolicy {
        action.navigationType == .other && action.request.url == Self.baseURL ? .allow : .cancel
    }
}
