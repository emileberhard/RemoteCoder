import SwiftUI

@MainActor @Observable
final class ShareProgress {
    enum Phase: Equatable {
        case adding(completed: Int, total: Int)
        case partial(failed: Int, total: Int)
        case failed(String)
    }

    var phase = Phase.adding(completed: 0, total: 0)
}

struct ShareView: View {
    let progress: ShareProgress
    let cancel: () -> Void
    let addReadable: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            switch progress.phase {
            case .adding(let completed, let total):
                ProgressView(value: Double(completed), total: Double(max(total, 1))) {
                } currentValueLabel: {
                    Text("\(completed) of \(total)")
                }
                Button("Cancel", role: .cancel, action: cancel)
            case .partial(let failed, let total):
                Text("\(failed) of \(total) items couldn't be read.")
                HStack {
                    Button("Cancel", role: .cancel, action: cancel)
                    Button("Add \(total - failed)", action: addReadable)
                        .buttonStyle(.borderedProminent)
                }
            case .failed(let message):
                Text(message)
                Button("Done", role: .cancel, action: cancel)
            }
        }
        .multilineTextAlignment(.center)
        .padding(32)
        .frame(maxWidth: 420, maxHeight: .infinity)
        .frame(maxWidth: .infinity)
    }
}
