import Foundation

/// `InputStream` that delivers one chunk and then reports a hard read error (`read`
/// returning -1, the documented `Stream.read(_:maxLength:)` contract for I/O errors) on the
/// next call, simulating a body stream that fails partway through.
final class FailingAfterFirstReadInputStream: InputStream {
    private var delivered = false
    private let firstChunk: [UInt8]

    init(firstChunk: String = "partial") {
        self.firstChunk = Array(firstChunk.utf8)
        super.init(data: Data())
    }

    override func open() {}
    override func close() {}
    override var hasBytesAvailable: Bool { true }

    override func read(_ buffer: UnsafeMutablePointer<UInt8>, maxLength len: Int) -> Int {
        guard !delivered else { return -1 }
        delivered = true
        for (index, byte) in firstChunk.enumerated() { buffer[index] = byte }
        return firstChunk.count
    }
}
