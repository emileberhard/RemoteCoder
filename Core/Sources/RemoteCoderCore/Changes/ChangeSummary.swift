import Foundation

struct ChangeSummary: Decodable, Sendable {
    enum Evidence: String, Decodable, Sendable {
        case edited, command, workingFolder
    }

    struct Checkout: Decodable, Sendable {
        enum Outcome: Sendable {
            case ready(ChangeSnapshot)
            case unavailable(ChangeUnavailability)
            case failed
        }

        let root: String
        let evidence: Set<Evidence>
        let outcome: Outcome

        private enum CodingKeys: String, CodingKey {
            case root, evidence, status, snapshot, reason
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            root = try container.decode(String.self, forKey: .root)
            evidence = try container.decode(Set<Evidence>.self, forKey: .evidence)
            switch try container.decode(String.self, forKey: .status) {
            case "ready": outcome = .ready(try container.decode(ChangeSnapshot.self, forKey: .snapshot))
            case "unavailable": outcome = .unavailable(try container.decode(ChangeUnavailability.self, forKey: .reason))
            case "failed": outcome = .failed
            case let status:
                throw DecodingError.dataCorruptedError(forKey: .status, in: container,
                                                       debugDescription: "Unknown checkout summary status \(status)")
            }
        }
    }

    let workedIn: [Checkout]
    let inFolder: [String]
    let complete: Bool
}

struct PreparedChangeSummary: Equatable, Sendable {
    struct Checkout: Equatable, Sendable {
        let root: String
        let evidence: Set<ChangeSummary.Evidence>
        let totals: ChangeTotals?
    }

    struct Primary: Equatable, Sendable {
        let root: String
        let source: ChangeSource
    }

    let workedIn: [Checkout]
    let inFolder: [String]
    let complete: Bool
    let totals: ChangeTotals
    let primary: Primary?

    init(_ summary: ChangeSummary) {
        var primary: Primary?
        workedIn = summary.workedIn.map { checkout in
            let totals: ChangeTotals?
            switch checkout.outcome {
            case .ready(let snapshot):
                totals = ChangeTotals(snapshot)
                if primary == nil, let totals, totals.files > 0 {
                    primary = Primary(root: checkout.root, source: snapshot.source)
                }
            case .unavailable, .failed:
                totals = nil
            }
            return Checkout(root: checkout.root, evidence: checkout.evidence, totals: totals)
        }
        inFolder = summary.inFolder
        complete = summary.complete
        totals = ChangeTotals(summing: workedIn.lazy.map(\.totals))
        self.primary = primary
    }
}
