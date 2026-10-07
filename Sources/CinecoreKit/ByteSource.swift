import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Random-access bytes. Demuxers read the container structure. The player reads
/// a sample when the display asks for it. Nothing here downloads a whole remote
/// object up front.
protocol MediaByteSource: AnyObject, Sendable {
    var length: Int64 { get }
    func read(at offset: Int64, count: Int) throws -> Data
    /// The exact range. Playback may widen a read into a cache block.
    /// Indexing must use this so a header does not pull the frame behind it.
    func readExact(at offset: Int64, count: Int) throws -> Data
    /// Remote Matroska sets this so open returns after the first cluster.
    var indexesIncrementally: Bool { get }
    var isWorkCancelled: Bool { get }
    func cancelWork()
}

extension MediaByteSource {
    public var indexesIncrementally: Bool { false }
    public var isWorkCancelled: Bool { false }
    public func cancelWork() {}

    public func readExact(at offset: Int64, count: Int) throws -> Data {
        try read(at: offset, count: count)
    }
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
                return try readExact(at: offset, count: n)
            } catch {
                if attempt == 3 { return Data() }
                Thread.sleep(forTimeInterval: delay)
                delay = min(delay * 2, 2)
            }
        }
        return Data()
    }
}

/// Immutable bytes. `Data` is not mutated, so the type is Sendable without a lock.
final class MemoryByteSource: MediaByteSource, Sendable {
    private let data: Data
    init(_ data: Data) { self.data = data }
    var length: Int64 { Int64(data.count) }
    func read(at offset: Int64, count: Int) throws -> Data {
        guard offset >= 0, count > 0 else { return Data() }
        let start = Int(offset)
        if start >= data.count || start < 0 { return Data() }
        let end = min(data.count, start + count)
        return data.subdata(in: start ..< end)
    }
}

/// The file handle is not Sendable. Every seek/read holds `lock`, and nothing
/// else touches the handle. That is the reason for the unchecked conformance.
final class FileByteSource: MediaByteSource, @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    let length: Int64

    init(url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        self.handle = handle
        length = Int64(try handle.seekToEnd())
    }

    deinit { try? handle.close() }

    func read(at offset: Int64, count: Int) throws -> Data {
        guard offset >= 0, count > 0, offset < length else { return Data() }
        let n = Int(min(Int64(count), length - offset))
        lock.lock()
        defer { lock.unlock() }
        try handle.seek(toOffset: UInt64(offset))
        return try handle.read(upToCount: n) ?? Data()
    }
}

/// The in-flight list is shared by the length probe and later reads.
/// `URLSessionTask` is not Sendable. The array is only touched under `lock`.
private final class TaskList: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [URLSessionTask] = []

    func add(_ task: URLSessionTask) {
        lock.lock()
        tasks.append(task)
        lock.unlock()
    }

    func remove(_ task: URLSessionTask) {
        lock.lock()
        tasks.removeAll { $0 === task }
        lock.unlock()
    }

    func cancelAll() {
        lock.lock()
        let live = tasks
        lock.unlock()
        live.forEach { $0.cancel() }
    }
}

/// URLSession and the block cache are mutable. The cache, the stats, and the
/// task list are only touched under `lock`. Delegate callbacks go through
/// `HTTPBridge`, which has its own lock. Unchecked is required because
/// `URLSession` is not Sendable. The cache holds at most `maxBlocks` blocks.
final class HTTPByteSource: MediaByteSource, @unchecked Sendable {
    let length: Int64
    let url: URL
    var indexesIncrementally: Bool { true }
    private let bridge: HTTPBridge
    private let session: URLSession
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var blocks: [Int64: Data] = [:]
    private var order: [Int64] = []
    private let tasks: TaskList
    private var token: CancelToken
    private var requestCount = 0
    private var byteCount = 0
    private var retryCount = 0
    private var lastStatus = 0
    private var lastError = ""
    private var started: Date?
    private let blockSize = 256 * 1024
    /// 48 × 256 KB = 12 MB. Older blocks are dropped.
    private let maxBlocks = 48

    /// One session for the life of the source. Range reads are tasks on that
    /// session, so TLS and the CDN connection stay up across samples.
    init(url: URL, timeout: TimeInterval = 20, token: CancelToken = CancelToken()) throws {
        self.url = url
        self.timeout = timeout
        self.token = token
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
        let live = TaskList()
        self.tasks = live
        token.onCancel { live.cancelAll() }
        length = try Self.probeLength(url: url, session: session, bridge: bridge, timeout: timeout, token: token, tasks: live)
        if length <= 0 { throw CinecoreFailure(.network, "Remote object has no length.") }
    }

    deinit { session.invalidateAndCancel() }

    var isWorkCancelled: Bool { currentToken().isCancelled }

    func cancelWork() {
        currentToken().cancel()
    }

    func attach(_ token: CancelToken) {
        lock.lock()
        self.token = token
        let tasks = self.tasks
        lock.unlock()
        token.onCancel { tasks.cancelAll() }
    }

    private func currentToken() -> CancelToken {
        lock.lock()
        defer { lock.unlock() }
        return token
    }

    var cachedBlockCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return blocks.count
    }

    var transport: (requests: Int, bytes: Int, retries: Int, status: Int, error: String, perSecond: Double) {
        lock.lock()
        defer { lock.unlock() }
        let elapsed = started.map { Date().timeIntervalSince($0) } ?? 0
        let rate = elapsed > 0.05 ? Double(byteCount) / elapsed : 0
        return (requestCount, byteCount, retryCount, lastStatus, lastError, rate)
    }

    /// Bypasses the 256 KB cache. Indexing uses this so a block header does not download the frame.
    func readExact(at offset: Int64, count: Int) throws -> Data {
        guard offset >= 0, count > 0 else { return Data() }
        if offset >= length { return Data() }
        let n = Int(min(Int64(count), length - offset))
        return try fetch(offset, n)
    }

    func read(at offset: Int64, count: Int) throws -> Data {
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
        let active = currentToken()
        if active.isCancelled { throw CinecoreFailure(.cancelled, "Read cancelled.") }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("bytes=\(offset)-\(offset + Int64(count) - 1)", forHTTPHeaderField: "Range")
        return try perform(request, expect: count, allow: [206], token: active)
    }

    private func perform(_ request: URLRequest, expect: Int?, allow: Set<Int>, token: CancelToken) throws -> Data {
        if token.isCancelled { throw CinecoreFailure(.cancelled, "Read cancelled.") }
        let transfer = Transfer(expect: expect, allow: allow)
        let task = session.dataTask(with: request)
        tasks.add(task)
        lock.lock()
        requestCount += 1
        if started == nil { started = Date() }
        lock.unlock()
        bridge.track(task.taskIdentifier, transfer)
        task.resume()
        if token.isCancelled { task.cancel() }
        guard wait(transfer, token: token, timeout: timeout + 5) else {
            task.cancel()
            note(status: 0, bytes: 0, error: "Timed out reading \(url.host ?? "remote").", retry: true)
            throw CinecoreFailure(.network, "Timed out reading \(url.host ?? "remote").")
        }
        bridge.forget(task.taskIdentifier)
        tasks.remove(task)
        let snap = transfer.snapshot()
        if token.isCancelled || currentToken().isCancelled {
            throw CinecoreFailure(.cancelled, "Read cancelled.")
        }
        if let failure = snap.failure {
            let typed = classify(failure)
            note(status: snap.status, bytes: snap.body.count, error: typed.message, retry: typed.code == .network)
            throw typed
        }
        if !allow.contains(snap.status) {
            let message = "Server did not honor the byte range (HTTP \(snap.status))."
            note(status: snap.status, bytes: snap.body.count, error: message, retry: false)
            throw CinecoreFailure(.httpRange, message)
        }
        if let expect, snap.body.count != expect {
            let message = "Short range response: got \(snap.body.count) of \(expect) bytes."
            note(status: snap.status, bytes: snap.body.count, error: message, retry: false)
            throw CinecoreFailure(.httpRange, message)
        }
        note(status: snap.status, bytes: snap.body.count, error: "", retry: false)
        return snap.body
    }

    /// Polls so a cancel is noticed even when the session does not complete the task promptly.
    private func wait(_ transfer: Transfer, token: CancelToken, timeout: TimeInterval) -> Bool {
        let limit = Date().addingTimeInterval(timeout)
        while Date() < limit {
            if token.isCancelled { return true }
            if transfer.sem.wait(timeout: .now() + 0.05) == .success { return true }
        }
        return token.isCancelled
    }

    private func note(status: Int, bytes: Int, error: String, retry: Bool) {
        lock.lock()
        lastStatus = status
        byteCount += bytes
        if retry { retryCount += 1 }
        if !error.isEmpty { lastError = error }
        lock.unlock()
    }

    private static func probeLength(url: URL, session: URLSession, bridge: HTTPBridge, timeout: TimeInterval, token: CancelToken, tasks: TaskList) throws -> Int64 {
        if token.isCancelled { throw CinecoreFailure(.cancelled, "Read cancelled.") }
        if let n = try headLength(url: url, session: session, bridge: bridge, timeout: timeout, token: token, tasks: tasks), n > 0 {
            return n
        }
        if token.isCancelled { throw CinecoreFailure(.cancelled, "Read cancelled.") }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let transfer = Transfer(expect: 1, allow: [206])
        let task = session.dataTask(with: request)
        tasks.add(task)
        bridge.track(task.taskIdentifier, transfer)
        task.resume()
        if token.isCancelled { task.cancel() }
        let limit = Date().addingTimeInterval(timeout)
        var finished = false
        while Date() < limit {
            if token.isCancelled { task.cancel(); finished = true; break }
            if transfer.sem.wait(timeout: .now() + 0.05) == .success { finished = true; break }
        }
        if !finished { task.cancel() }
        bridge.forget(task.taskIdentifier)
        tasks.remove(task)
        if token.isCancelled { throw CinecoreFailure(.cancelled, "Read cancelled.") }
        if !finished {
            throw CinecoreFailure(.network, "Timed out asking for the length of \(url.absoluteString).")
        }
        let snap = transfer.snapshot()
        if snap.length > 1 { return snap.length }
        if let failure = snap.failure { throw classify(failure) }
        throw CinecoreFailure(.httpRange, "The server did not say how long \(url.lastPathComponent) is. HEAD had no length and Range bytes=0-0 had no Content-Range total.")
    }

    private static func headLength(url: URL, session: URLSession, bridge: HTTPBridge, timeout: TimeInterval, token: CancelToken, tasks: TaskList) throws -> Int64? {
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "HEAD"
        if token.isCancelled { throw CinecoreFailure(.cancelled, "Read cancelled.") }
        let transfer = Transfer(expect: nil, allow: [200])
        let task = session.dataTask(with: request)
        tasks.add(task)
        bridge.track(task.taskIdentifier, transfer)
        task.resume()
        if token.isCancelled { task.cancel() }
        let limit = Date().addingTimeInterval(timeout)
        var finished = false
        while Date() < limit {
            if token.isCancelled { task.cancel(); finished = true; break }
            if transfer.sem.wait(timeout: .now() + 0.05) == .success { finished = true; break }
        }
        if !finished { task.cancel() }
        bridge.forget(task.taskIdentifier)
        tasks.remove(task)
        if token.isCancelled { throw CinecoreFailure(.cancelled, "Read cancelled.") }
        if !finished { return nil }
        let snap = transfer.snapshot()
        return snap.length > 0 ? snap.length : nil
    }
}

/// Delegate callbacks arrive on the session queue. `inflight` is only used
/// under `lock`. URLSession requires an NSObject delegate, which cannot be an actor.
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

/// The semaphore is waited on the caller. The body is appended on the session
/// queue. Both sides take `lock` before touching the buffers.
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
        if let raw = response.value(forHTTPHeaderField: "Content-Range"),
           let slash = raw.lastIndex(of: "/"),
           let n = Int64(raw[raw.index(after: slash)...]), n > 0 {
            headerLength = n
        } else if let raw = response.value(forHTTPHeaderField: "Content-Length"), let n = Int64(raw), n >= 0 {
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
