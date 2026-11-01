import SwiftUI

extension View {
    func shimmer(isActive: Bool) -> some View {
        modifier(ShimmerEffect(isActive: isActive))
    }
}
