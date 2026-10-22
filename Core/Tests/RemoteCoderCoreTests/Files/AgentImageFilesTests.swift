import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import RemoteCoderCore

struct AgentImageFilesTests {
    @Test func pastedImagesPreferAFormatAgentsCanRead() {
        #expect(AgentImageFiles.preferredType(among: [.tiff, .png]) == .png)
        #expect(AgentImageFiles.preferredType(among: [.heic, .jpeg]) == .jpeg)
        #expect(AgentImageFiles.preferredType(among: [.utf8PlainText, .tiff]) == .tiff)
        #expect(AgentImageFiles.preferredType(among: [.utf8PlainText, .pdf]) == nil)
    }

    @Test(arguments: [("IMG_0001.HEIC", "IMG_0001.jpg"), ("dropped", "dropped.jpg"), ("mislabeled.jpg", "mislabeled.jpg")])
    func stagedHEICBecomesAJPEGWithTheSameNameAndPixels(name: String, stagedName: String) async throws {
        let root = URL.temporaryDirectory.appending(path: "agent-image-files-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let heic = root.appending(path: name)
        try write(width: 40, height: 30, as: .heic, to: heic)
        let staging = UploadStaging(directory: root.appending(path: "staging"))
        let id = UUID()

        let staged = try await staging.prepare(heic, id: id)

        #expect(staged.fileName == stagedName)
        #expect(FileManager.default.fileExists(atPath: heic.path))
        let folder = staging.directory.appending(path: id.uuidString)
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path) == [stagedName])
        let source = try #require(CGImageSourceCreateWithURL(folder.appending(path: staged.fileName) as CFURL, nil))
        #expect(CGImageSourceGetType(source) as String? == UTType.jpeg.identifier)
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 40)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 30)
    }

    @Test func readableImagesAssetsAndOtherFilesAreUploadedUnchanged() throws {
        let png = try DeferredImportFile.scratchFile(named: "screenshot.png")
        let icon = try DeferredImportFile.scratchFile(named: "favicon.ico")
        let scan = try DeferredImportFile.scratchFile(named: "scan.tiff")
        let text = try DeferredImportFile.scratchFile(named: "notes.txt")
        defer {
            for file in [png, icon, scan, text] { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        }
        try write(width: 4, height: 4, as: .png, to: png)
        try write(width: 16, height: 16, as: .ico, to: icon)
        try write(width: 8, height: 8, as: .tiff, to: scan, pages: 2)
        try Data("notes".utf8).write(to: text)

        for file in [png, icon, scan, text] {
            #expect(try AgentImageFiles.readable(file) == file)
            #expect(FileManager.default.fileExists(atPath: file.path))
        }
    }

    @Test func pastedBytesKeepTheirFormatInTheirOwnDirectory() async throws {
        let data = Data("GIF89a".utf8)
        let file = try await AgentImageFiles.write(PastedImage(data: data, type: .gif))
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        #expect(file.pathExtension == "gif")
        #expect(try Data(contentsOf: file) == data)
        #expect(try FileManager.default.contentsOfDirectory(atPath: file.deletingLastPathComponent().path) == [file.lastPathComponent])
    }

    private func write(width: Int, height: Int, as type: UTType, to url: URL, pages: Int = 1) throws {
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, pages, nil))
        for _ in 0..<pages { CGImageDestinationAddImage(destination, image, nil) }
        #expect(CGImageDestinationFinalize(destination))
    }
}
