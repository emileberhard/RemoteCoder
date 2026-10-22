import Foundation

enum RemoteCoderAppGroup {
    static let identifier: String = {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "RemoteCoderAppGroup") as? String,
              !value.isEmpty, !value.contains("$(") else {
            preconditionFailure("RemoteCoderAppGroup must be configured in Info.plist")
        }
        return value
    }()
}
