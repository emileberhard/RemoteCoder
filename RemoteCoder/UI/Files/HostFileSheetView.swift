import SwiftUI
import UniformTypeIdentifiers

struct HostFileSheetView: View {
    let item: HostFileSheet
    let opener: HostFileOpener
    @Environment(\.dismiss) private var dismiss
    @Environment(\.interfaceScale) private var interfaceScale
    @State private var showsSource = false
    @State private var showsFind = false
    @State private var savingFile: OpenedFile?
    @State private var exportFailure: String?
    @AccessibilityFocusState private var focusedElement: Int?

    var body: some View {
        NavigationStack {
            Group {
                switch item.content {
                case .document(let file, let content): document(file, content: content)
                case .html(let file): html(file)
                case .failure(let failure): failureView(failure)
                }
            }
            .navigationTitle(title)
            .inlineNavigationTitle()
            #if os(iOS)
            .toolbarBackground(Color.appSystemBackground, for: .navigationBar)
            .toolbarBackgroundVisibility(.visible, for: .navigationBar)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark") { dismiss() }
                        .tooltip("Close")
                }
                if let file = openedFile {
                    ToolbarItemGroup(placement: .primaryAction) {
                        if case .document(_, .some) = item.content {
                            Button(showsSource ? "Rendered" : "Source", systemImage: showsSource ? "doc.richtext" : "chevron.left.forwardslash.chevron.right") {
                                showsSource.toggle()
                            }
                            .tooltip(showsSource ? "Rendered" : "Source")
                        }
                        if case .html = item.content {
                            Button("Find", systemImage: "magnifyingglass") { showsFind.toggle() }
                                .keyboardShortcut("f", modifiers: .command)
                                .tooltip("Find")
                        }
                        AppMenu(trigger: .icon) {
                            ShareLink(item: HostFileExportItem(file: file), preview: SharePreview(file.name)) {
                                Label("Share", systemImage: "square.and.arrow.up")
                            }
                            Button("Save to Files", systemImage: "folder") { savingFile = file }
                        } label: {
                            Label("File actions", systemImage: "ellipsis")
                        }
                        .tooltip("File actions")
                    }
                }
            }
            .fileExporter(isPresented: Binding(get: { savingFile != nil }, set: { if !$0 { savingFile = nil } }),
                          item: savingFile.map(HostFileExportItem.init), defaultFilename: savingFile?.name) { result in
                switch result {
                case .success: AccessibilityNotification.Announcement("Saved to Files.").post()
                case .failure(let error): exportFailure = error.localizedDescription
                }
            }
            .alert("File export", isPresented: Binding(get: { exportFailure != nil }, set: { if !$0 { exportFailure = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(exportFailure ?? "") }
        }
        .environment(\.openURL, OpenURLAction { url in
            guard let file = openedFile, let origin = opener.origin,
                  opener.lastDocument?.id == file.id else { return .discarded }
            return opener.open(url, origin: origin,
                               relativeTo: file.host.map { ($0.lease.reference.path as NSString).deletingLastPathComponent }
                                   ?? origin.workingDirectory,
                               transition: nil)
        })
        .task {
            if case .document(_, let content) = item.content, content != nil { focusedElement = 0 }
            else { focusedElement = -1 }
        }
    }

    private var title: String {
        switch item.content {
        case .document(let file, _): file.name
        case .html(let file): file.lease.metadata.name
        case .failure: "Couldn’t open file"
        }
    }

    private var openedFile: OpenedFile? {
        switch item.content {
        case .document(let file, _): file
        case .html(let file): .host(file)
        case .failure: nil
        }
    }

    private func html(_ file: OpenedHostFile) -> some View {
        VStack(spacing: 0) {
            if file.isCachedCopy {
                Label("Saved copy from \(file.lease.downloadedAt.formatted(date: .abbreviated, time: .shortened)). The original could not be verified.", systemImage: "clock")
                    .scaledFont(.callout).foregroundStyle(.secondary).padding()
            }
            HostHTMLPreview(file: file, showsFind: $showsFind)
        }
    }

    private func document(_ file: OpenedFile, content: HostFileReaderContent?) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if let host = file.host, host.isCachedCopy {
                    Label("Saved copy from \(host.lease.downloadedAt.formatted(date: .abbreviated, time: .shortened)). The original could not be verified.", systemImage: "clock")
                        .scaledFont(.callout).foregroundStyle(.secondary)
                }
                if let content {
                    if showsSource {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(content.sourceChunks.indices, id: \.self) { index in
                                Text(content.sourceChunks[index]).scaledFont(.system(.body, design: .monospaced))
                                    .accessibilityFocused($focusedElement, equals: index)
                            }
                        }
                        .textSelection(.enabled)
                    } else {
                        LazyVStack(alignment: .leading, spacing: MarkdownBlockView.spacing * interfaceScale) {
                            ForEach(content.blocks.indices, id: \.self) { index in
                                MarkdownBlockView(block: content.blocks[index], isFirst: index == 0, reveal: .settled)
                                    .accessibilityFocused($focusedElement, equals: index)
                            }
                        }
                        .textSelection(.enabled)
                    }
                } else {
                    Label(file.name, systemImage: "doc")
                        .scaledFont(.title2).accessibilityAddTraits(.isHeader).accessibilityFocused($focusedElement, equals: -1)
                    Text("This file is ready to save or share.").foregroundStyle(.secondary)
                    LabeledContent("Size", value: ByteCountFormatter.string(fromByteCount: file.bytes, countStyle: .file))
                    if let host = file.host {
                        LabeledContent("Modified", value: Date(timeIntervalSince1970: host.lease.metadata.modifiedAt).formatted())
                        if let origin = opener.origin { LabeledContent("Host", value: origin.hostName) }
                        Text(host.lease.reference.path).scaledFont(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Button("Save to Files", systemImage: "folder") { savingFile = file }
                        .buttonStyle(.borderedProminent)
                    ShareLink(item: HostFileExportItem(file: file), preview: SharePreview(file.name)) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(20)
        }
        .defaultScrollAnchor(.top)
        .background(Color.appSystemBackground)
    }

    private func failureView(_ failure: HostFileFailure) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Label("Couldn’t open file", systemImage: "exclamationmark.triangle")
                    .scaledFont(.title2).accessibilityAddTraits(.isHeader).accessibilityFocused($focusedElement, equals: -1)
                Text(failure.message)
                if let reference = failure.reference {
                    Text(reference.path).scaledFont(.footnote).foregroundStyle(.secondary).textSelection(.enabled)
                    if let origin = opener.origin {
                        Button("Try Again", systemImage: "arrow.clockwise") { opener.request(reference, origin: origin, transition: nil) }
                            .buttonStyle(.borderedProminent)
                    }
                }
                if let cached = failure.cached {
                    Button("Open saved copy", systemImage: "clock") { opener.useCachedCopy(cached) }.buttonStyle(.bordered)
                    Text("Downloaded \(cached.lease.downloadedAt.formatted(date: .abbreviated, time: .shortened)). This copy may be out of date.")
                        .scaledFont(.footnote).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: 760, alignment: .leading).padding(20)
        }
    }
}

struct HostFileExportItem: Transferable {
    let url: URL
    private let retainedFile: OpenedFile

    @MainActor init(file: OpenedFile) {
        url = file.url
        retainedFile = file
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .data) { SentTransferredFile($0.url) }
    }
}
