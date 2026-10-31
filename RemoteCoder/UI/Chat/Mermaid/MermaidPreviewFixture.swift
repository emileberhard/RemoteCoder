#if DEBUG
import SwiftUI

/// Opt-in, offline UI acceptance surface using the production parser and views.
/// No messages are sent and no changes are made to the user's conversations.
struct MermaidPreviewFixture: View {
    @State private var mode = "Flowchart"
    @State private var dark = false
    @State private var largeText = false
    @State private var finished = false
    @State private var store = RenderedMessageStore()
    @State private var visibility = TranscriptVisibility()
    @State private var message = ChatMessage(role: .codex, text: "", isStreaming: false)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Diagrams, not code blocks.").scaledFont(.title2.bold())
                    Text("An offline rendering of the architecture in your conversation.")
                        .foregroundStyle(.secondary)
                    HStack {
                        AppMenu {
                            ForEach(["Flowchart", "Wide sequence", "Streaming", "Invalid"], id: \.self) { value in
                                Button(value) { mode = value; finished = false }
                            }
                        } label: {
                            Text(mode)
                        }
                        .accessibilityIdentifier("mermaid-example")
                        Spacer()
                        Toggle("Dark", isOn: $dark)
                        Toggle("Large text", isOn: $largeText)
                    }
                    if mode == "Streaming", !finished {
                        Button("Finish diagram") { finished = true }
                    }
                    if store[message.id] != nil {
                        ChatBubble(message: message, renderedMessages: store, onFork: nil, queuedActions: nil)
                            .id(ChatStreamItem.message(message).id)
                            .environment(\.transcriptRowVisibility, TranscriptRowVisibility(
                                rowID: ChatStreamItem.message(message).id, visibility: visibility))
                    }
                    Text("The rest of the conversation continues normally below the diagram.")
                    ForEach(0..<12) { index in Text("Conversation paragraph \(index + 1)").padding(.vertical, 12) }
                }
                .padding(20)
                .scrollTargetLayout()
            }
            .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.01) { ids in
                visibility.setVisibleRowIDs(Set(ids))
            }
            .navigationTitle("Mermaid Preview")
            .inlineNavigationTitle()
        }
        .preferredColorScheme(dark ? .dark : .light)
        .dynamicTypeSize(largeText ? .accessibility2 : .large)
        .onChange(of: message.id, initial: true) {
            visibility.retainRows([ChatStreamItem.message(message).id])
        }
        .task(id: "\(mode)-\(finished)") {
            message = ChatMessage(role: .codex, text: markdown, isStreaming: mode == "Streaming" && !finished)
            await store.prepare([message])
        }
    }

    private var markdown: String {
        let source: String
        switch mode {
        case "Wide sequence":
            source = """
            sequenceDiagram
            accTitle: Voice transcription sequence
            participant P as iPhone · TestFlight
            participant G as Remote Coder gateway
            participant S as Azure Speech
            participant A as Agent conversation
            P->>G: Audio + instructions
            G->>S: Audio + server-held credentials
            S-->>G: Transcript
            G-->>P: Transcript
            P->>A: Send the dictated message
            """
        case "Invalid": source = "flowchart LR\nA[Unclosed node --> B"
        default:
            source = """
            flowchart TD
            accTitle: Private speech transcription
            accDescr: The iPhone sends audio to the gateway. Only the gateway holds the Azure credential. The transcript returns to the phone.
            A[\"iPhone · TestFlight\"] -->|Audio + instructions| B[\"Remote Coder gateway\"]
            B -->|Server-held credential| C[\"Azure Speech\"]
            C -->|Transcript| B
            B -->|Transcript| A
            """
        }
        return "```mermaid\n\(source)" + (mode == "Streaming" && !finished ? "" : "\n```")
    }
}
#endif
