import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Random-access bytes. Demuxers read the container structure. The player reads
/// a sample when the display asks for it. Nothing here downloads a whole remote
/// object up front.
public protocol MediaByteSource: AnyObject, Sendable {
    var length: Int64 { get }
    func read(at offset: Int64, count: Int) throws -> Data
}

extension MediaByteSource {
    /// Structural reads. A hard failure is retried, then reported as an empty
    /// slice so a box walk can stop. Playback must not use this: an empty slice
    /// is indistinguishable from a dropped frame.
    func readOrEmpty(at offset: Int64, count: Int) -> Data {
        guard offset >= 0, count > 0, offset < length else { return Data() }
        let n = Int(min(Int64(count), length - offset))
        var delay = 0.2
        for attempt in 0 ..< 4 {
            do {
                return try read(at: offset, count: n)
            } catch {
                if attempt == 3 { return Data() }
                Thread.sleep(forTimeInterval: delay)
                delay = min(delay * 2, 2)
            }
        }
        return Data()
    }
}

public final class MemoryByteSource: MediaByteSource, @unchecked Sendable {
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

public final class FileByteSource: MediaByteSource, @unchecked Sendable {
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

public final class HTTPByteSource: MediaByteSource, @unchecked Sendable {
    public let length: Int64
    public let url: URL
    private let bridge: HTTPBridge
    private let session: URLSession
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var blocks: [Int64: Data] = [:]
    private var order: [Int64] = []
    private let blockSize = 256 * 1024
    private let maxBlocks = 48

    /// One session for the life of the source. Range reads are tasks on that
    /// session, so TLS and the CDN connection stay up across samples.
    public init(url: URL, timeout: TimeInterval = 20) throws {
        self.url = url
        self.timeout = timeout
        let bridge = HTTPBridge()
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = max(timeout, 60)
        config.httpMaximumConnectionsPerHost = 4
        config.httpShouldSetCookies = false
        let session = URLSession(configuration: config, delegate: bridge, delegateQueue: nil)
        self.bridge = bridge
        self.session = session
        length = try Self.probeLength(url: url, session: session, bridge: bridge, timeout: timeout)
        if length <= 0 { throw CinecoreError("Remote object has no length.") }
    }

    deinit { session.invalidateAndCancel() }

    public func read(at offset: Int64, count: Int) throws -> Data {
        guard offset >= 0, count > 0 else { return Data() }
        if offset >= length { return Data() }
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
            if inner < 0 || inner >= chunk.count {
                throw CinecoreError("Short range response at byte \(pos): got \(out.count) of \(n).")
            }
            let take = min(chunk.count - inner, Int(end - pos))
            if take <= 0 {
                throw CinecoreError("Short range response at byte \(pos): got \(out.count) of \(n).")
            }
            out.append(chunk.subdata(in: inner ..< (inner + take)))
            pos += Int64(take)
        }
        if out.count != n {
            throw CinecoreError("Short range response: got \(out.count) of \(n) bytes at \(offset).")
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
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("bytes=\(offset)-\(offset + Int64(count) - 1)", forHTTPHeaderField: "Range")
        return try perform(request, expect: count, allow: [206])
    }

    private func perform(_ request: URLRequest, expect: Int?, allow: Set<Int>) throws -> Data {
        let transfer = Transfer(expect: expect, allow: allow)
        let task = session.dataTask(with: request)
        bridge.track(task.taskIdentifier, transfer)
        task.resume()
        if transfer.sem.wait(timeout: .now() + timeout + 5) == .timedOut {
            task.cancel()
            throw CinecoreError("Timed out reading \(url.host ?? "remote").")
        }
        bridge.forget(task.taskIdentifier)
        let snap = transfer.snapshot()
        if let failure = snap.failure { throw failure }
        if !allow.contains(snap.status) {
            throw CinecoreError("Server did not honor the byte range (HTTP \(snap.status)). A 60 GB remux cannot be pulled in one response.")
        }
        if let expect, snap.body.count != expect {
            throw CinecoreError("Short range response: got \(snap.body.count) of \(expect) bytes.")
        }
        return snap.body
    }

    private static func probeLength(url: URL, session: URLSession, bridge: HTTPBridge, timeout: TimeInterval) throws -> Int64 {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "HEAD"
        let transfer = Transfer(expect: nil, allow: [200])
        let task = session.dataTask(with: request)
        bridge.track(task.taskIdentifier, transfer)
        task.resume()
        if transfer.sem.wait(timeout: .now() + timeout) == .timedOut {
            task.cancel()
            throw CinecoreError("Timed out asking for the length of \(url.absoluteString).")
        }
        bridge.forget(task.taskIdentifier)
        let snap = transfer.snapshot()
        if let failure = snap.failure { throw failure }
        if snap.length > 0 { return snap.length }
        throw CinecoreError("The server did not say how long \(url.lastPathComponent) is.")
    }
}

private final class HTTPBridge: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var inflight: [Int: Transfer] = [:]

    func track(_ id: Int, _ transfer: Transfer) {
        lock.lock()
        inflight[id] = transfer
        lock.unlock()
    }

    func forget(_ id: Int) {
        lock.lock()
        inflight[id] = nil
        lock.unlock()
    }

    private func find(_ task: URLSessionTask) -> Transfer? {
        lock.lock()
        defer { lock.unlock() }
        return inflight[task.taskIdentifier]
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse, let transfer = find(dataTask) else {
            completionHandler(.cancel)
            return
        }
        completionHandler(transfer.noteResponse(http))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        find(dataTask)?.append(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        find(task)?.finish(error)
    }
}

private final class Transfer: @unchecked Sendable {
    let sem = DispatchSemaphore(value: 0)
    /// Nil skips the body-length check. Used for HEAD.
    let expect: Int?
    let allow: Set<Int>
    private let lock = NSLock()
    private var storage = Data()
    private var statusCode = 0
    private var headerLength: Int64 = -1
    private var failure: Error?
    private var signaled = false

    init(expect: Int?, allow: Set<Int>) {
        self.expect = expect
        self.allow = allow
    }

    func noteResponse(_ response: HTTPURLResponse) -> URLSession.ResponseDisposition {
        lock.lock()
        statusCode = response.statusCode
        if let raw = response.value(forHTTPHeaderField: "Content-Length"), let n = Int64(raw), n >= 0 {
            headerLength = n
        }
        let ok = allow.contains(response.statusCode)
        lock.unlock()
        return ok ? .allow : .cancel
    }

    func append(_ data: Data) {
        lock.lock()
        storage.append(data)
        lock.unlock()
    }

    func finish(_ error: Error?) {
        lock.lock()
        if let error {
            let ns = error as NSError
            let cancelled = ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled
            if !cancelled && failure == nil { failure = error }
        }
        if failure == nil && !allow.contains(statusCode) {
            failure = CinecoreError("Server did not honor the byte range (HTTP \(statusCode)).")
        }
        if failure == nil, let expect, storage.count != expect {
            failure = CinecoreError("Short range response: got \(storage.count) of \(expect) bytes.")
        }
        let already = signaled
        signaled = true
        lock.unlock()
        if !already { sem.signal() }
    }

    func snapshot() -> (status: Int, body: Data, length: Int64, failure: Error?) {
        lock.lock()
        defer { lock.unlock() }
        return (statusCode, storage, headerLength, failure)
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
