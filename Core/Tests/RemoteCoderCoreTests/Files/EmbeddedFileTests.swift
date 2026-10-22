import Foundation
import Testing
@testable import RemoteCoderCore

struct EmbeddedFileTests {
    private static let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="

    @Test func stagesBase64ImageUnderItsDescriptiveName() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let staged = try EmbeddedFile.stage(EmbeddedFileRequest(dataURL: "data:image/png;base64,\(Self.png)",
            suggestedName: "Plane work items"), in: directory)
        #expect(staged.url.lastPathComponent == "Plane work items.png")
        #expect(try Data(contentsOf: staged.url) == Data(base64Encoded: Self.png))
        #expect(staged.bytes == 70)
        staged.discard()
        #expect(!FileManager.default.fileExists(atPath: staged.url.deletingLastPathComponent().path))
        #expect(FileManager.default.fileExists(atPath: directory.path))
    }

    @Test func decodesTypeParametersAndBase64() throws {
        let (type, data) = try EmbeddedFile.decode("data:text/csv;charset=utf-8;base64,bmFtZSx2YWx1ZQphLDE=")
        #expect(type == .commaSeparatedText)
        #expect(String(decoding: data, as: UTF8.self) == "name,value\na,1")
    }

    @Test(arguments: [
        ("report.pdf", "application/pdf", "report.pdf"),
        ("report.pdf", "application/octet-stream", "report.pdf"),
        ("Before/after: chart", "image/png", "Before-after- chart.png"),
        ("..hidden", "image/jpeg", "hidden.jpeg"),
        ("  ", "image/png", "Image.png"),
        ("", "video/mp4", "Video.mp4"),
        ("", "application/pdf", "File.pdf"),
        ("notes.txt", "application/pdf", "notes.txt.pdf"),
    ])
    func namesFilesByTheirTypeAndSuggestion(suggested: String, mimeType: String, expected: String) throws {
        let (type, _) = try EmbeddedFile.decode("data:\(mimeType);base64,AA==")
        #expect(EmbeddedFile.filename(suggested: suggested, type: type) == expected)
    }

    @Test(arguments: [("a", 200), ("é", 100), ("🛩️", 28)])
    func boundsNameBytesAtCharacterBoundaries(character: String, count: Int) {
        let name = EmbeddedFile.filename(suggested: String(repeating: character, count: 500), type: .png)
        #expect(name == String(repeating: character, count: count) + ".png")
    }

    @Test(arguments: ["https://example.com/a.png", "data:image/png;base64", "data:image/png;base64,%zz", "data:text/csv,a%2Cb"])
    func rejectsMalformedDataURLs(dataURL: String) {
        #expect(throws: EmbeddedFileError.invalid) { try EmbeddedFile.decode(dataURL) }
    }
}
