import AppKit
import GRDB

enum ContentType: String, Codable, DatabaseValueConvertible {
    case text, rtf, image, file
}

struct ClipboardEntry: Identifiable, Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    var id: Int64?
    var contentType: ContentType
    var content: String
    var contentRTF: Data?
    var contentImage: Data?
    var contentFiles: String?
    var sourceApp: String?
    var sourceAppName: String?
    var createdAt: Date
    var lastPastedAt: Date?
    var pasteCount: Int
    var isPinned: Bool
    var pinOrder: Int?
    var title: String?
    var crc32: UInt32

    static let databaseTableName = "clips"

    enum Columns {
        static let id = Column(CodingKeys.id)
        static let contentType = Column(CodingKeys.contentType)
        static let content = Column(CodingKeys.content)
        static let isPinned = Column(CodingKeys.isPinned)
        static let pinOrder = Column(CodingKeys.pinOrder)
        static let createdAt = Column(CodingKeys.createdAt)
        static let crc32 = Column(CodingKeys.crc32)
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }

    var preview: String {
        switch contentType {
        case .text, .rtf:
            return content
        case .image:
            return "[Image]"
        case .file:
            let files = contentFiles?.split(separator: "\n").map(String.init) ?? []
            return files.count == 1 ? (files.first ?? "[File]") : "\(files.count) files"
        }
    }

    var writeToNSPasteboard: [(NSPasteboard.PasteboardType, Data)] {
        var items: [(NSPasteboard.PasteboardType, Data)] = []
        if let rtfData = contentRTF {
            items.append((.rtf, rtfData))
        }
        if let imgData = contentImage {
            items.append((.png, imgData))
        }
        if let fileString = contentFiles {
            let urls = fileString.split(separator: "\n")
                .compactMap { URL(string: String($0)) }
            if !urls.isEmpty,
               let data = try? NSKeyedArchiver.archivedData(withRootObject: urls.map(\.path), requiringSecureCoding: false) {
                items.append((.init("NSFilenamesPboardType"), data))
            }
        }
        if items.isEmpty || contentType == .text {
            if let data = content.data(using: .utf8) {
                items.append((.string, data))
            }
        }
        return items
    }
}
