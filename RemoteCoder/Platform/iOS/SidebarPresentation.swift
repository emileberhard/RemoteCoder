import SwiftUI
import UIKit

enum SidebarPresentation {
    static let projectRowLimit: Int? = 5

    @MainActor
    static func isPersistent(sizeClass: UserInterfaceSizeClass?) -> Bool {
        UIDevice.current.userInterfaceIdiom == .pad && sizeClass == .regular
    }
}
