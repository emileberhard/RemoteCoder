import SwiftUI

extension View {
    @ViewBuilder
    func transcriptPerfFeature<Modified: View>(_ name: String, @ViewBuilder _ feature: (Self) -> Modified) -> some View {
        #if RC_PERF_HARNESS
        if PerfBuild.isDisabled(name) {
            self
        } else {
            feature(self)
        }
        #else
        feature(self)
        #endif
    }

    @ViewBuilder
    func transcriptHorizontalScroll() -> some View {
        #if os(macOS) && RC_PERF_HARNESS
        if PerfBuild.isDisabled("horizontalScrolls") {
            fixedSize(horizontal: true, vertical: false)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .clipped()
        } else {
            ScrollView(.horizontal) { self }
                .transcriptHorizontalScrollIndicators()
        }
        #else
        ScrollView(.horizontal) { self }
            .transcriptHorizontalScrollIndicators()
        #endif
    }
}
