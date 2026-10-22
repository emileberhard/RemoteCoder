import Foundation
@preconcurrency import WebRTC

/// WebRTC offer/answer transport shared by the iOS call UI and the headless
/// realtime probe. OpenAI owns signaling after the local offer is created.
@MainActor
final class RealtimeWebRTCSession: NSObject {
    struct MediaStatistics: Equatable, Sendable {
        let outboundAudioBytes: UInt64
        let outboundAudioPackets: UInt64
        let inboundAudioBytes: UInt64
        let inboundAudioPackets: UInt64
    }

    enum SessionError: LocalizedError {
        case peerConnectionCreationFailed
        case audioTrackCreationFailed
        case dataChannelCreationFailed
        case missingOffer
        case connectionFailed
        case connectionTimedOut
        case conflictingAnswer
        case closed

        var errorDescription: String? {
            switch self {
            case .peerConnectionCreationFailed:
                "Could not create the realtime audio connection."
            case .audioTrackCreationFailed:
                "Could not attach the microphone to the realtime call."
            case .dataChannelCreationFailed:
                "Could not create the realtime event channel."
            case .missingOffer:
                "The realtime audio connection returned no SDP offer."
            case .connectionFailed:
                "The realtime audio connection failed."
            case .connectionTimedOut:
                "The realtime audio connection timed out."
            case .conflictingAnswer:
                "The realtime audio connection received conflicting answers."
            case .closed:
                "The realtime audio connection was closed."
            }
        }
    }

    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory()
    }()

    var onICEConnectionStateChange: ((RTCIceConnectionState) -> Void)?
    var onICEGatheringStateChange: ((RTCIceGatheringState) -> Void)?

    private var peerConnection: RTCPeerConnection?
    private var localAudioTrack: RTCAudioTrack?
    private var eventsDataChannel: RTCDataChannel?
    private var acceptedAnswerSDP: String?
    private var connectionContinuation: CheckedContinuation<Void, Error>?
    private var connectionTimeoutTask: Task<Void, Never>?

    private(set) var iceConnectionState: RTCIceConnectionState = .new

    var hasRemoteDescription: Bool {
        peerConnection?.remoteDescription != nil
    }

    func createOffer(inputEnabled: Bool) async throws -> String {
        close()
        iceConnectionState = .new

        let configuration = RTCConfiguration()
        configuration.sdpSemantics = .unifiedPlan
        configuration.continualGatheringPolicy = .gatherOnce
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: ["DtlsSrtpKeyAgreement": "true"]
        )
        guard let peer = Self.factory.peerConnection(
            with: configuration,
            constraints: constraints,
            delegate: self
        ) else {
            throw SessionError.peerConnectionCreationFailed
        }
        peerConnection = peer

        let audioSource = Self.factory.audioSource(with: RTCMediaConstraints(
            mandatoryConstraints: [
                "googEchoCancellation": "true",
                "googAutoGainControl": "true",
                "googNoiseSuppression": "true",
            ],
            optionalConstraints: nil
        ))
        let track = Self.factory.audioTrack(
            with: audioSource,
            trackId: "remote-coder-microphone"
        )
        guard peer.add(track, streamIds: ["remote-coder-audio"]) != nil else {
            close()
            throw SessionError.audioTrackCreationFailed
        }
        track.isEnabled = inputEnabled
        localAudioTrack = track

        guard let channel = peer.dataChannel(
            forLabel: "oai-events",
            configuration: RTCDataChannelConfiguration()
        ) else {
            close()
            throw SessionError.dataChannelCreationFailed
        }
        eventsDataChannel = channel

        let offer = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<RTCSessionDescription, Error>) in
            peer.offer(for: RTCMediaConstraints(
                mandatoryConstraints: [
                    "OfferToReceiveAudio": "true",
                    "OfferToReceiveVideo": "false",
                ],
                optionalConstraints: nil
            )) { offer, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let offer {
                    continuation.resume(returning: offer)
                } else {
                    continuation.resume(throwing: SessionError.missingOffer)
                }
            }
        }
        try Task.checkCancellation()
        guard peerConnection === peer else { throw SessionError.closed }
        try await setLocalDescription(offer, on: peer)
        try Task.checkCancellation()
        guard peerConnection === peer else { throw SessionError.closed }
        guard !offer.sdp.isEmpty else {
            close()
            throw SessionError.missingOffer
        }
        // OpenAI's unified WebRTC flow expects the original offer immediately;
        // ICE continues gathering while the backend creates the call.
        return offer.sdp
    }

    func applyAnswer(_ sdp: String) async throws {
        if let acceptedAnswerSDP {
            guard acceptedAnswerSDP != sdp else { return }
            throw SessionError.conflictingAnswer
        }
        guard let peerConnection else { throw SessionError.closed }
        acceptedAnswerSDP = sdp
        do {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                peerConnection.setRemoteDescription(
                    RTCSessionDescription(type: .answer, sdp: sdp)
                ) { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume(returning: ())
                    }
                }
            }
        } catch {
            if acceptedAnswerSDP == sdp {
                acceptedAnswerSDP = nil
            }
            throw error
        }
    }

    func setInputEnabled(_ enabled: Bool) {
        localAudioTrack?.isEnabled = enabled
    }

    func mediaStatistics() async throws -> MediaStatistics {
        guard let peerConnection else { throw SessionError.closed }
        return await withCheckedContinuation { continuation in
            peerConnection.statistics { report in
                var outboundBytes: UInt64 = 0
                var outboundPackets: UInt64 = 0
                var inboundBytes: UInt64 = 0
                var inboundPackets: UInt64 = 0

                for statistic in report.statistics.values {
                    let kind = statistic.values["kind"] as? String
                        ?? statistic.values["mediaType"] as? String
                    guard kind == "audio" else { continue }

                    switch statistic.type {
                    case "outbound-rtp":
                        outboundBytes += Self.unsignedValue(
                            statistic.values["bytesSent"]
                        )
                        outboundPackets += Self.unsignedValue(
                            statistic.values["packetsSent"]
                        )
                    case "inbound-rtp":
                        inboundBytes += Self.unsignedValue(
                            statistic.values["bytesReceived"]
                        )
                        inboundPackets += Self.unsignedValue(
                            statistic.values["packetsReceived"]
                        )
                    default:
                        continue
                    }
                }

                continuation.resume(returning: MediaStatistics(
                    outboundAudioBytes: outboundBytes,
                    outboundAudioPackets: outboundPackets,
                    inboundAudioBytes: inboundBytes,
                    inboundAudioPackets: inboundPackets
                ))
            }
        }
    }

    func waitUntilConnected(timeout: Duration) async throws {
        switch iceConnectionState {
        case .connected, .completed:
            return
        case .failed:
            throw SessionError.connectionFailed
        case .closed:
            throw SessionError.closed
        default:
            break
        }

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                connectionContinuation = continuation
                connectionTimeoutTask = Task { @MainActor [weak self] in
                    do {
                        try await Task.sleep(for: timeout)
                    } catch {
                        return
                    }
                    self?.finishConnectionWait(.failure(SessionError.connectionTimedOut))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finishConnectionWait(.failure(CancellationError()))
            }
        }
    }

    func close() {
        finishConnectionWait(.failure(SessionError.closed))
        eventsDataChannel?.close()
        eventsDataChannel = nil
        peerConnection?.close()
        peerConnection = nil
        localAudioTrack = nil
        acceptedAnswerSDP = nil
        iceConnectionState = .closed
    }

    private func setLocalDescription(
        _ description: RTCSessionDescription,
        on peer: RTCPeerConnection
    ) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            peer.setLocalDescription(description) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func finishConnectionWait(_ result: Result<Void, Error>) {
        guard let continuation = connectionContinuation else { return }
        connectionContinuation = nil
        connectionTimeoutTask?.cancel()
        connectionTimeoutTask = nil
        continuation.resume(with: result)
    }

    nonisolated private static func unsignedValue(_ value: NSObject?) -> UInt64 {
        (value as? NSNumber)?.uint64Value ?? 0
    }
}

extension RealtimeWebRTCSession: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didChange stateChanged: RTCSignalingState
    ) {}

    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didAdd stream: RTCMediaStream
    ) {}

    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didRemove stream: RTCMediaStream
    ) {}

    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didChange newState: RTCIceConnectionState
    ) {
        let peerID = ObjectIdentifier(peerConnection)
        Task { @MainActor [weak self] in
            guard let self, self.peerConnection.map(ObjectIdentifier.init) == peerID else { return }
            iceConnectionState = newState
            onICEConnectionStateChange?(newState)
            switch newState {
            case .connected, .completed:
                finishConnectionWait(.success(()))
            case .failed:
                finishConnectionWait(.failure(SessionError.connectionFailed))
            case .closed:
                finishConnectionWait(.failure(SessionError.closed))
            default:
                break
            }
        }
    }

    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didChange newState: RTCIceGatheringState
    ) {
        let peerID = ObjectIdentifier(peerConnection)
        Task { @MainActor [weak self] in
            guard let self, self.peerConnection.map(ObjectIdentifier.init) == peerID else { return }
            onICEGatheringStateChange?(newState)
        }
    }

    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didGenerate candidate: RTCIceCandidate
    ) {}

    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didRemove candidates: [RTCIceCandidate]
    ) {}

    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didOpen dataChannel: RTCDataChannel
    ) {}
}
