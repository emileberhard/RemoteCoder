import SwiftUI
import UIKit

struct WorkingSymbol: View {
    let systemName: String
    let tint: Color
    let isAnimating: Bool

    var body: some View {
        if isAnimating {
            IterativeSymbol(systemName: systemName, tint: tint)
                .fixedSize()
        } else {
            Image(systemName: systemName)
                .foregroundStyle(tint)
        }
    }
}

private struct IterativeSymbol: UIViewRepresentable {
    let systemName: String
    let tint: Color

    func makeUIView(context: Context) -> IterativeSymbolView {
        IterativeSymbolView()
    }

    func updateUIView(_ view: IterativeSymbolView, context: Context) {
        let font = (context.environment.font ?? .body).resolve(in: context.environment.fontResolutionContext)
        view.tintColor = UIColor(cgColor: tint.resolve(in: context.environment).cgColor)
        view.show(systemName, configuration: UIImage.SymbolConfiguration(pointSize: font.pointSize, weight: UIImage.SymbolWeight(font.weight)))
    }
}

private final class IterativeSymbolView: UIImageView {
    private var shownName: String?

    init() {
        super.init(frame: .zero)
        isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func show(_ name: String, configuration: UIImage.SymbolConfiguration) {
        guard name != shownName || configuration != preferredSymbolConfiguration else { return }
        shownName = name
        image = UIImage(systemName: name)
        preferredSymbolConfiguration = configuration
        restartEffect()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        restartEffect()
    }

    private func restartEffect() {
        removeAllSymbolEffects()
        guard window != nil else { return }
        addSymbolEffect(.variableColor.iterative, options: .repeating.speed(0.7))
    }
}

private extension UIImage.SymbolWeight {
    init(_ weight: Font.Weight) {
        self = switch weight {
        case .ultraLight: .ultraLight
        case .thin: .thin
        case .light: .light
        case .medium: .medium
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        case .black: .black
        default: .regular
        }
    }
}
