extension CompletionNotificationCenter {
    func presentInForeground(_ delivery: ForegroundNotificationPresentation.Delivery) -> ForegroundNotificationPresentation.Disposition {
        present(delivery)
        return .inApp
    }
}
