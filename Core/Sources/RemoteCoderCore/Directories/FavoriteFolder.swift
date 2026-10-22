import Foundation

struct FavoriteFolder: Identifiable, Hashable, Sendable {
    struct ID: Hashable, Sendable {
        let hostID: UUID
        let path: String
    }

    struct Host {
        let id: UUID
        let name: String
        let paths: [String]
        let remoteHomePath: String?
    }

    let id: ID
    let hostName: String
    let showsHostLabel: Bool
    let title: String
    let displayPath: String

    var hostID: UUID { id.hostID }
    var path: String { id.path }

    static func list(_ hosts: [Host]) -> [FavoriteFolder] {
        let showsHostLabel = hosts.count > 1
        return hosts.flatMap { host in
            let displayPaths = host.paths.map {
                WorkingDirectoryPathFormatter.displayPath($0, remoteHomePath: host.remoteHomePath)
            }
            let names = zip(host.paths, displayPaths).map { path, displayPath in
                displayPath == "~" ? "Home" : (path as NSString).lastPathComponent
            }
            let repeatedNames = Set(Dictionary(grouping: names, by: \.self).filter { $0.value.count > 1 }.keys)
            return host.paths.indices.map { index in
                FavoriteFolder(
                    id: ID(hostID: host.id, path: host.paths[index]),
                    hostName: host.name,
                    showsHostLabel: showsHostLabel,
                    title: repeatedNames.contains(names[index]) ? displayPaths[index] : names[index],
                    displayPath: displayPaths[index]
                )
            }
        }
    }
}
