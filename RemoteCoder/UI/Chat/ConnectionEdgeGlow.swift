import SwiftUI

struct ConnectionEdgeGlow: View {
    var connectivity: GatewayConnectivity
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var opacity: Double {
        connectivity == .disconnected ? 0.72 : 0.58
    }

    private var glowColor: Color {
        switch connectivity {
        case .disconnected: Color(red: 0.9, green: 0.2, blue: 0.2)
        case .restarting: Color(white: 0.6)
        case .connected(.relay): Color(red: 0.35, green: 0.6, blue: 1)
        case .connected(.lan), .connected(.configured): Color(red: 0.3, green: 0.85, blue: 0.45)
        }
    }

    var body: some View {
        VStack {
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(glowColor)
                    .opacity(opacity)
                    .frame(width: geo.size.width * 0.38, height: 3)
                    .frame(maxWidth: .infinity)
            }
            .frame(height: 3)
            .padding(.top, 6)
            Spacer()
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: connectivity)
    }
}
