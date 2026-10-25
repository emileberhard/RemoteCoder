import AVFoundation
import Dispatch
import Foundation
import OSLog
import UIKit

struct AgentPhotoCapture: DeviceTool {
    let isForeground: @MainActor @Sendable () -> Bool
    var declaration: DeviceToolsDeclare.Tool { .init(name: "take_photo", version: 1) }

    func execute(arguments: JSONValue, context: DeviceToolContext) async throws -> DeviceToolOutput {
        let selection: TakePhotoArguments
        do { selection = try JSONDecoder().decode(TakePhotoArguments.self, from: JSONEncoder().encode(arguments)) }
        catch { throw DeviceToolRefusal(reason: .invalidArguments, detail: "Use camera back, front or both and lens wide, ultra_wide or telephoto. Non-wide lenses are back-only.") }
        try await requireForeground()
        try context.checkCanStart()
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                throw DeviceToolRefusal(reason: .permissionDenied, detail: "Camera access for RemoteCoder is off in iOS Settings.")
            }
        case .authorized: break
        case .denied, .restricted:
            throw DeviceToolRefusal(reason: .permissionDenied, detail: "Camera access for RemoteCoder is off in iOS Settings.")
        @unknown default:
            throw CaptureFailure(message: "The camera authorization status is unknown.")
        }
        try context.checkCanStart()
        try await requireForeground()
        var content: [DeviceToolContent] = []
        var captures: [(camera: PhotoCamera, lens: PhotoLens, photo: CapturedAgentPhoto)] = []
        var originals: [DeviceToolOriginal] = []
        var uploadFailures: [String] = []
        for capture in selection.captures {
            try context.checkCanStart()
            try await requireForeground()
            let photo = try await AgentPhotoSession().capture(camera: capture.camera, lens: capture.lens,
                                                             context: context, isForeground: isForeground)
            try Task.checkCancellation()
            let model = try await ImagePreparation.shared.deviceToolPhoto(from: photo.data)
            content.append(.image(mimeType: "image/jpeg", data: model.data.base64EncodedString()))
            captures.append((capture.camera, capture.lens, photo))
        }
        for capture in captures {
            do {
                let original = try await upload(capture.photo, camera: capture.camera, lens: capture.lens, context: context)
                originals.append(original)
            } catch {
                if Task.isCancelled || error is CancellationError { throw CancellationError() }
                let failure = "\(capture.camera.rawValue.capitalized) original was not saved: \(error.localizedDescription)"
                uploadFailures.append(failure)
            }
        }
        return DeviceToolOutput(content: content, originals: originals,
                                detail: uploadFailures.isEmpty ? nil : uploadFailures.joined(separator: "\n"))
    }

    private func requireForeground() async throws {
        guard await isForeground() else {
            throw DeviceToolRefusal(reason: .foregroundRequired, detail: "RemoteCoder must be open on the iPhone screen to use the camera.")
        }
        try Task.checkCancellation()
    }

    @concurrent
    private func upload(_ photo: CapturedAgentPhoto, camera: PhotoCamera, lens: PhotoLens,
                        context: DeviceToolContext) async throws -> DeviceToolOriginal {
        let directory = FileManager.default.temporaryDirectory.appending(path: "agent-photo-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { AppLogger(category: "DeviceTools").error("Photo staging cleanup failed: \(error.localizedDescription)") }
        }
        let name = "\(camera.rawValue)-\(lens.rawValue).jpg"
        let file = directory.appending(path: name)
        try photo.data.write(to: file)
        let uploaded = try await context.uploadOriginal(file, name: name)
        try Task.checkCancellation()
        return DeviceToolOriginal(path: uploaded.path, sha256: uploaded.sha256, bytes: uploaded.bytes,
                                  camera: camera, lens: lens, width: photo.width, height: photo.height)
    }
}

struct CaptureFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct CapturedAgentPhoto: Sendable {
    let data: Data
    let width: Int
    let height: Int
}

private actor AgentPhotoSession {
    private nonisolated let queue = DispatchSerialQueue(label: "RemoteCoder.AgentPhotoSession")
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()
    private var delegate: AgentPhotoDelegate?

    func capture(camera: PhotoCamera, lens: PhotoLens, context: DeviceToolContext,
                 isForeground: @escaping @MainActor @Sendable () -> Bool) async throws -> CapturedAgentPhoto {
        try context.checkCanStart()
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera],
            mediaType: .video, position: camera == .back ? .back : .front)
        guard !discovery.devices.isEmpty else {
            throw DeviceToolRefusal(reason: .cameraUnavailable, detail: "The \(camera.rawValue) camera is unavailable.")
        }
        guard let device = discovery.devices.first(where: { $0.deviceType == lens.deviceType }) else {
            let available = PhotoLens.allCases.filter { lens in
                discovery.devices.contains { $0.deviceType == lens.deviceType }
            }.map(\.rawValue).joined(separator: ", ")
            throw DeviceToolRefusal(reason: .lensUnavailable, detail: "Available \(camera.rawValue) lenses: \(available).")
        }
        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        session.automaticallyConfiguresApplicationAudioSession = false
        session.sessionPreset = .photo
        guard session.canAddInput(input), session.canAddOutput(output) else {
            session.commitConfiguration()
            throw CaptureFailure(message: "The photo capture session could not be configured.")
        }
        session.addInput(input)
        session.addOutput(output)
        session.commitConfiguration()
        guard let dimensions = device.activeFormat.supportedMaxPhotoDimensions.max(by: {
            Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height)
        }) else { throw CaptureFailure(message: "The camera reports no supported photo dimensions.") }
        output.maxPhotoDimensions = dimensions
        let rotation = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        let stream = AsyncThrowingStream<CapturedAgentPhoto, Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let background = NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification,
            object: nil, queue: nil) { _ in
                stream.continuation.finish(throwing: DeviceToolRefusal(reason: .foregroundRequired,
                    detail: "RemoteCoder left the foreground during photo capture."))
            }
        let interruption = NotificationCenter.default.addObserver(forName: AVCaptureSession.wasInterruptedNotification,
            object: session, queue: nil) { _ in
                stream.continuation.finish(throwing: CaptureFailure(message: "Photo capture was interrupted."))
            }
        let runtimeError = NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification,
            object: session, queue: nil) { _ in
                stream.continuation.finish(throwing: CaptureFailure(message: "The camera capture session failed."))
            }
        defer {
            NotificationCenter.default.removeObserver(background)
            NotificationCenter.default.removeObserver(interruption)
            NotificationCenter.default.removeObserver(runtimeError)
            session.stopRunning()
            delegate = nil
        }
        return try await withTaskCancellationHandler {
            session.startRunning()
            guard session.isRunning else { throw CaptureFailure(message: "The camera could not start.") }
            try await Task.sleep(for: .milliseconds(350))
            try context.checkCanStart()
            guard await isForeground() else {
                throw DeviceToolRefusal(reason: .foregroundRequired, detail: "RemoteCoder must be open on the iPhone screen to use the camera.")
            }
            try context.checkCanStart()
            guard let connection = output.connection(with: .video) else { throw CaptureFailure(message: "The camera has no video connection.") }
            let angle = rotation.videoRotationAngleForHorizonLevelCapture
            guard connection.isVideoRotationAngleSupported(angle) else { throw CaptureFailure(message: "The camera cannot apply its capture orientation.") }
            connection.videoRotationAngle = angle
            let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
            settings.maxPhotoDimensions = dimensions
            let delegate = AgentPhotoDelegate(continuation: stream.continuation)
            self.delegate = delegate
            await MainActor.run { HapticService.shared.play(.photoCapture) }
            try context.checkCanStart()
            guard session.isRunning, !session.isInterrupted else { throw CaptureFailure(message: "Photo capture was interrupted.") }
            guard await isForeground() else { throw DeviceToolRefusal(reason: .foregroundRequired, detail: "RemoteCoder left the foreground during photo capture.") }
            try context.checkCanStart()
            output.capturePhoto(with: settings, delegate: delegate)
            let deadline = Task {
                do {
                    let remaining = max(0, context.deadlineUnixMs - Int64(Date.now.timeIntervalSince1970 * 1_000))
                    try await Task.sleep(for: .milliseconds(remaining))
                    stream.continuation.finish(throwing: CaptureFailure(message: "The camera did not finish before the device tool deadline."))
                } catch {}
            }
            defer { deadline.cancel() }
            for try await photo in stream.stream { return photo }
            throw CaptureFailure(message: "The camera finished without a photo.")
        } onCancel: {
            stream.continuation.finish(throwing: CancellationError())
        }
    }
}

private extension PhotoLens {
    var deviceType: AVCaptureDevice.DeviceType {
        switch self {
        case .wide: .builtInWideAngleCamera
        case .ultraWide: .builtInUltraWideCamera
        case .telephoto: .builtInTelephotoCamera
        }
    }
}
