import AppKit
import Foundation

final class TimelineAttachmentOpener {
    static let shared = TimelineAttachmentOpener()
    private let resolver = TimelineAttachmentResolver()

    private init() {}

    func open(_ attachment: TimelineAttachment) {
        guard let url = resolver.resolveURL(for: attachment) else { return }
        NSWorkspace.shared.open(url)
    }
}

private final class TimelineAttachmentResolver {
    private let fileManager = FileManager.default
    private var cache: [String: URL] = [:]
    private let baseURL: URL

    init() {
        baseURL = fileManager.temporaryDirectory
            .appendingPathComponent("CodMate-Attachments", isDirectory: true)
        try? fileManager.createDirectory(at: baseURL, withIntermediateDirectories: true)
    }

    func resolveURL(for attachment: TimelineAttachment) -> URL? {
        if let url = attachment.url { return url }
        guard let dataURL = attachment.dataURL else { return nil }
        if let cached = cache[attachment.id] { return cached }
        guard let resolved = Self.decodeDataURL(dataURL) else { return nil }

        let filename = "image-\(attachment.id).\(resolved.fileExtension)"
        let fileURL = baseURL.appendingPathComponent(filename)
        if !fileManager.fileExists(atPath: fileURL.path) {
            do {
                try resolved.data.write(to: fileURL, options: [.atomic])
            } catch {
                return nil
            }
        }
        cache[attachment.id] = fileURL
        return fileURL
    }

    private static func decodeDataURL(_ dataURL: String) -> (data: Data, fileExtension: String)? {
        guard let decoded = TimelineAttachmentDecoder.decodeDataURL(dataURL) else { return nil }
        return (data: decoded.data, fileExtension: TimelineAttachmentDecoder.fileExtension(for: decoded.mimeType))
    }
}
