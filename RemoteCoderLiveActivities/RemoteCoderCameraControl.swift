import SwiftUI
import WidgetKit

struct RemoteCoderCameraControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "emileberhard.RemoteCoder.camera") {
            ControlWidgetButton(action: RemoteCoderCameraCaptureIntent()) {
                Label("RemoteCoder", systemImage: "camera")
            }
        }
        .displayName("RemoteCoder Camera")
        .description("Attach a photo to a new chat.")
    }
}
