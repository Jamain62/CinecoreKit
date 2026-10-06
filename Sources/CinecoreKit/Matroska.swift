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
}

struct MkvResult {
    var docType: String
    var duration: Double
    var tracks: [LoadedTrack]
    var warnings: [String]
    var log: [String]
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
        } else if h.id == MID.cluster {
            break
        }
        let next = dataStart + payload
        if next <= o { break }
        o = next
    }
    if title.isEmpty == false { log.append(title) }
    log.append("\(docType) · timescale \(scale) ns · \(drafts.count) tracks")
    var samplesByTrack: [Int: [SampleRec]] = [:]
    for draft in drafts { samplesByTrack[draft.number] = [] }
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
            let frames = indexCluster(source, payloadStart, payloadEnd, scale, drafts)
            for frame in frames {
                samplesByTrack[frame.track, default: []].append(SampleRec(
                    pts: frame.pts, duration: frame.duration, key: frame.key, offset: frame.offset, size: frame.size, inline: nil
                ))
            }
        }
        clusters += 1
        clusterAt = payloadEnd
    }
    if clusters == 0 { warnings.append("No cluster found. There is nothing to decode.") }
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
    return .success(MkvResult(docType: docType, duration: max(duration, tracks.map(\.report.duration).max() ?? 0), tracks: tracks, warnings: warnings, log: log))
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
private func indexCluster(_ source: MediaByteSource, _ start: Int64, _ end: Int64, _ scale: Int, _ drafts: [MkDraft]) -> [FrameRef] {
    var clusterTs = 0
    var frames: [FrameRef] = []
    var o = start
    while o + 2 < end {
        guard let h = peekId(source, o), let size = h.size else { break }
        let header = Int64(h.idLen + h.sizeLen)
        let dataStart = o + header
        let dataEnd = dataStart + Int64(size)
        if dataEnd <= dataStart || dataEnd > end { break }
        if h.id == MID.timestamp {
            clusterTs = uintOf(exactBytes(source, dataStart, min(size, 8)))
        } else if h.id == MID.simpleBlock {
            frames.append(contentsOf: indexBlock(source, dataStart, dataEnd, clusterTs, scale, true, true, 0))
        } else if h.id == MID.blockGroup {
            frames.append(contentsOf: indexGroup(source, dataStart, dataEnd, clusterTs, scale))
        }
        o = dataEnd
    }
    fillFrameDurations(&frames, drafts)
    return frames
}

private func indexGroup(_ source: MediaByteSource, _ start: Int64, _ end: Int64, _ clusterTs: Int, _ scale: Int) -> [FrameRef] {
    var blockAt: (Int64, Int64)?
    var duration = 0
    var referenced = false
    var o = start
    while o + 2 < end {
        guard let h = peekId(source, o), let size = h.size else { break }
        let header = Int64(h.idLen + h.sizeLen)
        let dataStart = o + header
        let dataEnd = dataStart + Int64(size)
        if dataEnd <= dataStart || dataEnd > end { break }
        if h.id == MID.block { blockAt = (dataStart, dataEnd) }
        if h.id == MID.blockDuration { duration = uintOf(exactBytes(source, dataStart, min(size, 8))) }
        if h.id == MID.reference { referenced = true }
        o = dataEnd
    }
    guard let blockAt else { return [] }
    return indexBlock(source, blockAt.0, blockAt.1, clusterTs, scale, false, !referenced, duration)
}

private func indexBlock(_ source: MediaByteSource, _ start: Int64, _ end: Int64, _ clusterTs: Int, _ scale: Int, _ simple: Bool, _ keyHint: Bool, _ blockDur: Int) -> [FrameRef] {
    let length = end - start
    if length < 4 { return [] }
    let prefix = exactBytes(source, start, Int(min(length, 16)))
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
    let spans = laceSpans(source, start + Int64(p), end, lacing)
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

/// Lace headers only. `start` is the first byte after the block flags. `end` is the end of the block.
private func laceSpans(_ source: MediaByteSource, _ start: Int64, _ end: Int64, _ mode: Int) -> [(Int64, Int64)] {
    if mode == 0 { return start < end ? [(start, end)] : [] }
    if start >= end { return [] }
    if mode == 2 {
        let countByte = exactBytes(source, start, 1)
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
    let countByte = exactBytes(source, start, 1)
    if countByte.isEmpty { return [] }
    let count = Int(countByte[0]) + 1
    var pos = start + 1
    if mode == 1 {
        var sizes: [Int64] = []
        for _ in 0 ..< (count - 1) {
            var s: Int64 = 0
            while pos < end {
                let b = exactBytes(source, pos, 1)
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
    guard let first = readExactVint(source, pos, end) else { return pos < end ? [(pos, end)] : [] }
    pos += Int64(first.len)
    var sizes = [Int64(first.value)]
    for i in 1 ..< count {
        guard let v = readExactVint(source, pos, end) else { break }
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

private func readExactVint(_ source: MediaByteSource, _ offset: Int64, _ limit: Int64) -> (value: Int, len: Int)? {
    if offset >= limit { return nil }
    let first = exactBytes(source, offset, 1)
    if first.isEmpty { return nil }
    let len = vintLen(Int(first[0]))
    if offset + Int64(len) > limit { return nil }
    let raw = len == 1 ? first : exactBytes(source, offset, len)
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
