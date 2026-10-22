import Foundation
import UIKit

extension DiagnosticsOutbox {
    /// iOS reports a generic model name, so the vendor id keeps two phones apart.
    /// `UIDevice` is main-actor isolated.
    static let shared = DiagnosticsOutbox(deviceLabel: {
        await MainActor.run {
            let model = UIDevice.current.model.replacingOccurrences(of: " ", with: "-")
            let vendor = UIDevice.current.identifierForVendor?
                .uuidString.prefix(8).lowercased() ?? "unknown"
            return "\(model)-\(vendor)"
        }
    })
}
