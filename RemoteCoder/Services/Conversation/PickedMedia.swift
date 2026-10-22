import CoreTransferable
import Foundation
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

extension DeferredImportFile {
    static func photo(_ item: PhotosPickerItem) -> DeferredImportFile {
        inOwnDirectory {
            guard let media = try await item.loadTransferable(type: PickedMedia.self) else {
                throw UploadStaging.Failure(message: "Could not load the selected item from Photos.")
            }
            return media.url
        }
    }
}

private struct PickedMedia: Transferable, Sendable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie, importing: copy)
        FileRepresentation(importedContentType: .image, importing: copy)
    }

    private static func copy(_ received: ReceivedTransferredFile) throws -> PickedMedia {
        // Photos owns the supplied URL only for this import callback.
        PickedMedia(url: try DeferredImportFile.scratchCopy(of: received.file))
    }
}
