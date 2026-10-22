import Foundation
import Observation

@Observable @MainActor
final class ConversationDrawerPreferences {
    private enum Key {
        static let mode = "conversationDrawer.mode"
        static let unreadOnly = "conversationDrawer.unreadOnly"
        static let isPinnedFolded = "conversationDrawer.pinnedFolded"
        static let isAutomationsFolded = "conversationDrawer.automationsFolded"
        static let isSettledFolded = "conversationDrawer.settledFolded"
        static let foldedProjects = "conversationDrawer.foldedProjects"
    }

    static let foldedProjectLimit = 256
    static let syncedKeys: Set<String> = [Key.mode]

    @ObservationIgnored private let defaults: UserDefaults

    private var appliedMode: ConversationDrawerMode
    var mode: ConversationDrawerMode {
        get { appliedMode }
        set {
            appliedMode = newValue
            defaults.set(newValue.rawValue, forKey: Key.mode)
        }
    }

    var unreadOnly: Bool {
        didSet { defaults.set(unreadOnly, forKey: Key.unreadOnly) }
    }

    var isPinnedFolded: Bool {
        didSet { defaults.set(isPinnedFolded, forKey: Key.isPinnedFolded) }
    }

    var isAutomationsFolded: Bool {
        didSet { defaults.set(isAutomationsFolded, forKey: Key.isAutomationsFolded) }
    }

    var isSettledFolded: Bool {
        didSet { defaults.set(isSettledFolded, forKey: Key.isSettledFolded) }
    }

    private(set) var foldedProjects: Set<String> {
        didSet { defaults.set(foldedProjects.sorted(), forKey: Key.foldedProjects) }
    }

    init(defaults: UserDefaults) {
        self.defaults = defaults
        appliedMode = Self.storedMode(defaults)
        unreadOnly = defaults.bool(forKey: Key.unreadOnly)
        isPinnedFolded = defaults.bool(forKey: Key.isPinnedFolded)
        isAutomationsFolded = defaults.bool(forKey: Key.isAutomationsFolded)
        isSettledFolded = defaults.object(forKey: Key.isSettledFolded) as? Bool ?? true
        foldedProjects = Set(defaults.stringArray(forKey: Key.foldedProjects) ?? [])
    }

    func reloadMode() {
        let stored = Self.storedMode(defaults)
        if stored != appliedMode { appliedMode = stored }
    }

    private static func storedMode(_ defaults: UserDefaults) -> ConversationDrawerMode {
        defaults.string(forKey: Key.mode).flatMap(ConversationDrawerMode.init(rawValue:)) ?? .priority
    }

    func setFolded(_ isFolded: Bool, project key: String, among present: Set<String>) {
        var folded = foldedProjects
        if isFolded { folded.insert(key) } else { folded.remove(key) }
        if folded.count > Self.foldedProjectLimit { folded.formIntersection(present) }
        foldedProjects = folded
    }

    func setAllFolded(_ isFolded: Bool, projects present: Set<String>) {
        isPinnedFolded = isFolded
        isAutomationsFolded = isFolded
        isSettledFolded = isFolded
        let folded = isFolded ? foldedProjects.union(present) : foldedProjects.subtracting(present)
        foldedProjects = folded.count > Self.foldedProjectLimit ? present : folded
    }
}
