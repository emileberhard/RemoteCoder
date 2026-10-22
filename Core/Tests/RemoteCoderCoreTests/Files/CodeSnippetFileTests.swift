import Testing
@testable import RemoteCoderCore

struct CodeSnippetFileTests {
    @Test(arguments: [
        ("swift", "snippet.swift"),
        ("Python", "snippet.py"),
        ("typescript title=\"app.ts\"", "snippet.ts"),
        ("yml", "snippet.yaml"),
        ("c++", "snippet.cpp"),
    ])
    func knownLanguageNamesTheFileByItsExtension(language: String, filename: String) {
        #expect(CodeSnippetFile.defaultFilename(language: language) == filename)
    }

    @Test(arguments: [nil, "", "output", "../etc/passwd"] as [String?])
    func unknownOrMissingLanguageSavesPlainText(language: String?) {
        #expect(CodeSnippetFile.defaultFilename(language: language) == "snippet.txt")
    }
}
