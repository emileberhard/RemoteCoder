import SwiftUI

struct PendingComposerImportTile: View {
    @InterfaceScaledMetric(relativeTo: .caption) private var height = ComposerMetrics.attachmentTileHeight

    var body: some View {
        ProgressView()
            .frame(width: height, height: height)
            .background(.background.secondary, in: .rect(cornerRadius: 12))
            .accessibilityLabel("Preparing attachment")
    }
}
