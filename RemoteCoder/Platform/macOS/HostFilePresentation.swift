#if os(macOS)
import SwiftUI
import QuickLook

extension HostFileOpener {
    static func quickLookCanPreview(_ url: URL) -> Bool { true }
}

struct HostFilePresentation: ViewModifier {
    @Bindable var opener: HostFileOpener
    let isBlocked: Bool
    let scope: UUID?

    func body(content: Content) -> some View {
        let shows = !isBlocked && opener.presents(in: scope)
        return content
            .quickLookPreview(Binding(
                get: { shows ? opener.quickLook?.url : nil },
                set: { if $0 == nil { opener.presentationDismissed() } }
            ))
            .sheet(item: Binding(get: { shows ? opener.sheet : nil }, set: { opener.sheet = $0 }),
                   onDismiss: opener.presentationDismissed) { item in
                HostFileSheetView(item: item, opener: opener)
                    .transcriptCodeExportPresentation()
                    .frame(minWidth: 560, minHeight: 520)
            }
            .onChange(of: isBlocked, initial: true) { _, blocked in
                if blocked, opener.presents(in: scope) { opener.suspendPresentation() }
            }
    }
}
#endif
