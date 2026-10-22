#if os(macOS)
import SwiftUI

struct QuickEntrySettingsToggle: View {
    @Environment(QuickEntry.self) private var quickEntry

    var body: some View {
        @Bindable var quickEntry = quickEntry
        Toggle("Quick entry with \(QuickEntry.shortcutLabel)", isOn: $quickEntry.isEnabled)
        if let failure = quickEntry.registrationFailure {
            Text(failure)
                .scaledFont(.callout)
                .foregroundStyle(.secondary)
        }
    }
}
#endif
