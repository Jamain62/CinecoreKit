#if os(iOS) || os(macOS) || os(tvOS)
import AVFoundation
import CoreMedia
import Foundation
#if os(iOS) || os(tvOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
import SwiftUI

/// Swift player. The container is read by `CinecoreOpen`. H.264 and HEVC samples
/// are handed to VideoToolbox through `AVSampleBufferDisplayLayer`. AAC goes to
/// `AVSampleBufferAudioRenderer` when the format description can be built.
/// Dolby Vision atoms are attached to the format description; the RPU itself is
/// not composited in this process.
public final class CinecorePlayer: NSObject, ObservableObject, @unchecked Sendable {
    @Published public private(set) var info: MediaInfo?
    @Published public private(set) var time: Double = 0
    @Published public private(set) var duration: Double = 0
    @Published public private(set) var playing = false
    @Published public private(set) var decodePath = "not open"
    @Published public private(set) var detail = "Standby"
    @Published public private(set) var buffering = false
    @Published public private(set) var lastError: String?
    @Published public private(set) var state: PlaybackState = .idle
    @Published public private(set) var failure: CinecoreFailure?
    @Published public private(set) var diagnostics = CinecoreDiagnostics()

    public let view: CinecorePlayerView
    private let display = AVSampleBufferDisplayLayer()
    private let sync = AVSampleBufferRenderSynchronizer()
    private let audioRenderer = AVSampleBufferAudioRenderer()
    private var media: LoadedMedia?
    private var videoFormat: CMFormatDescription?
    private var audioFormat: CMAudioFormatDescription?
    private var nalLength = 4
    private var family: VideoFamily = .other
    private var audioAttached = false
    private var feeding = false
    private var feedGeneration = 0
    private var videoCursor = 0
    private var audioCursor = 0
    private var bufferHolds = 0
    private var workerRetries = 0
    private var videoDelay = 0.4
    private var audioDelay = 0.4
    private var readyDetail = "Standby"
    private var droppedVideo = 0
    private let session = PlayerSession()
    private let mediaQueue = DispatchQueue(label: "cinecore.samples")
    private let cursorLock = NSLock()
    private var ticker: Timer?

    public override init() {
        let view = CinecorePlayerView(display: display)
        self.view = view
        super.init()
        display.videoGravity = .resizeAspect
        display.backgroundColor = CGColor(gray: 0, alpha: 1)
        sync.addRenderer(display)
        display.controlTimebase = sync.timebase
    }

    public func open(data: Data, name: String) {
        releaseSource()
        let generation = session.beginOpen()
        publish()
        let opened = CinecoreOpen.open(data: data, name: name)
        guard session.isCurrent(generation) else { return }
        adopt(opened, generation: generation)
    }

    public func open(fileURL: URL) {
        releaseSource()
        let generation = session.beginOpen()
        publish()
        do {
            let opened = try CinecoreOpen.open(fileURL: fileURL)
            guard session.isCurrent(generation) else { return }
            adopt(opened, generation: generation)
        } catch {
            guard session.isCurrent(generation) else { return }
            let failure = classify(error)
            _ = session.adopt(generation, .failed(failure))
            self.failure = failure
            lastError = failure.message
            detail = failure.message
            publish()
        }
    }

    public func open(remote url: URL) {
        releaseSource()
        let generation = session.beginOpen()
        detail = "Opening"
        lastError = nil
        failure = nil
        publish()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let opened = try CinecoreOpen.open(remote: url)
                DispatchQueue.main.async {
                    guard let self, self.session.isCurrent(generation) else {
                        (opened.source as? HTTPByteSource)?.cancelWork()
                        return
                    }
                    (opened.source as? HTTPByteSource)?.attach(self.session.currentToken)
                    self.adopt(opened, generation: generation)
                }
            } catch {
                DispatchQueue.main.async {
                    guard let self, self.session.isCurrent(generation) else { return }
                    let failure = classify(error)
                    _ = self.session.adopt(generation, .failed(failure))
                    self.failure = failure
                    self.lastError = failure.message
                    self.detail = failure.message
                    self.publish()
                }
            }
        }
    }

    private func adopt(_ opened: LoadedMedia, generation: UInt64) {
        stopFeeding()
        stopTicker()
        sync.rate = 0
        display.flush()
        audioRenderer.flush()
        cursorLock.lock()
        media = opened
        cursorLock.unlock()
        info = opened.info
        duration = opened.info.duration
        time = 0
        playing = false
        lastError = nil
        videoFormat = nil
        audioFormat = nil
        videoCursor = 0
        audioCursor = 0
        guard let video = opened.video, let setup = video.video else {
            decodePath = "metadata"
            let message = opened.info.warnings.first ?? "No picture track."
            let failure = CinecoreFailure(.unsupported, message)
            _ = session.adopt(generation, .failed(failure))
            self.failure = failure
            lastError = message
            detail = message
            publish()
            return
        }
        family = setup.family
        switch setup.family {
        case .avc, .hevc:
            videoFormat = makeVideoFormat(setup)
            if videoFormat == nil {
                decodePath = "metadata"
                let failure = CinecoreFailure(.decoder, "VideoToolbox rejected the \(video.report.codecLabel) parameter sets.")
                _ = session.adopt(generation, .failed(failure))
                self.failure = failure
                lastError = failure.message
                detail = failure.message
                publish()
                return
            } else {
                decodePath = "VideoToolbox"
                readyDetail = video.report.codecLabel
                detail = readyDetail
                if video.report.hdr.dolbyVision != nil {
                    detail += " · base layer. RPU is attached for the display, not composited here."
                    readyDetail = detail
                }
            }
        case .jpeg:
            decodePath = "ImageIO"
            readyDetail = "Motion JPEG"
            detail = readyDetail
            if let first = video.samples.first, let bytes = try? loadSample(opened, first) {
                view.show(jpeg: bytes)
            }
        default:
            decodePath = "metadata"
            readyDetail = "\(video.report.codecLabel) was demuxed. This engine does not include a \(setup.family.rawValue) decoder."
            detail = readyDetail
            lastError = detail
        }
        if let audio = opened.audio, audio.playableAudio, let setup = audio.audio, setup.codecs.first?.hasPrefix("mp4a") == true {
            audioFormat = makeAudioFormat(setup)
            if audioFormat != nil && !audioAttached {
                sync.addRenderer(audioRenderer)
                audioAttached = true
            }
        }
        if case .failed = session.currentState { return }
        _ = session.adopt(generation, .ready)
        failure = nil
        lastError = nil
        publish()
    }

    public func play() {
        guard videoFormat != nil || family == .jpeg else {
            lastError = lastError ?? "Nothing playable is open."
            return
        }
        guard session.adopt(session.currentGeneration, .playing) else { return }
        publish()
        if family == .jpeg {
            playing = true
            startTicker()
            return
        }
        if !feeding { startFeeding(from: time) }
        sync.rate = 1
        playing = true
        startTicker()
    }

    public func pause() {
        if let timebase = sync.timebase {
            time = CMTimeGetSeconds(CMTimebaseGetTime(timebase))
        }
        sync.rate = 0
        _ = session.adopt(session.currentGeneration, .paused)
        publish()
        stopTicker()
    }

    public func seek(to seconds: Double) {
        let target = max(0, min(seconds, duration))
        let wasPlaying = playing
        guard let generation = session.beginSeek() else { return }
        publish()
        sync.rate = 0
        stopFeeding()
        display.flush()
        audioRenderer.flush()
        sync.setRate(0, time: CMTime(seconds: target, preferredTimescale: 600))
        (media?.source as? HTTPByteSource)?.cancelWork()
        (media?.source as? HTTPByteSource)?.attach(session.currentToken)
        let index = media?.matroska
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let step = index?.index(covering: target) ?? .advanced
            DispatchQueue.main.async {
                guard let self, self.session.isCurrent(generation) else { return }
                switch step {
                case .cancelled:
                    return
                case .retry:
                    self.workerRetries += 1
                    guard self.workerRetries <= 8, self.session.adopt(generation, .buffering) else {
                        let failure = CinecoreFailure(.seek, index?.lastIndexError ?? "Could not index that position.")
                        _ = self.session.adopt(generation, .failed(failure))
                        self.failure = failure
                        self.lastError = failure.message
                        self.detail = failure.message
                        self.publish()
                        return
                    }
                    self.detail = "Buffering"
                    self.publish()
                    let delay = min(0.4 * pow(2, Double(self.workerRetries - 1)), 5)
                    self.mediaQueue.asyncAfter(deadline: .now() + delay) {
                        DispatchQueue.main.async {
                            guard self.session.isCurrent(generation) else { return }
                            self.seek(to: target)
                        }
                    }
                case .malformed:
                    let failure = CinecoreFailure(.indexing, index?.lastIndexError ?? "Could not index that position.")
                    _ = self.session.adopt(generation, .failed(failure))
                    self.failure = failure
                    self.lastError = failure.message
                    self.detail = failure.message
                    self.publish()
                case .advanced, .endOfFile:
                    self.workerRetries = 0
                    let next: PlaybackState = wasPlaying ? .playing : .paused
                    _ = self.session.adopt(generation, next)
                    self.publish()
                    self.startFeeding(from: target)
                    if wasPlaying {
                        self.sync.rate = 1
                    }
                }
            }
        }
    }

    public func close() {
        releaseSource()
        _ = session.close()
        pauseClock()
        stopFeeding()
        stopTicker()
        display.flush()
        audioRenderer.flush()
        cursorLock.lock()
        media = nil
        cursorLock.unlock()
        info = nil
        videoFormat = nil
        audioFormat = nil
        decodePath = "not open"
        detail = "Standby"
        readyDetail = "Standby"
        time = 0
        duration = 0
        failure = nil
        lastError = nil
        droppedVideo = 0
        diagnostics = CinecoreDiagnostics()
        publish()
    }

    private func pauseClock() {
        sync.rate = 0
    }

    private func releaseSource() {
        (media?.source as? HTTPByteSource)?.cancelWork()
    }

    private func publish() {
        let next = session.currentState
        state = next
        playing = next == .playing
        buffering = next == .buffering || next == .opening || next == .seeking
        if case .failed(let error) = next {
            failure = error
            lastError = error.message
        }
        diagnostics = makeDiagnostics()
        detail = diagnostics.detail.isEmpty ? detail : detail
    }

    private func makeDiagnostics() -> CinecoreDiagnostics {
        var snap = CinecoreDiagnostics()
        snap.state = String(describing: session.currentState)
        snap.detail = detail
        snap.time = time
        snap.duration = duration
        snap.videoSample = videoCursor
        snap.audioSample = audioCursor
        snap.droppedVideo = droppedVideo
        snap.lastError = failure?.message ?? lastError ?? ""
        if let media {
            snap.container = media.info.container
            snap.name = media.info.name
            if let video = media.video {
                snap.videoCodec = video.report.codecLabel
                snap.hdr = video.report.hdr.label
            }
            if let audio = media.audio {
                snap.audioCodec = audio.report.audio?.codecLabel ?? audio.report.codecLabel
                snap.audioLayout = audio.report.audio?.layout ?? ""
                if audio.report.audio?.atmos == true { snap.audioLayout += " Atmos" }
            }
            if let span = media.matroska?.indexedSpan() {
                snap.indexedStart = span.0
                snap.indexedEnd = span.1
            }
            if let http = media.source as? HTTPByteSource {
                let transport = http.transport
                snap.requests = transport.requests
                snap.bytes = transport.bytes
                snap.retries = transport.retries
                snap.lastStatus = transport.status
                if !transport.error.isEmpty { snap.lastError = transport.error }
                snap.bytesPerSecond = transport.perSecond
            }
        }
        if let timebase = sync.timebase {
            let clock = CMTimeGetSeconds(CMTimebaseGetTime(timebase))
            if clock.isFinite { snap.avOffset = time - clock }
        }
        return snap
    }

    private func listedCount(_ media: LoadedMedia, video: Bool) -> Int {
        if let index = media.matroska {
            let id = video ? media.video?.report.id : media.audio?.report.id
            if let id { return index.sampleCount(for: id) }
        }
        return (video ? media.video?.samples : media.audio?.samples)?.count ?? 0
    }

    private func listedSample(_ media: LoadedMedia, video: Bool, at index: Int) -> SampleRec? {
        if let matroska = media.matroska {
            let id = video ? media.video?.report.id : media.audio?.report.id
            if let id { return matroska.sample(track: id, at: index) }
        }
        let samples = (video ? media.video?.samples : media.audio?.samples) ?? []
        guard index >= 0, index < samples.count else { return nil }
        return samples[index]
    }

    private func armCursors(from start: Double, generation: Int) {
        guard let media, media.video != nil else { return }
        let videoIndex: Int
        let audioIndex: Int
        if let matroska = media.matroska, let videoId = media.video?.report.id {
            videoIndex = matroska.firstIndex(track: videoId, from: start, keyframe: true)
            audioIndex = media.audio?.report.id.map { matroska.firstIndex(track: $0, from: start, keyframe: false) } ?? 0
        } else {
            videoIndex = FeedPoint.video(media.video?.samples ?? [], from: start)
            audioIndex = FeedPoint.audio(media.audio?.samples ?? [], from: start)
        }
        cursorLock.lock()
        guard generation == feedGeneration else {
            cursorLock.unlock()
            return
        }
        videoCursor = videoIndex
        audioCursor = audioIndex
        bufferHolds = 0
        videoDelay = 0.4
        audioDelay = 0.4
        cursorLock.unlock()
        display.requestMediaDataWhenReady(on: mediaQueue) { [weak self] in
            self?.supplyVideo(generation)
        }
        if audioFormat != nil {
            audioRenderer.requestMediaDataWhenReady(on: mediaQueue) { [weak self] in
                self?.supplyAudio(generation)
            }
        }
    }

    private func startFeeding(from start: Double) {
        guard let media, media.video != nil else { return }
        cursorLock.lock()
        feedGeneration += 1
        let generation = feedGeneration
        cursorLock.unlock()
        feeding = true
        let index = media.matroska
        mediaQueue.async { [weak self] in
            let step = index?.index(covering: start) ?? .advanced
            DispatchQueue.main.async {
                guard let self, generation == self.feedGeneration else { return }
                switch step {
                case .cancelled:
                    return
                case .retry:
                    self.workerRetries += 1
                    if self.workerRetries > 8 {
                        self.lastError = index?.lastIndexError ?? "Indexing stalled."
                        self.detail = self.lastError ?? ""
                        self.feeding = false
                        break
                    }
                    self.buffering = true
                    self.detail = "Buffering"
                    let delay = min(0.4 * pow(2, Double(self.workerRetries - 1)), 5)
                    self.mediaQueue.asyncAfter(deadline: .now() + delay) {
                        DispatchQueue.main.async {
                            guard generation == self.feedGeneration else { return }
                            self.startFeeding(from: start)
                        }
                    }
                case .malformed:
                    self.lastError = index?.lastIndexError ?? "Matroska index is malformed."
                    self.detail = self.lastError ?? ""
                    self.feeding = false
                case .advanced, .endOfFile:
                    self.workerRetries = 0
                    self.armCursors(from: start, generation: generation)
                }
            }
        }
    }

    private func stopFeeding() {
        display.stopRequestingMediaData()
        audioRenderer.stopRequestingMediaData()
        cursorLock.lock()
        feedGeneration += 1
        let generation = feedGeneration
        bufferHolds = 0
        videoDelay = 0.4
        audioDelay = 0.4
        cursorLock.unlock()
        feeding = false
        DispatchQueue.main.async { [weak self] in
            guard let self, generation == self.feedGeneration else { return }
            self.publish()
        }
    }

    private func supplyVideo(_ generation: Int) {
        guard let format = videoFormat else {
            display.stopRequestingMediaData()
            return
        }
        if display.status == .failed { display.flush() }
        while display.isReadyForMoreMediaData {
            cursorLock.lock()
            if generation != feedGeneration {
                cursorLock.unlock()
                return
            }
            guard let media, media.video != nil else {
                cursorLock.unlock()
                display.stopRequestingMediaData()
                return
            }
            let count = listedCount(media, video: true)
            if videoCursor >= count {
                let step = media.matroska?.indexAhead() ?? .endOfFile
                cursorLock.unlock()
                switch step {
                case .advanced:
                    continue
                case .cancelled:
                    display.stopRequestingMediaData()
                    return
                case .retry:
                    holdForBuffer(generation, video: true)
                    return
                case .endOfFile, .malformed:
                    if case .malformed = step {
                        DispatchQueue.main.async { [weak self] in
                            self?.lastError = media.matroska?.lastIndexError ?? "Matroska index is malformed."
                        }
                    }
                    display.stopRequestingMediaData()
                    return
                }
            }
            guard let sample = listedSample(media, video: true, at: videoCursor) else {
                cursorLock.unlock()
                display.stopRequestingMediaData()
                return
            }
            let cursor = videoCursor
            let total = count
            cursorLock.unlock()
            switch SamplePull.take(cursor: cursor, count: total, read: { try self.loadSample(media, sample) }) {
            case .finished:
                display.stopRequestingMediaData()
                return
            case .retry:
                holdForBuffer(generation, video: true)
                return
            case .enqueued(let next, let bytes):
                cursorLock.lock()
                if generation != feedGeneration {
                    cursorLock.unlock()
                    return
                }
                videoCursor = next
                videoDelay = 0.4
                cursorLock.unlock()
                noteFlowing()
                let normalized = normalize(bytes)
                guard !normalized.isEmpty, let buffer = makeVideoBuffer(normalized, sample, format) else { continue }
                display.enqueue(buffer)
            }
        }
    }

    private func supplyAudio(_ generation: Int) {
        guard let format = audioFormat else {
            audioRenderer.stopRequestingMediaData()
            return
        }
        while audioRenderer.isReadyForMoreMediaData {
            cursorLock.lock()
            if generation != feedGeneration {
                cursorLock.unlock()
                return
            }
            guard let media, let track = media.audio, track.playableAudio else {
                cursorLock.unlock()
                audioRenderer.stopRequestingMediaData()
                return
            }
            let count = listedCount(media, video: false)
            if audioCursor >= count {
                let step = media.matroska?.indexAhead() ?? .endOfFile
                cursorLock.unlock()
                switch step {
                case .advanced:
                    continue
                case .cancelled:
                    audioRenderer.stopRequestingMediaData()
                    return
                case .retry:
                    holdForBuffer(generation, video: false)
                    return
                case .endOfFile, .malformed:
                    audioRenderer.stopRequestingMediaData()
                    return
                }
            }
            guard let sample = listedSample(media, video: false, at: audioCursor) else {
                cursorLock.unlock()
                audioRenderer.stopRequestingMediaData()
                return
            }
            let cursor = audioCursor
            let total = count
            cursorLock.unlock()
            switch SamplePull.take(cursor: cursor, count: total, read: { try self.loadSample(media, sample) }) {
            case .finished:
                audioRenderer.stopRequestingMediaData()
                return
            case .retry:
                holdForBuffer(generation, video: false)
                return
            case .enqueued(let next, let bytes):
                cursorLock.lock()
                if generation != feedGeneration {
                    cursorLock.unlock()
                    return
                }
                audioCursor = next
                audioDelay = 0.4
                cursorLock.unlock()
                noteFlowing()
                guard !bytes.isEmpty, let buffer = makeAudioBuffer(bytes, sample, format) else { continue }
                audioRenderer.enqueue(buffer)
            }
        }
    }

    /// Failed read. The cursor stays put. The clock stops until a later read works.
    private func holdForBuffer(_ generation: Int, video: Bool) {
        cursorLock.lock()
        bufferHolds += 1
        let delay = video ? videoDelay : audioDelay
        if video { videoDelay = min(videoDelay * 2, 5) } else { audioDelay = min(audioDelay * 2, 5) }
        cursorLock.unlock()
        if video { display.stopRequestingMediaData() } else { audioRenderer.stopRequestingMediaData() }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.buffering = true
            self.detail = "Buffering"
            self.sync.rate = 0
        }
        mediaQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.cursorLock.lock()
            let live = generation == self.feedGeneration
            if live { self.bufferHolds = max(0, self.bufferHolds - 1) }
            let waiting = self.bufferHolds > 0
            self.cursorLock.unlock()
            guard live else { return }
            DispatchQueue.main.async {
                if !waiting {
                    self.buffering = false
                    self.detail = self.readyDetail
                    if self.playing { self.sync.rate = 1 }
                }
            }
            if video {
                self.display.requestMediaDataWhenReady(on: self.mediaQueue) { [weak self] in
                    self?.supplyVideo(generation)
                }
            } else {
                self.audioRenderer.requestMediaDataWhenReady(on: self.mediaQueue) { [weak self] in
                    self?.supplyAudio(generation)
                }
            }
        }
    }

    private func noteFlowing() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.bufferHolds == 0, self.buffering else { return }
            self.buffering = false
            self.detail = self.readyDetail
        }
    }

    private func loadSample(_ media: LoadedMedia, _ sample: SampleRec) throws -> Data {
        if let inline = sample.inline { return inline }
        if sample.offset < 0 || sample.size <= 0 { return Data() }
        let raw = try media.source.read(at: Int64(sample.offset), count: sample.size)
        if media.info.container == "ts", let packet = media.packetSize, let skip = media.headerSkip {
            return extractPesBytes(raw, packet, skip)
        }
        return raw
    }

    private func normalize(_ data: Data) -> Data {
        guard family == .avc || family == .hevc else { return data }
        let annex = data.count > 4 && data[0] == 0 && data[1] == 0 && (data[2] == 1 || (data[2] == 0 && data[3] == 1))
        if !annex && nalLength == 4 { return data }
        let nals = annex ? splitAnnexB(data) : lengthPrefixedNals(data, nalLength)
        var out = Data()
        for nal in nals {
            var len = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
            out.append(nal)
        }
        return out
    }

    private func lengthPrefixedNals(_ data: Data, _ length: Int) -> [Data] {
        var o = 0
        var nals: [Data] = []
        let ls = max(1, length)
        while o + ls <= data.count {
            var size = 0
            for _ in 0 ..< ls {
                size = (size << 8) | Int(data[o])
                o += 1
            }
            if size <= 0 || o + size > data.count { break }
            nals.append(data.subdata(in: o ..< (o + size)))
            o += size
        }
        return nals
    }

    private func makeVideoFormat(_ setup: VideoSetup) -> CMFormatDescription? {
        var atoms: [CFString: Any] = [:]
        for (key, value) in setup.atoms {
            atoms[key as CFString] = value as CFData
        }
        let extensions: CFDictionary? = atoms.isEmpty ? nil : [kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: atoms] as CFDictionary
        if setup.family == .avc, let avcC = setup.description ?? setup.atoms["avcC"] {
            let sets = avcParameterSets(avcC)
            nalLength = 4
            return parameterFormat(sets.sps + sets.pps, hevc: false, extensions: extensions)
        }
        if setup.family == .hevc, let hvcC = setup.description ?? setup.atoms["hvcC"] {
            nalLength = hvcC.count > 21 ? (Int(hvcC[21]) & 3) + 1 : 4
            return parameterFormat(hevcParameterSets(hvcC), hevc: true, extensions: extensions)
        }
        return nil
    }

    private func parameterFormat(_ sets: [Data], hevc: Bool, extensions: CFDictionary?) -> CMFormatDescription? {
        if sets.isEmpty { return nil }
        let owned = sets.map { $0 as NSData }
        var pointers = owned.map { UnsafePointer<UInt8>($0.bytes.assumingMemoryBound(to: UInt8.self)) }
        var sizes = owned.map(\.length)
        var format: CMFormatDescription?
        let status: OSStatus
        if hevc {
            status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: pointers.count,
                parameterSetPointers: &pointers, parameterSetSizes: &sizes,
                nalUnitHeaderLength: 4, extensions: extensions, formatDescriptionOut: &format
            )
        } else {
            status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: pointers.count,
                parameterSetPointers: &pointers, parameterSetSizes: &sizes,
                nalUnitHeaderLength: 4, extensions: extensions, formatDescriptionOut: &format
            )
        }
        return status == noErr ? format : nil
    }

    private func makeAudioFormat(_ setup: AudioSetup) -> CMAudioFormatDescription? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(setup.sampleRate), mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(max(1, setup.channels)), mBitsPerChannel: 0, mReserved: 0
        )
        let cookie = (setup.description ?? Data()) as NSData
        var format: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: cookie.length, magicCookie: cookie.length == 0 ? nil : cookie.bytes,
            extensions: nil, formatDescriptionOut: &format
        )
        return status == noErr ? format : nil
    }

    private func makeVideoBuffer(_ data: Data, _ sample: SampleRec, _ format: CMFormatDescription) -> CMSampleBuffer? {
        makeBuffer(data, sample, format)
    }

    private func makeAudioBuffer(_ data: Data, _ sample: SampleRec, _ format: CMAudioFormatDescription) -> CMSampleBuffer? {
        makeBuffer(data, sample, format)
    }

    private func makeBuffer(_ data: Data, _ sample: SampleRec, _ format: CMFormatDescription) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: data.count, flags: 0, blockBufferOut: &block
        ) == kCMBlockBufferNoErr, let block else { return nil }
        let replaced = data.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count)
        }
        if replaced != kCMBlockBufferNoErr { return nil }
        var timing = CMSampleTimingInfo(
            duration: CMTime(seconds: sample.duration > 0 ? sample.duration : 1.0 / 30.0, preferredTimescale: 600),
            presentationTimeStamp: CMTime(seconds: max(0, sample.pts), preferredTimescale: 600),
            decodeTimeStamp: .invalid
        )
        var size = data.count
        var buffer: CMSampleBuffer?
        let status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: block, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
            sampleSizeArray: &size, sampleBufferOut: &buffer
        )
        return status == noErr ? buffer : nil
    }

    private func startTicker() {
        stopTicker()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.family == .jpeg { self.advanceJpeg() ; return }
            guard let timebase = self.sync.timebase else { return }
            let now = CMTimeGetSeconds(CMTimebaseGetTime(timebase))
            if now.isFinite { self.time = now }
            if self.duration > 0 && now >= self.duration - 0.05 {
                self.pause()
            }
        }
        ticker = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func advanceJpeg() {
        guard let media, let track = media.video else { return }
        time += 0.1
        if time >= duration { pause(); return }
        if let sample = track.samples.last(where: { $0.pts <= time }) ?? track.samples.first,
           let bytes = try? loadSample(media, sample) {
            view.show(jpeg: bytes)
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }
}

#if os(iOS) || os(tvOS)
public final class CinecorePlayerView: UIView {
    private let imageView = UIImageView()
    init(display: AVSampleBufferDisplayLayer) {
        super.init(frame: .zero)
        backgroundColor = .black
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        display.frame = bounds
        layer.addSublayer(display)
    }
    public override func layoutSubviews() {
        super.layoutSubviews()
        layer.sublayers?.forEach { $0.frame = bounds }
    }
    func show(jpeg data: Data) {
        imageView.image = UIImage(data: data)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use CinecorePlayer") }
}
#elseif os(macOS)
public final class CinecorePlayerView: NSView {
    private let imageView = NSImageView()
    init(display: AVSampleBufferDisplayLayer) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        if let layer { layer.addSublayer(display) }
    }
    public override func layout() {
        super.layout()
        layer?.sublayers?.forEach { $0.frame = bounds }
    }
    func show(jpeg data: Data) {
        imageView.image = NSImage(data: data)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use CinecorePlayer") }
}
#endif

public struct CinecoreView: View {
    @ObservedObject var player: CinecorePlayer
    public init(player: CinecorePlayer) { self.player = player }
    public var body: some View {
        CinecoreRepresentable(player: player)
    }
}

#if os(iOS) || os(tvOS)
private struct CinecoreRepresentable: UIViewRepresentable {
    let player: CinecorePlayer
    func makeUIView(context: Context) -> CinecorePlayerView { player.view }
    func updateUIView(_ uiView: CinecorePlayerView, context: Context) {}
}
#elseif os(macOS)
private struct CinecoreRepresentable: NSViewRepresentable {
    let player: CinecorePlayer
    func makeNSView(context: Context) -> CinecorePlayerView { player.view }
    func updateNSView(_ nsView: CinecorePlayerView, context: Context) {}
}
#endif
#endif
