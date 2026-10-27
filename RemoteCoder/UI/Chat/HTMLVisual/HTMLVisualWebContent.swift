import Foundation
import WebKit

enum HTMLVisualEvent {
    case layout(height: Double)
    case interaction(active: Bool)
    case settled
}

enum HTMLVisualOpenRequest {
    case link(URL)
    case embedded(EmbeddedFileRequest, frame: CGRect)
}

@MainActor
final class HTMLVisualWebContent {
    private let websiteDataStore = WKWebsiteDataStore.nonPersistent()
    private let resourceHandlers: [URLScheme: any URLSchemeHandler]

    init(resourceHandlers: [URLScheme: any URLSchemeHandler] = [:]) {
        self.resourceHandlers = resourceHandlers
    }

    func make(reference: HTMLVisualReference, theme: HTMLVisualTheme,
              onEvent: @escaping @MainActor (HTMLVisualEvent) -> Void,
              open: @escaping @MainActor (HTMLVisualOpenRequest) -> Void,
              onRegistration: (WKUserContentController) -> Void = { _ in }) async throws -> WebPage {
        #if RC_PERF_HARNESS
        if AppStorageScope.isOfflineReplay {
            PerformanceReplayHTTP.blockVisual()
            throw PerformanceReplayScenario.Failure.invalidScenario("HTML visuals are outside the offline text replay")
        }
        #endif
        let origin = try Self.baseURL(for: reference)
        var configuration = WebPage.Configuration()
        configuration.websiteDataStore = websiteDataStore
        configuration.urlSchemeHandlers = resourceHandlers
        configuration.deviceSensorAuthorization = .init(decision: .deny)
        configuration.allowsAirPlayForMediaPlayback = false
        #if os(iOS)
        configuration.mediaPlaybackBehavior = .allowsInlinePlayback
        #endif
        let controller = configuration.userContentController
        let bridge = HTMLVisualBridge(origin: origin, onEvent: onEvent, open: open)
        controller.add(bridge, contentWorld: .defaultClient, name: "rcVisual")
        onRegistration(controller)
        do {
            let themeScript = try await Self.prepareThemeScript(theme)
            try Task.checkCancellation()
            controller.addUserScript(WKUserScript(source: themeScript,
                injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .defaultClient))
            controller.addUserScript(WKUserScript(source: Self.layoutScript,
                injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient))
            return WebPage(configuration: configuration, navigationDecider: HTMLVisualNavigation(origin: origin),
                           dialogPresenter: HTMLVisualDialogs())
        } catch {
            controller.removeScriptMessageHandler(forName: "rcVisual", contentWorld: .defaultClient)
            throw error
        }
    }

    func discardStorage() async {
        await websiteDataStore.removeData(ofTypes: Self.storageTypes, modifiedSince: .distantPast)
    }

    private static let storageTypes: Set<String> = [WKWebsiteDataTypeLocalStorage, WKWebsiteDataTypeSessionStorage,
        WKWebsiteDataTypeIndexedDBDatabases, WKWebsiteDataTypeFetchCache, WKWebsiteDataTypeFileSystem,
        WKWebsiteDataTypeCookies]

    static func baseURL(for reference: HTMLVisualReference) throws -> URL {
        guard let url = URL(string: "https://\(reference.digest).rc-visual.invalid/") else { throw URLError(.badURL) }
        return url
    }

    @concurrent
    private static func prepareThemeScript(_ theme: HTMLVisualTheme) async throws -> String {
        let values = try JSONSerialization.data(withJSONObject: theme.variables, options: [.sortedKeys])
        guard let serialized = String(data: values, encoding: .utf8) else { throw URLError(.cannotDecodeContentData) }
        return """
            (() => {
                const variables = \(serialized);
                const install = () => {
                    for (const [name,value] of Object.entries(variables)) document.documentElement.style.setProperty(name,value);
                };
                if (document.documentElement) install();
                else new MutationObserver((_,observer) => { if (document.documentElement) { install(); observer.disconnect(); } }).observe(document,{childList:true,subtree:true});
            })();
            """
    }

    @concurrent
    private static func prepareData(_ html: String) async -> Data {
        Data((documentPrefix + html + "</html>").utf8)
    }

    nonisolated private static let documentPrefix = """
        <!doctype html><html><head><meta charset="utf-8">\
        <meta name="viewport" content="width=device-width,initial-scale=1">\
        <style>\(HTMLVisualTheme.baseCSS.replacing("\n", with: " "))\(probeCSS)</style></head>
        """

    #if DEBUG
    nonisolated private static let probeCSS = ProcessInfo.processInfo.arguments.contains("-html-visual-fixture-probe")
        ? "html{background:#00ffff !important}" : ""
    #else
    nonisolated private static let probeCSS = ""
    #endif

    func load(_ page: WebPage, html: String, reference: HTMLVisualReference) async throws {
        let origin = try Self.baseURL(for: reference)
        let schemes = resourceHandlers.keys.map { $0.rawValue + ":" }.sorted().joined(separator: " ")
        let policy = Self.contentSecurityPolicy.replacing("default-src *", with: "default-src * \(schemes)")
        guard let response = HTTPURLResponse(url: origin, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "text/html; charset=utf-8", "Content-Security-Policy": policy]
        ) else { throw URLError(.badServerResponse) }
        let data = await Self.prepareData(html)
        try Task.checkCancellation()
        for try await event in page.load(simulatedRequest: URLRequest(url: origin), response: response, responseData: data)
            where event == .committed { break }
        try Task.checkCancellation()
        try await page.callJavaScript("""
            if (document.readyState !== 'complete') await Promise.race([
                new Promise(resolve => addEventListener('load', resolve, {once: true})),
                new Promise(resolve => setTimeout(resolve, 500))]);
            globalThis.rcVisualRevealed = true;
            globalThis.rcVisualMeasure?.(true);
            """, contentWorld: .defaultClient)
    }

    static func apply(_ page: WebPage, theme: HTMLVisualTheme, scrolling: Bool) async throws {
        let variables = await prepareVariables(theme)
        try Task.checkCancellation()
        try await page.callJavaScript("""
            for (const [name,value] of Object.entries(variables)) document.documentElement.style.setProperty(name,value);
            document.documentElement.style.setProperty('overflow',scrolling ? 'auto' : 'clip','important');
            if (!scrolling) window.scrollTo(0,0);
            globalThis.rcVisualMeasure?.(true);
            """, arguments: ["variables": variables, "scrolling": scrolling], contentWorld: .defaultClient)
    }

    @concurrent
    private static func prepareVariables(_ theme: HTMLVisualTheme) async -> [String: String] {
        theme.variables
    }

    private static let contentSecurityPolicy = "sandbox allow-scripts allow-same-origin; default-src * wss: data: blob: 'unsafe-inline' 'unsafe-eval'; object-src 'none'; base-uri 'none'; form-action 'none'"

    private static let layoutScript = """
        (() => {
            const send = value => window.webkit.messageHandlers.rcVisual.postMessage(value);
            let height = -1, scheduled = false, focused = false, selected = false;
            const pointers = new Set();
            let interacting = false;
            const interaction = () => {
                const active = focused || selected || pointers.size > 0;
                if (active !== interacting) { interacting = active; send({kind:'interaction',active}); }
            };
            const measure = (force = false) => {
                scheduled = false;
                const measured = Math.min(20000,Math.ceil(Math.max(0,document.documentElement.getBoundingClientRect().height)));
                if (Number.isFinite(measured) && (force || measured !== height)) { height = measured; send({kind:'layout',height}); }
            };
            globalThis.rcVisualMeasure = measure;
            const schedule = () => { if (!scheduled) { scheduled = true; queueMicrotask(() => measure()); } };
            new ResizeObserver(schedule).observe(document.documentElement,{box:'border-box'});
            let settleTimer;
            const settle = () => {
                if (!globalThis.rcVisualRevealed) return;
                clearTimeout(settleTimer); settleTimer = setTimeout(() => send({kind:'settled'}),1000);
            };
            if (document.body) new MutationObserver(settle).observe(document.body,{childList:true,subtree:true,characterData:true,attributes:true});
            document.addEventListener('load',settle,true);
            window.addEventListener('load',settle);
            document.fonts.addEventListener('loadingdone',settle);
            document.addEventListener('focusin', () => { focused = true; interaction(); },true);
            document.addEventListener('focusout', () => queueMicrotask(() => {
                focused = document.activeElement !== document.body && document.activeElement !== document.documentElement;
                interaction();
            }),true);
            document.addEventListener('pointerdown', event => { if (event.isTrusted && pointers.size < 16) { pointers.add(event.pointerId); interaction(); } },true);
            const release = event => { pointers.delete(event.pointerId); interaction(); };
            document.addEventListener('pointerup',release,true);
            document.addEventListener('pointercancel',release,true);
            document.addEventListener('selectionchange',() => { selected = document.getSelection()?.isCollapsed === false; interaction(); });
            window.addEventListener('blur',() => { focused = false; selected = false; pointers.clear(); interaction(); });
            document.addEventListener('input',settle,true);
            document.addEventListener('change',settle,true);
            let latestOpen = 0, reading;
            const embed = async (source,name,element) => {
                const request = ++latestOpen;
                reading?.abort();
                const controller = reading = new AbortController();
                const rect = element.getBoundingClientRect();
                const response = await fetch(source,{signal:controller.signal});
                if (Number(response.headers.get('content-length')) > \(EmbeddedFile.maximumBytes)) { controller.abort(); return; }
                const blob = await response.blob();
                if (request !== latestOpen || blob.size > \(EmbeddedFile.maximumBytes)) return;
                const url = await new Promise((resolve,reject) => {
                    const reader = new FileReader();
                    reader.onload = () => resolve(reader.result);
                    reader.onerror = () => reject(reader.error);
                    reader.readAsDataURL(blob);
                });
                if (request !== latestOpen || typeof url !== 'string' || url.length > \(EmbeddedFile.maximumDataURLLength)) return;
                send({kind:'open',url,name:name.slice(0,200),frame:[rect.left,rect.top,rect.width,rect.height]});
            };
            globalThis.rcVisualEmbed = embed;
            document.addEventListener('click',event => {
                const link = event.composedPath().find(node => node instanceof Element && node.matches('a[href],area[href]'));
                if (!link) return;
                let destination;
                try { destination = new URL(link.getAttribute('href'),document.baseURI); } catch { event.preventDefault(); return; }
                const localAnchor = destination.origin === location.origin && destination.pathname === location.pathname && destination.search === location.search && destination.hash;
                if (localAnchor) return;
                event.preventDefault();
                if (!event.isTrusted) return;
                if (['data:','blob:'].includes(destination.protocol)) {
                    embed(destination.href,link.getAttribute('download') || '',link).catch(() => {});
                } else if (['http:','https:','mailto:','tel:','file:'].includes(destination.protocol) && destination.href.length <= 4096) {
                    send({kind:'link',url:destination.href});
                }
            },true);
            const interactive = 'a[href],area[href],button,label,summary,select,input,textarea,[role=button],[role=link],[onclick],[contenteditable]:not([contenteditable=false])';
            window.addEventListener('click',event => {
                if (!event.isTrusted || event.defaultPrevented) return;
                const path = event.composedPath();
                const index = path.findIndex(node => node instanceof HTMLImageElement || node instanceof HTMLVideoElement && !node.controls);
                if (index < 0 || path.slice(index).some(node => node instanceof Element && node.matches(interactive))) return;
                const media = path[index];
                const source = media.currentSrc || media.src;
                if (!/^(data|blob):/i.test(source)) return;
                embed(source,media.getAttribute('alt') || media.getAttribute('title') || '',media).catch(() => {});
            });
        })();
        """
}

@MainActor
private final class HTMLVisualBridge: NSObject, WKScriptMessageHandler {
    private let origin: URL
    private let onEvent: @MainActor (HTMLVisualEvent) -> Void
    private let open: @MainActor (HTMLVisualOpenRequest) -> Void
    private var lastInteraction = false

    init(origin: URL, onEvent: @escaping @MainActor (HTMLVisualEvent) -> Void,
         open: @escaping @MainActor (HTMLVisualOpenRequest) -> Void) {
        self.origin = origin
        self.onEvent = onEvent
        self.open = open
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.frameInfo.request.url?.host == origin.host,
              let value = message.body as? [String: Any], value.count <= 4,
              let kind = value["kind"] as? String else { return }
        switch kind {
        case "layout":
            guard let height = value["height"] as? Double, height.isFinite, height >= 0,
                  height <= 20_000, height.rounded() == height else { return }
            onEvent(.layout(height: height))
        case "interaction":
            guard let active = value["active"] as? Bool, active != lastInteraction else { return }
            lastInteraction = active
            onEvent(.interaction(active: active))
        case "settled": onEvent(.settled)
        case "link":
            guard let raw = value["url"] as? String, raw.utf8.count <= 4096,
                  let url = URL(string: raw), ["http", "https", "mailto", "tel", "file"].contains(url.scheme?.lowercased() ?? ""),
                  url.host != origin.host else { return }
            open(.link(url))
        case "open":
            guard let raw = value["url"] as? NSString, raw.length <= EmbeddedFile.maximumDataURLLength,
                  raw.range(of: "data:", options: [.anchored, .caseInsensitive]).location != NSNotFound,
                  let name = value["name"] as? String, name.utf16.count <= 200,
                  let frame = value["frame"] as? [Double], frame.count == 4, frame.allSatisfy(\.isFinite),
                  frame[2] >= 0, frame[3] >= 0 else { return }
            open(.embedded(EmbeddedFileRequest(dataURL: raw as String, suggestedName: name),
                           frame: CGRect(x: frame[0], y: frame[1], width: frame[2], height: frame[3])))
        default: break
        }
    }
}

@MainActor
private final class HTMLVisualNavigation: WebPage.NavigationDeciding {
    private let origin: URL
    private var initialLoad = true

    init(origin: URL) { self.origin = origin }

    func decidePolicy(for action: WebPage.NavigationAction,
                      preferences: inout WebPage.NavigationPreferences) async -> WKNavigationActionPolicy {
        guard let url = action.request.url, let target = action.target else { return .cancel }
        if !target.isMainFrame { return .allow }
        if initialLoad, action.navigationType == .other, url == origin {
            initialLoad = false
            return .allow
        }
        if action.navigationType == .linkActivated, url.host == origin.host,
           url.scheme == origin.scheme, url.path == origin.path, url.query == nil, url.fragment != nil {
            return .allow
        }
        return .cancel
    }

    func decidePolicy(for response: WebPage.NavigationResponse) async -> WKNavigationResponsePolicy {
        response.canShowMimeType ? .allow : .cancel
    }
}

private struct HTMLVisualDialogs: WebPage.DialogPresenting {
    func handleJavaScriptAlert(message: String, initiatedBy frame: WebPage.FrameInfo) async { }
    func handleJavaScriptConfirm(message: String, initiatedBy frame: WebPage.FrameInfo) async -> WebPage.JavaScriptConfirmResult { .cancel }
    func handleJavaScriptPrompt(message: String, defaultText: String?, initiatedBy frame: WebPage.FrameInfo) async -> WebPage.JavaScriptPromptResult { .cancel }
    func handleFileInputPrompt(parameters: WKOpenPanelParameters, initiatedBy frame: WebPage.FrameInfo) async -> WebPage.FileInputPromptResult { .cancel }
}
