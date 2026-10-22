import SwiftUI

struct AccountResetCount: View {
    let resets: AccountResets?
    var isStale = false

    var body: some View {
        if let count = resets?.knownCount {
            Label(count == 1 ? "1 reset" : "\(count) resets", systemImage: "arrow.counterclockwise.circle")
                .scaledFont(.caption.weight(.medium))
                .foregroundStyle(isStale ? Color.secondary : Color.accentColor)
                .accessibilityLabel("\(count) usage resets\(isStale ? ", last known" : "")")
        }
    }
}

struct AccountResetOffersView: View {
    let resets: AccountResets?
    let accountName: String
    let redemption: ResetRedemptionState?
    let isEnabled: Bool
    let isStale: Bool
    let error: String?
    let onUse: (AccountResetOffer) -> Void
    let onRetry: () -> Void
    let onForget: () -> Void
    @State private var confirmation: AccountResetOffer?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            AccountResetCount(resets: resets, isStale: isStale)
            if let error { Text(error).scaledFont(.footnote).foregroundStyle(.secondary) }
            if let redemption {
                AccountResetAttemptView(accountName: accountName, redemption: redemption,
                    isEnabled: isEnabled, onRetry: onRetry, onForget: onForget)
            }
            if let resets, resets.state == .known {
                if let offers = resets.offers {
                    if offers.isEmpty, resets.knownCount != 0 {
                        Text("No reset offers reported").scaledFont(.subheadline).foregroundStyle(.secondary)
                    }
                    ForEach(offers) { offer in
                        offerRow(offer)
                    }
                } else {
                    Text("Reset details unavailable").scaledFont(.subheadline).foregroundStyle(.secondary)
                }
            } else {
                Text(resets == nil ? "Resets not loaded" : AccountResetMessages.unavailable(code: resets?.error, accountName: accountName))
                    .scaledFont(.subheadline).foregroundStyle(.secondary)
            }
        }
        .confirmationDialog("Use reset?", isPresented: Binding(
            get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }
        ), titleVisibility: .visible, presenting: confirmation) { choice in
            Button("Use reset") {
                HapticService.shared.play(.commit)
                onUse(choice)
            }
            Button("Cancel", role: .cancel) {}
        } message: { choice in
            Text("Use “\(choice.displayTitle)” for \(accountName)?")
        }
    }

    private func offerRow(_ offer: AccountResetOffer) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                offerTitle(offer)
                Spacer(minLength: 8)
                useButton(offer)
            }
            VStack(alignment: .leading, spacing: 8) {
                offerTitle(offer)
                useButton(offer)
            }
        }
    }

    private func offerTitle(_ offer: AccountResetOffer) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(offer.displayTitle).scaledFont(.subheadline.weight(.medium))
            if offer.remaining != 1 {
                Text("\(offer.remaining) left").scaledFont(.caption).foregroundStyle(.secondary)
            }
            Text(offer.expiresAt.map {
                let date = Date(timeIntervalSince1970: $0)
                return "\(date > .now ? "Expires" : "Expired") \(date.formatted(date: .abbreviated, time: .shortened))"
            } ?? "Does not expire")
            .scaledFont(.caption).foregroundStyle(.secondary)
            if offer.usableNow == false {
                Text("Unavailable now")
                    .scaledFont(.caption).foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func useButton(_ offer: AccountResetOffer) -> some View {
        Button("Use") { confirmation = offer }
            .buttonStyle(.bordered)
            .disabled(!isEnabled || isStale || redemption?.isUnresolved == true || !offer.canUse(now: .now))
            .accessibilityLabel("Use \(offer.displayTitle) for \(accountName)")
            .accessibilityIdentifier("use-reset-\(offer.id)")
    }
}

struct AccountResetAttemptView: View {
    let accountName: String
    let redemption: ResetRedemptionState
    let isEnabled: Bool
    let onRetry: () -> Void
    let onForget: () -> Void
    @State private var confirmation: Confirmation?

    private enum Confirmation { case retry, forget }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if redemption.isSubmitting {
                ProgressView("Using reset…")
            } else if let message = redemption.message {
                Text(message).scaledFont(.subheadline).foregroundStyle(.secondary)
            }
            if let attempt = redemption.attempt {
                if redemption.canRetry {
                    Button("Retry \(attempt.title)") { confirmation = .retry }.disabled(!isEnabled)
                }
                if redemption.canForget {
                    Button("Forget attempt", role: .destructive) { confirmation = .forget }.disabled(!isEnabled)
                }
            }
        }
        .confirmationDialog(confirmation == .forget ? "Forget reset attempt?" : "Use reset?", isPresented: Binding(
            get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }
        ), titleVisibility: .visible, presenting: confirmation) { choice in
            if choice == .forget {
                Button("Forget attempt", role: .destructive, action: onForget)
            } else {
                Button("Use reset") {
                    HapticService.shared.play(.commit)
                    onRetry()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { choice in
            if choice == .forget {
                Text("Forget “\(redemption.attempt?.title ?? "Usage reset")” for \(accountName)? Its outcome will stay unknown.")
            } else {
                Text("Use “\(redemption.attempt?.title ?? "Usage reset")” for \(accountName)?")
            }
        }
    }
}

struct OrphanedAccountResetsView: View {
    let redemptions: AccountResetRedemptions
    let accountIDs: Set<String>
    let onRetry: (String) -> Void

    var body: some View {
        let orphanIDs = redemptions.states.keys.filter { !accountIDs.contains($0) && redemptions.states[$0]?.isUnresolved == true }.sorted()
        if !orphanIDs.isEmpty {
            Section("Unconfirmed resets") {
                ForEach(orphanIDs, id: \.self) { id in
                    if let state = redemptions.states[id], let attempt = state.attempt {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(attempt.accountName).scaledFont(.headline)
                            Text(attempt.title).scaledFont(.subheadline)
                            AccountResetAttemptView(accountName: attempt.accountName, redemption: state,
                                isEnabled: redemptions.isRestored, onRetry: { onRetry(id) },
                                onForget: { Task { await redemptions.forget(accountID: id) } })
                        }
                    }
                }
            }
        }
    }
}
