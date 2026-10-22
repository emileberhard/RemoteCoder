enum ResumeOutcome {
    case loaded
    case failed(any Error)
    case superseded
}
