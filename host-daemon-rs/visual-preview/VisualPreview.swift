import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import WebKit

@main
enum VisualPreview {
    @MainActor
    static func main() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 20) {
            FileHandle.standardError.write(Data("rendering did not finish within 20 seconds\n".utf8))
            exit(2)
        }
        NSApplication.shared.setActivationPolicy(.accessory)
        Task {
            do {
                let arguments = CommandLine.arguments
                guard arguments.count == 2, let url = URL(string: "rc-visual:" + arguments[1]),
                      let reference = HTMLVisualReference(url: url) else { throw PreviewError("usage: rc-visual-preview <sha256> < visual.html") }
                let data = try FileHandle.standardInput.readToEnd() ?? Data()
                let report = try await PreviewRun(reference: reference, html: try reference.verify(data)).report()
                FileHandle.standardOutput.write(report)
                exit(0)
            } catch {
                FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
                exit(1)
            }
        }
        NSApplication.shared.run()
    }
}

struct PreviewError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

struct Problem: Codable, Hashable {
    let kind: String
    let message: String
    let location: String?
}

private struct Report: Encodable {
    let image: String
    let width: Int
    let heights: [Int]
    let capturedHeight: Int
    let contentWidth: Int
    let visible: Bool
    let loaded: Bool
    let problems: [Problem]
}

private struct Render {
    let pdf: Data
    let backdrop: CGColor
    let captured: Double
    let height: Double
    let contentWidth: Double
    let visible: Bool
    let loaded: Bool
    let problems: [Problem]
}

@MainActor
private final class ProblemRecorder: NSObject, WKScriptMessageHandler {
    private(set) var problems: [Problem] = []

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard problems.count < 40, let body = message.body as? [String: Any],
              let kind = body["kind"] as? String, let text = body["message"] as? String else { return }
        problems.append(Problem(kind: kind, message: text, location: body["location"] as? String))
    }
}

@MainActor
private struct PreviewRun {
    let reference: HTMLVisualReference
    let html: String
    private static let width = 360.0
    private static let gap = 12.0
    private static let longestEdge = 1568.0
    private static let maximumCapturedHeight = 2000.0

    func report() async throws -> Data {
        async let light = render(Self.light)
        async let dark = render(Self.dark)
        let renders = try await [light, dark]
        var seen = Set<Problem>()
        let report = Report(image: try Self.jpeg(Self.compose(renders)).base64EncodedString(), width: Int(Self.width),
            heights: renders.map { Int($0.height.rounded(.up)) },
            capturedHeight: Int(renders.map(\.captured).max() ?? 0),
            contentWidth: Int(renders.map(\.contentWidth).max() ?? 0), visible: renders.allSatisfy(\.visible),
            loaded: renders.allSatisfy(\.loaded),
            problems: renders.flatMap(\.problems).filter { seen.insert($0).inserted }.prefix(12).map(\.self))
        return try JSONEncoder().encode(report)
    }

    private func render(_ theme: (value: HTMLVisualTheme, backdrop: CGColor)) async throws -> Render {
        let recorder = ProblemRecorder()
        let page = try await HTMLVisualWebContent().make(reference: reference, theme: theme.value,
            onEvent: { _ in }, open: { _ in }) { controller in
            controller.add(recorder, contentWorld: .page, name: "rcPreview")
            controller.addUserScript(WKUserScript(source: Self.problemScript, injectionTime: .atDocumentStart,
                forMainFrameOnly: true, in: .page))
        }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: Self.width, height: 800),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.hasShadow = false
        window.collectionBehavior = [.transient, .ignoresCycle]
        window.contentView = NSHostingView(rootView: WebView(page).webViewContentBackground(.hidden))
        window.orderFrontRegardless()
        defer {
            window.orderOut(nil)
            page.stopLoading()
        }
        try await HTMLVisualWebContent.load(page, html: html, reference: reference)
        guard let geometry = try await page.callJavaScript(Self.settleScript, contentWorld: .defaultClient) as? [Any],
              geometry.count == 4, let height = geometry[0] as? Double, let contentWidth = geometry[1] as? Double,
              let visible = geometry[2] as? Bool, let loaded = geometry[3] as? Bool
        else { throw PreviewError("the page reported no geometry") }
        let captured = min(max(1, height.rounded(.up)), Self.maximumCapturedHeight)
        window.setContentSize(CGSize(width: Self.width, height: captured))
        _ = try await page.callJavaScript(Self.frameScript, contentWorld: .defaultClient)
        let pdf = try await page.exported(as: .pdf(region: .rect(CGRect(x: 0, y: 0, width: Self.width, height: captured)),
            allowTransparentBackground: true))
        return Render(pdf: pdf, backdrop: theme.backdrop, captured: captured, height: height,
            contentWidth: contentWidth, visible: visible, loaded: loaded, problems: recorder.problems)
    }

    private static func compose(_ renders: [Render]) throws -> CGImage {
        let height = renders.map(\.captured).max() ?? 1
        let width = Double(renders.count) * Self.width + gap * Double(renders.count - 1)
        let scale = min(1, longestEdge / max(width, height))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: Int((width * scale).rounded(.up)),
                  height: Int((height * scale).rounded(.up)), bitsPerComponent: 8, bytesPerRow: 0, space: space,
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw PreviewError("the preview could not be composed") }
        context.scaleBy(x: scale, y: scale)
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        for (index, render) in renders.enumerated() {
            guard let provider = CGDataProvider(data: render.pdf as CFData),
                  let page = CGPDFDocument(provider)?.page(at: 1) else { throw PreviewError("the page exported no PDF") }
            let x = Double(index) * (Self.width + gap)
            context.setFillColor(render.backdrop)
            context.fill(CGRect(x: x, y: 0, width: Self.width, height: height))
            let box = page.getBoxRect(.mediaBox)
            context.saveGState()
            context.clip(to: CGRect(x: x, y: 0, width: Self.width, height: height))
            context.translateBy(x: x, y: height - render.captured)
            context.scaleBy(x: Self.width / box.width, y: render.captured / box.height)
            context.translateBy(x: -box.minX, y: -box.minY)
            context.drawPDFPage(page)
            context.restoreGState()
        }
        guard let image = context.makeImage() else { throw PreviewError("the preview could not be composed") }
        return image
    }

    private static func jpeg(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw PreviewError("the preview could not be encoded")
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw PreviewError("the preview could not be encoded") }
        return data as Data
    }

    private static let light = (value: HTMLVisualTheme(fontSize: 17, text: "rgba(0,0,0,1.0000)",
        secondaryText: "rgba(60,60,67,0.6000)", background: "rgba(255,255,255,1.0000)",
        surface: "rgba(242,242,247,1.0000)", accent: "rgba(219,89,46,1.0000)", isDark: false),
        backdrop: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
    private static let dark = (value: HTMLVisualTheme(fontSize: 17, text: "rgba(255,255,255,1.0000)",
        secondaryText: "rgba(235,235,245,0.6000)", background: "rgba(0,0,0,1.0000)",
        surface: "rgba(28,28,30,1.0000)", accent: "rgba(219,89,46,1.0000)", isDark: true),
        backdrop: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1))

    private static let problemScript = """
        (() => {
            const post = value => window.webkit.messageHandlers.rcPreview.postMessage(value);
            const text = value => String(value ?? '').slice(0, 400);
            addEventListener('error', event => {
                if (event instanceof ErrorEvent) {
                    const file = event.filename && event.filename !== location.href ? event.filename + ':' : 'line ';
                    post({kind: 'error', message: text(event.message), location: text(file + event.lineno + ':' + event.colno)});
                } else if (event.target instanceof Element) {
                    const target = event.target;
                    post({kind: 'resource', message: text(target.localName + ' ' + (target.currentSrc || target.src || target.href || ''))});
                }
            }, true);
            addEventListener('unhandledrejection', event => post({kind: 'rejection', message: text(event.reason)}));
            document.addEventListener('securitypolicyviolation', event => post({kind: 'blocked', message: text(event.effectiveDirective + ' ' + event.blockedURI)}));
            const original = console.error;
            console.error = (...values) => {
                post({kind: 'console', message: text(values.join(' '))});
                return original.apply(console, values);
            };
        })();
        """

    private static let settleScript = """
        if (document.readyState !== 'complete') await Promise.race([
            new Promise(resolve => addEventListener('load', resolve, {once: true})),
            new Promise(resolve => setTimeout(resolve, 4000))]);
        await Promise.race([document.fonts.ready, new Promise(resolve => setTimeout(resolve, 1500))]);
        await new Promise(resolve => {
            let quiet;
            const finish = () => { observer.disconnect(); clearTimeout(quiet); clearTimeout(limit); resolve(); };
            const observer = new MutationObserver(() => { clearTimeout(quiet); quiet = setTimeout(finish, 300); });
            observer.observe(document, {subtree: true, childList: true, attributes: true, characterData: true});
            quiet = setTimeout(finish, 300);
            const limit = setTimeout(finish, 2500);
        });
        const root = document.documentElement;
        return [root.getBoundingClientRect().height, root.scrollWidth, document.visibilityState === 'visible',
            document.readyState === 'complete'];
        """

    private static let frameScript = """
        await Promise.race([new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))),
            new Promise(resolve => setTimeout(resolve, 200))]);
        """
}
