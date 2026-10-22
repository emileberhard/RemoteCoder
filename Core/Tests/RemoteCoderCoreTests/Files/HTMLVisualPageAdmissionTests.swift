import Foundation
import Testing
@testable import RemoteCoderCore

struct HTMLVisualPageAdmissionTests {
    @Test func boundsPagesAndWaitingAndDrainsInOrder() throws {
        var admission = HTMLVisualPageAdmission()
        let live = (0..<3).map { _ in UUID() }
        for id in live { #expect(try admission.request(id, kind: .automatic)) }
        let waiting = (0..<16).map { _ in UUID() }
        for id in waiting { #expect(try !admission.request(id, kind: .automatic)) }
        #expect(throws: HTMLVisualAdmissionError.self) { try admission.request(UUID(), kind: .automatic) }
        #expect(admission.live.count == 3)
        #expect(admission.waiting.count == 16)
        #expect(admission.remove(waiting[2]) == nil)
        #expect(admission.remove(live[0]) == waiting[0])
        #expect(admission.remove(live[1]) == waiting[1])
        #expect(admission.remove(live[2]) == waiting[3])
        #expect(admission.live.count == 3)
        #expect(admission.waiting.count == 12)
    }

    @Test func interactionPinsPreventEvictionAndReleaseTheirScope() throws {
        var admission = HTMLVisualPageAdmission()
        let ids = (0..<3).map { _ in UUID() }
        for id in ids {
            _ = try admission.request(id, kind: .automatic)
            admission.pin(id, active: true)
        }
        #expect(admission.evictionCandidate(excluding: UUID()) == nil)
        admission.pin(ids[1], active: false)
        #expect(admission.evictionCandidate(excluding: ids[0]) == ids[1])
        #expect(admission.evictionCandidate(excluding: ids[1]) == nil)
        _ = admission.remove(ids[1])
        #expect(admission.evictionCandidate(excluding: UUID()) == nil)
        #expect(admission.live.count == 2)
    }

    @Test func explicitInteractionAdmitsItsOccurrenceBeforeOtherWaiters() throws {
        var admission = HTMLVisualPageAdmission()
        let live = (0..<3).map { _ in UUID() }
        for id in live { _ = try admission.request(id, kind: .automatic) }
        let first = UUID()
        let selected = UUID()
        _ = try admission.request(first, kind: .automatic)
        _ = try admission.request(selected, kind: .automatic)
        admission.prioritize(selected)
        #expect(admission.remove(live[0]) == selected)
        #expect(admission.remove(live[1]) == first)
        admission.prioritize(UUID())
        #expect(admission.waiting.isEmpty)
    }

    @Test func selectionPrioritySurvivesAnEntirelyPinnedPool() throws {
        var admission = HTMLVisualPageAdmission()
        let live = (0..<3).map { _ in UUID() }
        for id in live {
            _ = try admission.request(id, kind: .automatic)
            admission.pin(id, active: true)
        }
        let ordinary = UUID()
        let selected = UUID()
        _ = try admission.request(ordinary, kind: .automatic)
        _ = try admission.request(selected, kind: .selected)
        admission.prioritize(selected)
        #expect(admission.evictionCandidate(excluding: selected) == nil)
        #expect(admission.remove(live[0]) == selected)
        #expect(admission.remove(live[1]) == ordinary)
    }

    @Test func energyConservationLeavesOneAutomaticPageAndAllowsExplicitInteraction() throws {
        var admission = HTMLVisualPageAdmission()
        #expect(admission.conserveEnergy(true).isEmpty)
        let automatic = UUID()
        let waiting = UUID()
        let selected = UUID()
        #expect(try admission.request(automatic, kind: .automatic))
        #expect(try !admission.request(waiting, kind: .automatic))
        #expect(try admission.request(selected, kind: .selected))
        #expect(admission.live.count == 2)
        #expect(admission.admitWaiting() == nil)
        _ = admission.conserveEnergy(false)
        #expect(admission.admitWaiting() == waiting)
        #expect(admission.live.count == 3)
        #expect(admission.conserveEnergy(true) == [waiting])
    }

    @Test func preparationYieldsItsSlotToVisibleDemand() throws {
        var admission = HTMLVisualPageAdmission()
        let visible = (0..<2).map { _ in UUID() }
        for id in visible { #expect(try admission.request(id, kind: .automatic)) }
        let preparation = UUID()
        #expect(try admission.request(preparation, kind: .preparation))
        let nextPreparation = UUID()
        let reveal = UUID()
        #expect(try !admission.request(nextPreparation, kind: .preparation))
        #expect(try !admission.request(reveal, kind: .automatic))
        #expect(admission.preparationBlocking(reveal) == preparation)
        #expect(admission.preparationBlocking(nextPreparation) == nil)
        #expect(admission.evictionCandidate(excluding: reveal) == preparation)
        #expect(admission.remove(preparation) == reveal)
        #expect(admission.preparationBlocking(nextPreparation) == nil)
        #expect(admission.remove(visible[0]) == nextPreparation)
    }

    @Test func energyConservationKeepsPreparationWithinTheReducedLimit() throws {
        var admission = HTMLVisualPageAdmission()
        let visible = UUID()
        let preparation = UUID()
        #expect(try admission.request(visible, kind: .automatic))
        #expect(try admission.request(preparation, kind: .preparation))
        #expect(admission.conserveEnergy(true) == [preparation])
        _ = admission.remove(preparation)
        _ = admission.remove(visible)
        let required = UUID()
        #expect(try admission.request(required, kind: .preparation))
        let reveal = UUID()
        #expect(try !admission.request(reveal, kind: .automatic))
        #expect(admission.preparationBlocking(reveal) == required)
        #expect(admission.remove(required) == reveal)
        let next = UUID()
        #expect(try !admission.request(next, kind: .preparation))
        #expect(admission.conserveEnergy(false).isEmpty)
        #expect(admission.admitWaiting() == next)
    }
}
