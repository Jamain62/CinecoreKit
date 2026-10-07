import Foundation

/// Why a playback operation failed. The message is for a person. The code is for the app.
public struct CinecoreFailure: Error, Equatable, CustomStringConvertible {
    public enum Code: String, Equatable, Sendable {
        case cancelled
        case network
        case httpRange
        case malformed
        case unsupported
        case indexing
        case decoder
        case audio
        case seek
    }

    public var code: Code
    public var message: String

    public init(_ code: Code, _ message: String) {
        self.code = code
        self.message = message
    }

    public var description: String { "\(code.rawValue): \(message)" }
}

func classify(_ error: Error) -> CinecoreFailure {
    if let failure = error as? CinecoreFailure { return failure }
    let text = String(describing: error)
    let lower = text.lowercased()
    if lower.contains("cancel") { return CinecoreFailure(.cancelled, text) }
    if lower.contains("timed out") || lower.contains("offline") || lower.contains("network") {
        return CinecoreFailure(.network, text)
    }
    if lower.contains("byte range") || lower.contains("http") || lower.contains("short range") {
        return CinecoreFailure(.httpRange, text)
    }
    if lower.contains("videotoolbox") || lower.contains("parameter set") {
        return CinecoreFailure(.decoder, text)
    }
    return CinecoreFailure(.malformed, text)
}

/// What the screen can show. Transitions that are not in `PlayerSession` are ignored.
public enum PlaybackState: Equatable, Sendable {
    case idle
    case opening
    case ready
    case playing
    case buffering
    case paused
    case seeking
    case ended
    case failed(CinecoreFailure)
}

/// Copy-out snapshot. Safe to log or put on a pasteboard.
public struct CinecoreDiagnostics: Equatable, Sendable {
    public var state: String = "idle"
    public var detail: String = ""
    public var container: String = ""
    public var name: String = ""
    public var videoCodec: String = ""
    public var audioCodec: String = ""
    public var hdr: String = ""
    public var audioLayout: String = ""
    public var time: Double = 0
    public var duration: Double = 0
    public var indexedStart: Double = 0
    public var indexedEnd: Double = 0
    public var videoSample: Int = 0
    public var audioSample: Int = 0
    public var requests: Int = 0
    public var bytes: Int = 0
    public var retries: Int = 0
    public var lastStatus: Int = 0
    public var lastError: String = ""
    public var bytesPerSecond: Double = 0
    public var droppedVideo: Int = 0
    public var avOffset: Double = 0

    public var report: String {
        [
            "state \(state)",
            detail,
            "\(name) \(container)",
            "video \(videoCodec) \(hdr)",
            "audio \(audioCodec) \(audioLayout)",
            String(format: "time %.2f / %.2f", time, duration),
            String(format: "indexed %.2f–%.2f", indexedStart, indexedEnd),
            "samples v\(videoSample) a\(audioSample) dropped \(droppedVideo)",
            String(format: "av offset %.3f", avOffset),
            "http \(requests) req \(bytes) bytes status \(lastStatus) retries \(retries)",
            String(format: "%.0f B/s", bytesPerSecond),
            lastError,
        ].filter { !$0.isEmpty }.joined(separator: "\n")
    }
}

/// Set from any queue. The flag is only read and written under the lock.
final class CancelToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }
}

/// One playback session.
///
/// `beginOpen`, `beginSeek`, and `close` cancel the previous token and bump
/// the generation. A callback captured the old generation. `adopt` then
/// returns false, so the old work cannot publish into the new movie.
/// `beginOpen` and `close` are allowed from every state. Everything else
/// has to be a legal transition, or it is ignored.
final class PlayerSession: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var state: PlaybackState = .idle
    private var token = CancelToken()

    var currentGeneration: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    var currentState: PlaybackState {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    var currentToken: CancelToken {
        lock.lock()
        defer { lock.unlock() }
        return token
    }

    func isCurrent(_ generation: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return self.generation == generation
    }

    @discardableResult
    func beginOpen() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        token.cancel()
        token = CancelToken()
        generation += 1
        state = .opening
        return generation
    }

    /// Nil when nothing is loaded, so a seek during open or idle does not start work.
    func beginSeek() -> UInt64? {
        lock.lock()
        defer { lock.unlock() }
        switch state {
        case .ready, .playing, .paused, .buffering, .seeking, .ended:
            break
        default:
            return nil
        }
        token.cancel()
        token = CancelToken()
        generation += 1
        state = .seeking
        return generation
    }

    @discardableResult
    func close() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        token.cancel()
        token = CancelToken()
        generation += 1
        state = .idle
        return generation
    }

    @discardableResult
    func adopt(_ generation: UInt64, _ next: PlaybackState) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard self.generation == generation else { return false }
        guard legal(state, next) else { return false }
        state = next
        return true
    }
}

/// Legal edges. Same-state is a no-op success so a repeated play does not fail.
private func legal(_ from: PlaybackState, _ to: PlaybackState) -> Bool {
    if from == to { return true }
    switch (from, to) {
    case (.idle, .opening):
        return true
    case (.opening, .ready), (.opening, .failed), (.opening, .idle):
        return true
    case (.ready, .playing), (.ready, .seeking), (.ready, .idle), (.ready, .failed):
        return true
    case (.playing, .buffering), (.playing, .paused), (.playing, .seeking), (.playing, .ended), (.playing, .failed), (.playing, .idle):
        return true
    case (.buffering, .playing), (.buffering, .paused), (.buffering, .seeking), (.buffering, .failed), (.buffering, .idle):
        return true
    case (.paused, .playing), (.paused, .seeking), (.paused, .idle), (.paused, .failed):
        return true
    case (.seeking, .ready), (.seeking, .playing), (.seeking, .paused), (.seeking, .buffering), (.seeking, .failed), (.seeking, .idle):
        return true
    case (.ended, .opening), (.ended, .idle), (.ended, .seeking), (.ended, .playing):
        return true
    case (.failed, .opening), (.failed, .idle):
        return true
    default:
        return false
    }
}
