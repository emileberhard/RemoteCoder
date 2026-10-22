import SwiftUI

struct ThirdPartyLicensesView: View {
    @State private var document: String?
    @State private var files: [URL] = []
    @State private var failure: String?

    var body: some View {
        Form {
            Section {
                if let document {
                    Text(document)
                        .scaledFont(.caption.monospaced())
                        .textSelection(.enabled)
                } else if let failure {
                    Text(failure)
                } else {
                    ProgressView()
                }
            }
            Section("License texts") {
                ForEach(files, id: \.self) { file in
                    NavigationLink(file.lastPathComponent) { LicenseTextView(file: file) }
                }
            }
        }
        .navigationTitle("Licenses")
        .inlineNavigationTitle()
        .task {
            do { (document, files) = try await Self.readNotices() }
            catch { failure = "Licenses could not be read: \(error.localizedDescription)" }
        }
    }

    @concurrent private static func readNotices() async throws -> (String, [URL]) {
        guard let notices = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md"),
              let directory = Bundle.main.resourceURL?.appending(path: "LICENSES") else {
            throw CocoaError(.fileNoSuchFile)
        }
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
            .filter { try $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        return (try String(contentsOf: notices, encoding: .utf8), files)
    }
}

private struct LicenseTextView: View {
    let file: URL
    @State private var blocks: [String]?
    @State private var failure: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let blocks {
                    ForEach(blocks.indices, id: \.self) { index in
                        Text(blocks[index])
                            .scaledFont(.caption.monospaced())
                            .textSelection(.enabled)
                    }
                } else if let failure {
                    Text(failure)
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationTitle(file.lastPathComponent)
        .inlineNavigationTitle()
        .task {
            do { blocks = try await Self.read(file) }
            catch { failure = error.localizedDescription }
        }
    }

    @concurrent private static func read(_ file: URL) async throws -> [String] {
        let source = try String(contentsOf: file, encoding: .utf8)
        var blocks: [String] = []
        var current = ""
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            if current.utf8.count + line.utf8.count > 16_384, !current.isEmpty {
                blocks.append(current)
                current = ""
            }
            current += line + "\n"
        }
        if !current.isEmpty { blocks.append(current) }
        return blocks
    }
}
