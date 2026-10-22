import SwiftUI

struct WorkingDirectoryHeader: View {
    let path: String?
    let remoteHomePath: String?
    let hostID: UUID
    let hostName: String
    let favorites: () -> [FavoriteFolder]
    let contextID: UUID
    let onActivate: () -> Void
    let onSelectFavorite: (FavoriteFolder) -> Void
    @State private var owner = UUID()
    @State private var isPressed = false
    @State private var heldSession: DirectoryQuickSwitchPresentation.Session?
    @InterfaceScaledMetric(relativeTo: .body) private var rowHeight = DirectoryQuickSwitchLayout.minimumRowHeight
    @Environment(DirectoryQuickSwitchPresentation.self) private var picker
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        ZStack {
            VStack(spacing: 1) {
                HStack(spacing: 5) {
                    Text(displayPath == "~" ? "Home" : displayPath)
                        .scaledFont(.subheadline.weight(.semibold))
                        .lineLimit(1).truncationMode(.head)
                    Image(systemName: "chevron.down")
                        .scaledFont(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                }
                Text(hostName).scaledFont(.caption2).lineLimit(1)
            }
            .foregroundStyle(.primary)
            .padding(.horizontal, 18)
            .frame(minHeight: 44)
            .contentShape(.capsule)
            .appGlass(.standard, in: .capsule)
            .scaleEffect(isPressed && !reduceMotion ? 0.96 : 1)
            .opacity(isPressed ? 0.9 : 1)
            .animation(reduceMotion ? nil : AppControlMotion.press(isPressed), value: isPressed)
            .opacity(picker.presentedSession?.owner == owner ? 0 : 1)
            .accessibilityHidden(true)
        }
        .overlay {
            TapHoldButton(label: "Running on \(hostName)", value: "Working folder: \(displayPath)",
                          hint: "Tap to choose a folder or host. Hold, slide to a favorite, then release.",
                          identifier: "active-host", accessibilityActions: [],
                          onPress: pressChanged, onContactEnded: finishContact, onTap: onActivate, onHold: holdChanged)
                .accessibilityShowsLargeContentViewer {
                    Label(displayPath == "~" ? "Home" : displayPath, systemImage: "folder")
                }
        }
        .onChange(of: hostID) { cancel() }
        .onChange(of: contextID) { cancel() }
        .onChange(of: path) { cancel() }
        .onChange(of: rowHeight) { cancel() }
        .onChange(of: layoutDirection) { cancel() }
        .onChange(of: scenePhase) { if scenePhase != .active { cancel() } }
        .onChange(of: isEnabled) { if !isEnabled { cancel() } }
        .onDisappear { cancel() }
    }

    private func pressChanged(_ pressed: Bool) {
        isPressed = pressed
        guard pressed, isEnabled, scenePhase == .active else { return }
        HapticService.shared.beginInteraction(owner: owner)
        HapticService.shared.playInteraction(.buttonPress, owner: owner)
    }

    private func holdChanged(_ phase: TapHoldPhase, _ location: CGPoint, _ source: CGRect) {
        switch phase {
        case .began:
            guard isEnabled, scenePhase == .active else { return }
            heldSession = picker.present(owner: owner, hostID: hostID, favorites: favorites(),
                currentPath: path, source: source, rowHeight: rowHeight,
                columnCount: dynamicTypeSize.favoriteColumnCount, isRightToLeft: layoutDirection == .rightToLeft) { action in
                    switch action {
                    case .favorite(let favorite): onSelectFavorite(favorite)
                    case .browse: onActivate()
                    case .copyPath: if let path { HapticService.shared.copy(path) }
                    }
                }
            // Very small viewports still have the accessible full browser.
            if let heldSession { picker.update(heldSession, at: location) }
            else { onActivate() }
        case .changed:
            if let heldSession { picker.update(heldSession, at: location) }
        case .ended:
            if let heldSession { picker.finish(heldSession, at: location) }
            heldSession = nil
        case .cancelled:
            cancel()
        }
    }

    private func finishContact() {
        if heldSession == nil { HapticService.shared.cancelInteraction(owner: owner) }
    }

    private func cancel() {
        picker.dismiss(owner: owner)
        heldSession = nil
        isPressed = false
        HapticService.shared.cancelInteraction(owner: owner)
    }

    private var displayPath: String {
        guard let path else { return "Choose Folder" }
        return WorkingDirectoryPathFormatter.displayPath(path, remoteHomePath: remoteHomePath)
    }
}
