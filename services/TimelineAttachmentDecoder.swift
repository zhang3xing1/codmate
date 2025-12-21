import Foundation

struct TimelineAttachmentDecoder {
    static func decodeDataURL(_ dataURL: String) -> (data: Data, mimeType: String)? {
        let trimmed = dataURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("data:") else { return nil }
        let parts = trimmed.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }

        let meta = String(parts[0].dropFirst(5))
        let dataPart = String(parts[1])
        let metaParts = meta.split(separator: ";")
        let mimeType = metaParts.first.map(String.init) ?? "application/octet-stream"
        guard metaParts.contains("base64") else { return nil }
        guard let data = Data(base64Encoded: dataPart, options: [.ignoreUnknownCharacters]) else { return nil }

        return (data: data, mimeType: mimeType)
    }

    static func fileExtension(for mimeType: String) -> String {
        switch mimeType.lowercased() {
        case "image/png": return "png"
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        case "image/heic": return "heic"
        case "image/heif": return "heif"
        case "image/tiff": return "tiff"
        case "image/bmp": return "bmp"
        case "image/svg+xml": return "svg"
        default: return "bin"
        }
    }

    static func imageData(for attachment: TimelineAttachment) -> Data? {
        if let url = attachment.url {
            guard url.isFileURL else { return nil }
            return try? Data(contentsOf: url)
        }
        if let dataURL = attachment.dataURL,
           let decoded = decodeDataURL(dataURL)
        {
            return decoded.data
        }
        return nil
    }
}
