import Foundation

private struct IdSize { var id: Int; var idLen: Int; var size: Int?; var sizeLen: Int }
private struct El { var id: Int; var start: Int; var end: Int }

private func vintLen(_ b: Int) -> Int {
    if b == 0 { return 1 }
    var n = 1
    var mask = 0x80
    while n <= 8 && (b & mask) == 0 { mask >>= 1; n += 1 }
    return n
}

private func readIdSize(_ data: Data, _ offset: Int) -> IdSize? {
    if offset >= data.count { return nil }
    let idLen = vintLen(Int(data[offset]))
    if offset + idLen >= data.count { return nil }
    var id = 0
    for i in 0 ..< idLen { id = id * 256 + Int(data[offset + i]) }
    let sizePos = offset + idLen
    let sizeLen = vintLen(sizePos < data.count ? Int(data[sizePos]) : 0)
    if sizePos + sizeLen > data.count { return nil }
    let marker = 1 << (8 - sizeLen)
    var size = Int(data[sizePos]) & (marker - 1)
    var unknown = size == marker - 1
    if sizeLen > 1 {
        for i in 1 ..< sizeLen {
            let by = Int(data[sizePos + i])
            size = size * 256 + by
            if by != 0xff { unknown = false }
        }
    }
    if sizeLen == 1 && (Int(data[sizePos]) & 0x7f) == 0x7f { unknown = true }
    return IdSize(id: id, idLen: idLen, size: unknown ? nil : size, sizeLen: sizeLen)
}

private func uintOf(_ data: Data) -> Int {
    var v = 0
    for b in data { v = v * 256 + Int(b) }
    return v
}

private func floatOf(_ data: Data) -> Double {
    if data.count >= 8 {
        let bits = data.prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        return Double(bitPattern: bits)
    }
    if data.count >= 4 {
        let bits = data.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        return Double(Float(bitPattern: bits))
    }
    return 0
}

private func textOf(_ data: Data) -> String {
    String(data: data, encoding: .utf8) ?? ""
}

private func elements(_ data: Data, _ start: Int, _ end: Int) -> [El] {
    var out: [El] = []
    var o = start
    let limit = min(end, data.count)
    while o + 2 < limit {
        guard let head = readIdSize(data, o) else { break }
        let header = head.idLen + head.sizeLen
        let payload = head.size ?? (limit - (o + header))
        let elStart = o + header
        let elEnd = min(limit, elStart + payload)
        if elEnd < elStart { break }
        out.append(El(id: head.id, start: elStart, end: elEnd))
        if head.size == nil { break }
        o = elEnd
    }
    return out
}

private func child(_ data: Data, _ el: El, _ id: Int) -> El? {
    elements(data, el.start, el.end).first { $0.id == id }
}

private enum MID {
    static let segment = 0x18538067
    static let info = 0x1549a966
    static let timestampScale = 0x2ad7b1
    static let duration = 0x4489
    static let title = 0x7ba9
    static let tracks = 0x1654ae6b
    static let track = 0xae
    static let trackNumber = 0xd7
    static let trackType = 0x83
    static let defaultDuration = 0x23e383
    static let name = 0x536e
    static let language = 0x22b59c
    static let codecId = 0x86
    static let codecPrivate = 0x63a2
    static let codecName = 0x258688
    static let video = 0xe0
    static let pixelWidth = 0xb0
    static let pixelHeight = 0xba
    static let audio = 0xe1
    static let sampling = 0xb5
    static let channels = 0x9f
    static let colour = 0x55b0
    static let transfer = 0x55ba
    static let primaries = 0x55bb
    static let matrix = 0x55b1
    static let range = 0x55b9
    static let maxCll = 0x55bc
    static let maxFall = 0x55bd
    static let cluster = 0x1f43b675
    static let timestamp = 0xe7
    static let simpleBlock = 0xa3
    static let blockGroup = 0xa0
    static let block = 0xa1
    static let blockDuration = 0x9b
    static let reference = 0xfb
    static let seekHead = 0x114d9b74
    static let seek = 0x4dbb
    static let seekID = 0x53ab
    static let seekPosition = 0x53ac
    static let cues = 0x1c53bb6b
    static let cuePoint = 0xbb
    static let cueTime = 0xb3
    static let cueTrackPositions = 0xb7
    static let cueTrack = 0xf7
    static let cueClusterPosition = 0xf1
}

struct MkvResult {
    var docType: String
    var duration: Double
    var tracks: [LoadedTrack]
    var warnings: [String]
    var log: [String]
    var index: MatroskaIndex?
}

private func peekId(_ source: MediaByteSource, _ offset: Int64) -> IdSize? {
    if offset < 0 || offset >= source.length { return nil }
    let window = exactBytes(source, offset, 16)
    return readIdSize(window, 0)
}

private func exactBytes(_ source: MediaByteSource, _ offset: Int64, _ count: Int) -> Data {
    guard count > 0, offset >= 0, offset < source.length else { return Data() }
    let n = Int(min(Int64(count), source.length - offset))
    var delay = 0.2
    for attempt in 0 ..< 4 {
        do { return try source.readExact(at: offset, count: n) }
        catch {
            if attempt == 3 { return Data() }
            Thread.sleep(forTimeInterval: delay)
            delay = min(delay * 2, 2)
        }
    }
    return Data()
}

/// A read that failed is not an empty file. Callers decide whether to retry.
private func bytesNow(_ source: MediaByteSource, _ offset: Int64, _ count: Int) throws -> Data {
    guard count > 0, offset >= 0, offset < source.length else { return Data() }
    let n = Int(min(Int64(count), source.length - offset))
    let data = try source.readExact(at: offset, count: n)
    if data.count != n {
        throw CinecoreError("Short index read at byte \(offset): \(data.count) of \(n).")
    }
    return data
}

private func peekNow(_ source: MediaByteSource, _ offset: Int64) throws -> IdSize? {
    if offset < 0 || offset >= source.length { return nil }
    return readIdSize(try bytesNow(source, offset, 16), 0)
}

public enum IndexAdvance: Equatable {
    case advanced
    case endOfFile
    case malformed
    case retry
}

func parseMatroska(_ source: MediaByteSource, webm: Bool) -> Result<MkvResult, CinecoreError> {
    var warnings: [String] = []
    var log: [String] = []
    let fileLength = source.length
    guard let top = peekId(source, 0), top.id == 0x1a45dfa3 else {
        return .failure(CinecoreError("Not an EBML file."))
    }
    let ebmlPayload = Int64(top.idLen + top.sizeLen)
    let ebmlSize = Int64(top.size ?? 0)
    let ebmlEnd = ebmlPayload + ebmlSize
    var docType = "matroska"
    if ebmlSize > 0 && ebmlSize < 1_000_000 {
        let ebml = exactBytes(source, ebmlPayload, Int(ebmlSize))
        for el in elements(ebml, 0, ebml.count) where el.id == 0x4282 {
            docType = textOf(ebml.subdata(in: el.start ..< el.end))
        }
    }
    var o = ebmlEnd
    guard let seg = peekId(source, o), seg.id == MID.segment else {
        return .failure(CinecoreError("Matroska segment is missing."))
    }
    let segmentData = o + Int64(seg.idLen + seg.sizeLen)
    let segmentEnd = seg.size == nil ? fileLength : min(fileLength, segmentData + Int64(seg.size ?? 0))
    o = segmentData
    var scale = 1_000_000
    var duration = 0.0
    var title = ""
    var drafts: [MkDraft] = []
    var seekMap: [Int: Int64] = [:]
    var cuePayload: Data?
    var guardN = 0
    while o + 2 < segmentEnd && guardN < 4000 {
        guardN += 1
        guard let h = peekId(source, o) else { break }
        let headerLen = Int64(h.idLen + h.sizeLen)
        let dataStart = o + headerLen
        if h.size == nil { break }
        let payload = Int64(h.size ?? 0)
        if h.id == MID.info && payload > 0 && payload < 1_000_000 {
            let buf = exactBytes(source, dataStart, Int(payload))
            for el in elements(buf, 0, buf.count) {
                let raw = buf.subdata(in: el.start ..< el.end)
                if el.id == MID.timestampScale { scale = uintOf(raw) == 0 ? scale : uintOf(raw) }
                if el.id == MID.duration { duration = (floatOf(raw) * Double(scale)) / 1e9 }
                if el.id == MID.title { title = textOf(raw) }
            }
        } else if h.id == MID.tracks && payload > 0 && payload < 8_000_000 {
            let buf = exactBytes(source, dataStart, Int(payload))
            for el in elements(buf, 0, buf.count) where el.id == MID.track {
                if let built = buildMkTrack(buf, el) { drafts.append(built) }
            }
        } else if h.id == MID.seekHead && payload > 0 && payload < 1_000_000 {
            seekMap = parseSeekHead(exactBytes(source, dataStart, Int(payload)))
        } else if h.id == MID.cues && payload > 0 && payload < 32_000_000 {
            cuePayload = exactBytes(source, dataStart, Int(payload))
        } else if h.id == MID.cluster {
            break
        }
        let next = dataStart + payload
        if next <= o { break }
        o = next
    }
    if title.isEmpty == false { log.append(title) }
    log.append("\(docType) · timescale \(scale) ns · \(drafts.count) tracks")
    let remote = source.indexesIncrementally
    var samplesByTrack: [Int: [SampleRec]] = [:]
    for draft in drafts { samplesByTrack[draft.number] = [] }
    var timeline: MatroskaIndex?
    if remote {
        if cuePayload == nil, let relative = seekMap[MID.cues] {
            cuePayload = elementPayload(source, segmentData + relative)
        }
        let cueList = parseCueList(cuePayload ?? Data(), scale, segmentData)
        let timelineBox = MatroskaIndex(source: source, segmentEnd: segmentEnd, scale: scale, drafts: drafts, cues: cueList)
        if let head = peekId(source, o), head.id == MID.cluster {
            timelineBox.ingest(clusterAt: o)
        }
        for draft in drafts {
            samplesByTrack[draft.number] = timelineBox.samples(for: draft.number)
        }
        timeline = timelineBox
        log.append("remote cues \(cueList.count) · indexed \(timelineBox.indexedClusters) cluster")
        if cueList.isEmpty {
            warnings.append("No Matroska cues. Playback can start, but a far seek has to walk forward cluster by cluster.")
        }
    } else {
        var clusterAt = o
        var clusters = 0
        while clusterAt + 2 < segmentEnd && clusters < 200_000 {
            guard let h = peekId(source, clusterAt) else { break }
            let headerLen = Int64(h.idLen + h.sizeLen)
            if h.size == nil { break }
            let payload = Int64(h.size ?? 0)
            if h.id != MID.cluster {
                clusterAt = clusterAt + headerLen + payload
                continue
            }
            let payloadStart = clusterAt + headerLen
            let payloadEnd = payloadStart + payload
            if payload > 0 && payload < 512_000_000 && payloadStart < fileLength && payloadEnd <= fileLength {
                do {
                    let frames = try indexCluster(source, payloadStart, payloadEnd, scale, drafts)
                    for frame in frames {
                        samplesByTrack[frame.track, default: []].append(SampleRec(
                            pts: frame.pts, duration: frame.duration, key: frame.key, offset: frame.offset, size: frame.size, inline: nil
                        ))
                    }
                } catch {
                    warnings.append("Cluster read failed: \(error). Indexing stopped.")
                    break
                }
            }
            clusters += 1
            clusterAt = payloadEnd
        }
        if clusters == 0 { warnings.append("No cluster found. There is nothing to decode.") }
    }
    var tracks: [LoadedTrack] = []
    for draft in drafts {
        var samples = samplesByTrack[draft.number] ?? []
        samples.sort { $0.pts < $1.pts }
        var report = draft.report
        if let last = samples.last { report.duration = max(duration, last.pts + last.duration) }
        else { report.duration = duration }
        tracks.append(LoadedTrack(report: report, samples: samples, video: draft.video, audio: draft.audio, playableAudio: draft.playable, timescale: 1_000_000_000))
    }
    if webm || docType == "webm" { log.append("WebM") }
    let movie = max(duration, tracks.map(\.report.duration).max() ?? 0)
    return .success(MkvResult(docType: docType, duration: movie, tracks: tracks, warnings: warnings, log: log, index: timeline))
}

private func parseSeekHead(_ buf: Data) -> [Int: Int64] {
    var map: [Int: Int64] = [:]
    for seek in elements(buf, 0, buf.count) where seek.id == MID.seek {
        var id = 0
        var position = 0
        for el in elements(buf, seek.start, seek.end) {
            let raw = buf.subdata(in: el.start ..< el.end)
            if el.id == MID.seekID { id = uintOf(raw) }
            if el.id == MID.seekPosition { position = uintOf(raw) }
        }
        if id != 0 { map[id] = Int64(position) }
    }
    return map
}

private func parseCueList(_ buf: Data, _ scale: Int, _ segmentData: Int64) -> [MatroskaCue] {
    var out: [MatroskaCue] = []
    for point in elements(buf, 0, buf.count) where point.id == MID.cuePoint {
        var cueTime = 0
        var cluster: Int?
        for el in elements(buf, point.start, point.end) {
            if el.id == MID.cueTime { cueTime = uintOf(buf.subdata(in: el.start ..< el.end)) }
            if el.id == MID.cueTrackPositions {
                for child in elements(buf, el.start, el.end) where child.id == MID.cueClusterPosition {
                    cluster = uintOf(buf.subdata(in: child.start ..< child.end))
                }
            }
        }
        if let cluster {
            out.append(MatroskaCue(time: (Double(cueTime) * Double(scale)) / 1e9, cluster: segmentData + Int64(cluster)))
        }
    }
    return out.sorted { $0.time < $1.time }
}

private func elementPayload(_ source: MediaByteSource, _ at: Int64) -> Data? {
    guard let head = peekId(source, at), let size = head.size, size > 0, size < 32_000_000 else { return nil }
    let start = at + Int64(head.idLen + head.sizeLen)
    return exactBytes(source, start, size)
}

public struct MatroskaCue: Equatable {
    public var time: Double
    /// Absolute file offset of the Cluster element.
    public var cluster: Int64
}

/// Cue-driven Matroska index. Remote opens keep this and fill it as playback moves.
/// The cache remembers every cluster that has been read. The playback frontier is
/// separate: a seek, including a seek back onto a cached cluster, starts a new
/// chain at that cluster. Later cached clusters are not treated as the next frame.
public final class MatroskaIndex: @unchecked Sendable {
    /// A cue-less seek stops after this many new clusters even if the time is still ahead.
    /// One cluster a second is far more than a feature film. The cap is there so a
    /// missing cue does not turn into an unbounded scan.
    public static let cueLessWalkLimit = 50_000
    public let cueCount: Int
    public private(set) var indexedClusters = 0
    public private(set) var finished = false
    private let source: any MediaByteSource
    private let segmentEnd: Int64
    private let scale: Int
    private let drafts: [MkDraft]
    private let cues: [MatroskaCue]
    private let lock = NSLock()
    private var clusters: [Int64: (end: Int64, frames: [FrameRef])] = [:]
    /// File offsets of the clusters in the active chain, in playback order.
    private var playback: [Int64] = []
    /// First byte after the active chain. The next cluster, if there is one, starts here.
    private var frontier: Int64 = 0
    /// Flat per-track samples for the active chain. Appended to. Not rebuilt per frame.
    private var activeSamples: [Int: [SampleRec]] = [:]
    public private(set) var lastIndexError: String?

    fileprivate init(source: any MediaByteSource, segmentEnd: Int64, scale: Int, drafts: [MkDraft], cues: [MatroskaCue]) {
        self.source = source
        self.segmentEnd = segmentEnd
        self.scale = scale
        self.drafts = drafts
        self.cues = cues
        cueCount = cues.count
    }

    public func samples(for track: Int) -> [SampleRec] {
        lock.lock()
        defer { lock.unlock() }
        return activeSamples[track] ?? []
    }

    public func sampleCount(for track: Int) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return activeSamples[track]?.count ?? 0
    }

    public func sample(track: Int, at index: Int) -> SampleRec? {
        lock.lock()
        defer { lock.unlock() }
        guard let list = activeSamples[track], index >= 0, index < list.count else { return nil }
        return list[index]
    }

    public func firstIndex(track: Int, from time: Double, keyframe: Bool) -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard let list = activeSamples[track], !list.isEmpty else { return 0 }
        var lo = 0
        var hi = list.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if list[mid].pts < time { lo = mid + 1 } else { hi = mid }
        }
        var index = min(lo, list.count - 1)
        if keyframe {
            while index > 0, list[index].key == false { index -= 1 }
        }
        return index
    }

    @discardableResult
    public func index(covering time: Double) -> IndexAdvance {
        if !cues.isEmpty {
            guard let cue = cues.last(where: { $0.time <= time + 0.0008 }) ?? cues.first else { return .endOfFile }
            if !isCached(cue.cluster) {
                let step = cache(clusterAt: cue.cluster)
                if step != .advanced { return step }
            }
            activate(cue.cluster)
            return .advanced
        }
        lock.lock()
        let hit = clusterCovering(time)
        lock.unlock()
        if let hit {
            activate(hit)
            return .advanced
        }
        var walked = 0
        while walked < Self.cueLessWalkLimit {
            if playbackCovers(time) { return .advanced }
            let step = indexAhead()
            if step != .advanced { return step }
            walked += 1
        }
        return .advanced
    }

    @discardableResult
    public func indexAhead() -> IndexAdvance {
        lock.lock()
        var cursor = frontier
        let endLimit = segmentEnd
        lock.unlock()
        if cursor + 2 >= endLimit {
            lock.lock()
            finished = true
            lock.unlock()
            return .endOfFile
        }
        var skips = 0
        while cursor + 2 < endLimit && skips < 32 {
            let head: IdSize
            do {
                guard let parsed = try peekNow(source, cursor) else {
                    lastIndexError = "Cluster header at byte \(cursor) is not an element."
                    return .malformed
                }
                head = parsed
            } catch {
                lastIndexError = String(describing: error)
                return .retry
            }
            guard let size = head.size else {
                lastIndexError = "Cluster element at byte \(cursor) has no size."
                return .malformed
            }
            let header = Int64(head.idLen + head.sizeLen)
            let next = cursor + header + Int64(size)
            if next <= cursor {
                lastIndexError = "Element at byte \(cursor) does not advance."
                return .malformed
            }
            if head.id == MID.cluster {
                if !isCached(cursor) {
                    let step = cache(clusterAt: cursor)
                    if step != .advanced { return step }
                }
                return extend(cursor) ? .advanced : .malformed
            }
            cursor = next
            skips += 1
        }
        lock.lock()
        finished = true
        lock.unlock()
        return .endOfFile
    }

    @discardableResult
    fileprivate func ingest(clusterAt fileOffset: Int64) -> Bool {
        guard cache(clusterAt: fileOffset) == .advanced else { return false }
        activate(fileOffset)
        return true
    }

    private func isCached(_ fileOffset: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return clusters[fileOffset] != nil
    }

    private func cache(clusterAt fileOffset: Int64) -> IndexAdvance {
        if isCached(fileOffset) { return .advanced }
        do {
            guard let head = try peekNow(source, fileOffset), head.id == MID.cluster, let size = head.size else {
                lastIndexError = "Expected a cluster at byte \(fileOffset)."
                return .malformed
            }
            let header = Int64(head.idLen + head.sizeLen)
            let start = fileOffset + header
            let end = start + Int64(size)
            guard end > start, end <= source.length else { return .malformed }
            let frames = try indexCluster(source, start, end, scale, drafts)
            lock.lock()
            if clusters[fileOffset] == nil {
                clusters[fileOffset] = (end, frames)
                indexedClusters = clusters.count
            }
            lock.unlock()
            return .advanced
        } catch {
            lastIndexError = String(describing: error)
            return .retry
        }
    }

    private func activate(_ fileOffset: Int64) {
        lock.lock()
        defer { lock.unlock() }
        guard let cluster = clusters[fileOffset] else { return }
        playback = [fileOffset]
        frontier = cluster.end
        finished = frontier >= segmentEnd
        activeSamples = records(cluster.frames)
    }

    private func extend(_ fileOffset: Int64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let cluster = clusters[fileOffset] else { return false }
        if playback.last == fileOffset { return false }
        playback.append(fileOffset)
        frontier = cluster.end
        finished = frontier >= segmentEnd
        for (track, recs) in records(cluster.frames) {
            activeSamples[track, default: []].append(contentsOf: recs)
        }
        return true
    }

    private func records(_ frames: [FrameRef]) -> [Int: [SampleRec]] {
        var built: [Int: [SampleRec]] = [:]
        for frame in frames {
            built[frame.track, default: []].append(SampleRec(
                pts: frame.pts, duration: frame.duration, key: frame.key, offset: frame.offset, size: frame.size, inline: nil
            ))
        }
        return built
    }

    private func clusterCovering(_ time: Double) -> Int64? {
        var best: (offset: Int64, start: Double)?
        for (offset, cluster) in clusters {
            guard let start = cluster.frames.map(\.pts).min() else { continue }
            let end = cluster.frames.map { $0.pts + $0.duration }.max() ?? start
            guard start <= time + 0.0008, time <= end + 0.0008 else { continue }
            if best == nil || start >= best!.start { best = (offset, start) }
        }
        return best?.offset
    }

    private func playbackCovers(_ time: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let last = activeSamples.values.compactMap { $0.max(by: { $0.pts < $1.pts }) }.max(by: { $0.pts < $1.pts })
        guard let last else { return false }
        return last.pts + max(last.duration, 0) + 0.001 >= time
    }
}

private struct MkDraft {
    var number: Int
    var report: TrackReport
    var video: VideoSetup?
    var audio: AudioSetup?
    var playable: Bool
    var defaultNs: Int
}

private func buildMkTrack(_ buf: Data, _ el: El) -> MkDraft? {
    guard let numEl = child(buf, el, MID.trackNumber), let codecEl = child(buf, el, MID.codecId) else { return nil }
    let number = uintOf(buf.subdata(in: numEl.start ..< numEl.end))
    let type = child(buf, el, MID.trackType).map { uintOf(buf.subdata(in: $0.start ..< $0.end)) } ?? 0
    let codecId = textOf(buf.subdata(in: codecEl.start ..< codecEl.end))
    let kind: TrackKind = type == 1 ? .video : type == 2 ? .audio : .other
    let defaultNs = child(buf, el, MID.defaultDuration).map { uintOf(buf.subdata(in: $0.start ..< $0.end)) } ?? 0
    let language = child(buf, el, MID.language).map { textOf(buf.subdata(in: $0.start ..< $0.end)) }
    let priv = child(buf, el, MID.codecPrivate).map { buf.subdata(in: $0.start ..< $0.end) }
    var hdr = HdrReport.sdr()
    var width: Int?
    var height: Int?
    var sampleRate: Int?
    var channels: Int?
    if let videoEl = child(buf, el, MID.video) {
        if let w = child(buf, videoEl, MID.pixelWidth) { width = uintOf(buf.subdata(in: w.start ..< w.end)) }
        if let h = child(buf, videoEl, MID.pixelHeight) { height = uintOf(buf.subdata(in: h.start ..< h.end)) }
        if let colour = child(buf, videoEl, MID.colour) { readColour(buf, colour, &hdr) }
    }
    if let audioEl = child(buf, el, MID.audio) {
        if let rate = child(buf, audioEl, MID.sampling) { sampleRate = Int(floatOf(buf.subdata(in: rate.start ..< rate.end))) }
        if let ch = child(buf, audioEl, MID.channels) { channels = uintOf(buf.subdata(in: ch.start ..< ch.end)) }
    }
    finishHdr(&hdr)
    let described = describeMk(codecId, priv, width, height, sampleRate, channels, &hdr)
    let report = TrackReport(
        id: number, kind: kind, codec: described.codec, codecLabel: described.label, language: language,
        width: width, height: height, fps: defaultNs > 0 ? 1e9 / Double(defaultNs) : nil,
        profile: described.profile, level: nil, hdr: hdr, audio: described.audioReport, duration: 0, bitrate: nil
    )
    return MkDraft(number: number, report: report, video: described.video, audio: described.audio, playable: described.playable, defaultNs: defaultNs)
}

private func readColour(_ buf: Data, _ colour: El, _ hdr: inout HdrReport) {
    func num(_ id: Int) -> Int? {
        guard let el = child(buf, colour, id) else { return nil }
        return uintOf(buf.subdata(in: el.start ..< el.end))
    }
    if let t = num(MID.transfer) { hdr.transfer = [1: "BT.709", 16: "PQ", 18: "HLG"][t] ?? "TC \(t)" }
    if let p = num(MID.primaries) { hdr.primaries = [1: "BT.709", 9: "BT.2020"][p] ?? "P \(p)" }
    if let m = num(MID.matrix) { hdr.matrix = [1: "BT.709", 9: "BT.2020 NC"][m] ?? "M \(m)" }
    if num(MID.range) == 2 { hdr.fullRange = true }
    if let cll = num(MID.maxCll) { hdr.maxCll = cll }
    if let fall = num(MID.maxFall) { hdr.maxFall = fall }
}

private struct MkCodec {
    var codec: String
    var label: String
    var profile: String?
    var video: VideoSetup?
    var audio: AudioSetup?
    var playable: Bool
    var audioReport: AudioReport?
}

private func describeMk(_ codecId: String, _ priv: Data?, _ width: Int?, _ height: Int?, _ sampleRate: Int?, _ channels: Int?, _ hdr: inout HdrReport) -> MkCodec {
    let w = width ?? 16
    let h = height ?? 16
    if codecId == "V_MPEG4/ISO/AVC" {
        let rec = priv.flatMap { $0.count >= 7 ? avcRecord($0) : nil }
        let codec = rec?.codec ?? "avc1.42E01E"
        return MkCodec(codec: codec, label: rec.map { "H.264 \($0.profile)" } ?? "H.264", profile: rec?.profile, video: VideoSetup(family: .avc, codecs: [codec], description: priv, codedWidth: w, codedHeight: h, bitstream: .avcc, atoms: [:]), audio: nil, playable: false, audioReport: nil)
    }
    if codecId == "V_MPEGH/ISO/HEVC" {
        return MkCodec(codec: "hvc1.1.6.L120.B0", label: "HEVC", profile: nil, video: VideoSetup(family: .hevc, codecs: ["hvc1.1.6.L93.B0", "hev1.1.6.L93.B0"], description: priv, codedWidth: w, codedHeight: h, bitstream: .avcc, atoms: [:]), audio: nil, playable: false, audioReport: nil)
    }
    if codecId == "V_VP9" {
        let codec = priv.map(vp9Codec) ?? "vp09.00.10.08"
        return MkCodec(codec: codec, label: "VP9", profile: nil, video: VideoSetup(family: .vp9, codecs: [codec], description: priv, codedWidth: w, codedHeight: h, bitstream: .raw, atoms: [:]), audio: nil, playable: false, audioReport: nil)
    }
    if codecId == "V_VP8" {
        return MkCodec(codec: "vp8", label: "VP8", profile: nil, video: VideoSetup(family: .vp8, codecs: ["vp8"], description: nil, codedWidth: w, codedHeight: h, bitstream: .raw, atoms: [:]), audio: nil, playable: false, audioReport: nil)
    }
    if codecId == "V_AV1" {
        return MkCodec(codec: "av01.0.08M.08", label: "AV1", profile: nil, video: VideoSetup(family: .av1, codecs: ["av01.0.08M.08"], description: priv, codedWidth: w, codedHeight: h, bitstream: .raw, atoms: [:]), audio: nil, playable: false, audioReport: nil)
    }
    if codecId == "A_AAC" || codecId.hasPrefix("A_AAC/") {
        let asc = priv.flatMap(parseAsc)
        let rate = asc?.sampleRate ?? sampleRate ?? 48000
        let ch = asc?.channels ?? channels ?? 2
        let codec = "mp4a.40.\(asc?.objectType ?? 2)"
        return MkCodec(codec: codec, label: "AAC-LC", profile: nil, video: nil, audio: AudioSetup(codecs: [codec], description: priv, sampleRate: rate, channels: ch), playable: true, audioReport: AudioReport(codecLabel: "AAC-LC", channels: ch, layout: ch == 2 ? "stereo" : "\(ch) ch", sampleRate: rate, atmos: false, detail: nil))
    }
    if codecId == "A_OPUS" {
        let ch = channels ?? 2
        return MkCodec(codec: "opus", label: "Opus", profile: nil, video: nil, audio: AudioSetup(codecs: ["opus"], description: priv, sampleRate: 48000, channels: ch), playable: false, audioReport: AudioReport(codecLabel: "Opus", channels: ch, layout: ch == 2 ? "stereo" : "\(ch) ch", sampleRate: 48000, atmos: false, detail: "Opus is identified. Apple's audio converter does not decode it here."))
    }
    _ = hdr
    return MkCodec(codec: codecId, label: codecId, profile: nil, video: nil, audio: nil, playable: false, audioReport: kindAudio(codecId, channels, sampleRate))
}

private func kindAudio(_ codecId: String, _ channels: Int?, _ sampleRate: Int?) -> AudioReport? {
    if codecId == "A_EAC3" || codecId == "A_AC3" || codecId == "A_TRUEHD" || codecId.hasPrefix("A_DTS") {
        let label = codecId == "A_EAC3" ? "Dolby Digital Plus" : codecId == "A_AC3" ? "Dolby Digital" : codecId == "A_TRUEHD" ? "Dolby TrueHD" : "DTS"
        return AudioReport(codecLabel: label, channels: channels, layout: nil, sampleRate: sampleRate, atmos: false, detail: "Identified. Not decoded.")
    }
    return nil
}

private struct FrameRef { var track: Int; var pts: Double; var duration: Double; var key: Bool; var offset: Int; var size: Int }

/// Cluster index. Element headers, timestamps, and block headers are read.
/// Frame bytes are skipped. Their file offset and size are what playback reads later.
private func indexCluster(_ source: MediaByteSource, _ start: Int64, _ end: Int64, _ scale: Int, _ drafts: [MkDraft]) throws -> [FrameRef] {
    var clusterTs = 0
    var frames: [FrameRef] = []
    var o = start
    while o + 2 < end {
        guard let h = try peekNow(source, o), let size = h.size else { break }
        let header = Int64(h.idLen + h.sizeLen)
        let dataStart = o + header
        let dataEnd = dataStart + Int64(size)
        if dataEnd <= dataStart || dataEnd > end { break }
        if h.id == MID.timestamp {
            clusterTs = uintOf(try bytesNow(source, dataStart, min(size, 8)))
        } else if h.id == MID.simpleBlock {
            frames.append(contentsOf: try indexBlock(source, dataStart, dataEnd, clusterTs, scale, true, true, 0))
        } else if h.id == MID.blockGroup {
            frames.append(contentsOf: try indexGroup(source, dataStart, dataEnd, clusterTs, scale))
        }
        o = dataEnd
    }
    fillFrameDurations(&frames, drafts)
    return frames
}

private func indexGroup(_ source: MediaByteSource, _ start: Int64, _ end: Int64, _ clusterTs: Int, _ scale: Int) throws -> [FrameRef] {
    var blockAt: (Int64, Int64)?
    var duration = 0
    var referenced = false
    var o = start
    while o + 2 < end {
        guard let h = try peekNow(source, o), let size = h.size else { break }
        let header = Int64(h.idLen + h.sizeLen)
        let dataStart = o + header
        let dataEnd = dataStart + Int64(size)
        if dataEnd <= dataStart || dataEnd > end { break }
        if h.id == MID.block { blockAt = (dataStart, dataEnd) }
        if h.id == MID.blockDuration { duration = uintOf(try bytesNow(source, dataStart, min(size, 8))) }
        if h.id == MID.reference { referenced = true }
        o = dataEnd
    }
    guard let blockAt else { return [] }
    return try indexBlock(source, blockAt.0, blockAt.1, clusterTs, scale, false, !referenced, duration)
}

private func indexBlock(_ source: MediaByteSource, _ start: Int64, _ end: Int64, _ clusterTs: Int, _ scale: Int, _ simple: Bool, _ keyHint: Bool, _ blockDur: Int) throws -> [FrameRef] {
    let length = end - start
    if length < 4 { return [] }
    let prefix = try bytesNow(source, start, Int(min(length, 16)))
    guard let vint = readValueVint(prefix, 0) else { return [] }
    var p = vint.len
    if p + 3 > prefix.count { return [] }
    let rel = (Int(prefix[p]) << 8) | Int(prefix[p + 1])
    let signed = rel & 0x8000 != 0 ? rel - 0x10000 : rel
    p += 2
    let flags = Int(prefix[p])
    p += 1
    let key = simple ? (flags & 0x80) != 0 : keyHint
    let lacing = (flags & 0x06) >> 1
    let spans = try laceSpans(source, start + Int64(p), end, lacing)
    let pts0 = (Double(clusterTs + signed) * Double(scale)) / 1e9
    let each = !spans.isEmpty && blockDur > 0 ? (Double(blockDur) * Double(scale)) / 1e9 / Double(spans.count) : 0
    var out: [FrameRef] = []
    for (i, span) in spans.enumerated() {
        let size = span.1 - span.0
        if size <= 0 || span.0 > Int64(Int.max) { continue }
        out.append(FrameRef(track: vint.value, pts: pts0 + Double(i) * each, duration: each, key: i == 0 ? key : false, offset: Int(span.0), size: Int(size)))
    }
    return out
}

private func laceSpans(_ source: MediaByteSource, _ start: Int64, _ end: Int64, _ mode: Int) throws -> [(Int64, Int64)] {
    if mode == 0 { return start < end ? [(start, end)] : [] }
    if start >= end { return [] }
    if mode == 2 {
        let countByte = try bytesNow(source, start, 1)
        if countByte.isEmpty { return [] }
        let count = Int(countByte[0]) + 1
        if count <= 0 { return [] }
        let frame = start + 1
        let total = end - frame
        if total <= 0 { return [] }
        let sz = total / Int64(count)
        return (0 ..< count).map { i in
            let a = frame + Int64(i) * sz
            let b = i == count - 1 ? end : frame + Int64(i + 1) * sz
            return (a, b)
        }
    }
    let countByte = try bytesNow(source, start, 1)
    if countByte.isEmpty { return [] }
    let count = Int(countByte[0]) + 1
    var pos = start + 1
    if mode == 1 {
        var sizes: [Int64] = []
        for _ in 0 ..< (count - 1) {
            var s: Int64 = 0
            while pos < end {
                let b = try bytesNow(source, pos, 1)
                if b.isEmpty { return [] }
                pos += 1
                s += Int64(b[0])
                if b[0] < 255 { break }
            }
            sizes.append(s)
        }
        var frames: [(Int64, Int64)] = []
        for s in sizes {
            let next = min(end, pos + s)
            if next > pos { frames.append((pos, next)) }
            pos += s
        }
        if pos < end { frames.append((pos, end)) }
        return frames
    }
    guard let first = try readExactVint(source, pos, end) else { return pos < end ? [(pos, end)] : [] }
    pos += Int64(first.len)
    var sizes = [Int64(first.value)]
    for i in 1 ..< count {
        guard let v = try readExactVint(source, pos, end) else { break }
        pos += Int64(v.len)
        let bias = (1 << (7 * v.len - 1)) - 1
        sizes.append(sizes[i - 1] + Int64(v.value - bias))
    }
    var frames: [(Int64, Int64)] = []
    for s in sizes {
        let next = min(end, pos + s)
        if next > pos { frames.append((pos, next)) }
        pos += s
    }
    if pos < end { frames.append((pos, end)) }
    return frames
}

private func readExactVint(_ source: MediaByteSource, _ offset: Int64, _ limit: Int64) throws -> (value: Int, len: Int)? {
    if offset >= limit { return nil }
    let first = try bytesNow(source, offset, 1)
    if first.isEmpty { return nil }
    let len = vintLen(Int(first[0]))
    if offset + Int64(len) > limit { return nil }
    let raw = len == 1 ? first : try bytesNow(source, offset, len)
    return readValueVint(raw, 0)
}

private func fillFrameDurations(_ frames: inout [FrameRef], _ drafts: [MkDraft]) {
    var byTrack: [Int: [Int]] = [:]
    for (i, f) in frames.enumerated() { byTrack[f.track, default: []].append(i) }
    for (track, indexes) in byTrack {
        let def = drafts.first { $0.number == track }?.defaultNs ?? 0
        for (n, index) in indexes.enumerated() {
            if frames[index].duration > 0 { continue }
            if n + 1 < indexes.count && frames[indexes[n + 1]].pts > frames[index].pts {
                frames[index].duration = frames[indexes[n + 1]].pts - frames[index].pts
            } else if def > 0 {
                frames[index].duration = Double(def) / 1e9
            } else {
                frames[index].duration = 1 / 24
            }
        }
    }
}

private func readValueVint(_ data: Data, _ offset: Int) -> (value: Int, len: Int)? {
    if offset >= data.count { return nil }
    let len = vintLen(Int(data[offset]))
    if offset + len > data.count { return nil }
    let marker = 1 << (8 - len)
    var value = Int(data[offset]) & (marker - 1)
    if len > 1 { for i in 1 ..< len { value = value * 256 + Int(data[offset + i]) } }
    return (value, len)
}
