import Foundation
import Testing
@testable import RemoteCoder

@MainActor
struct DirectoryPickerViewModelTests {
    @Test func initialLoadPreservesPrefetchedChildrenWithoutRequestingTheGateway() async throws {
        let url = try #require(URL(string: "ws://127.0.0.1:1/ws"))
        let gateway = GatewayClient(config: .init(url: url, authToken: "test", hostLabel: "Test"), routes: nil)
        let defaults = try #require(UserDefaults(suiteName: "DirectoryPickerViewModelTests.\(UUID().uuidString)"))
        let directories = HostDirectories(gateway: gateway, hostID: UUID(), hostLabel: "Test", defaults: defaults)
        let child = DirectoryItem(path: "/home/project")
        let model = DirectoryPickerViewModel(directories: directories, currentWorkingDirectory: nil,
                                             prefetchedRootChildren: [child])

        await model.loadInitialChildren()

        #expect(model.tree.root.children == .loaded([child]))
        #expect(model.errorMessage == nil)
    }
}
