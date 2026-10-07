import XCTest
@testable import CinecoreKit

final class SessionTests: XCTestCase {
    func testOpenAThenOpenBDropsA() {
        let session = PlayerSession()
        let first = session.beginOpen()
        let second = session.beginOpen()
        XCTAssertFalse(session.adopt(first, .ready))
        XCTAssertTrue(session.adopt(second, .ready))
        XCTAssertEqual(session.currentState, .ready)
    }

    func testSeekThenOpenDropsTheSeek() {
        let session = PlayerSession()
        let open = session.beginOpen()
        XCTAssertTrue(session.adopt(open, .ready))
        let seek = session.beginSeek()
        let next = session.beginOpen()
        XCTAssertFalse(session.adopt(seek!, .playing))
        XCTAssertTrue(session.adopt(next, .ready))
    }

    func testRapidSeeksKeepOnlyTheLast() {
        let session = PlayerSession()
        let open = session.beginOpen()
        XCTAssertTrue(session.adopt(open, .ready))
        let first = session.beginSeek()!
        let second = session.beginSeek()!
        let third = session.beginSeek()!
        XCTAssertFalse(session.adopt(first, .playing))
        XCTAssertFalse(session.adopt(second, .paused))
        XCTAssertTrue(session.adopt(third, .playing))
        XCTAssertEqual(session.currentState, .playing)
    }

    func testCloseWhileOpening() {
        let session = PlayerSession()
        let open = session.beginOpen()
        let token = session.currentToken
        _ = session.close()
        XCTAssertTrue(token.isCancelled)
        XCTAssertFalse(session.adopt(open, .ready))
        XCTAssertEqual(session.currentState, .idle)
        XCTAssertFalse(session.currentToken.isCancelled)
    }

    func testCloseDuringSeek() {
        let session = PlayerSession()
        let open = session.beginOpen()
        XCTAssertTrue(session.adopt(open, .ready))
        XCTAssertTrue(session.adopt(open, .playing))
        let seek = session.beginSeek()!
        _ = session.close()
        XCTAssertFalse(session.isCurrent(seek))
        XCTAssertFalse(session.adopt(seek, .playing))
        XCTAssertEqual(session.currentState, .idle)
    }

    func testIllegalTransitionIsIgnored() {
        let session = PlayerSession()
        XCTAssertFalse(session.adopt(session.currentGeneration, .playing))
        XCTAssertEqual(session.currentState, .idle)
        XCTAssertNil(session.beginSeek())
    }

    func testOpenAfterClose() {
        let session = PlayerSession()
        let first = session.beginOpen()
        XCTAssertTrue(session.adopt(first, .ready))
        _ = session.close()
        let second = session.beginOpen()
        XCTAssertNotEqual(first, second)
        XCTAssertTrue(session.adopt(second, .ready))
        XCTAssertEqual(session.currentState, .ready)
    }

    func testRepeatedOpenCloseDoesNotStick() {
        let session = PlayerSession()
        var previous: UInt64 = 0
        for _ in 0 ..< 200 {
            let generation = session.beginOpen()
            XCTAssertGreaterThan(generation, previous)
            XCTAssertTrue(session.adopt(generation, .ready))
            XCTAssertTrue(session.adopt(generation, .playing))
            _ = session.close()
            XCTAssertEqual(session.currentState, .idle)
            previous = session.currentGeneration
        }
    }

    func testStaleIndexResultAfterSeek() {
        let session = PlayerSession()
        let open = session.beginOpen()
        XCTAssertTrue(session.adopt(open, .ready))
        let seek = session.beginSeek()!
        let later = session.beginSeek()!
        let stale = IndexAdvance.advanced
        if session.isCurrent(seek) {
            XCTFail("the first seek was still current")
        }
        XCTAssertTrue(session.isCurrent(later))
        XCTAssertEqual(stale, .advanced)
        XCTAssertTrue(session.adopt(later, .paused))
        XCTAssertFalse(session.adopt(seek, .playing))
    }

    func testCancelledReadIsNotEOF() throws {
        let file = URL(fileURLWithPath: "/tmp/cinecore-cancel.bin")
        try Data(repeating: 1, count: 64).write(to: file)
        let server = try RangeServer(root: "/tmp", port: 18790)
        defer { server.stop() }
        let source = try HTTPByteSource(url: URL(string: "http://127.0.0.1:18790/cinecore-cancel.bin")!)
        source.cancelWork()
        XCTAssertThrowsError(try source.readExact(at: 0, count: 16)) { error in
            XCTAssertEqual(classify(error).code, .cancelled)
        }
    }

    func testHTTPCacheIsCapped() throws {
        let url = URL(fileURLWithPath: "/tmp/cinecore-blocks.bin")
        if !FileManager.default.fileExists(atPath: url.path) {
            let block = Data(count: 256 * 1024)
            _ = FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            for _ in 0 ..< 50 { try handle.write(contentsOf: block) }
            try handle.close()
        }
        let server = try RangeServer(root: "/tmp", port: 18791)
        defer { server.stop() }
        let source = try HTTPByteSource(url: URL(string: "http://127.0.0.1:18791/cinecore-blocks.bin")!)
        for index in 0 ..< 50 {
            _ = try source.read(at: Int64(index) * 256 * 1024, count: 32)
        }
        XCTAssertLessThanOrEqual(source.cachedBlockCount, 48)
        XCTAssertGreaterThan(source.transport.requests, 0)
        XCTAssertGreaterThan(source.transport.bytes, 0)
    }

    func testClusterCacheDropsUnrelatedClusters() throws {
        let url = URL(fileURLWithPath: "/tmp/cinecore-evict.mkv")
        try writeCuedMkv(url, clusters: 120)
        let data = try Data(contentsOf: url)
        let media = CinecoreOpen.open(source: IncrementalMemory(data), name: "evict.mkv")
        let index = try XCTUnwrap(media.matroska)
        for time in stride(from: 0, to: 120, by: 1) {
            XCTAssertEqual(index.index(covering: Double(time)), .advanced)
        }
        XCTAssertLessThanOrEqual(index.indexedClusters, 96)
        XCTAssertEqual(index.sampleCount(for: 1), 1)
        XCTAssertEqual(index.samples(for: 1).map { Int($0.pts) }, [119])
    }

    func testDiagnosticsReportIsReadable() {
        var snap = CinecoreDiagnostics()
        snap.state = "playing"
        snap.name = "movie.mkv"
        snap.container = "mkv"
        snap.videoCodec = "HEVC"
        snap.hdr = "HDR10"
        snap.requests = 4
        snap.bytes = 1000
        let text = snap.report
        XCTAssertTrue(text.contains("playing"))
        XCTAssertTrue(text.contains("HEVC"))
        XCTAssertTrue(text.contains("HDR10"))
        XCTAssertTrue(text.contains("4"))
    }

    func testBufferingAndEndedGoThroughTheSession() {
        let session = PlayerSession()
        let generation = session.beginOpen()
        XCTAssertTrue(session.adopt(generation, .ready))
        XCTAssertTrue(session.adopt(generation, .playing))
        let playing = playbackFlags(session.currentState)
        XCTAssertTrue(playing.playing)
        XCTAssertFalse(playing.buffering)
        XCTAssertTrue(session.adopt(generation, .buffering))
        let stalled = playbackFlags(session.currentState)
        XCTAssertFalse(stalled.playing)
        XCTAssertTrue(stalled.buffering)
        XCTAssertTrue(session.adopt(generation, .playing))
        XCTAssertTrue(session.adopt(generation, .ended))
        XCTAssertEqual(session.currentState, .ended)
        let ended = playbackFlags(session.currentState)
        XCTAssertFalse(ended.playing)
        XCTAssertFalse(ended.buffering)
    }

    func testIndexStallBecomesFailed() {
        let session = PlayerSession()
        let generation = session.beginOpen()
        XCTAssertTrue(session.adopt(generation, .ready))
        XCTAssertTrue(session.adopt(generation, .playing))
        let failure = CinecoreFailure(.indexing, "Indexing stalled.")
        XCTAssertTrue(session.adopt(generation, .failed(failure)))
        if case .failed(let error) = session.currentState {
            XCTAssertEqual(error.code, .indexing)
        } else {
            XCTFail("expected failed")
        }
    }

    func testFlagsAreNeverPlayingAndBuffering() {
        let states: [PlaybackState] = [.idle, .opening, .ready, .playing, .buffering, .paused, .seeking, .ended, .failed(CinecoreFailure(.network, "down"))]
        for state in states {
            let flags = playbackFlags(state)
            XCTAssertFalse(flags.playing && flags.buffering)
        }
    }

    func testCancelledTokenAbortsTheLengthProbe() throws {
        let file = URL(fileURLWithPath: "/tmp/cinecore-abort.bin")
        try Data(repeating: 7, count: 128).write(to: file)
        let server = try RangeServer(root: "/tmp", port: 18792)
        defer { server.stop() }
        try "2000".write(toFile: "/tmp/cinecore-delay-18792", atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: "/tmp/cinecore-delay-18792") }
        let token = CancelToken()
        let started = Date()
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
            token.cancel()
        }
        XCTAssertThrowsError(try HTTPByteSource(url: URL(string: "http://127.0.0.1:18792/cinecore-abort.bin")!, token: token)) { error in
            XCTAssertEqual(classify(error).code, .cancelled)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.2)
    }

    func testAlreadyCancelledTokenMakesNoRequest() throws {
        let file = URL(fileURLWithPath: "/tmp/cinecore-nocall.bin")
        try Data(repeating: 3, count: 32).write(to: file)
        let server = try RangeServer(root: "/tmp", port: 18793)
        defer { server.stop() }
        let before = server.requests
        let token = CancelToken()
        token.cancel()
        XCTAssertThrowsError(try HTTPByteSource(url: URL(string: "http://127.0.0.1:18793/cinecore-nocall.bin")!, token: token)) { error in
            XCTAssertEqual(classify(error).code, .cancelled)
        }
        XCTAssertEqual(server.requests, before)
    }
}
