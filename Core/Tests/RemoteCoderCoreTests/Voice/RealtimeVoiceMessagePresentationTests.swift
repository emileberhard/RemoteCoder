import Foundation
import Testing

@testable import RemoteCoderCore

struct RealtimeVoiceMessagePresentationTests {
    @Test(arguments: [
        "Explain <realtime_delegation><input>Example</input></realtime_delegation>",
        "<realtime_delegation><input>Broken & input</input></realtime_delegation>",
        "<realtime_delegation><source>unknown</source><input>Example</input></realtime_delegation>",
        "<realtime_delegation><input>Keep <![CDATA[A < B]]> exactly</input></realtime_delegation>",
        "<realtime_delegation><input>   </input></realtime_delegation>",
    ])
    func malformedEnvelopesAreNotVoiceMessages(text: String) {
        #expect(RealtimeVoiceMessagePresentation.parse(text) == nil)
    }

    @Test func wellFormedEnvelopesYieldTheRequestOrTheFlushedTail() {
        if case .request(let input)? = RealtimeVoiceMessagePresentation.parse(
            "<realtime_delegation><input>Example</input></realtime_delegation>") {
            #expect(input == "Example")
        } else {
            Issue.record("Expected a voice request")
        }
        if case .transcriptTail(let delta)? = RealtimeVoiceMessagePresentation.parse(
            "<realtime_delegation><source>transcript_tail_flush</source><input>Flush</input><transcript_delta>Tail</transcript_delta></realtime_delegation>") {
            #expect(delta == "Tail")
        } else {
            Issue.record("Expected a transcript tail")
        }
    }
}
