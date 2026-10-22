import AVFoundation
import Dispatch
import Foundation
import CoreGraphics
import Synchronization

actor CameraCaptureSession {
    private nonisolated let queue = DispatchSerialQueue(label: "RemoteCoder.CameraCaptureSession")
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }
    nonisolated let preview: CameraPreviewSource

    private let session: AVCaptureSession
    private let output = AVCapturePhotoOutput()
    private var controls: CameraControlsDelegate?
    private var updates: AsyncStream<CameraCaptureUpdate>.Continuation?
    private var input: AVCaptureDeviceInput?
    private var zoomObservation: NSKeyValueObservation?
    private var rotation: AVCaptureDevice.RotationCoordinator?
    private var generation: UUID?
    private var captures: [Int64: AsyncThrowingStream<Data, Error>.Continuation] = [:]
    private var delegates: [Int64: CameraPhotoDelegate] = [:]
    private var readiness: AVCapturePhotoOutputReadinessCoordinator?
    private var readinessDelegate: CameraReadinessDelegate?
    private var isConfigured = false

    init() {
        let session = AVCaptureSession()
        self.session = session
        preview = CameraPreviewSource(session: session)
    }

    func start(generation: UUID) async throws -> AsyncStream<CameraCaptureUpdate> {
        self.generation = generation
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .video) else {
                throw CameraCaptureError("Camera access for RemoteCoder is off in Settings.")
            }
        case .authorized: break
        case .denied, .restricted:
            throw CameraCaptureError("Camera access for RemoteCoder is off in Settings.")
        @unknown default: throw CameraCaptureError("The camera permission status is unknown.")
        }
        try Task.checkCancellation()
        guard self.generation == generation else { throw CancellationError() }
        let fullscreen = AsyncStream<CameraCaptureUpdate>.makeStream(bufferingPolicy: .bufferingNewest(8))
        updates = fullscreen.continuation
        if !isConfigured { try configure() }
        else if let device = input?.device { observeZoom(of: device) }
        let controls = CameraControlsDelegate(continuation: fullscreen.continuation)
        self.controls = controls
        if session.supportsControls { session.setControlsDelegate(controls, queue: queue) }
        let readiness = AVCapturePhotoOutputReadinessCoordinator(photoOutput: output)
        let readinessDelegate = CameraReadinessDelegate(continuation: fullscreen.continuation)
        self.readiness = readiness
        self.readinessDelegate = readinessDelegate
        readiness.delegate = readinessDelegate
        session.startRunning()
        guard session.isRunning else { throw CameraCaptureError("The camera could not start.") }
        publishConfiguration()
        return fullscreen.stream
    }

    func stop(generation: UUID) {
        guard self.generation == generation else { return }
        self.generation = nil
        for capture in captures.values { capture.finish(throwing: CancellationError()) }
        readiness?.delegate = nil
        readiness = nil
        readinessDelegate = nil
        session.stopRunning()
        controls?.finish()
        controls = nil
        updates?.finish()
        updates = nil
        zoomObservation = nil
    }

    func takePhoto(id: UUID, into directory: URL, flash: AVCaptureDevice.FlashMode) async throws -> CameraCapturedPhoto {
        try Task.checkCancellation()
        guard session.isRunning, !session.isInterrupted, captures.count < 2, output.captureReadiness == .ready,
              let connection = output.connection(with: .video), let rotation else {
            throw CameraCaptureError("The camera is not ready to take a photo.")
        }
        let angle = rotation.videoRotationAngleForHorizonLevelCapture
        guard connection.isVideoRotationAngleSupported(angle) else {
            throw CameraCaptureError("The camera cannot apply the photo orientation.")
        }
        connection.videoRotationAngle = angle
        let codec: AVVideoCodecType = output.availablePhotoCodecTypes.contains(.hevc) ? .hevc : .jpeg
        let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: codec])
        settings.maxPhotoDimensions = output.maxPhotoDimensions
        settings.photoQualityPrioritization = .quality
        if let thumbnailCodec = settings.availableEmbeddedThumbnailPhotoCodecTypes.first {
            settings.embeddedThumbnailPhotoFormat = [
                AVVideoCodecKey: thumbnailCodec, AVVideoWidthKey: 512, AVVideoHeightKey: 512,
            ]
        }
        if output.supportedFlashModes.contains(flash) { settings.flashMode = flash }
        let captureID = settings.uniqueID
        let result = AsyncThrowingStream<Data, Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let delegate = CameraPhotoDelegate(continuation: result.continuation)
        delegates[captureID] = delegate
        captures[captureID] = result.continuation
        let observers = [AVCaptureSession.wasInterruptedNotification, AVCaptureSession.runtimeErrorNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: session, queue: nil) { _ in
                result.continuation.finish(throwing: CameraCaptureError("Photo capture was interrupted."))
            }
        }
        defer {
            observers.forEach(NotificationCenter.default.removeObserver)
            delegates[captureID] = nil
            captures[captureID] = nil
        }
        return try await withTaskCancellationHandler {
            output.capturePhoto(with: settings, delegate: delegate)
            for try await data in result.stream {
                let folder = directory.appending(path: id.uuidString, directoryHint: .isDirectory)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                let file = folder.appending(path: "Photo.\(codec == .hevc ? "heic" : "jpg")")
                try data.write(to: file, options: .atomic)
                return CameraCapturedPhoto(id: id, file: file)
            }
            throw CameraCaptureError("The camera finished without a photo.")
        } onCancel: {
            result.continuation.finish(throwing: CancellationError())
        }
    }

    private func configure() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.automaticallyConfiguresApplicationAudioSession = false
        session.sessionPreset = .photo
        guard session.canAddOutput(output) else {
            throw CameraCaptureError("The photo capture session could not be configured.")
        }
        session.addOutput(output)
        output.maxPhotoQualityPrioritization = .quality
        try setCamera(.back)
        isConfigured = true
    }

    func flipCamera() throws {
        guard captures.isEmpty else { throw CameraCaptureError("A photo is still being captured.") }
        session.beginConfiguration()
        do { try setCamera(input?.device.position == .front ? .back : .front) }
        catch {
            session.commitConfiguration()
            throw error
        }
        session.commitConfiguration()
        publishConfiguration()
    }

    func setZoom(_ zoom: Double) throws {
        try Task.checkCancellation()
        guard let device = input?.device else { throw CameraCaptureError("The camera is unavailable.") }
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }
        device.videoZoomFactor = min(max(CGFloat(zoom), device.minAvailableVideoZoomFactor), device.maxAvailableVideoZoomFactor)
    }

    private func setCamera(_ position: AVCaptureDevice.Position) throws {
        let types: [AVCaptureDevice.DeviceType] = position == .back
            ? [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
            : [.builtInTrueDepthCamera, .builtInWideAngleCamera]
        let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: position)
        guard let device = types.lazy.compactMap({ type in discovery.devices.first { $0.deviceType == type } }).first else {
            throw CameraCaptureError("The selected camera is unavailable.")
        }
        let replacement = try AVCaptureDeviceInput(device: device)
        let previous = input
        if let previous { session.removeInput(previous) }
        guard session.canAddInput(replacement) else {
            if let previous { session.addInput(previous) }
            throw CameraCaptureError("The selected camera could not be configured.")
        }
        session.addInput(replacement)
        input = replacement
        guard let dimensions = device.activeFormat.supportedMaxPhotoDimensions.max(by: {
            Int64($0.width) * Int64($0.height) < Int64($1.width) * Int64($1.height)
        }) else { throw CameraCaptureError("The camera reports no supported photo dimensions.") }
        output.maxPhotoDimensions = dimensions
        output.isResponsiveCaptureEnabled = output.isResponsiveCaptureSupported
        output.isFastCapturePrioritizationEnabled = output.isFastCapturePrioritizationSupported
        rotation = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        preview.setDevice(device)
        for control in session.controls { session.removeControl(control) }
        if session.supportsControls {
            let sliders: [AVCaptureControl] = [
                AVCaptureSystemZoomSlider(device: device),
                AVCaptureSystemExposureBiasSlider(device: device),
            ]
            for slider in sliders where session.canAddControl(slider) { session.addControl(slider) }
        }
        try setZoom(Double(1 / device.displayVideoZoomFactorMultiplier))
        observeZoom(of: device)
    }

    private func observeZoom(of device: AVCaptureDevice) {
        let updates = updates
        zoomObservation = device.observe(\.videoZoomFactor, options: [.initial, .new]) { device, _ in
            updates?.yield(.zoom(Double(device.videoZoomFactor)))
        }
    }

    private func publishConfiguration() {
        guard let device = input?.device else { return }
        let switchovers = device.virtualDeviceSwitchOverVideoZoomFactors.map(\.doubleValue)
        var factors = [Double(device.minAvailableVideoZoomFactor)] + switchovers
            + device.activeFormat.secondaryNativeResolutionZoomFactors.map(Double.init)
        for (index, constituent) in device.constituentDevices.enumerated() {
            let base = index == 0 ? 1 : switchovers[index - 1]
            factors += constituent.activeFormat.secondaryNativeResolutionZoomFactors.map { Double($0) * base }
        }
        let lenses = Array(Set(factors.filter {
            $0 >= Double(device.minAvailableVideoZoomFactor) && $0 <= Double(device.maxAvailableVideoZoomFactor)
        })).sorted()
        updates?.yield(.configuration(CameraConfiguration(
            lenses: lenses, zoom: Double(device.videoZoomFactor),
            displayMultiplier: Double(device.displayVideoZoomFactorMultiplier),
            flashModes: output.supportedFlashModes,
            deviceID: device.uniqueID)))
    }
}

struct CameraConfiguration: Sendable {
    let lenses: [Double]
    let zoom: Double
    let displayMultiplier: Double
    let flashModes: [AVCaptureDevice.FlashMode]
    let deviceID: String
}

enum CameraCaptureUpdate: Sendable {
    case configuration(CameraConfiguration)
    case zoom(Double)
    case fullscreen(Bool)
    case ready(Bool)
}

struct CameraCapturedPhoto: Identifiable, Sendable {
    let id: UUID
    let file: URL
    var thumbnail: CGImage?
    var saveFailure: String?
}

struct CameraCaptureError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

private final class CameraPhotoDelegate: NSObject, AVCapturePhotoCaptureDelegate, Sendable {
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private let data = Mutex<Result<Data, Error>?>(nil)

    init(continuation: AsyncThrowingStream<Data, Error>.Continuation) {
        self.continuation = continuation
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        let result: Result<Data, Error>
        if let error { result = .failure(error) }
        else if let data = photo.fileDataRepresentation(), !data.isEmpty { result = .success(data) }
        else { result = .failure(CameraCaptureError("The camera returned no photo data.")) }
        data.withLock { $0 = result }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        if let error { continuation.finish(throwing: error) }
        else if let result = data.withLock({ $0 }) {
            switch result {
            case .success(let data):
                continuation.yield(data)
                continuation.finish()
            case .failure(let error): continuation.finish(throwing: error)
            }
        } else { continuation.finish(throwing: CameraCaptureError("The camera finished without processed photo data.")) }
    }
}

private final class CameraControlsDelegate: NSObject, AVCaptureSessionControlsDelegate, Sendable {
    private let continuation: AsyncStream<CameraCaptureUpdate>.Continuation
    init(continuation: AsyncStream<CameraCaptureUpdate>.Continuation) { self.continuation = continuation }
    func finish() { continuation.finish() }
    func sessionControlsDidBecomeActive(_ session: AVCaptureSession) {}
    func sessionControlsDidBecomeInactive(_ session: AVCaptureSession) { continuation.yield(.fullscreen(false)) }
    func sessionControlsWillEnterFullscreenAppearance(_ session: AVCaptureSession) { continuation.yield(.fullscreen(true)) }
    func sessionControlsWillExitFullscreenAppearance(_ session: AVCaptureSession) { continuation.yield(.fullscreen(false)) }
}

private final class CameraReadinessDelegate: NSObject, AVCapturePhotoOutputReadinessCoordinatorDelegate, Sendable {
    private let continuation: AsyncStream<CameraCaptureUpdate>.Continuation
    init(continuation: AsyncStream<CameraCaptureUpdate>.Continuation) { self.continuation = continuation }
    func readinessCoordinator(_ coordinator: AVCapturePhotoOutputReadinessCoordinator, captureReadinessDidChange readiness: AVCapturePhotoOutput.CaptureReadiness) {
        continuation.yield(.ready(readiness == .ready))
    }
}
