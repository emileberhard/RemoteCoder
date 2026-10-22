import Foundation
import Testing
@testable import RemoteCoderCore

struct HostFilePathAdmissionTests {
    @Test(.timeLimit(.minutes(1)))
    func samePathWaitsWhileOtherPathsRemainIndependent() async throws {
        let admission = HostFilePathAdmission()
        try await admission.acquire("/image.png")
        try await withThrowingTaskGroup(of: Bool.self) { group in
            for _ in 0..<25 {
                group.addTask {
                    do {
                        try await admission.acquire("/image.png")
                        return true
                    } catch HostFileError.busy {
                        return false
                    }
                }
            }
            defer { group.cancelAll() }
            #expect(try await group.next() == false)
            try await admission.acquire("/other.png")
            await admission.release("/other.png")
            await admission.release("/image.png")
            #expect(try await group.next() == true)
        }
        await admission.release("/image.png")
        try await admission.acquire("/image.png")
        await admission.release("/image.png")
    }

    @Test(.timeLimit(.minutes(1)))
    func cancellationRemovesWaitersWithoutReleasingTheActiveRead() async throws {
        let admission = HostFilePathAdmission()
        try await admission.acquire("/image.png")
        for _ in 0..<2 {
            await withTaskGroup(of: String.self) { group in
                for _ in 0..<25 {
                    group.addTask {
                        do {
                            try await admission.acquire("/image.png")
                            return "acquired"
                        } catch HostFileError.busy {
                            return "busy"
                        } catch is CancellationError {
                            return "cancelled"
                        } catch {
                            return "unexpected"
                        }
                    }
                }
                #expect(await group.next() == "busy")
                group.cancelAll()
                var cancelled = 0
                for await result in group {
                    #expect(result == "cancelled")
                    cancelled += 1
                }
                #expect(cancelled == 24)
            }
        }
        await admission.release("/image.png")
        try await admission.acquire("/image.png")
        await admission.release("/image.png")
    }
}
