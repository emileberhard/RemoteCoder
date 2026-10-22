import SwiftUI

/// Page-control style dots for a multi-question card: tap to move, no scrubbing.
/// Hidden from assistive technology; the header's value carries the same information.
struct QuestionProgressDots: View {
    struct Dot: Identifiable {
        let id: Int
        let isAnswered: Bool
    }

    let dots: [Dot]
    let current: Int
    let onSelect: (Int) -> Void

    @Environment(AppThemeStore.self) private var themeStore

    init(flow: QuestionFlow, onSelect: @escaping (Int) -> Void) {
        // Deferred SwiftUI children must not index a subsequently shortened flow.
        dots = flow.indices.map { Dot(id: $0, isAnswered: flow.isAnswered($0)) }
        current = flow.current
        self.onSelect = onSelect
    }

    var body: some View {
        HStack(spacing: 8) {
            ForEach(Array(dots.enumerated()), id: \.element.id) { position, dot in
                Button {
                    onSelect(dot.id)
                } label: {
                    Circle()
                        .fill(dot.id == current ? AnyShapeStyle(themeStore.theme.colors.accentTint)
                              : dot.isAnswered ? AnyShapeStyle(.secondary) : AnyShapeStyle(.clear))
                        .overlay(Circle().strokeBorder(.secondary, lineWidth: dot.id == current || dot.isAnswered ? 0 : 1))
                        .frame(width: 6, height: 6)
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(maxWidth: .infinity)
        .accessibilityHidden(true)
    }
}
