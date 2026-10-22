import Observation

@MainActor
@Observable
final class RenderedMessageEntry<Presentation> {
    private(set) var rendered: Presentation?
    private(set) var isPresent = false
    @ObservationIgnored var sourceBytes = 0

    func replace(with presentation: Presentation?) {
        let present = presentation != nil
        if isPresent != present { isPresent = present }
        rendered = presentation
    }
}
