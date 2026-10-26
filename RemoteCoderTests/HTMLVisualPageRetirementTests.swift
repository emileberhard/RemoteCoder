import Foundation
import Testing
import WebKit
@testable import RemoteCoder

@Suite(.serialized)
@MainActor
struct HTMLVisualPageRetirementTests {
    private let webContent = HTMLVisualWebContent()
    private let theme = HTMLVisualTheme(fontSize: 17, text: "black", secondaryText: "gray",
        background: "white", surface: "white", accent: "blue", isDark: false)

    @Test
    func cancelledCreationReleasesBridgeCapturesWhileControllerSurvives() async throws {
        let reference = try reference()
        var controller: WKUserContentController?
        weak var retained: OpenCapture?
        do {
            let capture = OpenCapture()
            retained = capture
            let creation = Task {
                try await webContent.make(reference: reference, theme: theme, onEvent: { _ in },
                    open: { _ in capture.count += 1 }, onRegistration: { controller = $0 })
            }
            creation.cancel()
            await #expect(throws: CancellationError.self) { try await creation.value }
        }
        #expect(controller != nil)
        withExtendedLifetime(controller) { #expect(retained == nil) }
    }

    @Test
    func retirementReleasesBridgeCapturesWhileControllerSurvives() async throws {
        let instance = HTMLVisualInstance(surface: .inline)
        var controller: WKUserContentController?
        weak var retained: OpenCapture?
        do {
            let capture = OpenCapture()
            retained = capture
            instance.page = try await webContent.make(reference: reference(), theme: theme, onEvent: { _ in },
                open: { _ in capture.count += 1 }, onRegistration: {
                    controller = $0
                    instance.userContentController = $0
                })
            instance.retirePage()
        }
        #expect(controller != nil)
        withExtendedLifetime(controller) { #expect(retained == nil) }
    }

    private func reference() throws -> HTMLVisualReference {
        let url = try #require(URL(string: "rc-visual:" + String(repeating: "a", count: 64)))
        return try #require(HTMLVisualReference(url: url))
    }
}

@MainActor
private final class OpenCapture {
    var count = 0
}
