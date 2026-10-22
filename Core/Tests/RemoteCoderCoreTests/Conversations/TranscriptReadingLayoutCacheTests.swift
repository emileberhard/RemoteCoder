import Foundation
import Testing
@testable import RemoteCoderCore

struct TranscriptReadingLayoutCacheTests {
    @Test func nativeSamplesComputeLayoutIdentityOncePerEnvironmentOrColumnChange() {
        var cache = TranscriptReadingLayoutCache<String>()
        var computations = 0
        func sample(environment: String, width: CGFloat) -> TranscriptReadingLayout {
            cache.layout(environment: environment, columnWidth: width) {
                computations += 1
                return TranscriptReadingLayout(columnWidth: width, interfaceScale: 1, dynamicTypeSize: environment,
                    localeIdentifier: "en", isRightToLeft: false)
            }
        }
        for _ in 0..<20 { #expect(sample(environment: "large", width: 500).columnWidth == 500) }
        #expect(computations == 1)
        for _ in 0..<20 { #expect(sample(environment: "large", width: 600).columnWidth == 600) }
        #expect(computations == 2)
        for _ in 0..<20 { #expect(sample(environment: "accessibility", width: 600).dynamicTypeSize == "accessibility") }
        #expect(computations == 3)
        #expect(sample(environment: "large", width: 500).dynamicTypeSize == "large")
        #expect(computations == 4)
    }
}
