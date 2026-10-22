#if os(macOS)
import Foundation

extension DiagnosticsOutbox {
    static let shared = DiagnosticsOutbox(deviceLabel: {
        let name = Host.current().localizedName ?? "Mac"
        return name.replacingOccurrences(of: " ", with: "-")
    })
}
#endif
