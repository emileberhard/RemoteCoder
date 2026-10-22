#if os(macOS)
import SwiftUI

enum SidebarPresentation {
    static let projectRowLimit: Int? = nil

    static func isPersistent(sizeClass: UserInterfaceSizeClass?) -> Bool { true }
}
#endif
