import UniformTypeIdentifiers

/// File types the importers accept (Documents tab and the chat "+" menu).
enum DocumentTypes {
    static var allowed: [UTType] {
        var types: [UTType] = [.pdf, .plainText, .text, .image, .rtf, .json]
        for ext in ["md", "markdown", "csv", "log", "yaml", "yml"] {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        return types
    }
}
