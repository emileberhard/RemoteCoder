import Foundation
import Network
import SwiftUI
import Testing
import UIKit
import WebKit
@testable import RemoteCoder

@Suite(.serialized)
@MainActor
struct HostHTMLWebKitTests {
    @Test(.timeLimit(.minutes(1)))
    func runsReportScriptsFiltersAndNetworkResourcesAndPreservesOriginalBytes() async throws {
        let server = try await HTMLTestServer.start()
        defer { server.listener.cancel() }
        let source = """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <title>Report</title>
        <link rel="stylesheet" href="http://127.0.0.1:\(server.port)/style.css">
        </head><body><h1>Åsa’s report</h1>
        <button id="filter">Engineering</button><table><tbody id="benchmark-rows"></tbody></table>
        <img id="embedded" src="data:image/gif;base64,R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7">
        <img id="network-image" src="http://127.0.0.1:\(server.port)/image.gif">
        <iframe id="frame" src="http://127.0.0.1:\(server.port)/frame.html"></iframe>
        <form id="form" method="post" action="http://127.0.0.1:\(server.port)/submit"><input name="value" value="report"></form>
        <script src="http://127.0.0.1:\(server.port)/script.js"></script>
        <script>
        document.title='Script executed';
        document.getElementById('benchmark-rows').innerHTML='<tr><td>Professional work</td></tr><tr><td>Engineering</td></tr>';
        document.getElementById('filter').addEventListener('click',()=>{
          document.getElementById('benchmark-rows').innerHTML='<tr><td>Engineering</td></tr>';
        });
        fetch('http://127.0.0.1:\(server.port)/data.json').then(r=>r.json()).then(value=>{
          document.body.dataset.network=value.value;
        });
        </script></body></html>
        """
        let file = try file(source)
        defer { try? FileManager.default.removeItem(at: file.lease.url.deletingLastPathComponent()) }
        let document = try HostHTMLDocument(lease: file.lease)
        let page = try HostHTMLWebContent.page(file: file, document: document) { _ in
            Issue.record("Web resources must load inside the preview")
        }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        scene.keyWindow?.endEditing(true)
        let window = HostedWindow(scene: scene)
        let controller = UIHostingController(rootView: WebView(page).environment(\.scenePhase, .active))
        window.show(controller)
        defer { window.close() }
        let mountDeadline = ContinuousClock.now + .seconds(5)
        while webView(in: controller.view)?.window == nil, ContinuousClock.now < mountDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(webView(in: controller.view)?.window != nil)
        defer { page.stopLoading() }
        for try await _ in page.load(document.url) { }
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if try await page.callJavaScript("return document.body.dataset.network;", contentWorld: .defaultClient) as? String == "Network fetched" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(page.title == "Script executed")
        let result = try await page.callJavaScript("""
            return {width:document.getElementById('embedded').naturalWidth,
                    networkWidth:document.getElementById('network-image').naturalWidth,
                    color:getComputedStyle(document.querySelector('h1')).color,
                    text:document.querySelector('h1').textContent,
                    external:document.body.dataset.external,
                    network:document.body.dataset.network,
                    rows:document.querySelectorAll('#benchmark-rows tr').length};
            """, contentWorld: .defaultClient)
        let values = try #require(result as? [String: Any])
        #expect(values["width"] as? Int == 1)
        #expect(values["networkWidth"] as? Int == 1)
        #expect(values["color"] as? String == "rgb(12, 34, 56)")
        #expect(values["text"] as? String == "Åsa’s report")
        #expect(values["external"] as? String == "loaded")
        #expect(values["network"] as? String == "Network fetched")
        #expect(values["rows"] as? Int == 2)
        #expect(server.requests.contains("/frame.html"))
        #expect(try Data(contentsOf: file.lease.url) == Data(source.utf8))
        _ = try await page.callJavaScript("document.getElementById('filter').click();", contentWorld: .defaultClient)
        #expect(try await page.callJavaScript("return document.querySelectorAll('#benchmark-rows tr').length;", contentWorld: .defaultClient) as? Int == 1)
        _ = try await page.callJavaScript("document.getElementById('form').submit();", contentWorld: .defaultClient)
        let formDeadline = ContinuousClock.now + .seconds(5)
        while page.title != "Form submitted", ContinuousClock.now < formDeadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(page.title == "Form submitted")
    }

    @Test(.timeLimit(.minutes(1)))
    func loadsRelativeHostScriptsStylesImagesFramesAndFetches() async throws {
        let file = try file("""
            <!doctype html><title>Supporting files</title><link rel="stylesheet" href="style.css?v=2">
            <h1>Local resources</h1><img id="image" src="image.gif"><iframe id="child" src="child.html"></iframe>
            <script src="app.js"></script><a id="popup" href="child.html" target="_blank">Open child</a>
            <a id="absolute" href="file:///Users/developer/reports/nested/child.html?revision=2#section">Absolute child</a>
            """, resources: [
                "style.css": Data("h1{color:rgb(23,45,67)}".utf8),
                "app.js": Data("document.title='Local script ran';try{localStorage.setItem('host-html-test','Saved state');document.body.dataset.storage=localStorage.getItem('host-html-test');}catch(e){document.body.dataset.storage=e.name;}fetch('data.json?v=2').then(r=>r.json()).then(v=>document.body.dataset.local=v.value);".utf8),
                "data.json": Data("{\"value\":\"Local fetch worked\"}".utf8),
                "child.html": Data("<!doctype html><title>Child page</title><p>Child frame</p><script>document.body.dataset.frame='ran';</script>".utf8),
                "image.gif": try #require(Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"))
            ])
        defer { try? FileManager.default.removeItem(at: file.lease.url.deletingLastPathComponent()) }
        let document = try HostHTMLDocument(lease: file.lease)
        var destinations: [URL] = []
        let page = try HostHTMLWebContent.page(file: file, document: document, willNavigate: { destinations.append($0) }) { _ in Issue.record("Supporting files must not replace the viewer") }
        defer { page.stopLoading() }
        for try await _ in page.load(document.url) { }
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if try await page.callJavaScript("return document.body.dataset.local;", contentWorld: .defaultClient) as? String == "Local fetch worked" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(page.title == "Local script ran")
        let result = try await page.callJavaScript("""
            return {color:getComputedStyle(document.querySelector('h1')).color,
                    width:document.getElementById('image').naturalWidth,
                    local:document.body.dataset.local,storage:document.body.dataset.storage,
                    frame:document.getElementById('child').contentDocument.body.dataset.frame};
            """, contentWorld: .defaultClient)
        let values = try #require(result as? [String: Any])
        #expect(values["color"] as? String == "rgb(23, 45, 67)")
        #expect(values["width"] as? Int == 1)
        #expect(values["local"] as? String == "Local fetch worked")
        #expect(values["storage"] as? String == "Saved state")
        #expect(values["frame"] as? String == "ran")
        #expect(try await page.callJavaScript("return document.getElementById('absolute').href;", contentWorld: .defaultClient) as? String
                == document.url.deletingLastPathComponent().appendingPathComponent("child.html").absoluteString + "?revision=2#section")
        _ = try await page.callJavaScript("document.getElementById('absolute').click();", contentWorld: .defaultClient)
        let absoluteDeadline = ContinuousClock.now + .seconds(5)
        while page.title != "Child page", ContinuousClock.now < absoluteDeadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(page.title == "Child page")
        #expect(destinations.last?.path == "/Users/developer/reports/nested/child.html")
        #expect(page.url?.scheme == HostHTMLDocument.scheme)
        #expect(page.url?.host == document.url.host)
        for try await _ in page.load(document.url) { }
        _ = try await page.callJavaScript("document.getElementById('popup').click();", contentWorld: .defaultClient)
        let popupDeadline = ContinuousClock.now + .seconds(5)
        while page.title != "Child page", ContinuousClock.now < popupDeadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(page.title == "Child page")
    }

    @Test(.timeLimit(.minutes(1)))
    func clickedRelativeLinksUseRemotePathsAndAnchorsStayInThePage() async throws {
        let file = try file("""
            <!doctype html><title>Links</title>
            <a id="anchor" href="#section">Section</a><h1 id="section">Heading</h1>
            <a id="relative" href="My%20Report.md#L12">Related file</a>
            """)
        defer { try? FileManager.default.removeItem(at: file.lease.url.deletingLastPathComponent()) }
        let document = try HostHTMLDocument(lease: file.lease)
        var links: [URL] = []
        let page = try HostHTMLWebContent.page(file: file, document: document) { links.append($0) }
        defer { page.stopLoading() }
        for try await _ in page.load(document.url) { }
        _ = try await page.callJavaScript("document.getElementById('anchor').click();", contentWorld: .defaultClient)
        let deadline = ContinuousClock.now + .seconds(5)
        while page.url?.fragment != "section", ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(page.url?.fragment == "section")
        #expect(links.isEmpty)
        _ = try await page.callJavaScript("document.getElementById('relative').click();", contentWorld: .defaultClient)
        let linkDeadline = ContinuousClock.now + .seconds(5)
        while links.isEmpty, ContinuousClock.now < linkDeadline { try await Task.sleep(for: .milliseconds(10)) }
        let link = try #require(links.first)
        let reference = try #require(try HostFileReference.resolve(url: link, hostID: file.lease.reference.hostID, relativeTo: nil))
        #expect(reference.path == "/Users/developer/reports/nested/My Report.md")
        #expect(reference.lineAnchor == 12)
        #expect(page.url?.fragment == "section")
    }

    @Test(.timeLimit(.minutes(1)))
    func blocksOutsideFolderFetchesFramesAndNavigationAndIsolatesStorage() async throws {
        let server = try await HTMLTestServer.start()
        defer { server.listener.cancel() }
        let source = """
            <!doctype html><title>Confined</title><body>
            <iframe src="../private.html"></iframe><img src="/tmp/private.gif">
            <iframe src="http://127.0.0.1:\(server.port)/frame.html"></iframe>
            <a id="escape" href="file:///tmp/private.html">Outside</a>
            <script>
            window.addEventListener('message', event=>document.body.dataset.externalRead=event.data);
            fetch('../private.txt').then(r=>r.text()).then(v=>document.body.dataset.escape=v)
              .catch(()=>document.body.dataset.escape='blocked');
            </script></body>
            """
        let file = try file(source, resources: ["private.txt": Data("inside secret".utf8), "../private.txt": Data("secret".utf8), "../private.html": Data("<title>Private</title>".utf8)])
        defer { try? FileManager.default.removeItem(at: file.lease.url.deletingLastPathComponent()) }
        let document = try HostHTMLDocument(lease: file.lease)
        let secret = try #require(URL(string: "private.txt", relativeTo: document.url)?.absoluteURL)
        server.frameScript = "fetch('\(secret.absoluteString)').then(r=>r.text()).then(value=>parent.postMessage(value,'*')).catch(()=>parent.postMessage('cross-origin blocked','*'));"
        let page = try HostHTMLWebContent.page(file: file, document: document) { _ in Issue.record("Outside links must not open host files") }
        defer { page.stopLoading() }
        for try await _ in page.load(document.url) { }
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if try await page.callJavaScript("return document.body.dataset.escape;", contentWorld: .defaultClient) as? String == "blocked",
               try await page.callJavaScript("return document.body.dataset.externalRead;", contentWorld: .defaultClient) as? String == "cross-origin blocked" { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(try await page.callJavaScript("return document.body.dataset.escape;", contentWorld: .defaultClient) as? String == "blocked")
        #expect(try await page.callJavaScript("return document.body.dataset.externalRead;", contentWorld: .defaultClient) as? String == "cross-origin blocked")
        _ = try await page.callJavaScript("document.getElementById('escape').click();", contentWorld: .defaultClient)
        #expect(page.title == "Confined")
        _ = try await page.callJavaScript("try { localStorage.setItem('private-test', 'secret'); } catch {}", contentWorld: .defaultClient)
        let next = try HostHTMLWebContent.page(file: file, document: document) { _ in }
        defer { next.stopLoading() }
        for try await _ in next.load(document.url) { }
        #expect(try await next.callJavaScript("try { return localStorage.getItem('private-test') === null; } catch { return true; }", contentWorld: .defaultClient) as? Bool == true)
    }

    @Test(.timeLimit(.minutes(1)))
    func javascriptDialogsReturnNativeResponsesAndDismissalCancelsPendingPrompts() async throws {
        let file = try file("""
            <!doctype html><title>Dialogs</title><body><button id="dialogs">Start dialogs</button><script>
            document.getElementById('dialogs').onclick=()=>{
                alert('Alert');
                document.body.dataset.response=confirm('Confirm') ? prompt('Prompt','Default') : 'Declined';
                document.title=prompt('Pending')===null ? 'Pending cancelled' : 'Unexpected response';
            };
            </script></body>
            """)
        defer { try? FileManager.default.removeItem(at: file.lease.url.deletingLastPathComponent()) }
        let document = try HostHTMLDocument(lease: file.lease)
        let dialogs = HostHTMLDialogs()
        let page = try HostHTMLWebContent.page(file: file, document: document, dialogs: dialogs) { _ in }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = HostedWindow(scene: scene)
        let controller = UIHostingController(rootView: WebView(page).environment(\.scenePhase, .active))
        window.show(controller)
        controller.view.layoutIfNeeded()
        defer { window.close() }
        defer { dialogs.close(); page.stopLoading() }
        let mountDeadline = ContinuousClock.now + .seconds(5)
        while webView(in: controller.view)?.window == nil, ContinuousClock.now < mountDeadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        for try await _ in page.load(document.url) { }
        let mounted = try #require(webView(in: controller.view))
        try #require(mounted.window != nil && mounted.bounds.width > 0 && mounted.bounds.height > 0)
        try #require(mounted.url == document.url)
        controller.view.endEditing(true)
        let script = Task {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                mounted.evaluateJavaScript("document.getElementById('dialogs').click();") { _, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume() }
                }
            }
        }
        defer { script.cancel() }
        for message in ["Alert", "Confirm", "Prompt"] {
            let deadline = ContinuousClock.now + .seconds(30)
            while dialogs.request?.message != message, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
            try #require(dialogs.request?.message == message)
            if message == "Prompt" {
                #expect(dialogs.text == "Default")
                dialogs.text = "Native response"
            }
            dialogs.accept()
        }
        let deadline = ContinuousClock.now + .seconds(5)
        while dialogs.request == nil, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(dialogs.request?.message == "Pending")
        dialogs.cancel()
        let cancelledDeadline = ContinuousClock.now + .seconds(5)
        while page.title != "Pending cancelled", ContinuousClock.now < cancelledDeadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(page.title == "Pending cancelled")
        try await script.value
        #expect(try await page.callJavaScript("return document.body.dataset.response;", contentWorld: .defaultClient) as? String == "Native response")
        #expect(dialogs.request == nil)
    }

    @Test(.timeLimit(.minutes(1)))
    func laterNavigationFailuresStayVisibleAndRetryTheFailedDestination() async throws {
        let file = try file("<!doctype html><title>Links</title><a id='missing' href='missing.html'>Missing page</a>")
        defer { try? FileManager.default.removeItem(at: file.lease.url.deletingLastPathComponent()) }
        let browser = HostHTMLBrowser(file: file)
        let run = Task { await browser.run { _ in } }
        defer { run.cancel(); browser.stop() }
        let deadline = ContinuousClock.now + .seconds(5)
        while browser.page?.title != "Links", ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        let page = try #require(browser.page)
        _ = try await page.callJavaScript("document.getElementById('missing').click();", contentWorld: .defaultClient)
        let failureDeadline = ContinuousClock.now + .seconds(5)
        while browser.failure == nil, ContinuousClock.now < failureDeadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(browser.failure != nil)
        run.cancel()
        await run.value
        browser.retry()
        let retry = Task { await browser.run { _ in } }
        defer { retry.cancel() }
        let retryDeadline = ContinuousClock.now + .seconds(5)
        while (browser.page === page || browser.failure == nil), ContinuousClock.now < retryDeadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(browser.failure != nil)
        #expect(browser.page?.title != "Links")
    }

    @Test(.timeLimit(.minutes(1)))
    func loadsLargeBurstsOfSlowSupportingFiles() async throws {
        let image = try #require(Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"))
        let names = (0..<64).map { "image-\($0).gif" }
        let file = try file("<!doctype html><title>Resources</title>" + names.map { "<img src='\($0)'>" }.joined(),
                            resources: Dictionary(uniqueKeysWithValues: names.map { ($0, image) }), resourceDelay: .milliseconds(25))
        defer { try? FileManager.default.removeItem(at: file.lease.url.deletingLastPathComponent()) }
        let document = try HostHTMLDocument(lease: file.lease)
        let page = try HostHTMLWebContent.page(file: file, document: document) { _ in }
        defer { page.stopLoading() }
        for try await _ in page.load(document.url) { }
        #expect(try await page.callJavaScript("return Array.from(document.images).filter(i=>i.naturalWidth===1).length;", contentWorld: .defaultClient) as? Int == 64)
    }

    @Test(.timeLimit(.minutes(1)))
    func missingLeasedBytesFailInsteadOfShowingAnEmptyDocument() async throws {
        let file = try file("<title>Removed</title>")
        defer { try? FileManager.default.removeItem(at: file.lease.url.deletingLastPathComponent()) }
        try FileManager.default.removeItem(at: file.lease.url)
        let document = try HostHTMLDocument(lease: file.lease)
        let page = try HostHTMLWebContent.page(file: file, document: document) { _ in }
        defer { page.stopLoading() }
        await #expect(throws: (any Error).self) {
            for try await _ in page.load(document.url) { }
        }
    }

    private func file(_ source: String, resources: [String: Data] = [:], resourceDelay: Duration = .zero) throws -> OpenedHostFile {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("index.html")
        let data = Data(source.utf8)
        try data.write(to: url)
        let reference = try HostFileReference(hostID: UUID(), path: "/Users/developer/reports/nested/index.html")
        let lease = HostFileLease(id: UUID(), reference: reference,
            metadata: HostFileMetadata(path: reference.path, name: "index.html", bytes: Int64(data.count), modifiedAt: 0, revision: "test"),
            url: url, downloadedAt: .now)
        var leases: [String: HostFileLease] = [:]
        for (name, bytes) in resources {
            let resourceURL = directory.appendingPathComponent(UUID().uuidString)
            try bytes.write(to: resourceURL)
            let resourceReference = try HostFileReference(hostID: reference.hostID, path: "/Users/developer/reports/nested/" + name)
            leases[resourceReference.path] = HostFileLease(id: UUID(), reference: resourceReference,
                metadata: HostFileMetadata(path: resourceReference.path, name: (name as NSString).lastPathComponent, bytes: Int64(bytes.count), modifiedAt: 0, revision: "test"),
                url: resourceURL, downloadedAt: .now)
        }
        return OpenedHostFile(lease: lease, isCachedCopy: false, transition: nil, access: HTMLFileAccess(resources: leases, delay: resourceDelay))
    }

    private func webView(in view: UIView) -> WKWebView? {
        if let webView = view as? WKWebView { return webView }
        for child in view.subviews {
            if let webView = webView(in: child) { return webView }
        }
        return nil
    }
}

private actor HTMLFileAccess: HostFileAccess {
    let resources: [String: HostFileLease]
    let delay: Duration
    init(resources: [String: HostFileLease], delay: Duration) { self.resources = resources; self.delay = delay }
    func openVisual(reference: HTMLVisualReference, progress: @escaping @Sendable (HostFileProgress) -> Void) async throws -> HostFileLease {
        throw HostFileError.unavailable
    }

    func open(reference: HostFileReference, containingDirectory: String?, progress: @escaping @Sendable (HostFileProgress) -> Void) async throws -> HostFileLease {
        try await Task.sleep(for: delay)
        guard let lease = resources[reference.path], lease.reference.hostID == reference.hostID else { throw HostFileError.unavailable }
        return lease
    }
    func cachedCopy(for reference: HostFileReference) -> HostFileLease? { nil }
    func release(_ lease: HostFileLease) { }
}

@MainActor
private final class HTMLTestServer {
    let listener: NWListener
    private(set) var port: UInt16 = 0
    private(set) var requests: Set<String> = []
    var frameScript = ""
    private var started = false

    private init() throws { listener = try NWListener(using: .tcp) }

    static func start() async throws -> HTMLTestServer {
        let server = try HTMLTestServer()
        server.listener.newConnectionHandler = { [weak server] connection in
            Task { @MainActor in server?.receive(connection) }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            server.listener.stateUpdateHandler = { [weak server] state in
                Task { @MainActor in
                    guard let server, !server.started else { return }
                    switch state {
                    case .ready:
                        server.started = true
                        guard let port = server.listener.port?.rawValue else {
                            continuation.resume(throwing: URLError(.cannotConnectToHost))
                            return
                        }
                        server.port = port
                        continuation.resume()
                    case .failed(let error):
                        server.started = true
                        continuation.resume(throwing: error)
                    default: break
                    }
                }
            }
            server.listener.start(queue: .main)
        }
        return server
    }

    private func receive(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            Task { @MainActor in
                guard let self, let data,
                      let firstLine = String(data: data, encoding: .utf8)?.components(separatedBy: "\r\n").first else {
                    connection.cancel()
                    return
                }
                let parts = firstLine.split(separator: " ")
                guard parts.count >= 2 else { connection.cancel(); return }
                let path = String(parts[1])
                self.requests.insert(path)
                let mime: String
                let body: Data
                switch path {
                case "/style.css":
                    mime = "text/css"; body = Data("h1{color:rgb(12,34,56)}".utf8)
                case "/script.js":
                    mime = "text/javascript"; body = Data("document.body.dataset.external='loaded';".utf8)
                case "/data.json":
                    mime = "application/json"; body = Data("{\"value\":\"Network fetched\"}".utf8)
                case "/image.gif":
                    mime = "image/gif"
                    guard let image = Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7") else { connection.cancel(); return }
                    body = image
                case "/submit":
                    mime = "text/html"; body = Data("<!doctype html><title>Form submitted</title>Submitted".utf8)
                default:
                    mime = "text/html"; body = Data("<!doctype html><title>Frame</title>Embedded frame<script>\(self.frameScript)</script>".utf8)
                }
                var response = Data("HTTP/1.1 200 OK\r\nContent-Type: \(mime)\r\nContent-Length: \(body.count)\r\nAccess-Control-Allow-Origin: *\r\nConnection: close\r\n\r\n".utf8)
                response.append(body)
                connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
            }
        }
    }
}
