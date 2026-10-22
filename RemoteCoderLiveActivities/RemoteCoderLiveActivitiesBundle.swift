import SwiftUI
import WidgetKit

@main
struct RemoteCoderLiveActivitiesBundle: WidgetBundle {
    var body: some Widget {
        RemoteCoderActiveTasksWidget()
        RemoteCoderVoiceCallWidget()
        RemoteCoderCameraControl()
    }
}
