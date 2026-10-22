#if os(macOS)
import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class InterfaceZoom {
    private static let scaleKey = "appearance.interfaceZoomScale"

    private(set) var level: InterfaceZoomLevel {
        didSet { defaults.set(level.scale, forKey: Self.scaleKey) }
    }
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
        level = (defaults.object(forKey: Self.scaleKey) as? Double).map(InterfaceZoomLevel.init(storedScale:))
            ?? .actualSize
    }

    func zoomIn() {
        if let next = level.zoomedIn { level = next }
    }

    func zoomOut() {
        if let next = level.zoomedOut { level = next }
    }

    func resetToActualSize() {
        level = .actualSize
    }
}

struct InterfaceZoomEnvironment: ViewModifier {
    let zoom: InterfaceZoom

    func body(content: Content) -> some View {
        content.environment(\.interfaceScale, zoom.level.scale)
    }
}

struct InterfaceZoomCommands: Commands {
    let zoom: InterfaceZoom

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Divider()
            Button("Actual Size") { zoom.resetToActualSize() }
                .keyboardShortcut("0")
                .disabled(zoom.level.isActualSize)
            Button("Zoom In") { zoom.zoomIn() }
                .keyboardShortcut("+")
                .disabled(zoom.level.zoomedIn == nil)
            Button("Zoom Out") { zoom.zoomOut() }
                .keyboardShortcut("-")
                .disabled(zoom.level.zoomedOut == nil)
        }
    }
}
#endif
