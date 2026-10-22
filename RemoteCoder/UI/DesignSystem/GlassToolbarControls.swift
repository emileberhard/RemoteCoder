import SwiftUI

struct CompactProgressRing: View {
    let progress: Double
    let tint: Color
    let diameter: CGFloat
    private let lineWidth: CGFloat = 2.5
    @Environment(\.interfaceScale) private var scale

    private var clampedProgress: Double {
        min(1, max(0, progress))
    }

    var body: some View {
        ZStack {
            Circle()
                .inset(by: lineWidth / 2)
                .stroke(tint.opacity(0.3), lineWidth: lineWidth)

            Circle()
                .inset(by: lineWidth / 2)
                .trim(from: 0, to: clampedProgress)
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: diameter * scale, height: diameter * scale)
        .accessibilityHidden(true)
    }
}

struct GlassToolbarControl<Content: View>: View {
    private let horizontalPadding: CGFloat
    private let height: CGFloat
    private let content: Content

    init(height: CGFloat, horizontalPadding: CGFloat = 18, @ViewBuilder content: () -> Content) {
        self.height = height
        self.horizontalPadding = horizontalPadding
        self.content = content()
    }

    var body: some View {
        content
            .scaledFont(.system(size: 16, weight: .semibold))
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(.primary)
            .tint(.primary)
            .frame(minWidth: height)
            .frame(height: height)
            .padding(.horizontal, horizontalPadding)
            .contentShape(.capsule)
            .appGlass(.standard, in: .capsule, interactive: true)
    }
}

/// The icon-only glass circle at either edge of a screen header.
struct GlassCircleButton: View {
    @Environment(\.colorScheme) private var colorScheme

    let systemImage: String
    var symbolSize: CGFloat = 17
    var role: AppTheme.GlassRole = .standard
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .contentTransition(.symbolEffect(.replace))
                .scaledFont(.system(size: symbolSize, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(colorScheme == .dark ? Color.white : Color.primary)
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(ResponsiveButtonStyle(feedback: .iconPress, pressedScale: 0.96, pressedOpacity: 0.9))
        .appGlass(role, in: .circle)
        .accessibilityShowsLargeContentViewer()
    }
}
