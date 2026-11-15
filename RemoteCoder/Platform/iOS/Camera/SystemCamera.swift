import Photos
import SwiftUI
import UIKit

struct SystemCamera: UIViewControllerRepresentable {
    @MainActor static let isAvailable = UIImagePickerController.isSourceTypeAvailable(.camera)

    let onFinish: @MainActor (CameraPhoto?) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onFinish: onFinish) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {
        context.coordinator.onFinish = onFinish
    }

    @MainActor
    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        var onFinish: @MainActor (CameraPhoto?) -> Void

        init(onFinish: @escaping @MainActor (CameraPhoto?) -> Void) {
            self.onFinish = onFinish
        }

        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            onFinish((info[.originalImage] as? UIImage).map(CameraPhoto.init))
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            onFinish(nil)
        }
    }
}

struct CameraPhoto: Sendable {
    let image: UIImage

    @concurrent
    func writeFile() async throws -> URL {
        guard let data = image.jpegData(compressionQuality: 0.9) else {
            throw Failure(errorDescription: "The camera returned a photo that could not be encoded.")
        }
        return try DeferredImportFile.scratchFile(named: "photo-\(UUID().uuidString.prefix(8).lowercased()).jpg",
                                                  containing: data)
    }

    @concurrent
    static func saveToPhotos(_ file: URL) async throws {
        guard await PHPhotoLibrary.requestAuthorization(for: .addOnly) == .authorized else {
            throw Failure(errorDescription: "RemoteCoder may not add photos to your library.")
        }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .photo, fileURL: file, options: nil)
        }
    }

    private struct Failure: LocalizedError {
        let errorDescription: String?
    }
}
