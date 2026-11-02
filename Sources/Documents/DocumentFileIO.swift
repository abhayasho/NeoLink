import Foundation

enum DocumentFileError: LocalizedError {
    case unsupported, tooLarge, changedOnDisk, invalidPDF

    var errorDescription: String? {
        switch self {
        case .unsupported: return "This file isn’t a supported text file or PDF."
        case .tooLarge: return "This file is too large for an in-app preview. The limit is 8 MB for text and 50 MB for PDFs."
        case .changedOnDisk: return "This file changed outside NeoLink. Your edits are still here. Use Save Copy to keep them without overwriting the other changes."
        case .invalidPDF: return "This PDF could not be opened. It may be damaged or incomplete."
        }
    }
}

struct TextFileFormat {
    let encoding: String.Encoding
    let byteOrderMark: Data

    func encode(_ text: String) throws -> Data {
        guard let data = text.data(using: encoding, allowLossyConversion: false) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        return byteOrderMark + data
    }
}

struct LoadedDocument {
    let data: Data
    let text: String?
    let format: TextFileFormat?
    var isPDF: Bool { text == nil }
}

enum DocumentFileIO {
    static func sizeLimit(for name: String) -> Int {
        (name as NSString).pathExtension.lowercased() == "pdf" ? 50 * 1024 * 1024 : 8 * 1024 * 1024
    }

    static func read(_ url: URL) throws -> LoadedDocument {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw DocumentFileError.unsupported }
        let limit = sizeLimit(for: url.lastPathComponent)
        guard (values.fileSize ?? 0) <= limit else { throw DocumentFileError.tooLarge }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw DocumentFileError.tooLarge }
        return try decode(data, name: url.lastPathComponent)
    }

    static func decode(_ data: Data, name: String) throws -> LoadedDocument {
        guard data.count <= sizeLimit(for: name) else { throw DocumentFileError.tooLarge }
        if (name as NSString).pathExtension.lowercased() == "pdf" {
            guard data.starts(with: Data("%PDF-".utf8)) else { throw DocumentFileError.invalidPDF }
            return LoadedDocument(data: data, text: nil, format: nil)
        }
        let encoding: String.Encoding
        let mark: Data
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            encoding = .utf8; mark = Data([0xEF, 0xBB, 0xBF])
        } else if data.starts(with: [0xFF, 0xFE]) {
            encoding = .utf16LittleEndian; mark = Data([0xFF, 0xFE])
        } else if data.starts(with: [0xFE, 0xFF]) {
            encoding = .utf16BigEndian; mark = Data([0xFE, 0xFF])
        } else {
            encoding = .utf8; mark = Data()
        }
        guard let text = String(data: data.dropFirst(mark.count), encoding: encoding),
              !text.unicodeScalars.contains(where: { $0.value < 32 && ![9, 10, 12, 13].contains($0.value) }) else {
            throw DocumentFileError.unsupported
        }
        return LoadedDocument(data: data, text: text, format: TextFileFormat(encoding: encoding, byteOrderMark: mark))
    }

    static func save(_ text: String, format: TextFileFormat, to url: URL, originalData: Data) throws -> Data {
        // Never silently replace edits made by another application since this tab was loaded.
        let current = try read(url)
        guard current.data == originalData else { throw DocumentFileError.changedOnDisk }
        let data = try format.encode(text)
        try data.write(to: url, options: .atomic)
        return data
    }
}
