import Foundation

struct TsResult {
    var packetSize: Int
    var headerSkip: Int
    var duration: Double
    var video: LoadedTrack?
    var audio: LoadedTrack?
    var warnings: [String]
    var log: [String]
}

private struct Es { var type: Int; var pid: Int; var lang: String? }

func parseTs(_ source: Data) -> TsResult {
    var warnings: [String] = []
    var log: [String] = []
    var packetSize = 188
    var headerSkip = 0
    if source.count > 188 && source[0] == 0x47 && source[188] == 0x47 {
        packetSize = 188
    } else if source.count > 196 && source[4] == 0x47 && source[196] == 0x47 {
        packetSize = 192
        headerSkip = 4
    } else {
        warnings.append("Transport stream sync was not on a 188 or 192-byte grid. Trying 188.")
    }
    let programs = scanPsi(source, packetSize, headerSkip)
    if programs.isEmpty { warnings.append("No program map. Elementary streams could not be assigned.") }
    let videoEs = programs.first { $0.type == 0x1b || $0.type == 0x24 }
    let audioEs = programs.first { $0.type == 0x0f || $0.type == 0x11 || $0.type == 0x81 || $0.type == 0x87 }
    log.append("MPEG-TS \(packetSize) B · video PID \(videoEs.map { String($0.pid) } ?? "—") · audio PID \(audioEs.map { String($0.pid) } ?? "—")")

    var videoSamples: [SampleRec] = []
    var audioSamples: [SampleRec] = []
    var pesStart = -1
    var pesPid = -1
    var pesPts = 0.0
    var pesKey = false
    func flush(_ end: Int) {
        if pesStart < 0 || end <= pesStart { return }
        let rec = SampleRec(pts: pesPts, duration: 0, key: pesKey, offset: pesStart, size: end - pesStart, inline: nil)
        if let videoEs, pesPid == videoEs.pid { videoSamples.append(rec) }
        else if let audioEs, pesPid == audioEs.pid, audioEs.type == 0x0f || audioEs.type == 0x11 { audioSamples.append(rec) }
        pesStart = -1
    }
    var offset = 0
    while offset + packetSize <= source.count {
        let base = offset + headerSkip
        if source[base] == 0x47 {
            let pid = ((Int(source[base + 1]) & 0x1f) << 8) | Int(source[base + 2])
            let pusi = (Int(source[base + 1]) & 0x40) != 0
            let adapt = (Int(source[base + 3]) >> 4) & 3
            if !pusi && pesStart >= 0, let videoEs, pid == videoEs.pid && pid == pesPid && !pesKey {
                let mid = payloadOffset(source, base, adapt)
                if mid >= 0 {
                    let slice = source.subdata(in: (base + mid) ..< min(source.count, offset + packetSize))
                    if hasIdr(slice, videoEs.type == 0x24) { pesKey = true }
                }
            }
            if pusi && (pid == videoEs?.pid || pid == audioEs?.pid) {
                flush(offset)
                let payloadOff = payloadOffset(source, base, adapt)
                let pts = payloadOff >= 0 ? readPts(source.subdata(in: (base + payloadOff) ..< min(source.count, offset + packetSize))) : nil
                pesStart = offset
                pesPid = pid
                pesPts = pts ?? videoSamples.last?.pts ?? 0
                pesKey = false
                if let videoEs, pid == videoEs.pid, payloadOff >= 0 {
                    let slice = source.subdata(in: (base + payloadOff) ..< min(source.count, offset + packetSize))
                    pesKey = hasIdr(slice, videoEs.type == 0x24)
                }
            }
        }
        offset += packetSize
    }
    flush(offset)
    fillDurations(&videoSamples, 1 / 24)
    let origin = min(videoSamples.first?.pts ?? .infinity, audioSamples.first?.pts ?? .infinity)
    if origin.isFinite && origin > 0.001 {
        for i in videoSamples.indices { videoSamples[i].pts -= origin }
        for i in audioSamples.indices { audioSamples[i].pts -= origin }
    }
    let audioFrames = expandAac(source, audioSamples, packetSize, headerSkip)
    var videoOut: LoadedTrack?
    if let videoEs {
        let hevc = videoEs.type == 0x24
        let firstKey = videoSamples.first { $0.key } ?? videoSamples.first
        var description: Data?
        var codec = hevc ? "hvc1.1.6.L120.B0" : "avc1.42E01E"
        var profile: String?
        var pictureW = 0
        var pictureH = 0
        if let firstKey {
            let raw = extractPes(source, firstKey.offset, firstKey.size, packetSize, headerSkip)
            let nals = splitAnnexB(raw)
            if !hevc {
                let sps = nals.filter { !$0.isEmpty && (Int($0[0]) & 0x1f) == 7 }
                let pps = nals.filter { !$0.isEmpty && (Int($0[0]) & 0x1f) == 8 }
                if let avcC = buildAvcC(sps, pps) {
                    description = avcC
                    let rec = avcRecord(avcC)
                    codec = rec.codec
                    profile = rec.profile
                }
                if let sps0 = sps.first, let size = avcPictureSize(sps0) {
                    pictureW = size.0
                    pictureH = size.1
                }
            }
        }
        let step = videoSamples.first { $0.duration > 0.001 }?.duration
        let dur = videoSamples.last.map { $0.pts + $0.duration } ?? 0
        let report = TrackReport(
            id: videoEs.pid, kind: .video, codec: codec, codecLabel: hevc ? "HEVC" : (profile.map { "H.264 \($0)" } ?? "H.264"),
            language: videoEs.lang, width: pictureW == 0 ? nil : pictureW, height: pictureH == 0 ? nil : pictureH,
            fps: step.map { 1 / $0 }, profile: profile, level: nil, hdr: HdrReport.sdr(), audio: nil, duration: dur, bitrate: nil
        )
        videoOut = LoadedTrack(
            report: report, samples: videoSamples,
            video: VideoSetup(
                family: hevc ? .hevc : .avc,
                codecs: hevc ? ["hvc1.1.6.L93.B0", "hev1.1.6.L93.B0", codec] : [codec, "avc1.42E01E", "avc1.4D401F", "avc1.640028"],
                description: description, codedWidth: pictureW == 0 ? 16 : pictureW, codedHeight: pictureH == 0 ? 16 : pictureH,
                bitstream: .annexb, atoms: [:]
            ),
            audio: nil, playableAudio: false, timescale: 90000
        )
    }
    var audioOut: LoadedTrack?
    if let audioEs {
        let aac = audioEs.type == 0x0f || audioEs.type == 0x11
        let eac = audioEs.type == 0x87
        let ac3 = audioEs.type == 0x81
        var setup: AudioSetup?
        if aac, let first = audioSamples.first {
            let raw = extractPes(source, first.offset, first.size, packetSize, headerSkip)
            if let adts = splitAdts(raw).first {
                let parsed = parseAsc(adts.config)
                setup = AudioSetup(codecs: ["mp4a.40.\(parsed?.objectType ?? 2)"], description: adts.config, sampleRate: parsed?.sampleRate ?? 48000, channels: parsed?.channels ?? 2)
            }
        }
        let label = aac ? "AAC" : eac ? "E-AC-3" : ac3 ? "AC-3" : "type \(String(audioEs.type, radix: 16))"
        let frames = aac ? audioFrames : []
        let report = TrackReport(
            id: audioEs.pid, kind: .audio, codec: setup?.codecs.first ?? label, codecLabel: label, language: audioEs.lang,
            width: nil, height: nil, fps: nil, profile: nil, level: nil, hdr: HdrReport.sdr(),
            audio: AudioReport(codecLabel: eac ? "Dolby Digital Plus" : ac3 ? "Dolby Digital" : label, channels: setup?.channels, layout: nil, sampleRate: setup?.sampleRate, atmos: false, detail: aac ? nil : "Identified in the program map. This engine plays an AAC PID when one is present."),
            duration: frames.last.map { $0.pts + $0.duration } ?? 0, bitrate: nil
        )
        audioOut = LoadedTrack(report: report, samples: frames, video: nil, audio: setup, playableAudio: setup != nil, timescale: setup?.sampleRate ?? 48000)
    }
    let duration = max(videoOut?.report.duration ?? 0, audioOut?.report.duration ?? 0)
    if videoOut != nil { videoOut?.report.duration = duration }
    return TsResult(packetSize: packetSize, headerSkip: headerSkip, duration: duration, video: videoOut, audio: audioOut, warnings: warnings, log: log)
}

private func scanPsi(_ source: Data, _ packetSize: Int, _ headerSkip: Int) -> [Es] {
    let windowCount = min(source.count, packetSize * 4000)
    var pmtPid = -1
    var streams: [Es] = []
    var o = 0
    while o + packetSize <= windowCount {
        let base = o + headerSkip
        if source[base] == 0x47 {
            let pid = ((Int(source[base + 1]) & 0x1f) << 8) | Int(source[base + 2])
            let pusi = (Int(source[base + 1]) & 0x40) != 0
            let adapt = (Int(source[base + 3]) >> 4) & 3
            if pusi {
                let payloadAt = payloadOffset(source, base, adapt)
                if payloadAt >= 0 {
                    let payload = source.subdata(in: (base + payloadAt) ..< min(source.count, o + packetSize))
                    if pid == 0 && pmtPid < 0 { pmtPid = readPat(payload) }
                    else if pmtPid >= 0 && pid == pmtPid && streams.isEmpty {
                        streams.append(contentsOf: readPmt(payload))
                        if !streams.isEmpty { break }
                    }
                }
            }
        }
        o += packetSize
    }
    return streams
}

private func psiSection(_ payload: Data) -> Data {
    if payload.isEmpty { return payload }
    let start = 1 + Int(payload[0])
    if start < payload.count { return payload.subdata(in: start ..< payload.count) }
    return Data()
}

private func readPat(_ payload: Data) -> Int {
    let sec = psiSection(payload)
    if sec.count < 12 || sec[0] != 0 { return -1 }
    let sectionLen = ((Int(sec[1]) & 0x0f) << 8) | Int(sec[2])
    var o = 8
    let end = min(sec.count, 3 + sectionLen - 4)
    while o + 4 <= end {
        let program = (Int(sec[o]) << 8) | Int(sec[o + 1])
        let pid = ((Int(sec[o + 2]) & 0x1f) << 8) | Int(sec[o + 3])
        if program != 0 { return pid }
        o += 4
    }
    return -1
}

private func readPmt(_ payload: Data) -> [Es] {
    let sec = psiSection(payload)
    if sec.isEmpty || sec[0] != 0x02 || sec.count < 12 { return [] }
    let sectionLen = ((Int(sec[1]) & 0x0f) << 8) | Int(sec[2])
    let infoLen = ((Int(sec[10]) & 0x0f) << 8) | Int(sec[11])
    var o = 12 + infoLen
    let end = min(sec.count, 3 + sectionLen - 4)
    var out: [Es] = []
    while o + 5 <= end {
        let type = Int(sec[o])
        let pid = ((Int(sec[o + 1]) & 0x1f) << 8) | Int(sec[o + 2])
        let esLen = ((Int(sec[o + 3]) & 0x0f) << 8) | Int(sec[o + 4])
        var lang: String?
        let descEnd = min(end, o + 5 + esLen)
        var d = o + 5
        while d + 2 <= descEnd && d + 1 < sec.count {
            let tag = Int(sec[d])
            let len = Int(sec[d + 1])
            if tag == 0x0a && d + 4 < sec.count {
                lang = String(bytes: [sec[d + 2], sec[d + 3], sec[d + 4]], encoding: .ascii)
            }
            d += 2 + len
        }
        out.append(Es(type: type, pid: pid, lang: lang))
        o = descEnd
    }
    return out
}

private func payloadOffset(_ buf: Data, _ base: Int, _ adapt: Int) -> Int {
    if adapt == 1 { return 4 }
    if adapt == 3 || adapt == 2 {
        if base + 4 >= buf.count { return -1 }
        return 5 + Int(buf[base + 4])
    }
    return -1
}

private func readPts(_ payload: Data) -> Double? {
    if payload.count < 14 { return nil }
    if payload[0] != 0 || payload[1] != 0 || payload[2] != 1 { return nil }
    if (Int(payload[7]) & 0x80) == 0 { return nil }
    let o = 9
    if o + 5 > payload.count { return nil }
    let pts = (Int(payload[o]) & 0x0e) * (1 << 29)
        + ((Int(payload[o + 1]) << 22) | ((Int(payload[o + 2]) & 0xfe) << 14) | (Int(payload[o + 3]) << 7) | (Int(payload[o + 4]) >> 1))
    return Double(pts) / 90000
}

private func hasIdr(_ payload: Data, _ hevc: Bool) -> Bool {
    splitAnnexB(payload).contains { n in
        if n.isEmpty { return false }
        if !hevc { return (Int(n[0]) & 0x1f) == 5 }
        let t = (Int(n[0]) >> 1) & 0x3f
        return t == 19 || t == 20 || t == 21
    }
}

private func fillDurations(_ samples: inout [SampleRec], _ fallback: Double) {
    for i in samples.indices {
        if i + 1 < samples.count && samples[i + 1].pts > samples[i].pts {
            samples[i].duration = samples[i + 1].pts - samples[i].pts
        } else {
            samples[i].duration = fallback
        }
    }
}

func extractPes(_ source: Data, _ offset: Int, _ size: Int, _ packetSize: Int, _ headerSkip: Int) -> Data {
    let end = min(source.count, offset + size)
    if offset < 0 || offset >= end { return Data() }
    let raw = source.subdata(in: offset ..< end)
    var parts: [Data] = []
    var first = true
    var o = 0
    while o + packetSize <= raw.count {
        let base = o + headerSkip
        if raw[base] == 0x47 {
            let adapt = (Int(raw[base + 3]) >> 4) & 3
            let payloadAt = payloadOffset(raw, base, adapt)
            if payloadAt >= 0 && base + payloadAt < o + packetSize {
                var slice = raw.subdata(in: (base + payloadAt) ..< (o + packetSize))
                if first {
                    slice = pesBody(slice)
                    first = false
                }
                if !slice.isEmpty { parts.append(slice) }
            }
        }
        o += packetSize
    }
    return Bytes.concat(parts)
}

private func pesBody(_ payload: Data) -> Data {
    if payload.count < 9 || payload[0] != 0 || payload[1] != 0 || payload[2] != 1 { return payload }
    let start = 9 + Int(payload[8])
    if start < payload.count { return payload.subdata(in: start ..< payload.count) }
    return Data()
}

private struct Adts { var config: Data; var frame: Data }

private func splitAdts(_ data: Data) -> [Adts] {
    var out: [Adts] = []
    var i = 0
    while i + 7 < data.count {
        if data[i] != 0xff || (Int(data[i + 1]) & 0xf0) != 0xf0 { i += 1; continue }
        let protection = (Int(data[i + 1]) & 1) == 1
        let profile = ((Int(data[i + 2]) >> 6) & 3) + 1
        let freq = (Int(data[i + 2]) >> 2) & 0xf
        let ch = ((Int(data[i + 2]) & 1) << 2) | ((Int(data[i + 3]) >> 6) & 3)
        let len = ((Int(data[i + 3]) & 3) << 11) | (Int(data[i + 4]) << 3) | ((Int(data[i + 5]) >> 5) & 7)
        let header = protection ? 7 : 9
        if len < header || i + len > data.count { break }
        let config = Data([UInt8((profile << 3) | ((freq >> 1) & 7)), UInt8(((freq & 1) << 7) | (ch << 3))])
        out.append(Adts(config: config, frame: data.subdata(in: (i + header) ..< (i + len))))
        i += len
    }
    return out
}

private func expandAac(_ source: Data, _ pes: [SampleRec], _ packetSize: Int, _ headerSkip: Int) -> [SampleRec] {
    var frames: [SampleRec] = []
    for sample in pes {
        let body = extractPes(source, sample.offset, sample.size, packetSize, headerSkip)
        let adts = splitAdts(body)
        if adts.isEmpty { frames.append(sample); continue }
        let rate = parseAsc(adts[0].config)?.sampleRate ?? 48000
        let step = 1024.0 / Double(rate)
        for (index, frame) in adts.enumerated() {
            frames.append(SampleRec(pts: sample.pts + Double(index) * step, duration: step, key: true, offset: 0, size: frame.frame.count, inline: frame.frame))
        }
    }
    return frames
}
