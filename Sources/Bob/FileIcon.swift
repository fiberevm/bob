import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Finder's full-color document icons, shared by the tree, tabs, and file finder.
struct FileIcon: View {
    let path: String
    var isDirectory = false
    var size: CGFloat = 16

    var body: some View {
        Image(nsImage: NativeFileIcons.image(path: path, isDirectory: isDirectory))
            .resizable().renderingMode(.original).interpolation(.high).scaledToFit()
            .frame(width: size, height: size).accessibilityHidden(true)
    }
}

@MainActor private enum NativeFileIcons {
    private static let cache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 128
        return cache
    }()
    private static let sourceExtensions: Set<String> = [
        "swift", "c", "h", "cpp", "cc", "cxx", "hpp", "m", "mm", "js", "mjs", "cjs", "jsx",
        "ts", "tsx", "py", "rb", "rs", "go", "java", "kt", "kts", "cs", "php", "lua", "scala",
        "sh", "bash", "zsh", "fish", "ps1", "sql"
    ]

    static func image(path: String, isDirectory: Bool) -> NSImage {
        let type = isDirectory ? UTType.folder : contentType(for: path)
        let key = type.identifier as NSString
        if let image = cache.object(forKey: key) { return image }
        let image = NSWorkspace.shared.icon(for: type)
        cache.setObject(image, forKey: key)
        return image
    }

    private static func contentType(for path: String) -> UTType {
        let name = (path as NSString).lastPathComponent.lowercased()
        let ext = (name as NSString).pathExtension
        if ["dockerfile", "makefile", "gnumakefile", "justfile"].contains(name) || name.hasPrefix("dockerfile.") {
            return .sourceCode
        }
        if name == "package.resolved" { return .json }
        if ["license", "copying", "notice", "readme", ".gitignore", ".gitattributes", ".gitmodules", ".dockerignore", ".editorconfig", ".env"].contains(name) || name.hasPrefix(".env.") {
            return .plainText
        }
        if sourceExtensions.contains(ext) {
            // In particular, .ts must be treated as source rather than MPEG video.
            if let type = UTType(filenameExtension: ext, conformingTo: .sourceCode), type.isDeclared { return type }
            return .sourceCode
        }
        return UTType(filenameExtension: ext) ?? .data
    }
}
