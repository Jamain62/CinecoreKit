import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Random-access bytes. Demuxers read the container structure. The player reads
/// a sample when the display asks for it. Nothing here downloads a whole remote
/// object up front.
public protocol MediaByteSource: AnyObject {
    var length: Int64 { get }
    func read(at offset: Int64, count: Int) throws -> Data
}

extension MediaByteSource {
    func readOrEmpty(at offset: Int64, count: Int) -> Data {
        guard offset >= 0, count > 0, offset < length else { return Data() }
        let n = Int(min(Int64(count), length - offset))
        return (try? read(at: offset, count: n)) ?? Data()
    }
}

public final class MemoryByteSource: MediaByteSource {
    private let data: Data
    public init(_ data: Data) { self.data = data }
    public var length: Int64 { Int64(data.count) }
    public func read(at offset: Int64, count: Int) throws -> Data {
        guard offset >= 0, count > 0 else { return Data() }
        let start = Int(offset)
        if start >= data.count || start < 0 { return Data() }
        let end = min(data.count, start + count)
        return data.subdata(in: start ..< end)
    }
}

public final class FileByteSource: MediaByteSource {
    private let handle: FileHandle
    private let lock = NSLock()
    public let length: Int64

    public init(url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        self.handle = handle
        length = Int64(try handle.seekToEnd())
    }

    deinit { try? handle.close() }

    public func read(at offset: Int64, count: Int) throws -> Data {
        guard offset >= 0, count > 0, offset < length else { return Data() }
        let n = Int(min(Int64(count), length - offset))
        lock.lock()
        defer { lock.unlock() }
        try handle.seek(toOffset: UInt64(offset))
        return try handle.read(upToCount: n) ?? Data()
    }
}

public final class HTTPByteSource: MediaByteSource {
    public let length: Int64
    public let url: URL
    private let session: URLSession
    private let lock = NSLock()
    private var blocks: [Int64: Data] = [:]
    private var order: [Int64] = []
    private let blockSize = 256 * 1024
    private let maxBlocks = 48

    public init(url: URL, timeout: TimeInterval = 20) throws {
        self.url = url
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout
        session = URLSession(configuration: config)
        length = try HTTPByteSource.probeLength(url: url, session: session, timeout: timeout)
        if length <= 0 { throw CinecoreError("Remote object has no length.") }
    }

    public func read(at offset: Int64, count: Int) throws -> Data {
        guard offset >= 0, count > 0, offset < length else { return Data() }
        let n = Int(min(Int64(count), length - offset))
        if n > blockSize * 4 { return try fetch(offset, n) }
        var out = Data()
        out.reserveCapacity(n)
        var pos = offset
        let end = offset + Int64(n)
        while pos < end {
            let index = pos / Int64(blockSize)
            let start = index * Int64(blockSize)
            let chunk = try block(index, start)
            let inner = Int(pos - start)
            if inner >= chunk.count { break }
            let take = min(chunk.count - inner, Int(end - pos))
            out.append(chunk.subdata(in: inner ..< (inner + take)))
            pos += Int64(take)
        }
        return out
    }

    private func block(_ index: Int64, _ start: Int64) throws -> Data {
        lock.lock()
        if let hit = blocks[index] {
            lock.unlock()
            return hit
        }
        lock.unlock()
        let n = Int(min(Int64(blockSize), length - start))
        let data = try fetch(start, n)
        lock.lock()
        blocks[index] = data
        order.append(index)
        while order.count > maxBlocks {
            let drop = order.removeFirst()
            blocks[drop] = nil
        }
        lock.unlock()
        return data
    }

    private func fetch(_ offset: Int64, _ count: Int) throws -> Data {
        let task = RangeTask()
        var request = URLRequest(url: url)
        request.setValue("bytes=\(offset)-\(offset + Int64(count) - 1)", forHTTPHeaderField: "Range")
        let session = URLSession(configuration: self.session.configuration, delegate: task, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        session.dataTask(with: request).resume()
        if task.sem.wait(timeout: .now() + 30) == .timedOut {
            throw CinecoreError("Timed out reading \(url.host ?? "remote") at byte \(offset).")
        }
        if task.status != 206 {
            throw CinecoreError("Server did not honor the byte range (HTTP \(task.status)). A 60 GB remux cannot be pulled in one response.")
        }
        if let failure = task.failure { throw failure }
        return task.data
    }

    private static func probeLength(url: URL, session: URLSession, timeout: TimeInterval) throws -> Int64 {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "HEAD"
        let sem = DispatchSemaphore(value: 0)
        var length: Int64 = -1
        var failure: Error?
        session.dataTask(with: request) { _, response, error in
            if let http = response as? HTTPURLResponse {
                if let raw = http.value(forHTTPHeaderField: "Content-Length"), let n = Int64(raw), n > 0 {
                    length = n
                }
            }
            failure = error
            sem.signal()
        }.resume()
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            throw CinecoreError("Timed out asking for the length of \(url.absoluteString).")
        }
        if length > 0 { return length }
        if let failure { throw failure }
        throw CinecoreError("The server did not say how long \(url.lastPathComponent) is.")
    }
}

private final class RangeTask: NSObject, URLSessionDataDelegate {
    let sem = DispatchSemaphore(value: 0)
    var data = Data()
    var status = 0
    var failure: Error?

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        status = (response as? HTTPURLResponse)?.statusCode ?? 0
        completionHandler(status == 206 ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        self.data.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            let ns = error as NSError
            if ns.code != NSURLErrorCancelled { failure = error }
        }
        sem.signal()
    }
}

/// Sequential and small-range reads share a 1 MB window. A read larger than the
/// window goes straight to the source and is not kept.
final class ByteWindow {
    let source: MediaByteSource
    let count: Int
    private var origin = 0
    private var data = Data()
    private let span = 1_048_576

    init(_ source: MediaByteSource) {
        self.source = source
        count = source.length > Int64(Int.max) ? Int.max : Int(source.length)
    }

    subscript(index: Int) -> UInt8 {
        guard index >= 0, index < count else { return 0 }
        if index < origin || index >= origin + data.count {
            let end = min(count, index + span)
            data = source.readOrEmpty(at: Int64(index), count: end - index)
            origin = index
        }
        let local = index - origin
        if local < 0 || local >= data.count { return 0 }
        return data[local]
    }

    func subdata(in range: Range<Int>) -> Data {
        let start = range.lowerBound
        let end = min(range.upperBound, count)
        if start < 0 || start >= end { return Data() }
        if start >= origin && end <= origin + data.count {
            return data.subdata(in: (start - origin) ..< (end - origin))
        }
        return source.readOrEmpty(at: Int64(start), count: end - start)
    }
}
