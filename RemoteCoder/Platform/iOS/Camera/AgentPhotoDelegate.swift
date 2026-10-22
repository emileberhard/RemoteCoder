import AVFoundation
import Foundation
import Synchronization

final class AgentPhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate, Sendable {
    private let continuation: AsyncThrowingStream<CapturedAgentPhoto, Error>.Continuation
    private let photo = Mutex<Result<CapturedAgentPhoto, Error>?>(nil)

    init(continuation: AsyncThrowingStream<CapturedAgentPhoto, Error>.Continuation) {
        self.continuation = continuation
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let result: Result<CapturedAgentPhoto, Error>
        if let error {
            result = .failure(error)
        } else if let data = photo.fileDataRepresentation(), !data.isEmpty {
            let dimensions = photo.resolvedSettings.photoDimensions
            result = .success(CapturedAgentPhoto(data: data, width: Int(dimensions.width), height: Int(dimensions.height)))
        } else {
            result = .failure(CaptureFailure(message: "The camera returned no JPEG data."))
        }
        self.photo.withLock { $0 = result }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        if let error {
            continuation.finish(throwing: error)
        } else if let result = photo.withLock({ $0 }) {
            switch result {
            case .success(let photo):
                continuation.yield(photo)
                continuation.finish()
            case .failure(let error): continuation.finish(throwing: error)
            }
        } else {
            continuation.finish(throwing: CaptureFailure(message: "The camera finished without processed photo data."))
        }
    }
}
