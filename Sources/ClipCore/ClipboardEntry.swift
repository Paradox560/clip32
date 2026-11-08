import AppKit
import Foundation

public struct ClipboardRepresentation: Codable, Equatable, Sendable {
    public var type: String
    public var data: Data

    public init(type: String, data: Data) {
        self.type = type
        self.data = data
    }
}

public struct ClipboardItem: Codable, Equatable, Sendable {
    public var representations: [ClipboardRepresentation]

    public init(representations: [ClipboardRepresentation]) {
        self.representations = representations
    }

    public func data(for type: NSPasteboard.PasteboardType) -> Data? {
        representations.first(where: { $0.type == type.rawValue })?.data
    }

    public func string(for type: NSPasteboard.PasteboardType) -> String? {
        data(for: type).flatMap { String(data: $0, encoding: .utf8) }
    }
}

public struct ClipboardEntry: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case text, image, files
    }

    public var id: UUID
    public var createdAt: Date
    public var sourceApp: String?
    public var items: [ClipboardItem]
    public var isPinned: Bool

    public init(id: UUID = UUID(), createdAt: Date = Date(), sourceApp: String? = nil, items: [ClipboardItem], isPinned: Bool = false) {
        self.id = id
        self.createdAt = createdAt
        self.sourceApp = sourceApp
        self.items = items
        self.isPinned = isPinned
    }

    public var kind: Kind {
        if !fileURLs.isEmpty { return .files }
        if imageData != nil { return .image }
        return .text
    }

    public var byteCount: Int {
        items.reduce(0) { total, item in
            item.representations.reduce(total) { $0 + $1.data.count }
        }
    }

    /// File entries retain URLs, not copies of the files themselves.
    public var fileURLs: [URL] {
        items.compactMap { item in
            guard let value = item.string(for: .fileURL), let url = URL(string: value), url.isFileURL else { return nil }
            return url
        }
    }

    public var imageData: Data? {
        for item in items {
            if let data = item.data(for: .png) ?? item.data(for: .tiff) { return data }
        }
        return nil
    }

    public var searchableText: String {
        if !fileURLs.isEmpty {
            return fileURLs.map(\.path).joined(separator: "\n")
        }
        return items.compactMap { item in
            if let plain = item.string(for: .string) { return plain }
            if let url = item.string(for: .URL) { return url }
            if let data = item.data(for: .rtf),
               let attributed = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) {
                return attributed.string
            }
            // Avoid HTML importing, which can load external resources.
            return nil
        }.joined(separator: "\n")
    }

    public var title: String {
        switch kind {
        case .files:
            let urls = fileURLs
            if urls.count == 1 { return urls[0].lastPathComponent }
            return "\(urls.count) files · \(urls.first?.lastPathComponent ?? "Files")"
        case .image:
            return "Copied image"
        case .text:
            return Self.compactTitle(presentationText)
        }
    }

    /// Resolve both row strings together so an RTF-only entry is imported once.
    public var displayText: (title: String, preview: String) {
        guard kind == .text else { return (title, preview) }
        let text = presentationText
        return (Self.compactTitle(text), String(text.prefix(800)))
    }

    private static func compactTitle(_ text: String) -> String {
        // Build only the displayed portion instead of splitting a whole copy.
        var result = ""
        var count = 0
        var pendingSpace = false
        for character in text {
            if character.isNewline {
                if !result.isEmpty { break }
                continue
            }
            if character.isWhitespace {
                if !result.isEmpty { pendingSpace = true }
                continue
            }
            if pendingSpace {
                guard count + 1 < 140 else { break }
                result.append(" ")
                count += 1
                pendingSpace = false
            }
            result.append(character)
            count += 1
            if count == 140 { break }
        }
        return result.isEmpty ? "Formatted text" : result
    }

    public var preview: String {
        switch kind {
        case .files:
            return fileURLs.map(\.lastPathComponent).joined(separator: ", ")
        case .image:
            return ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
        case .text:
            return String(presentationText.prefix(800))
        }
    }

    /// Display-only bounds keep long copies cheap to render. The complete payload
    /// and searchableText remain unchanged. RTF uses the existing importer when no
    /// plain-text or URL representation is available.
    private var presentationText: String {
        var remainingBytes = 16 * 1_024
        var parts: [String] = []
        for item in items.prefix(32) {
            guard remainingBytes > 0 else { break }
            let text: String?
            if let plain = item.data(for: .string).flatMap({ Self.boundedUTF8($0, maximumBytes: remainingBytes) }) {
                text = plain
            } else if let url = item.data(for: .URL).flatMap({ Self.boundedUTF8($0, maximumBytes: remainingBytes) }) {
                text = url
            } else if let data = item.data(for: .rtf),
                      let attributed = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) {
                text = String(decoding: attributed.string.utf8.prefix(remainingBytes), as: UTF8.self)
            } else {
                text = nil
            }
            if let text {
                parts.append(text)
                remainingBytes -= text.utf8.count + 1
            }
        }
        return parts.joined(separator: "\n")
    }

    private static func boundedUTF8(_ data: Data, maximumBytes: Int) -> String? {
        guard data.count > maximumBytes else { return String(data: data, encoding: .utf8) }
        let prefix = data.prefix(maximumBytes)
        // The byte limit may cut through the final UTF-8 scalar. Drop only those
        // incomplete trailing bytes; malformed content elsewhere remains invalid.
        for trailingBytes in 0...3 {
            if let text = String(data: prefix.dropLast(trailingBytes), encoding: .utf8) { return text }
        }
        return nil
    }

    /// Pasteboard representation order is not part of copied content, but item order is.
    public func hasSameContent(as other: ClipboardEntry) -> Bool {
        guard items.count == other.items.count else { return false }
        return zip(items, other.items).allSatisfy { lhs, rhs in
            lhs.representations.sorted(by: Self.representationOrder) == rhs.representations.sorted(by: Self.representationOrder)
        }
    }

    private static func representationOrder(_ lhs: ClipboardRepresentation, _ rhs: ClipboardRepresentation) -> Bool {
        if lhs.type != rhs.type { return lhs.type < rhs.type }
        return lhs.data.lexicographicallyPrecedes(rhs.data)
    }
}
