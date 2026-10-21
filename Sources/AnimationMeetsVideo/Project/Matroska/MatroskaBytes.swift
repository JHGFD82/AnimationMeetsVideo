import Foundation

/// A Matroska file's bytes as `MatroskaIndex` reads them: through a window
/// read from the file in large pieces as the index moves through it.
/// Frame headers sit every few tens of kilobytes all through a file, so
/// walking them through a memory map faults in nearly every page one at a
/// time, which reads a 16 GB file at under 1 GB/s; reading it straight
/// through in pieces this size runs at the disk's full speed (6.5 GB/s on
/// an internal SSD). Bytes already in memory are one window that never
/// moves.
final class MatroskaBytes {
    static let windowSize = 16 << 20

    let count: Int
    /// Called with how far through the file the window has reached, 0...1,
    /// each time it moves.
    var progress: (Double) -> Void = { _ in }

    private let descriptor: Int32
    private var window: UnsafeMutableRawBufferPointer
    private var windowStart = 0
    private var windowEnd: Int

    init(url: URL) throws {
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else { throw CocoaError(.fileReadNoSuchFile, userInfo: [NSURLErrorKey: url]) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            close(descriptor)
            throw CocoaError(.fileReadUnknown, userInfo: [NSURLErrorKey: url])
        }
        self.descriptor = descriptor
        count = Int(info.st_size)
        window = .allocate(byteCount: Self.windowSize, alignment: 16_384)
        windowEnd = 0
    }

    init(data: Data) {
        descriptor = -1
        count = data.count
        window = .allocate(byteCount: max(data.count, 1), alignment: 16)
        data.copyBytes(to: window)
        windowEnd = data.count
    }

    deinit {
        window.deallocate()
        if descriptor >= 0 { close(descriptor) }
    }

    subscript(position: Int) -> UInt8 {
        get throws {
            if position < windowStart || position >= windowEnd { try move(to: position) }
            return window[position - windowStart]
        }
    }

    /// The bytes in `range`, which the caller has checked are in the file.
    func data(in range: Range<Int>) throws -> Data {
        if range.lowerBound < windowStart || range.upperBound > windowEnd {
            guard range.count <= Self.windowSize else { return try read(range) }
            try move(to: range.lowerBound)
        }
        return Data(window[(range.lowerBound - windowStart)..<(range.upperBound - windowStart)])
    }

    /// Reads the window from `position` on. Cancelling the calling task
    /// stops the read here.
    private func move(to position: Int) throws {
        guard descriptor >= 0, position < count else { throw MatroskaError.malformed("it ends early") }
        try Task.checkCancellation()
        let length = min(Self.windowSize, count - position)
        try fill(window.baseAddress!, length: length, from: position)
        windowStart = position
        windowEnd = position + length
        progress(Double(windowEnd) / Double(count))
    }

    private func read(_ range: Range<Int>) throws -> Data {
        var data = Data(count: range.count)
        try data.withUnsafeMutableBytes { try fill($0.baseAddress!, length: range.count, from: range.lowerBound) }
        return data
    }

    private func fill(_ buffer: UnsafeMutableRawPointer, length: Int, from position: Int) throws {
        var done = 0
        while done < length {
            let read = pread(descriptor, buffer + done, length - done, off_t(position + done))
            if read < 0, errno == EINTR { continue }
            guard read > 0 else { throw MatroskaError.malformed("its bytes can't be read") }
            done += read
        }
    }
}
