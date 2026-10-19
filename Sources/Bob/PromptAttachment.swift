import AppKit
import BobCore
import ImageIO
import UniformTypeIdentifiers

struct PromptAttachment: Identifiable {
    let id = UUID()
    let image: ModelImage
    let preview: NSImage

    /// Decode and downsample before retaining or sending dropped images.
    static func decode(_ data: Data) throws -> PromptAttachment {
        guard data.count <= 20 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 2048
              ] as CFDictionary) else {
            throw BobError.message("Drop a supported image smaller than 20 MB.")
        }
        let bitmap = NSBitmapImageRep(cgImage: thumbnail)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw BobError.message("Could not read the dropped image.")
        }
        return PromptAttachment(image: ModelImage(data: png, mimeType: "image/png", width: thumbnail.width, height: thumbnail.height),
                                preview: NSImage(cgImage: thumbnail, size: .zero))
    }

    static func load(_ provider: NSItemProvider) async throws -> PromptAttachment {
        let type = provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier)
            ? UTType.fileURL.identifier : UTType.image.identifier
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
                if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: error ?? BobError.message("Could not load the dropped image.")) }
            }
        }
        if type == UTType.fileURL.identifier {
            guard let url = URL(dataRepresentation: data, relativeTo: nil), url.isFileURL else {
                throw BobError.message("Only local image files can be attached.")
            }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 20 * 1024 * 1024 else { throw BobError.message("Images must be smaller than 20 MB.") }
            return try decode(Data(contentsOf: url, options: .mappedIfSafe))
        }
        return try decode(data)
    }
}
