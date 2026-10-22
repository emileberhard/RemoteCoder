import Foundation
import SwiftUI

extension View {
    func directoryQuickSwitchOverlay(isEnabled: Bool) -> some View {
        modifier(DirectoryQuickSwitchHost(isEnabled: isEnabled))
    }
}

private struct DirectoryQuickSwitchHost: ViewModifier {
    let isEnabled: Bool
    @State private var picker = DirectoryQuickSwitchPresentation()
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .environment(picker)
            .overlay {
                GeometryReader { geometry in
                    if let session = picker.presentedSession {
                        DirectoryQuickSwitchLayer(picker: picker, session: session,
                                                  origin: geometry.frame(in: .global).origin)
                            .id(session.id)
                    }
                }
                .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { picker.updateViewport($0) }
                // A recognized hold belongs to the header, not a new overlay recognizer.
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .onChange(of: isEnabled) { if !isEnabled { picker.dismissImmediately() } }
            .onChange(of: scenePhase) { if scenePhase != .active { picker.dismissImmediately() } }
            .onDisappear { picker.dismissImmediately() }
    }
}

private struct DirectoryQuickSwitchLayer: View {
    let picker: DirectoryQuickSwitchPresentation
    let session: DirectoryQuickSwitchPresentation.Session
    let origin: CGPoint
    @State private var expanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(expanded ? (colorScheme == .dark ? 0.24 : 0.08) : 0)
                .ignoresSafeArea()
            DirectoryQuickSwitchMorph(picker: picker, session: session, origin: origin,
                                      progress: expanded ? 1 : 0, reduceMotion: reduceMotion)
        }
        .onChange(of: picker.session?.id, initial: true) {
            if picker.session === session {
                withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .spring(duration: 0.32, bounce: 0.08)) {
                    expanded = true
                }
            } else {
                withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .smooth(duration: 0.22),
                              completionCriteria: .removed) {
                    expanded = false
                } completion: {
                    picker.completeDismissal(of: session)
                }
            }
        }
    }
}

/// Animate the shell, not a screenshot of its labels: text stays full-sized as it unfolds.
private struct DirectoryQuickSwitchMorph: View, Animatable {
    let picker: DirectoryQuickSwitchPresentation
    let session: DirectoryQuickSwitchPresentation.Session
    let origin: CGPoint
    var progress: CGFloat
    let reduceMotion: Bool

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let amount = reduceMotion ? 1 : min(max(progress, 0), 1)
        let source = session.source
        let target = session.layout.frame
        let width = source.width + (target.width - source.width) * amount
        let height = source.height + (target.height - source.height) * amount
        let radius = source.height / 2 + (24 - source.height / 2) * amount
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        DirectoryQuickSwitchPanel(picker: picker, session: session)
            .frame(width: target.width, height: target.height, alignment: .top)
            .opacity(reduceMotion ? 1 : max(0, min(1, (amount - 0.25) / 0.55)))
            .frame(width: width, height: height, alignment: .top)
            .clipShape(shape)
            .containerShape(shape)
            .appGlass(.standard, in: shape)
            .position(x: source.midX + (target.midX - source.midX) * amount - origin.x,
                      y: source.midY + (target.midY - source.midY) * amount - origin.y)
            .opacity(reduceMotion ? progress : 1)
            .transaction { $0.animation = nil }
    }
}

private struct DirectoryQuickSwitchPanel: View {
    let picker: DirectoryQuickSwitchPresentation
    let session: DirectoryQuickSwitchPresentation.Session
    @State private var scrollPosition = ScrollPosition(y: 0)
    @Namespace private var highlight
    @Environment(AppThemeStore.self) private var themeStore
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            heading
                .frame(height: session.layout.headerHeight)
            favorites
                .frame(height: session.layout.rows.height)
            HStack(spacing: 0) {
                footerItem("Browse", symbol: "folder.badge.gearshape", action: .browse)
                footerItem("Copy path", symbol: "doc.on.doc", action: .copyPath)
                    .opacity(session.currentPath == nil ? 0.3 : 1)
            }
            .frame(height: session.layout.footer.height)
            .padding(.bottom, 8)
        }
        .padding(.horizontal, 8)
        .animation(reduceMotion ? nil : .snappy(duration: 0.16), value: session.hovered)
    }

    private var heading: some View {
        HStack(spacing: 6) {
            Image(systemName: "star.fill")
                .foregroundStyle(themeStore.theme.colors.accentTint)
            Text("Favorites")
            Spacer(minLength: 0)
        }
        .scaledFont(.caption.weight(.semibold))
        .lineLimit(1)
        .padding(.horizontal, 10)
    }

    @ViewBuilder private var favorites: some View {
        if session.favorites.isEmpty {
            VStack(spacing: 4) {
                Text("No favorites yet").scaledFont(.subheadline.weight(.semibold))
                Text("Star a folder in the directory browser.").scaledFont(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let layout = session.layout
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    ForEach(Array(stride(from: 0, to: session.favorites.count, by: layout.columnCount)), id: \.self) { start in
                        HStack(spacing: 0) {
                            ForEach(session.favorites[start..<min(start + layout.columnCount, session.favorites.count)]) { favorite in
                                favoriteCell(favorite)
                                    .frame(width: layout.columnWidth, height: layout.rowHeight)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .scrollIndicators(.hidden)
            .scrollPosition($scrollPosition)
            .animation(reduceMotion ? nil : .linear(duration: 0.10), value: scrollPosition)
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, offset in
                picker.updateScrollOffset(session, to: offset)
            }
            .overlay(alignment: .top) { edgeCue("chevron.up", visible: session.scrollOffset > 1) }
            .overlay(alignment: .bottom) {
                edgeCue("chevron.down", visible: session.scrollOffset < session.maximumScrollOffset - 1)
            }
            .task(id: session.scrollDirection) {
                let direction = session.scrollDirection
                guard direction != 0 else { return }
                do {
                    // Edge dwell prevents a pass across the last row from starting a scroll.
                    try await Task.sleep(for: .milliseconds(300))
                    while !Task.isCancelled, picker.session === session, session.scrollDirection == direction {
                        withAnimation(reduceMotion ? nil : .linear(duration: 0.10)) {
                            scrollPosition.scrollTo(y: session.nextScrollOffset)
                        }
                        try await Task.sleep(for: .milliseconds(100))
                    }
                } catch { return }
            }
        }
    }

    private func favoriteCell(_ favorite: FavoriteFolder) -> some View {
        let isHighlighted = session.hovered == .favorite(favorite)
        return HStack(spacing: 6) {
            Image(systemName: isHighlighted ? "folder.fill" : "folder")
                .scaledFont(.footnote.weight(.medium))
                .foregroundStyle(isHighlighted ? themeStore.theme.colors.accentTint : .secondary)
                .frame(width: 18 * session.layout.rowHeight / DirectoryQuickSwitchLayout.minimumRowHeight)
            VStack(alignment: .leading, spacing: 0) {
                Text(favorite.title)
                    .scaledFont(.subheadline.weight(.medium))
                    .lineLimit(1).truncationMode(.middle)
                if favorite.showsHostLabel {
                    Text(favorite.hostName)
                        .scaledFont(.caption2.weight(.semibold))
                        .foregroundStyle(themeStore.theme.colors.accentTint)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 2)
            if session.isCurrent(favorite) {
                Image(systemName: "checkmark").scaledFont(.caption2.weight(.bold)).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background { selectionBackground(for: .favorite(favorite)) }
    }

    private func footerItem(_ title: String, symbol: String, action: DirectoryQuickSwitchPresentation.Action) -> some View {
        Label(title, systemImage: symbol)
            .scaledFont(.caption.weight(.medium))
            .lineLimit(1)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background { selectionBackground(for: action) }
    }

    @ViewBuilder private func selectionBackground(for action: DirectoryQuickSwitchPresentation.Action) -> some View {
        if session.hovered == action {
            ConcentricRectangle(corners: .concentric(minimum: .fixed(10)), isUniform: true)
                .fill(themeStore.theme.selectedOptionTint(for: colorScheme))
                .matchedGeometryEffect(id: "hover", in: highlight)
                .transition(.opacity)
        }
    }

    private func edgeCue(_ symbol: String, visible: Bool) -> some View {
        Image(systemName: symbol)
            .scaledFont(.caption2.weight(.bold))
            .padding(.horizontal, 10).padding(.vertical, 3)
            .background(.regularMaterial, in: .capsule)
            .opacity(visible ? 1 : 0)
    }
}
