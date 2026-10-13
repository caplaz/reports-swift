import Foundation

extension Data {
    /// Drains a request body stream (URLProtocol receives `httpBody` as a stream). Returns
    /// `nil` when `InputStream.read` reports an error (a negative return value) partway
    /// through, so a caller can't mistake a truncated read for the complete body.
    init?(reading stream: InputStream) {
        self.init()
        stream.open()
        defer { stream.close() }
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count > 0 {
                append(buffer, count: count)
            } else if count == 0 {
                break
            } else {
                return nil
            }
        }
    }
}
