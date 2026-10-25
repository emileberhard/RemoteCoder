struct TargetPresentation: Equatable, Sendable {
    var presented = false
    var key = false
    var drawerOpen = false
    var drawerOverlaysTranscript = true

    var coversTranscript: Bool { drawerOpen && drawerOverlaysTranscript }
}
