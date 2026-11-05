#if os(macOS)
import Foundation

@MainActor
final class FleetLiveActivityService {
    struct Host {
        let id: UUID
        let isCoordinatorCapable: @MainActor () async -> Bool
        let read: @MainActor ([UUID]) async throws -> ActiveTasksLiveActivitySnapshot
        let register: @MainActor (DeviceRegistrationRequest.FleetActivity?) -> Void
    }

    enum Scene {
        case active, inactive, background
    }

    init(
        hosts: @escaping @MainActor () -> [Host],
        configured: @escaping @MainActor () -> [UUID],
        preferred: @escaping @MainActor () -> UUID?
    ) {}

    func sceneChanged(_ next: Scene) {}
    func schedule() {}
    func settle() async {}
    func retire() {}
}
#endif
