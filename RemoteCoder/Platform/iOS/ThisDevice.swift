import UIKit

enum ThisDevice {
    @MainActor static var noun: String { UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "phone" }
}
