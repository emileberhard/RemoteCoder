import LockedCameraCapture
import ExtensionKit
import SwiftUI

@main
struct RemoteCoderCaptureExtension: @MainActor LockedCameraCaptureExtension {
    var body: some LockedCameraCaptureExtensionScene {
        LockedCameraCaptureUIScene { session in
            LockedCameraView(session: session)
        }
    }
}

private struct LockedCameraView: View {
    let session: LockedCameraCaptureSession

    var body: some View {
        CameraCaptureView(directory: session.sessionContentURL, onDone: { files in
            try await Self.confirm(files, in: session.sessionContentURL)
            do {
                try await session.openApplication(for: NSUserActivity(activityType: NSUserActivityTypeLockedCameraCapture))
            } catch {
                throw CameraCaptureError("Photos waiting for RemoteCoder. \(error.localizedDescription)")
            }
        }, dismissal: .system)
        .environment(\.scenePhase, .active)
    }

    @concurrent private static func confirm(_ files: [URL], in directory: URL) async throws {
        try CameraCaptureBatch.confirm(files, in: directory)
    }
}
