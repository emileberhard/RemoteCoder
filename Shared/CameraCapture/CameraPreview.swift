import AVFoundation
import SwiftUI
import Synchronization
import UIKit

final class CameraPreviewSource: @unchecked Sendable {
    private let session: AVCaptureSession
    private let device = Mutex<CameraPreviewDevice?>(nil)

    init(session: AVCaptureSession) { self.session = session }

    func setDevice(_ device: AVCaptureDevice) {
        let reference = CameraPreviewDevice(device: device)
        self.device.withLock { $0 = reference }
    }

    @MainActor
    fileprivate func connect(to layer: AVCaptureVideoPreviewLayer) {
        layer.session = session
    }

    @MainActor
    fileprivate func updateRotation(of view: CameraPreviewView) {
        if let device = device.withLock({ $0 }) { view.setDevice(device.device) }
    }
}

private final class CameraPreviewDevice: @unchecked Sendable {
    let device: AVCaptureDevice
    init(device: AVCaptureDevice) { self.device = device }
}

struct CameraPreview: UIViewRepresentable {
    let source: CameraPreviewSource
    let deviceID: String?

    func makeUIView(context: Context) -> CameraPreviewView {
        let view = CameraPreviewView()
        source.connect(to: view.previewLayer)
        return view
    }

    func updateUIView(_ view: CameraPreviewView, context: Context) {
        if deviceID != nil { source.updateRotation(of: view) }
    }

    static func dismantleUIView(_ view: CameraPreviewView, coordinator: ()) {
        view.previewLayer.session = nil
    }
}

final class CameraPreviewView: UIView {
    let previewLayer = AVCaptureVideoPreviewLayer()
    private var rotation: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    private var deviceID: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        previewLayer.videoGravity = .resizeAspectFill
        layer.addSublayer(previewLayer)
    }

    required init?(coder: NSCoder) { nil }

    func setDevice(_ device: AVCaptureDevice) {
        guard deviceID != device.uniqueID else { return }
        deviceID = device.uniqueID
        let rotation = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        self.rotation = rotation
        rotationObservation = rotation.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.initial, .new]) { [weak self] coordinator, _ in
            let angle = coordinator.videoRotationAngleForHorizonLevelPreview
            Task { @MainActor [weak self] in self?.applyRotation(angle) }
        }
    }

    private func applyRotation(_ angle: CGFloat) {
        if let connection = previewLayer.connection, connection.isVideoRotationAngleSupported(angle) {
            connection.videoRotationAngle = angle
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer.frame = bounds
        if let angle = rotation?.videoRotationAngleForHorizonLevelPreview { applyRotation(angle) }
    }
}
