import Foundation

enum CodeSnippetFile {
    static func defaultFilename(language: String?) -> String {
        "snippet." + fileExtension(language: language)
    }

    private static func fileExtension(language: String?) -> String {
        guard let name = language?.split(whereSeparator: \.isWhitespace).first?.lowercased() else { return "txt" }
        return extensions[name] ?? "txt"
    }

    private static let extensions: [String: String] = [
        "bash": "sh", "c": "c", "c#": "cs", "c++": "cpp", "cpp": "cpp", "cs": "cs", "csharp": "cs",
        "css": "css", "diff": "diff", "dockerfile": "dockerfile", "go": "go", "golang": "go",
        "h": "h", "html": "html", "java": "java", "javascript": "js", "js": "js", "json": "json",
        "jsx": "jsx", "kotlin": "kt", "kt": "kt", "lua": "lua", "markdown": "md", "md": "md",
        "mermaid": "mmd", "objc": "m", "objective-c": "m", "patch": "diff", "php": "php",
        "py": "py", "python": "py", "rb": "rb", "ruby": "rb", "rs": "rs", "rust": "rs",
        "scss": "scss", "sh": "sh", "shell": "sh", "sql": "sql", "svelte": "svelte", "swift": "swift",
        "toml": "toml", "ts": "ts", "tsx": "tsx", "typescript": "ts", "xml": "xml",
        "yaml": "yaml", "yml": "yaml", "zsh": "zsh",
    ]
}
