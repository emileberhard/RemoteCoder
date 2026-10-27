import CryptoKit
import Foundation
import Network
import SwiftUI
import Testing
import UIKit
import UniformTypeIdentifiers
import WebKit
@testable import RemoteCoder

@Suite(.serialized)
@MainActor
struct HTMLVisualWebKitTests {
    private let webContent = HTMLVisualWebContent()
    private let theme = HTMLVisualTheme(fontSize: 17, text: "rgb(12, 34, 56)", secondaryText: "gray",
                                       background: "white", surface: "#eee", accent: "blue", isDark: false)

    @Test(.timeLimit(.minutes(1)))
    func admitsNetworkLoadsAndRunsEvalWasmAndWorkers() async throws {
        let server = try await VisualNetworkServer.start()
        defer { server.listener.cancel() }
        let endpoint = "http://127.0.0.1:\(server.port)"
        let source = """
            <title>Networked visual</title><body><div style="height:60px">Inline content</div>
            <script>document.addEventListener('securitypolicyviolation',event=>document.body.dataset.violations=(document.body.dataset.violations??'')+event.effectiveDirective+' ');</script>
            <img src="\(endpoint)/image"><script src="\(endpoint)/script"></script>
            <iframe src="\(endpoint)/frame"></iframe><link rel="stylesheet" href="\(endpoint)/style">
            <object data="\(endpoint)/object"></object>
            <script>
                const mark=(key,value)=>document.body.dataset[key]=String(value);
                fetch('\(endpoint)/fetch').catch(()=>{});
                try { new WebSocket('wss://127.0.0.1:\(server.port)/socket'); } catch {}
                mark('eval',eval('6*7'));
                WebAssembly.compile(new Uint8Array([0,97,115,109,1,0,0,0])).then(()=>mark('wasm','ok'),error=>mark('wasm',error));
                const worker=new Worker(URL.createObjectURL(new Blob(['postMessage(6*7)'],{type:'text/javascript'})));
                worker.onmessage=event=>mark('worker',event.data);worker.onerror=()=>mark('worker','error');
            </script></body>
            """
        let reference = try reference(source)
        let page = try await webContent.make(reference: reference, theme: theme, onEvent: { _ in }, open: { _ in Issue.record("Resource loading must never open a native link") })
        let hosted = try await host(page, opacity: 1)
        defer { hosted.close(); page.stopLoading() }
        try await HTMLVisualWebContent.load(page, html: source, reference: reference)
        let marks = ["eval": "42", "wasm": "ok", "worker": "42"]
        let onlyObjectViolations = { (observed: [String: String]) in
            Set(observed["violations", default: ""].split(separator: " ")) == ["object-src"]
        }
        let deadline = ContinuousClock.now + .seconds(5)
        var observed: [String: String] = [:]
        while ContinuousClock.now < deadline {
            observed = try await page.callJavaScript("return {...document.body.dataset};", contentWorld: .defaultClient) as? [String: String] ?? [:]
            if marks.allSatisfy({ observed[$0.key] == $0.value }), onlyObjectViolations(observed), server.paths.contains("/image") { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(marks.allSatisfy { observed[$0.key] == $0.value } && onlyObjectViolations(observed) && server.paths.contains("/image"),
                "page \(observed), requests \(server.paths.sorted())")
        #expect(page.url == (try HTMLVisualWebContent.baseURL(for: reference)))
        #expect(try await page.callJavaScript("return typeof window.webkit?.messageHandlers?.rcVisual;", contentWorld: .page) as? String == "undefined")
    }

    @Test(.timeLimit(.minutes(1)))
    func revealsBeforeSlowNetworkResourcesFinishLoading() async throws {
        let server = try await VisualNetworkServer.start()
        defer { server.listener.cancel() }
        let source = """
            <body><p>Readable now</p><img id="late" width="40" height="40" src="http://127.0.0.1:\(server.port)/slow-image"></body>
            """
        let reference = try reference(source)
        let page = try await webContent.make(reference: reference, theme: theme, onEvent: { _ in }, open: { _ in })
        let hosted = try await host(page, opacity: 1)
        defer { hosted.close(); page.stopLoading() }
        try await HTMLVisualWebContent.load(page, html: source, reference: reference)
        #expect(!server.paths.contains("/slow-image-sent"))
        try await wait { server.paths.contains("/slow-image-sent") }
        try await wait { try await page.callJavaScript("return document.getElementById('late').naturalWidth;", contentWorld: .defaultClient) as? Int == 1 }
    }

    @Test(.timeLimit(.minutes(1)))
    func isolatesHostPathsAndBlocksProgrammaticNavigation() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let secret = directory.appendingPathComponent("private.js")
        try Data("window.hostSecret='exposed'".utf8).write(to: secret)
        let source = """
            <title>Confined</title><body><script src="private.js"></script><script src="\(secret.absoluteString)"></script>
            <a id="external" href="https://example.com/outside" target="_blank">Outside</a>
            <a id="anchor" href="#section">Section</a><p id="section">Section</p>
            <img id="image" alt="Pixel" src="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==">
            <a id="download" download="pixel.png" href="data:image/png;base64,AA==">Download</a>
            <script>
                fetch('private.js').then(r=>r.text()).then(v=>window.hostSecret=v).catch(()=>{});
                fetch('\(secret.absoluteString)').then(r=>r.text()).then(v=>window.hostSecret=v).catch(()=>{});
            </script></body>
            """
        var links: [HTMLVisualOpenRequest] = []
        let reference = try reference(source)
        let page = try await webContent.make(reference: reference, theme: theme, onEvent: { _ in }, open: { links.append($0) })
        let hosted = try await host(page, opacity: 1)
        defer { hosted.close(); page.stopLoading() }
        try await HTMLVisualWebContent.load(page, html: source, reference: reference)
        _ = try await page.callJavaScript("""
            document.getElementById('external').click();
            document.getElementById('image').click();
            document.getElementById('download').click();
            window.open('https://example.com/popup');
            location.href='https://example.com/programmatic';
            """, contentWorld: .page)
        try await Task.sleep(for: .milliseconds(250))
        #expect(links.isEmpty)
        #expect(page.title == "Confined")
        #expect(page.url == (try HTMLVisualWebContent.baseURL(for: reference)))
        #expect(try await page.callJavaScript("return typeof window.hostSecret;", contentWorld: .page) as? String == "undefined")
        _ = try await page.callJavaScript("document.getElementById('anchor').click();", contentWorld: .page)
        try await wait { page.url?.fragment == "section" }
        #expect(links.isEmpty)
    }

    @Test(.timeLimit(.minutes(1)))
    func readsDataAndPageBlobMediaThroughTheIsolatedWorldWithinTheLimit() async throws {
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
        let source = """
            <title>Media</title><body style="margin:0">
            <img id="data" style="display:block;margin-top:30px;width:40px;height:20px" src="data:image/png;base64,\(png)">
            <img id="blob">
            <script>
                const bytes = Uint8Array.from(atob('\(png)'), c => c.charCodeAt(0));
                document.getElementById('blob').src = URL.createObjectURL(new Blob([bytes], {type: 'image/png'}));
                document.body.dataset.large = URL.createObjectURL(new Blob([new Uint8Array(\(EmbeddedFile.maximumBytes + 1))]));
            </script></body>
            """
        var requests: [HTMLVisualOpenRequest] = []
        let reference = try reference(source)
        let page = try await webContent.make(reference: reference, theme: theme, onEvent: { _ in }, open: { requests.append($0) })
        let hosted = try await host(page, opacity: 1)
        defer { hosted.close(); page.stopLoading() }
        try await HTMLVisualWebContent.load(page, html: source, reference: reference)
        _ = try await page.callJavaScript("""
            const image = document.getElementById('data'), generated = document.getElementById('blob');
            await rcVisualEmbed(image.src, 'Pixel', image);
            await rcVisualEmbed(document.body.dataset.large, 'Large', document.body);
            await rcVisualEmbed(generated.src, 'Generated', generated);
            """, contentWorld: .defaultClient)
        try await wait { requests.count == 2 }
        let opened = requests.compactMap { request -> (EmbeddedFileRequest, CGRect)? in
            guard case .embedded(let file, let frame) = request else { return nil }
            return (file, frame)
        }
        #expect(opened.map { $0.0.suggestedName } == ["Pixel", "Generated"])
        for (file, _) in opened {
            let (type, data) = try EmbeddedFile.decode(file.dataURL)
            #expect(type == .png)
            #expect(data == Data(base64Encoded: png))
        }
        #expect(opened.first?.1 == CGRect(x: 0, y: 30, width: 40, height: 20))
        try await Task.sleep(for: .milliseconds(100))
        #expect(requests.count == 2)
    }

    @Test(.timeLimit(.minutes(1)))
    func reportsIntrinsicHeightGrowthAndShrinkAndAppliesThemeWithoutReload() async throws {
        let source = "<title>Layout</title><body><div id='content' style='height:80px'>Content</div><input id='input'><script>window.loads=(window.loads||0)+1</script></body>"
        let reference = try reference(source)
        var heights: [Double] = []
        var interaction: [Bool] = []
        var settled = 0
        let page = try await webContent.make(reference: reference, theme: theme, onEvent: {
            switch $0 {
            case .layout(let height): heights.append(height)
            case .interaction(let active): interaction.append(active)
            case .settled: settled += 1
            }
        }, open: { _ in })
        let hosted = try await host(page, opacity: 1)
        defer { hosted.close(); page.stopLoading() }
        try await HTMLVisualWebContent.load(page, html: source, reference: reference)
        try await wait { !heights.isEmpty }
        let initial = try #require(heights.last)
        _ = try await page.callJavaScript("document.getElementById('content').style.height='240px';", contentWorld: .page)
        try await wait { (heights.last ?? 0) > initial + 100 }
        let grown = try #require(heights.last)
        _ = try await page.callJavaScript("document.getElementById('content').style.height='20px';", contentWorld: .page)
        try await wait { (heights.last ?? grown) < initial }
        let count = heights.count
        try await Task.sleep(for: .milliseconds(250))
        #expect(heights.count == count)
        #expect(heights.allSatisfy { $0.rounded() == $0 })
        _ = try await page.callJavaScript("document.getElementById('content').style.height='24000px';", contentWorld: .page)
        try await wait { heights.last == 20_000 }
        _ = try await page.callJavaScript("document.getElementById('content').style.height='20px';", contentWorld: .page)
        try await wait { (heights.last ?? 20_000) < initial }
        let next = HTMLVisualTheme(fontSize: 23, text: "rgb(80, 90, 100)", secondaryText: "gray", background: "black", surface: "#333", accent: "orange", isDark: true)
        try await HTMLVisualWebContent.apply(page, theme: next, scrolling: false)
        #expect(try await page.callJavaScript("return getComputedStyle(document.body).fontSize;", contentWorld: .defaultClient) as? String == "23px")
        #expect(try await page.callJavaScript("return getComputedStyle(document.body).color;", contentWorld: .defaultClient) as? String == "rgb(80, 90, 100)")
        #expect(try await page.callJavaScript("return getComputedStyle(document.getElementById('input')).accentColor;", contentWorld: .defaultClient) as? String == "rgb(255, 165, 0)")
        #expect(try await page.callJavaScript("return window.loads;", contentWorld: .page) as? Int == 1)
        _ = try await page.callJavaScript("document.getElementById('input').focus();", contentWorld: .page)
        try await wait { interaction.last == true }
        _ = try await page.callJavaScript("document.getElementById('input').blur();document.getElementById('input').dispatchEvent(new Event('change',{bubbles:true}));", contentWorld: .page)
        try await wait { interaction.last == false && settled > 0 }
        _ = try await page.callJavaScript("const range=document.createRange();range.selectNodeContents(document.getElementById('content'));document.getSelection().addRange(range);", contentWorld: .page)
        try await wait { interaction.last == true }
        _ = try await page.callJavaScript("document.getSelection().removeAllRanges();", contentWorld: .page)
        try await wait { interaction.last == false }
    }

    @Test(.timeLimit(.minutes(1)))
    func reportsHeightBeforeTransparentWebViewIsRevealed() async throws {
        let source = "<body><div style='height:80px'>Content</div></body>"
        let reference = try reference(source)
        var height: Double?
        var reports = 0
        let page = try await webContent.make(reference: reference, theme: theme, onEvent: {
            if case .layout(let measured) = $0 { height = measured; reports += 1 }
        }, open: { _ in })
        let hosted = try await host(page, opacity: 0)
        defer { hosted.close(); page.stopLoading() }
        try await HTMLVisualWebContent.load(page, html: source, reference: reference)
        try await wait { height == 80 }
        _ = try await page.callJavaScript("globalThis.requestAnimationFrame=()=>{throw new Error('Animation frames unavailable')};", contentWorld: .defaultClient)
        _ = try await page.callJavaScript("document.querySelector('div').style.height='210px';", contentWorld: .page)
        try await wait { height == 210 }
        let before = reports
        try await HTMLVisualWebContent.apply(page, theme: theme, scrolling: false)
        try await wait { reports > before }
        #expect(height == 210)
        #expect(try await page.callJavaScript("return typeof globalThis.rcVisualMeasure;", contentWorld: .page) as? String == "undefined")
    }

    @Test(.timeLimit(.minutes(1)))
    func inlineWebViewClipsTallContentAndExpansionRestoresScrolling() async throws {
        let source = "<body><div style='height:2000px'>Tall content</div></body>"
        let reference = try reference(source)
        let page = try await webContent.make(reference: reference, theme: theme, onEvent: { _ in }, open: { _ in })
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = HostedWindow(scene: scene)
        let controller = UIHostingController(rootView: WebView(page).frame(width: 320, height: 600))
        window.show(controller)
        defer { window.close(); page.stopLoading() }
        try await HTMLVisualWebContent.load(page, html: source, reference: reference)
        try await wait { webView(in: controller.view) != nil }
        let native = try #require(webView(in: controller.view))
        #expect(native.bounds.height == 600)
        #expect(try await page.callJavaScript("return getComputedStyle(document.documentElement).overflow;", contentWorld: .defaultClient) as? String == "clip")
        try await HTMLVisualWebContent.apply(page, theme: theme, scrolling: true)
        _ = try await page.callJavaScript("window.scrollTo(0,1200);", contentWorld: .page)
        try await wait { try await page.callJavaScript("return window.scrollY;", contentWorld: .defaultClient) as? Int == 1200 }
        try await HTMLVisualWebContent.apply(page, theme: theme, scrolling: false)
        #expect(try await page.callJavaScript("return window.scrollY;", contentWorld: .defaultClient) as? Int == 0)
        #expect(try await page.callJavaScript("return document.body.getBoundingClientRect().height;", contentWorld: .defaultClient) as? Int == 2000)
    }

    @Test(.timeLimit(.minutes(1)))
    func keepsDiscardableBrowserStoragePerVisualAndPreservesInlineCanvasResources() async throws {
        let source = "<body>Storing visual</body>"
        let reference = try reference(source)
        let page = try await webContent.make(reference: reference, theme: theme, onEvent: { _ in }, open: { _ in })
        defer { page.stopLoading() }
        try await HTMLVisualWebContent.load(page, html: source, reference: reference)
        let values = try #require(try await page.callJavaScript("""
            const results = {};
            for (const name of ['localStorage','sessionStorage']) {
                try { window[name].setItem('visual-test','value'); results[name]=window[name].getItem('visual-test'); }
                catch (error) { results[name]=error.name; }
            }
            results.indexedDB = await new Promise(resolve => {
                try {
                    const request = indexedDB.open('visual-test');
                    request.onerror = () => resolve(request.error.name);
                    request.onsuccess = () => { request.result.close(); resolve('allowed'); };
                } catch (error) { resolve(error.name); }
            });
            const image = new Image();
            const url = URL.createObjectURL(new Blob(['<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1"><rect width="1" height="1" fill="red"/></svg>'],{type:'image/svg+xml'}));
            try {
                await new Promise((resolve,reject) => { image.onload=resolve;image.onerror=reject;image.src=url; });
                const canvas = document.createElement('canvas'); canvas.width=1;canvas.height=1;
                const context = canvas.getContext('2d'); context.drawImage(image,0,0);
                results.pixel = Array.from(context.getImageData(0,0,1,1).data);
            } finally { URL.revokeObjectURL(url); }
            return results;
            """, contentWorld: .page) as? [String: Any])
        #expect(values["localStorage"] as? String == "value")
        #expect(values["sessionStorage"] as? String == "value")
        #expect(values["indexedDB"] as? String == "allowed")
        #expect(values["pixel"] as? [Int] == [255, 0, 0, 255])

        let otherSource = "<body>Other visual</body>"
        let otherReference = try self.reference(otherSource)
        let other = try await webContent.make(reference: otherReference, theme: theme, onEvent: { _ in }, open: { _ in })
        defer { other.stopLoading() }
        try await HTMLVisualWebContent.load(other, html: otherSource, reference: otherReference)
        #expect(try await other.callJavaScript("return localStorage.getItem('visual-test') === null;", contentWorld: .page) as? Bool == true)

        await webContent.discardStorage()
        let reopened = try await webContent.make(reference: reference, theme: theme, onEvent: { _ in }, open: { _ in })
        defer { reopened.stopLoading() }
        try await HTMLVisualWebContent.load(reopened, html: source, reference: reference)
        #expect(try await reopened.callJavaScript("return localStorage.getItem('visual-test') === null;", contentWorld: .page) as? Bool == true)
    }

    @Test(.timeLimit(.minutes(1)))
    func reportsScriptErrorsWithTheirMessageAndSourceLine() async throws {
        let source = "<body>\n<script>\naddEventListener('error',event=>document.body.dataset.error=event.message+'@'+event.lineno);\nmissingFunction();\n</script></body>"
        let reference = try reference(source)
        let page = try await webContent.make(reference: reference, theme: theme, onEvent: { _ in }, open: { _ in })
        defer { page.stopLoading() }
        try await HTMLVisualWebContent.load(page, html: source, reference: reference)
        let error = try await page.callJavaScript("return document.body.dataset.error;", contentWorld: .page) as? String
        #expect(error?.contains("missingFunction") == true && error?.hasSuffix("@4") == true, "\(error ?? "none")")
    }

    private func reference(_ source: String) throws -> HTMLVisualReference {
        let digest = SHA256.hash(data: Data(source.utf8)).map { String(format: "%02x", $0) }.joined()
        let url = try #require(URL(string: "rc-visual:" + digest))
        return try #require(HTMLVisualReference(url: url))
    }

    private func webView(in view: UIView) -> WKWebView? {
        if let web = view as? WKWebView { return web }
        for child in view.subviews {
            if let web = webView(in: child) { return web }
        }
        return nil
    }

    private func host(_ page: WebPage, opacity: Double) async throws -> HostedWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        scene.keyWindow?.endEditing(true)
        let window = HostedWindow(scene: scene)
        let controller = UIHostingController(rootView: WebView(page).frame(width: 320, height: 600).opacity(opacity).environment(\.scenePhase, .active))
        window.show(controller)
        try await wait { controller.view.window != nil }
        return window
    }

    private func wait(_ condition: () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while try await !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        try #require(try await condition())
    }
}

@MainActor
private final class VisualNetworkServer {
    let listener: NWListener
    private(set) var port: UInt16 = 0
    private(set) var paths: Set<String> = []
    private var started = false

    private init() throws { listener = try NWListener(using: .tcp) }

    static func start() async throws -> VisualNetworkServer {
        let server = try VisualNetworkServer()
        server.listener.newConnectionHandler = { [weak server] connection in
            Task { @MainActor in
                guard let server else { connection.cancel(); return }
                connection.start(queue: .main)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, _, _ in
                    let line = data.flatMap { String(data: $0, encoding: .utf8)?.split(separator: "\r\n").first }
                    let path = line?.split(separator: " ").dropFirst().first.map(String.init) ?? ""
                    let gif = path == "/slow-image"
                    let body = gif ? Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7")! : Data("ok".utf8)
                    let response = Data("HTTP/1.1 200 OK\r\nContent-Type: \(gif ? "image/gif" : "text/plain")\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8) + body
                    Task { @MainActor in
                        server.paths.insert(path)
                        if path == "/slow-image" { try? await Task.sleep(for: .seconds(3)); server.paths.insert("/slow-image-sent") }
                        connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
                    }
                }
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            server.listener.stateUpdateHandler = { [weak server] state in
                Task { @MainActor in
                    guard let server, !server.started else { return }
                    switch state {
                    case .ready:
                        server.started = true
                        guard let port = server.listener.port?.rawValue else { continuation.resume(throwing: URLError(.cannotConnectToHost)); return }
                        server.port = port
                        continuation.resume()
                    case .failed(let error): server.started = true; continuation.resume(throwing: error)
                    default: break
                    }
                }
            }
            server.listener.start(queue: .main)
        }
        return server
    }
}

