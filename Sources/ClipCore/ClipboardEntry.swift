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
            let line = searchableText.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            let compact = line.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return compact.isEmpty ? "Formatted text" : String(compact.prefix(140))
        }
    }

    public var preview: String {
        switch kind {
        case .files:
            return fileURLs.map(\.lastPathComponent).joined(separator: ", ")
        case .image:
            return ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
        case .text:
            return String(searchableText.prefix(800))
        }
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
