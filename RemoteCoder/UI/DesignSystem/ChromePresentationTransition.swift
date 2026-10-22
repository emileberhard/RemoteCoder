import SwiftUI

extension View {
    func chromeTransitionSource(_ id: String) -> some View {
        modifier(ChromeTransitionSource(id: id))
    }

    func chromeZoomTransition(_ id: String) -> some View {
        modifier(ChromeZoomTransition(id: id))
    }
}

private struct ChromeTransitionSource: ViewModifier {
    let id: String
    @Environment(\.chromeTransitionNamespace) private var namespace

    func body(content: Content) -> some View {
        if let namespace {
            content.matchedTransitionSource(id: id, in: namespace)
        } else {
            content
        }
    }
}

private struct ChromeZoomTransition: ViewModifier {
    let id: String
    @Environment(\.chromeTransitionNamespace) private var namespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        #if os(iOS)
        if let namespace, !reduceMotion {
            content.navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            content
        }
        #else
        content
        #endif
    }
}
