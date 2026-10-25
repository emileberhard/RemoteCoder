#if DEBUG
import CryptoKit
import Foundation
import Observation
import OSLog
import SwiftUI

struct HTMLVisualFixture: View {
    private static let logger = AppLogger(category: "HTMLVisual")
    @Environment(\.appEnergyPolicy) private var systemEnergyPolicy
    @Environment(\.displayScale) private var systemDisplayScale
    @State private var fixture = HTMLVisualFixtureModel()
    @State private var textOnly = false
    @State private var snapshotsOnly = ProcessInfo.processInfo.arguments.contains("-html-visual-fixture-snapshots-only")
    @State private var dark = false
    @State private var largeText = false
    @State private var drawerOpen = false

    private static let conservesEnergy = ProcessInfo.processInfo.arguments.contains("-html-visual-fixture-conserve-energy")
    private static let displayScale = HTMLVisualFixtureModel.argument("-html-visual-fixture-scale").flatMap(Double.init)
    private var energyPolicy: AppEnergyPolicy {
        Self.conservesEnergy ? AppEnergyPolicy(isLowPowerModeEnabled: true, thermalState: systemEnergyPolicy.thermalState)
            : systemEnergyPolicy
    }

    var body: some View {
        Group {
            #if os(iOS)
            ConversationDrawer(isOpen: $drawerOpen, onBeginOpening: {}) {
                content
            } sidebar: {
                NavigationStack {
                    List(0..<36, id: \.self) { index in
                        Button("Visual \(index + 1)") {
                            fixture.show(index)
                            drawerOpen = false
                        }
                    }
                    .navigationTitle("Conversations")
                }
            }
            #else
            content
            #endif
        }
        .preferredColorScheme(dark ? .dark : .light)
        .onChange(of: energyPolicy, initial: true) { _, policy in
            Self.logger.notice("html visual fixture energy lowPower=\(policy.isLowPowerModeEnabled) thermal=\(policy.thermalState.rawValue)")
        }
        .dynamicTypeSize(largeText ? .accessibility2 : .large)
        .task(id: textOnly) {
            await fixture.prepare(textOnly: textOnly)
            await fixture.drive()
        }
    }

    private var content: some View {
        NavigationStack {
            Group {
                if let source = fixture.source {
                    ZStack(alignment: .topLeading) {
                        HTMLVisualPreparationHost()
                        ChatTranscriptView(items: fixture.items, readingPosition: fixture.readingPosition,
                            rowPresentations: fixture.rowPresentations, readingScope: fixture.readingScope,
                            retainedSurfaces: nil, renderedMessages: fixture.renderedMessages,
                            forkableMessageIDs: [], scrollToRow: fixture.request,
                            onFork: { _ in }, queuedActions: QueuedMessageActions(sendNow: nil, remove: { _ in }),
                            onToggleTimeline: { _ in }, questionCard: { _ in EmptyView() },
                            onBackgroundTap: {}, historyEdgeStatus: [:], canPrefetchOlderHistory: false, canLoadHistory: true,
                            onLoadHistory: { _ in nil }, onShowLatest: { fixture.show(35) },
                            onFirstContent: {}, bottomBar: Optional<EmptyView>.none)
                    }
                        .htmlVisualEnvironment()
                        .environment(\.htmlVisualSource, source)
                        .environment(\.htmlVisualSnapshotsOnly, snapshotsOnly)
                        .frame(maxWidth: fixture.width)
                        .environment(\.appEnergyPolicy, energyPolicy)
                        .environment(\.displayScale, Self.displayScale.map { CGFloat($0) } ?? systemDisplayScale)
                } else if let failure = fixture.failure {
                    Text(failure).foregroundStyle(.secondary).padding()
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("HTML visuals")
            .inlineNavigationTitle()
            .toolbar {
                #if os(iOS)
                ToolbarItem(placement: .topBarLeading) {
                    Button("Conversations", systemImage: "clock") { drawerOpen.toggle() }
                        .accessibilityIdentifier("open-conversations")
                }
                #endif
                ToolbarItem(placement: .primaryAction) {
                    AppMenu {
                        Button("First") { fixture.show(0) }
                        Button("Middle") { fixture.show(17) }
                        Button("Last") { fixture.show(35) }
                        Button("Mark trace") {
                            AppPerformanceDiagnostics.pointsOfInterest.emitEvent("HTMLVisualFixtureArm",
                                "snapshots=\(snapshotsOnly, privacy: .public) lowPower=\(energyPolicy.isLowPowerModeEnabled, privacy: .public) thermal=\(energyPolicy.thermalState.rawValue, privacy: .public) uptime=\(ProcessInfo.processInfo.systemUptime, privacy: .public)")
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                    .accessibilityLabel("Jump to visual")
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("Open") { fixture.open() }
                        .accessibilityIdentifier("html-visual-open")
                }
                ToolbarItem(placement: .primaryAction) {
                    Toggle("Dark", isOn: $dark)
                        .accessibilityIdentifier("html-visual-dark")
                }
                ToolbarItem(placement: .primaryAction) {
                    Toggle("Snapshots only", isOn: $snapshotsOnly)
                        .accessibilityIdentifier("html-visual-snapshots-only")
                }
                ToolbarItem(placement: .primaryAction) {
                    Toggle("Text only", isOn: $textOnly)
                        .accessibilityIdentifier("html-visual-text-only")
                }
                ToolbarItem(placement: .primaryAction) {
                    Toggle("Large text", isOn: $largeText)
                        .accessibilityIdentifier("html-visual-large-text")
                }
            }
        }
    }
}

@MainActor
@Observable
private final class HTMLVisualFixtureModel {
    let readingPosition = TranscriptReadingPosition()
    let rowPresentations = TranscriptRowPresentations()
    let readingScope = UUID()
    let renderedMessages = RenderedMessageStore()
    let visuals = HTMLVisualServices(directory: ProcessInfo.processInfo.arguments.contains("-html-visual-cold-cache")
        ? HTMLVisualServices.coldDirectory("html-visual-fixture-cold")
        : URL.applicationSupportDirectory.appending(path: "RemoteCoder/html-visual-fixture"))
    let width = HTMLVisualFixtureModel.argument("-html-visual-fixture-width").flatMap(Double.init).map { CGFloat($0) }
    private(set) var items: [ChatStreamItem] = []
    private(set) var source: HTMLVisualSource?
    private(set) var failure: String?
    private(set) var request: TranscriptRowRequest?
    @ObservationIgnored private let hostID = UUID()
    @ObservationIgnored private let conversationID = UUID()
    @ObservationIgnored private var documents: [HTMLVisualFixtureDocument] = []
    @ObservationIgnored private var transcript: [ChatMessage]?
    @ObservationIgnored private var deferred: [ChatStreamItem]?

    func open() {
        guard let deferred else { return }
        self.deferred = nil
        items = deferred
        AppLogger(category: "HTMLVisual").notice("html visual fixture ready rows=\(deferred.count) uptime=\(ProcessInfo.processInfo.systemUptime)")
    }
    @ObservationIgnored private var revision: UInt64 = 0
    @ObservationIgnored private var requestToken = 0

    isolated deinit {
        renderedMessages.retire()
    }

    func prepare(textOnly: Bool) async {
        do {
            if documents.isEmpty {
                let arguments = ProcessInfo.processInfo.arguments
                let prepared: [HTMLVisualFixtureDocument]
                if let path = Self.argument("-html-visual-fixture-transcript") {
                    let loaded = try await Self.transcript(path: path, hostID: hostID, cache: visuals.documents)
                    prepared = loaded.documents
                    transcript = loaded.messages
                } else {
                    prepared = try await Self.documents(hostID: hostID, arguments: arguments, cache: visuals.documents)
                }
                try Task.checkCancellation()
                let store = HTMLVisualDocumentStore(hostID: hostID, access: HTMLVisualFixtureFileAccess(), cache: visuals.documents)
                documents = prepared
                source = HTMLVisualSource(hostID: hostID, documents: store, renderer: visuals.renderer,
                    preparation: HTMLVisualPreparation(renderer: visuals.renderer))
            }
            let messages = transcript ?? documents.enumerated().map { index, document in
                let body = textOnly
                    ? (0..<8).map { "Conversation paragraph \($0 + 1), visual \(index + 1)." }.joined(separator: "\n\n")
                    : "![\(document.title)](rc-visual:\(document.reference.digest))"
                return ChatMessage(id: ChatMessage.deterministicID(for: "html-visual-fixture-\(index)"), role: .codex,
                    text: "## Visual \(index + 1)\n\nA paragraph before the visual.\n\n\(body)\n\nConversation continues below the visual.",
                    date: .distantPast)
            }
            await renderedMessages.prepare(messages)
            try Task.checkCancellation()
            let next = messages.map(ChatStreamItem.message)
            revision += 1
            let snapshot = ConversationSnapshot(conversationID: conversationID, ownerID: conversationID,
                threadID: "html-visual-fixture", revision: revision, messages: messages, timelines: [], items: next,
                lastTurnCompletedAt: nil, presentationRows: TranscriptPresentationRows(rowIDs: Set(next.map(\.id))))
            if items.isEmpty, let row = Self.argument("-html-visual-fixture-restore").flatMap(Int.init), next.indices.contains(row),
               let anchor = TranscriptReadingAnchor(rowID: next[row].id, frame: CGRect(x: 0, y: 0, width: 1, height: 400),
                                                    viewport: CGRect(x: 0, y: 0, width: 1, height: 800)) {
                readingPosition.record(isFollowingLatest: false, anchor: anchor, mountedStartRowID: next[row].id)
            }
            rowPresentations.prepareSource(snapshot, readingPosition: readingPosition)
            if ProcessInfo.processInfo.arguments.contains("-html-visual-fixture-defer") && items.isEmpty {
                deferred = next
                return
            }
            items = next
            failure = nil
            AppLogger(category: "HTMLVisual").notice("html visual fixture ready rows=\(next.count) uptime=\(ProcessInfo.processInfo.systemUptime)")
            if request == nil {
                switch Self.argument("-html-visual-fixture-start") {
                case "bottom": break
                case let value?: show(Int(value) ?? 0)
                case nil: if transcript == nil { show(0) }
                }
            }
        } catch is CancellationError {
        } catch {
            failure = error.localizedDescription
        }
    }

    func show(_ index: Int, anchor: UnitPoint = .top, motion: TranscriptRowRequest.Motion = .instant) {
        guard items.indices.contains(index) else { return }
        requestToken += 1
        request = TranscriptRowRequest(rowID: items[index].id, token: requestToken, anchor: anchor, motion: motion)
    }

    func drive() async {
        guard let script = Self.argument("-html-visual-fixture-drive") else { return }
        let logger = AppLogger(category: "HTMLVisual")
        for step in script.split(separator: ";").map(String.init) {
            let parts = step.split(separator: ":").map(String.init)
            logger.notice("html visual fixture step=\(step) uptime=\(ProcessInfo.processInfo.systemUptime)")
            switch parts.first {
            case "open": open()
            case "wait": try? await Task.sleep(for: .milliseconds(Int(parts[1]) ?? 0))
            case "row":
                let anchor: UnitPoint = switch parts[2] { case "bottom": .bottom; case "center": .center; default: .top }
                show(Int(parts[1]) ?? 0, anchor: anchor, motion: parts[3] == "animated" ? .animated : .instant)
            default: break
            }
        }
        logger.notice("html visual fixture drive finished uptime=\(ProcessInfo.processInfo.systemUptime)")
    }

    static func argument(_ name: String) -> String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: name), arguments.indices.contains(flag + 1) else { return nil }
        return arguments[flag + 1]
    }

    private struct TranscriptFile: Decodable {
        struct Message: Decodable {
            let role: String
            let text: String
        }
        let messages: [Message]
        let visuals: [String: String]
    }

    @concurrent
    private static func transcript(path: String, hostID: UUID, cache: HTMLVisualDocumentCache) async throws
        -> (messages: [ChatMessage], documents: [HTMLVisualFixtureDocument]) {
        let url = path.hasPrefix("/") ? URL(filePath: path) : FileManager.default.temporaryDirectory.appending(path: path)
        let file = try JSONDecoder().decode(TranscriptFile.self, from: Data(contentsOf: url))
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var documents: [HTMLVisualFixtureDocument] = []
        for (digest, html) in file.visuals.sorted(by: { $0.key < $1.key }) {
            let bytes = Data(html.utf8)
            guard SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == digest,
                  let url = URL(string: "rc-visual:" + digest), let reference = HTMLVisualReference(url: url)
            else { throw URLError(.badURL) }
            let source = directory.appending(path: "\(digest).html")
            try bytes.write(to: source)
            _ = try await cache.store(hostID: hostID, reference: reference, source: source)
            documents.append(HTMLVisualFixtureDocument(reference: reference, title: digest))
        }
        let messages = file.messages.enumerated().map { index, message in
            ChatMessage(id: ChatMessage.deterministicID(for: "html-visual-fixture-transcript-\(index)"),
                role: message.role == "user" ? .user : .codex, text: message.text, date: .distantPast)
        }
        return (messages, documents)
    }

    @concurrent
    private static func documents(hostID: UUID, arguments: [String], cache: HTMLVisualDocumentCache) async throws -> [HTMLVisualFixtureDocument] {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var imported: String?
        if let flag = arguments.firstIndex(of: "-html-visual-fixture-html") {
            guard arguments.indices.contains(flag + 1) else { throw CocoaError(.fileReadInvalidFileName) }
            let file = try FileHandle(forReadingFrom: URL(filePath: arguments[flag + 1]))
            defer { try? file.close() }
            let data = try file.read(upToCount: HTMLVisualReference.maximumBytes + 1) ?? Data()
            guard data.count <= HTMLVisualReference.maximumBytes else { throw HTMLVisualError.tooLarge }
            guard let html = String(data: data, encoding: .utf8) else { throw HTMLVisualError.invalidUTF8 }
            imported = html
        }
        var result: [HTMLVisualFixtureDocument] = []
        let count = arguments.contains("-html-visual-fixture-single") ? 1 : 36
        for index in 0..<count {
            try Task.checkCancellation()
            let generated = arguments.contains("-html-visual-fixture-compact")
                ? "<body><div style='height:80px'>Compact visual \(index + 1).</div></body>"
                : Self.html(index: index)
            let html = index == 0 ? (imported ?? generated) : generated
            let bytes = Data(html.utf8)
            let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            guard let url = URL(string: "rc-visual:" + digest), let reference = HTMLVisualReference(url: url) else { throw URLError(.badURL) }
            let source = directory.appending(path: "\(index).html")
            try bytes.write(to: source)
            _ = try await cache.store(hostID: hostID, reference: reference, source: source)
            result.append(HTMLVisualFixtureDocument(reference: reference,
                title: index == 0 && imported != nil ? "Published visual" : "Interactive visual \(index + 1)"))
        }
        return result
    }

    nonisolated private static func html(index: Int) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <style>
        p{margin:8px 0}label{display:block;margin:8px 0}
        input[type=range],input[type=text]{width:100%}input,button{color:var(--rc-text);background:var(--rc-background)}
        canvas{display:block;touch-action:pan-y;background:var(--rc-background);width:100%;height:80px;border:1px solid var(--rc-secondary-text)}
        </style></head><body>
        <label>Value <output id="value">50</output><input id="range" type="range" value="50" aria-label="Value"></label>
        <canvas width="600" height="160" aria-label="Brush"></canvas>
        <label>Notes <input type="text" aria-label="Notes" placeholder="Notes"></label>
        <button id="grow">Grow / shrink</button><div id="extra" hidden style="height:220px">Extra content</div>
        <p>Selectable text inside visual \(index + 1).</p>
        <a href="https://developer.apple.com/documentation/webkit" target="_blank">WebKit documentation</a>
        \(index == 35 ? "<div style='height:1000px'>Long visual content</div><p>End of the long visual.</p>" : "")
        <script>
        document.getElementById('range').addEventListener('input',event=>document.getElementById('value').textContent=event.target.value);
        document.getElementById('grow').addEventListener('click',()=>{const extra=document.getElementById('extra');extra.hidden=!extra.hidden});
        const canvas=document.querySelector('canvas'),brush=canvas.getContext('2d');
        const draw=event=>{const rect=canvas.getBoundingClientRect();brush.fillStyle=getComputedStyle(document.body).color;brush.fillRect((event.clientX-rect.left)*canvas.width/rect.width,(event.clientY-rect.top)*canvas.height/rect.height,8,8)};
        canvas.addEventListener('pointerdown',draw);
        canvas.addEventListener('pointermove',event=>{if(event.buttons)draw(event)});
        </script></body></html>
        """
    }
}

private struct HTMLVisualFixtureDocument: Sendable {
    let reference: HTMLVisualReference
    let title: String
}

private actor HTMLVisualFixtureFileAccess: HostFileAccess {
    func open(reference: HostFileReference, containingDirectory: String?, progress: @escaping @Sendable (HostFileProgress) -> Void) async throws -> HostFileLease { throw HostFileError.unavailable }
    func openVisual(reference: HTMLVisualReference, progress: @escaping @Sendable (HostFileProgress) -> Void) async throws -> HostFileLease { throw HostFileError.unavailable }
    func cachedCopy(for reference: HostFileReference) async throws -> HostFileLease? { nil }
    func release(_ lease: HostFileLease) async { }
}
#endif
