import SwiftUI

@MainActor
struct CommandPaletteCatalog {
    fileprivate enum Item {
        case conversation(ConversationSidebarRow)
        case folder(FavoriteFolder)
        case model(ModelOption)
        case command(ChatCommand)
    }

    fileprivate struct Entry {
        let item: Item
        let title: String
        let detail: String
    }

    fileprivate let actions: ChatWindowActions
    fileprivate let entries: [Entry]
    fileprivate let candidates: [CommandPaletteCandidate<Int>]

    init(actions: ChatWindowActions) {
        let conversations = actions.unfoldedConversationRows().map { row in
            Entry(item: .conversation(row), title: row.title, detail: "\(row.workingDirectory) \(row.hostName)")
        }
        let folders = actions.favoriteFolders.map { folder in
            Entry(item: .folder(folder), title: folder.displayPath, detail: "Folder \(folder.hostName)")
        }
        let models = actions.models.map { model in
            Entry(item: .model(model), title: model.displayName, detail: "Model")
        }
        let commands = ChatCommand.allCases
            .filter { $0.appearsInPalette && actions.isEnabled($0) }
            .map { Entry(item: .command($0), title: $0.title(in: actions), detail: "Command") }
        let entries = conversations + folders + models + commands
        self.actions = actions
        self.entries = entries
        candidates = entries.enumerated().map { index, entry in
            CommandPaletteCandidate(id: index, title: entry.title, detail: entry.detail)
        }
    }

    fileprivate func run(_ entry: Entry) {
        switch entry.item {
        case .conversation(let row): actions.selectConversation(row.address)
        case .folder(let folder): actions.selectFavorite(folder)
        case .model(let model): actions.selectModel(model)
        case .command(let command): actions.run(command)
        }
    }
}

struct CommandPalette: View {
    let catalog: CommandPaletteCatalog
    let dismiss: () -> Void
    @State private var query = ""
    @State private var results: [Int]?
    @State private var selection: Int?
    @State private var listHeight: CGFloat = 0
    @FocusState private var isFieldFocused: Bool

    private nonisolated static let resultLimit = 50
    private static let maximumListHeight: CGFloat = 380

    var body: some View {
        ZStack(alignment: .top) {
            Color.clear
                .contentShape(.rect)
                .onTapGesture(perform: dismiss)
                .accessibilityHidden(true)
            card
                .padding(.top, 56)
        }
        .task(id: query) {
            let ranked = await Self.rank(query, in: catalog.candidates)
            guard !Task.isCancelled else { return }
            results = ranked
            selection = ranked.first
        }
    }

    private var card: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField("Go to a conversation, folder, model or command", text: $query)
                    .textFieldStyle(.plain)
                    .scaledFont(.title3)
                    .focused($isFieldFocused)
                    .onSubmit(runSelection)
                    .onKeyPress(.upArrow) { moveSelection(by: -1) }
                    .onKeyPress(.downArrow) { moveSelection(by: 1) }
                    .onKeyPress(.escape) {
                        dismiss()
                        return .handled
                    }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            if let results {
                Divider()
                if results.isEmpty {
                    Text("No results")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(14)
                } else {
                    resultList(results)
                }
            }
        }
        .frame(width: 560)
        .appGlass(.standard, in: .rect(cornerRadius: 18))
        .onAppear { isFieldFocused = true }
    }

    private func resultList(_ results: [Int]) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(results, id: \.self) { index in
                        Button { run(index) } label: {
                            CommandPaletteRow(entry: catalog.entries[index], actions: catalog.actions, isSelected: index == selection)
                        }
                        .buttonStyle(.plain)
                        .id(index)
                    }
                }
                .padding(6)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { listHeight = $0 }
            }
            .frame(height: min(listHeight, Self.maximumListHeight))
            .onChange(of: selection) { _, selection in
                if let selection { proxy.scrollTo(selection) }
            }
        }
    }

    private func moveSelection(by step: Int) -> KeyPress.Result {
        guard let results, !results.isEmpty else { return .handled }
        let current = selection.flatMap(results.firstIndex(of:)) ?? 0
        selection = results[min(max(current + step, 0), results.count - 1)]
        return .handled
    }

    private func runSelection() {
        if let selection { run(selection) }
    }

    private func run(_ index: Int) {
        let entry = catalog.entries[index]
        dismiss()
        catalog.run(entry)
    }

    @concurrent
    private nonisolated static func rank(_ query: String, in candidates: [CommandPaletteCandidate<Int>]) async -> [Int] {
        CommandPaletteSearch.results(for: query, in: candidates, limit: resultLimit)
    }
}

private struct CommandPaletteRow: View {
    let entry: CommandPaletteCatalog.Entry
    let actions: ChatWindowActions
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .frame(width: 20)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .scaledFont(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 12)
            if isChecked {
                Image(systemName: "checkmark")
                    .accessibilityLabel("Current")
            }
            if let shortcut {
                Text(shortcut)
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(isSelected ? Color.white : Color.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? AnyShapeStyle(.selection) : AnyShapeStyle(.clear), in: .rect(cornerRadius: 8))
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var systemImage: String {
        switch entry.item {
        case .conversation: "text.bubble"
        case .folder: "folder"
        case .model: "sparkles"
        case .command(let command): command.systemImage
        }
    }

    private var subtitle: String? {
        switch entry.item {
        case .conversation(let row): row.showsHostLabel ? "\(row.workingDirectory) · \(row.hostName)" : row.workingDirectory
        case .folder(let folder): folder.hostName
        case .model: "Model"
        case .command: nil
        }
    }

    private var isChecked: Bool {
        switch entry.item {
        case .model(let model): model.id == actions.selectedModelID
        case .command(let command): actions.isOn(command) == true
        case .conversation, .folder: false
        }
    }

    private var shortcut: String? {
        guard case .command(let command) = entry.item else { return nil }
        return command.shortcut?.symbols
    }
}
