import Foundation

/// Minimal Sentry envelope reader for assertions on complete outgoing bytes.
struct Envelope {
    struct Item {
        let header: [String: Any]
        let payload: Data
        var type: String? { header["type"] as? String }
        var json: [String: Any]? { try? JSONSerialization.jsonObject(with: payload) as? [String: Any] }
    }

    let text: String
    let items: [Item]

    init(_ raw: Data) throws {
        let data = try Self.gunzipIfNeeded(raw)
        text = String(decoding: data, as: UTF8.self)
        var items: [Item] = []
        var cursor = data.startIndex
        func line() -> Data? {
            guard cursor < data.endIndex else { return nil }
            let end = data[cursor...].firstIndex(of: 0x0A) ?? data.endIndex
            defer { cursor = min(end + 1, data.endIndex) }
            return data[cursor..<end]
        }
        _ = line() // envelope header
        while let headerLine = line(), !headerLine.isEmpty {
            let header = try JSONSerialization.jsonObject(with: headerLine) as? [String: Any] ?? [:]
            let payload: Data
            if let length = header["length"] as? Int {
                payload = data[cursor..<min(cursor + length, data.endIndex)]
                cursor = min(cursor + length + 1, data.endIndex)
            } else {
                payload = line() ?? Data()
            }
            items.append(Item(header: header, payload: Data(payload)))
        }
        self.items = items
    }

    /// sentry-cocoa gzips bodies (no FNAME/extra fields). Apple's `.zlib` is raw DEFLATE.
    static func gunzipIfNeeded(_ data: Data) throws -> Data {
        guard data.count > 18, data[data.startIndex] == 0x1F, data[data.startIndex + 1] == 0x8B else {
            return data
        }
        precondition(data[data.startIndex + 3] == 0, "unexpected gzip header flags")
        let deflated = data.subdata(in: (data.startIndex + 10)..<(data.endIndex - 8))
        return try (deflated as NSData).decompressed(using: .zlib) as Data
    }
}
