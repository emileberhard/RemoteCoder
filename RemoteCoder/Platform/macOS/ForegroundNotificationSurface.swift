#if os(macOS)
extension CompletionNotificationCenter {
    func presentInForeground(_ delivery: ForegroundNotificationPresentation.Delivery) -> ForegroundNotificationPresentation.Disposition {
        .system
    }
}
#endif
