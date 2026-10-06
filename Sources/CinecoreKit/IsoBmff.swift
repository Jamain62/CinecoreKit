import Foundation

struct IsoResult {
    var format: String
    var brands: [String]
    var duration: Double
    var tracks: [LoadedTrack]
    var warnings: [String]
    var log: [String]
}

func parseIso(_ source: Data) -> IsoResult {
    var warnings: [String] = []
    var log: [String] = []
    var brands: [String] = []
    var movie: Data?
    var moofs: [(Data, Int)] = []
    var offset = 0
    while offset + 8 <= source.count {
        guard let header = headerAt(source, offset) else { break }
        if header.total < 8 { break }
        if header.type == "ftyp" {
            let body = Bytes.slice(source, offset + header.header, offset + min(header.total, header.header + 256))
            brands = [Bytes.fourcc(body, 0)]
            var i = 8
            while i + 4 <= body.count {
                brands.append(Bytes.fourcc(body, i))
                i += 4
            }
            log.append("ftyp \(brands.filter { !$0.isEmpty }.joined(separator: " "))")
        } else if header.type == "moov" {
            let size = header.total - header.header
            if size > 80_000_000 { warnings.append("Movie header is unusually large; sample index may be partial.") }
            movie = Bytes.slice(source, offset + header.header, offset + header.header + min(size, 80_000_000))
        } else if header.type == "moof" {
            let size = header.total - header.header
            if size > 0 && size < 8_000_000 {
                moofs.append((Bytes.slice(source, offset + header.header, offset + header.total), offset))
            }
        }
        let next = offset + header.total
        if next <= offset || next > source.count { break }
        offset = next
    }
    guard let movie else {
        warnings.append("No movie header found. The file is not a readable MP4 or MOV.")
        return IsoResult(format: "ISO BMFF", brands: brands, duration: 0, tracks: [], warnings: warnings, log: log)
    }
    let root = Bytes.boxes(movie, 0, movie.count)
    var movieDuration = 0.0
    if let mvhd = root.first(where: { $0.type == "mvhd" }) {
        let d = Bytes.slice(movie, mvhd.start, mvhd.end)
        let version = Bytes.u8(d, 0)
        if version == 1 && d.count >= 32 {
            let scale = Bytes.u32(d, 20)
            movieDuration = Double(Bytes.u64(d, 24)) / Double(scale == 0 ? 1000 : scale)
        } else if d.count >= 20 {
            let scale = Bytes.u32(d, 12)
            movieDuration = Double(Bytes.u32(d, 16)) / Double(scale == 0 ? 1000 : scale)
        }
    }
    var trex: [Int: (Int, Int, Int)] = [:]
    if let mvex = root.first(where: { $0.type == "mvex" }) {
        for box in Bytes.boxes(movie, mvex.start, mvex.end) where box.type == "trex" {
            let d = Bytes.slice(movie, box.start, box.end)
            if d.count >= 24 {
                trex[Bytes.u32(d, 4)] = (Bytes.u32(d, 12), Bytes.u32(d, 16), Bytes.u32(d, 20))
            }
        }
    }
    var tracks: [LoadedTrack] = []
    for trak in root where trak.type == "trak" {
        if let built = buildTrack(movie, trak, &warnings) { tracks.append(built) }
    }
    if !moofs.isEmpty {
        for moof in moofs { appendFragments(moof.0, moof.1, &tracks, trex) }
        log.append("\(moofs.count) movie fragments")
    }
    var duration = movieDuration
    for i in tracks.indices {
        let last = tracks[i].samples.last
        let end = last.map { $0.pts + $0.duration } ?? 0
        if end > duration { duration = end }
        if tracks[i].report.duration == 0 { tracks[i].report.duration = end }
        if tracks[i].report.fps == nil && tracks[i].report.kind == .video && tracks[i].samples.count > 1 {
            let span = tracks[i].samples[tracks[i].samples.count - 1].pts - tracks[i].samples[0].pts
            if span > 0 { tracks[i].report.fps = Double(tracks[i].samples.count - 1) / span }
        }
    }
    let qt = brands.contains("qt  ")
    let format = qt ? "QuickTime MOV" : (brands.contains { $0.hasPrefix("3gp") } ? "3GPP" : "MP4")
    log.append("\(format) · \(tracks.count) track\(tracks.count == 1 ? "" : "s") · \(String(format: "%.2f", duration))s")
    let clean = brands.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    return IsoResult(format: format, brands: clean, duration: duration, tracks: tracks, warnings: warnings, log: log)
}

private struct Header { var type: String; var header: Int; var total: Int }

private func headerAt(_ source: Data, _ offset: Int) -> Header? {
    if offset < 0 || offset + 8 > source.count { return nil }
    let h = Bytes.slice(source, offset, offset + 16)
    if h.count < 8 { return nil }
    let size32 = Bytes.u32(h, 0)
    let type = Bytes.fourcc(h, 4)
    if type.count != 4 || type.contains(where: { !$0.isASCII || $0.asciiValue! < 32 || $0.asciiValue! > 126 }) { return nil }
    if size32 == 1 {
        if h.count < 16 { return nil }
        let total = Bytes.u64(h, 8)
        if total < 16 { return nil }
        return Header(type: type, header: 16, total: total)
    }
    if size32 == 0 { return Header(type: type, header: 8, total: source.count - offset) }
    if size32 < 8 { return nil }
    return Header(type: type, header: 8, total: size32)
}

private func langOf(_ code: Int) -> String? {
    let a = 0x60 + ((code >> 10) & 31)
    let b = 0x60 + ((code >> 5) & 31)
    let c = 0x60 + (code & 31)
    let s = String(bytes: [UInt8(a), UInt8(b), UInt8(c)], encoding: .ascii) ?? ""
    if s.count == 3 && s != "und" && s.allSatisfy({ $0.isLetter && $0.isLowercase }) { return s }
    return nil
}

private func findBox(_ data: Data, _ parent: Box, _ type: String) -> Box? {
    Bytes.boxes(data, parent.start, parent.end).first { $0.type == type }
}

private func buildTrack(_ movie: Data, _ trak: Box, _ warnings: inout [String]) -> LoadedTrack? {
    guard let tkhd = findBox(movie, trak, "tkhd"), let mdia = findBox(movie, trak, "mdia") else { return nil }
    let tk = Bytes.slice(movie, tkhd.start, tkhd.end)
    let version = Bytes.u8(tk, 0)
    let id = version == 1 ? Bytes.u32(tk, 20) : Bytes.u32(tk, 12)
    var width = 0.0
    var height = 0.0
    if version == 1 && tk.count >= 96 {
        width = Double(Bytes.u32(tk, 88)) / 65536
        height = Double(Bytes.u32(tk, 92)) / 65536
    } else if tk.count >= 84 {
        width = Double(Bytes.u32(tk, 76)) / 65536
        height = Double(Bytes.u32(tk, 80)) / 65536
    }
    guard let mdhd = findBox(movie, mdia, "mdhd"), let hdlr = findBox(movie, mdia, "hdlr") else { return nil }
    let mh = Bytes.slice(movie, mdhd.start, mdhd.end)
    let mv = Bytes.u8(mh, 0)
    var timescale = 1
    var duration = 0.0
    var language: String?
    if mv == 1 && mh.count >= 34 {
        timescale = max(1, Bytes.u32(mh, 20))
        duration = Double(Bytes.u64(mh, 24)) / Double(timescale)
        language = langOf(Bytes.u16(mh, 32))
    } else if mh.count >= 22 {
        timescale = max(1, Bytes.u32(mh, 12))
        duration = Double(Bytes.u32(mh, 16)) / Double(timescale)
        language = langOf(Bytes.u16(mh, 20))
    }
    let handler = Bytes.fourcc(Bytes.slice(movie, hdlr.start, hdlr.end), 8)
    let kind: TrackKind = handler == "vide" ? .video : handler == "soun" ? .audio : .other
    guard let minf = findBox(movie, mdia, "minf"), let stbl = findBox(movie, minf, "stbl"), let stsd = findBox(movie, stbl, "stsd") else { return nil }
    let samples = readTables(movie, stbl, timescale)
    guard let entry = firstSampleEntry(movie, stsd) else { return nil }
    var hdr = HdrReport.sdr()
    var codec = entry.type
    var codecLabel = entry.type
    var profile: String?
    var level: String?
    var video: VideoSetup?
    var audio: AudioSetup?
    var playable = false
    var audioReport: AudioReport?
    if kind == .video {
        let visual = describeVideo(movie, entry, width, height, &hdr, &warnings)
        codec = visual.codec
        codecLabel = visual.label
        profile = visual.profile
        level = visual.level
        width = visual.width
        height = visual.height
        video = visual.setup
        hdr = visual.hdr
    } else if kind == .audio {
        let described = describeAudio(movie, entry)
        codec = described.codec
        codecLabel = described.label
        audio = described.setup
        playable = described.playable
        audioReport = described.report
    }
    finishHdr(&hdr)
    let bytes = samples.reduce(0) { $0 + $1.size }
    let bitrate = duration > 0 ? Double(bytes * 8) / duration : nil
    var fps: Double?
    if kind == .video && samples.count > 1 {
        let deltas = samples.prefix(48).map(\.duration).filter { $0 > 0 }
        if !deltas.isEmpty {
            let avg = deltas.reduce(0, +) / Double(deltas.count)
            if avg > 0 { fps = 1 / avg }
        }
    }
    let report = TrackReport(
        id: id, kind: kind, codec: codec, codecLabel: codecLabel, language: language,
        width: width == 0 ? nil : Int(width.rounded()),
        height: height == 0 ? nil : Int(height.rounded()),
        fps: fps, profile: profile, level: level, hdr: hdr, audio: audioReport, duration: duration, bitrate: bitrate
    )
    return LoadedTrack(report: report, samples: samples, video: video, audio: audio, playableAudio: playable, timescale: timescale)
}

private func firstSampleEntry(_ movie: Data, _ stsd: Box) -> Box? {
    let d = Bytes.slice(movie, stsd.start, stsd.end)
    if d.count < 8 { return nil }
    let nested = Bytes.boxes(d, 8, d.count)
    guard let local = nested.first else { return nil }
    return Box(type: local.type, start: stsd.start + local.start, end: stsd.start + local.end)
}

private func readTables(_ movie: Data, _ stbl: Box, _ timescale: Int) -> [SampleRec] {
    guard let stts = findBox(movie, stbl, "stts"),
          let stsc = findBox(movie, stbl, "stsc"),
          let stsz = findBox(movie, stbl, "stsz"),
          let stco = findBox(movie, stbl, "stco") ?? findBox(movie, stbl, "co64") else { return [] }
    let sz = Bytes.slice(movie, stsz.start, stsz.end)
    let fixed = Bytes.u32(sz, 4)
    let count = Bytes.u32(sz, 8)
    var sizes: [Int] = []
    if fixed != 0 {
        sizes = Array(repeating: fixed, count: count)
    } else {
        for i in 0 ..< count { sizes.append(Bytes.u32(sz, 12 + i * 4)) }
    }
    let co64 = Bytes.fourcc(movie, stco.start - 4) == "co64"
    let co = Bytes.slice(movie, stco.start, stco.end)
    let chunkCount = Bytes.u32(co, 4)
    var chunks: [Int] = []
    for i in 0 ..< chunkCount {
        chunks.append(co64 ? Bytes.u64(co, 8 + i * 8) : Bytes.u32(co, 8 + i * 4))
    }
    let sc = Bytes.slice(movie, stsc.start, stsc.end)
    let scCount = Bytes.u32(sc, 4)
    var scEntries: [(Int, Int)] = []
    for i in 0 ..< scCount {
        scEntries.append((Bytes.u32(sc, 8 + i * 12), Bytes.u32(sc, 12 + i * 12)))
    }
    let ts = Bytes.slice(movie, stts.start, stts.end)
    let tsCount = Bytes.u32(ts, 4)
    var deltas: [(Int, Int)] = []
    for i in 0 ..< tsCount { deltas.append((Bytes.u32(ts, 8 + i * 8), Bytes.u32(ts, 12 + i * 8))) }
    var cto: [(Int, Int)] = []
    if let ctts = findBox(movie, stbl, "ctts") {
        let c = Bytes.slice(movie, ctts.start, ctts.end)
        let ver = Bytes.u8(c, 0)
        let n = Bytes.u32(c, 4)
        for i in 0 ..< n {
            let count = Bytes.u32(c, 8 + i * 8)
            let offset = ver == 1 ? Bytes.i32(c, 12 + i * 8) : Bytes.u32(c, 12 + i * 8)
            cto.append((count, offset))
        }
    }
    var sync = Set<Int>()
    if let stss = findBox(movie, stbl, "stss") {
        let s = Bytes.slice(movie, stss.start, stss.end)
        let n = Bytes.u32(s, 4)
        for i in 0 ..< n { sync.insert(Bytes.u32(s, 8 + i * 4)) }
    }
    var samples: [SampleRec] = []
    var sampleIndex = 0
    var dts = 0
    var tsEntry = 0
    var tsLeft = deltas.first?.0 ?? 0
    var cEntry = 0
    var cLeft = cto.first?.0 ?? 0
    var scIndex = 0
    let scale = Double(max(timescale, 1))
    var chunk = 1
    while chunk <= chunks.count && sampleIndex < count {
        while scIndex + 1 < scEntries.count && scEntries[scIndex + 1].0 <= chunk { scIndex += 1 }
        let per = scEntries.isEmpty ? 1 : scEntries[scIndex].1
        var pos = chunks[chunk - 1]
        var i = 0
        while i < per && sampleIndex < count {
            let size = sizes[sampleIndex]
            let delta = tsEntry < deltas.count ? deltas[tsEntry].1 : 0
            let offsetC = cto.isEmpty ? 0 : (cEntry < cto.count ? cto[cEntry].1 : 0)
            let key = sync.isEmpty || sync.contains(sampleIndex + 1)
            samples.append(SampleRec(
                pts: Double(dts + offsetC) / scale,
                duration: Double(delta) / scale,
                key: key, offset: pos, size: size, inline: nil
            ))
            pos += size
            dts += delta
            sampleIndex += 1
            tsLeft -= 1
            if tsLeft <= 0 && tsEntry + 1 < deltas.count {
                tsEntry += 1
                tsLeft = deltas[tsEntry].0
            }
            if !cto.isEmpty {
                cLeft -= 1
                if cLeft <= 0 && cEntry + 1 < cto.count {
                    cEntry += 1
                    cLeft = cto[cEntry].0
                }
            }
            i += 1
        }
        chunk += 1
    }
    return samples
}

private struct Visual {
    var codec: String
    var label: String
    var profile: String?
    var level: String?
    var width: Double
    var height: Double
    var setup: VideoSetup?
    var hdr: HdrReport
}

private func describeVideo(_ movie: Data, _ entry: Box, _ widthHint: Double, _ heightHint: Double, _ hdrIn: inout HdrReport, _ warnings: inout [String]) -> Visual {
    let body = Bytes.slice(movie, entry.start, entry.end)
    var width = widthHint
    var height = heightHint
    if body.count >= 28 {
        let w = Bytes.u16(body, 24)
        let h = Bytes.u16(body, 26)
        if w != 0 { width = Double(w) }
        if h != 0 { height = Double(h) }
    }
    var hdr = hdrIn
    let children = body.count > 78 ? Bytes.boxes(body, 78, body.count) : []
    func raw(_ type: String) -> Data? {
        guard let box = children.first(where: { $0.type == type }) else { return nil }
        return Bytes.slice(body, box.start, box.end)
    }
    var atoms: [String: Data] = [:]
    if let avcC = raw("avcC") { atoms["avcC"] = avcC }
    if let hvcC = raw("hvcC") { atoms["hvcC"] = hvcC }
    if let av1C = raw("av1C") { atoms["av1C"] = av1C }
    if let vpcC = raw("vpcC") { atoms["vpcC"] = vpcC }
    for name in ["dvcC", "dvvC", "dvhC"] {
        if let box = raw(name) {
            atoms[name] = box
            if let dv = parseDvcc(box) { hdr.dolbyVision = dv }
        }
    }
    if let colr = raw("colr") { atoms["colr"] = colr; parseColr(colr, &hdr) }
    if let mdcv = raw("mdcv") { atoms["mdcv"] = mdcv; parseMdcv(mdcv, &hdr) }
    if let clli = raw("clli") { atoms["clli"] = clli; parseClli(clli, &hdr) }
    let four = entry.type
    let familyFour = four.lowercased()
    var codec = four
    var label = four
    var profile: String?
    var level: String?
    var setup: VideoSetup?
    let codedW = Int(width.rounded()) == 0 ? 16 : Int(width.rounded())
    let codedH = Int(height.rounded()) == 0 ? 16 : Int(height.rounded())
    if let avcC = atoms["avcC"], avcC.count >= 7 {
        let rec = avcRecord(avcC)
        codec = rec.codec
        profile = rec.profile
        level = rec.level
        label = "H.264 \(rec.profile)"
        setup = VideoSetup(family: .avc, codecs: [rec.codec], description: avcC, codedWidth: codedW, codedHeight: codedH, bitstream: .avcc, atoms: atoms)
        hdr.bitDepth = profile?.contains("10") == true ? 10 : 8
        hdr.chroma = "4:2:0"
    } else if let hvcC = atoms["hvcC"], hvcC.count >= 23 {
        let brand = four == "hev1" ? "hev1" : "hvc1"
        let rec = hevcRecord(hvcC, brand: brand)
        codec = rec.codec
        profile = rec.profile
        level = rec.level
        label = "HEVC \(rec.profile)"
        let alt = rec.codec.hasPrefix("hvc1") ? rec.codec.replacingOccurrences(of: "hvc1", with: "hev1") : rec.codec.replacingOccurrences(of: "hev1", with: "hvc1")
        setup = VideoSetup(family: .hevc, codecs: [rec.codec, alt], description: hvcC, codedWidth: codedW, codedHeight: codedH, bitstream: .avcc, atoms: atoms)
        hdr.bitDepth = rec.bitDepth
        hdr.chroma = rec.chroma
    } else if familyFour == "av01" || atoms["av1C"] != nil {
        codec = "av01.0.08M.08"
        label = "AV1"
        setup = VideoSetup(family: .av1, codecs: ["av01.0.08M.08", "av01.0.05M.08"], description: atoms["av1C"], codedWidth: codedW, codedHeight: codedH, bitstream: .raw, atoms: atoms)
    } else if familyFour.hasPrefix("vp09") || familyFour == "vp08" || atoms["vpcC"] != nil {
        let vp9 = familyFour.hasPrefix("vp09") || atoms["vpcC"] != nil
        codec = vp9 ? "vp09.00.10.08" : "vp8"
        label = vp9 ? "VP9" : "VP8"
        setup = VideoSetup(family: vp9 ? .vp9 : .vp8, codecs: vp9 ? ["vp09.00.10.08", "vp09.00.41.08"] : ["vp8"], description: atoms["vpcC"], codedWidth: codedW, codedHeight: codedH, bitstream: .raw, atoms: atoms)
    } else if familyFour == "mjpg" || familyFour == "jpeg" {
        codec = "mjpeg"
        label = "Motion JPEG"
        setup = VideoSetup(family: .jpeg, codecs: ["mjpeg"], description: nil, codedWidth: codedW, codedHeight: codedH, bitstream: .raw, atoms: atoms)
    } else if familyFour == "mp4v" || familyFour == "encv" {
        label = familyFour == "encv" ? "Encrypted video" : "MPEG-4 Part 2"
        warnings.append("\(label) is identified, not decoded.")
    } else if ["dvh1", "dvhe", "dvav", "dva1"].contains(four) {
        label = "Dolby Vision"
        if hdr.dolbyVision == nil {
            hdr.dolbyVision = DolbyVisionInfo(profile: four.hasPrefix("dvh") ? 5 : 9, level: 0, rpu: true, el: false, bl: true, compatibility: "Unknown", version: "1.0", summary: "\(four) sample entry")
        }
    }
    if hdr.dolbyVision != nil && !label.contains("Dolby") { label = "\(label) · Dolby Vision" }
    return Visual(codec: codec, label: label, profile: profile, level: level, width: width, height: height, setup: setup, hdr: hdr)
}

private struct AudioDescribed {
    var codec: String
    var label: String
    var setup: AudioSetup?
    var playable: Bool
    var report: AudioReport
}

private func describeAudio(_ movie: Data, _ entry: Box) -> AudioDescribed {
    let body = Bytes.slice(movie, entry.start, entry.end)
    let version = body.count >= 10 ? Bytes.u16(body, 8) : 0
    var header = 28
    if version == 1 { header = 44 } else if version == 2 { header = 64 }
    let channelsBox = body.count >= 18 ? Bytes.u16(body, 16) : 0
    let rateFixed = body.count >= 32 ? Bytes.u32(body, 24) : 0
    let rateBox = rateFixed > 0xffff ? rateFixed / 65536 : rateFixed
    let children = body.count > header ? Bytes.boxes(body, header, body.count) : []
    func raw(_ type: String) -> Data? {
        guard let box = children.first(where: { $0.type == type }) else { return nil }
        return Bytes.slice(body, box.start, box.end)
    }
    let four = entry.type
    if (four == "mp4a" || four == "mp4s"), let esds = raw("esds") {
        let asc = audioSpecificFromEsds(esds)
        let parsed = asc.flatMap(parseAsc)
        let channels = parsed?.channels ?? (channelsBox == 0 ? 2 : channelsBox)
        let sampleRate = parsed?.sampleRate ?? (rateBox == 0 ? 48000 : rateBox)
        let objectType = parsed?.objectType ?? 2
        let codec = "mp4a.40.\(objectType)"
        let names = [2: "AAC-LC", 5: "AAC-SBR", 29: "AAC-PS", 42: "xHE-AAC"]
        let label = names[objectType] ?? "AAC"
        return AudioDescribed(
            codec: codec, label: label,
            setup: AudioSetup(codecs: [codec], description: asc, sampleRate: sampleRate, channels: channels),
            playable: true,
            report: AudioReport(codecLabel: label, channels: channels, layout: layoutName(channels), sampleRate: sampleRate, atmos: false, detail: nil)
        )
    }
    if four == "ec-3" || raw("dec3") != nil {
        let parsed = raw("dec3").flatMap(parseDec3)
        let atmos = parsed?.atmos ?? false
        return AudioDescribed(
            codec: "ec-3", label: atmos ? "E-AC-3 JOC" : "E-AC-3", setup: nil, playable: false,
            report: AudioReport(
                codecLabel: atmos ? "Dolby Digital Plus + JOC" : "Dolby Digital Plus",
                channels: parsed?.channels, layout: parsed?.layout, sampleRate: parsed?.sampleRate ?? (rateBox == 0 ? 48000 : rateBox),
                atmos: atmos,
                detail: atmos
                    ? "Extension type A is set. That is the Atmos JOC flag. Object rendering needs the system audio path; this engine does not binauralize objects."
                    : "Channel bed only. No Atmos JOC flag in the EC3SpecificBox."
            )
        )
    }
    if four == "ac-3" || raw("dac3") != nil {
        let parsed = raw("dac3").flatMap(parseDac3)
        return AudioDescribed(
            codec: "ac-3", label: "AC-3", setup: nil, playable: false,
            report: AudioReport(codecLabel: "Dolby Digital", channels: parsed?.channels ?? channelsBox, layout: parsed?.layout, sampleRate: parsed?.sampleRate ?? (rateBox == 0 ? 48000 : rateBox), atmos: false, detail: "AC-3 bed identified from dac3. VideoToolbox does not decode AC-3 in this engine.")
        )
    }
    if four == "ac-4" {
        return AudioDescribed(codec: "ac-4", label: "AC-4", setup: nil, playable: false, report: AudioReport(codecLabel: "Dolby AC-4", channels: channelsBox == 0 ? nil : channelsBox, layout: nil, sampleRate: rateBox == 0 ? 48000 : rateBox, atmos: true, detail: "AC-4 sample entry is identified. Objects are not rendered."))
    }
    if four == "mlpa" {
        return AudioDescribed(codec: "mlpa", label: "TrueHD", setup: nil, playable: false, report: AudioReport(codecLabel: "Dolby TrueHD", channels: channelsBox == 0 ? nil : channelsBox, layout: nil, sampleRate: rateBox == 0 ? 48000 : rateBox, atmos: false, detail: "MLP / TrueHD sample entry. Atmos is not assumed without a JOC or AC-4 flag."))
    }
    if four == "Opus" || four == "opus" {
        let channels = channelsBox == 0 ? 2 : channelsBox
        return AudioDescribed(codec: "opus", label: "Opus", setup: AudioSetup(codecs: ["opus"], description: raw("dOps"), sampleRate: 48000, channels: channels), playable: false, report: AudioReport(codecLabel: "Opus", channels: channels, layout: layoutName(channels), sampleRate: 48000, atmos: false, detail: "Opus is identified. Apple platforms do not decode Opus in VideoToolbox."))
    }
    if four == "fLaC" || four == "flac" {
        let channels = channelsBox == 0 ? 2 : channelsBox
        let rate = rateBox == 0 ? 48000 : rateBox
        return AudioDescribed(codec: "flac", label: "FLAC", setup: AudioSetup(codecs: ["flac"], description: nil, sampleRate: rate, channels: channels), playable: false, report: AudioReport(codecLabel: "FLAC", channels: channels, layout: layoutName(channels), sampleRate: rate, atmos: false, detail: "FLAC is identified. This engine does not decode it."))
    }
    let dts = ["dtsc", "dtse", "dtsh", "dtsl"].contains(four)
    return AudioDescribed(
        codec: four, label: dts ? "DTS" : four, setup: nil, playable: false,
        report: AudioReport(codecLabel: dts ? "DTS" : four, channels: channelsBox == 0 ? nil : channelsBox, layout: nil, sampleRate: rateBox == 0 ? nil : rateBox, atmos: false, detail: dts ? "DTS is identified from the sample entry. No DTS decoder is linked." : nil)
    )
}

private func layoutName(_ channels: Int) -> String {
    if channels == 1 { return "mono" }
    if channels == 2 { return "stereo" }
    return "\(channels) ch"
}

private func appendFragments(_ moof: Data, _ moofOffset: Int, _ tracks: inout [LoadedTrack], _ trex: [Int: (Int, Int, Int)]) {
    for traf in Bytes.boxes(moof, 0, moof.count) where traf.type == "traf" {
        let kids = Bytes.boxes(moof, traf.start, traf.end)
        guard let tfhd = kids.first(where: { $0.type == "tfhd" }) else { continue }
        let hd = Bytes.slice(moof, tfhd.start, tfhd.end)
        let flags = Bytes.u32(hd, 0) & 0xffffff
        let trackId = Bytes.u32(hd, 4)
        guard let index = tracks.firstIndex(where: { $0.report.id == trackId }) else { continue }
        let defaults = trex[trackId]
        var cursor = 8
        var base = moofOffset
        if (flags & 0x000001) != 0 {
            base = Bytes.u64(hd, cursor)
            cursor += 8
        }
        if (flags & 0x000002) != 0 { cursor += 4 }
        var defDuration = defaults?.0 ?? 0
        var defSize = defaults?.1 ?? 0
        var defFlags = defaults?.2 ?? 0
        if (flags & 0x000008) != 0 { defDuration = Bytes.u32(hd, cursor); cursor += 4 }
        if (flags & 0x000010) != 0 { defSize = Bytes.u32(hd, cursor); cursor += 4 }
        if (flags & 0x000020) != 0 { defFlags = Bytes.u32(hd, cursor) }
        var dts = 0
        if let tfdt = kids.first(where: { $0.type == "tfdt" }) {
            let td = Bytes.slice(moof, tfdt.start, tfdt.end)
            dts = Bytes.u8(td, 0) == 1 ? Bytes.u64(td, 4) : Bytes.u32(td, 4)
        }
        let timescale = max(tracks[index].timescale, 1)
        for trun in kids where trun.type == "trun" {
            let td = Bytes.slice(moof, trun.start, trun.end)
            let tflags = Bytes.u32(td, 0) & 0xffffff
            let version = Bytes.u8(td, 0)
            let count = Bytes.u32(td, 4)
            var p = 8
            var dataOffset = 0
            if (tflags & 0x000001) != 0 { dataOffset = Bytes.i32(td, p); p += 4 }
            var firstFlags = defFlags
            if (tflags & 0x000004) != 0 { firstFlags = Bytes.u32(td, p); p += 4 }
            var pos = base + dataOffset
            for i in 0 ..< count {
                var dur = defDuration
                var size = defSize
                var sampleFlags = i == 0 && (tflags & 0x000004) != 0 ? firstFlags : defFlags
                var cto = 0
                if (tflags & 0x000100) != 0 { dur = Bytes.u32(td, p); p += 4 }
                if (tflags & 0x000200) != 0 { size = Bytes.u32(td, p); p += 4 }
                if (tflags & 0x000400) != 0 { sampleFlags = Bytes.u32(td, p); p += 4 }
                if (tflags & 0x000800) != 0 {
                    cto = version == 1 ? Bytes.i32(td, p) : Bytes.u32(td, p)
                    p += 4
                }
                let key = (sampleFlags & 0x00010000) == 0
                tracks[index].samples.append(SampleRec(
                    pts: Double(dts + cto) / Double(timescale),
                    duration: Double(dur) / Double(timescale),
                    key: key, offset: pos, size: size, inline: nil
                ))
                pos += size
                dts += dur
            }
        }
    }
}

func enrichIsoHdr(_ source: Data, _ result: inout IsoResult) {
    for i in result.tracks.indices {
        guard result.tracks[i].report.kind == .video, let video = result.tracks[i].video else { continue }
        if video.family != .avc && video.family != .hevc { continue }
        let lengthSize: Int
        if video.family == .avc, let desc = video.description, desc.count > 4 {
            lengthSize = (Int(desc[4]) & 3) + 1
        } else if let desc = video.description, desc.count > 21 {
            lengthSize = (Int(desc[21]) & 3) + 1
        } else { lengthSize = 4 }
        var hdr = result.tracks[i].report.hdr
        let keys = result.tracks[i].samples.filter(\.key).prefix(2)
        let extra = result.tracks[i].samples.prefix(2)
        var seen = Set<Int>()
        for sample in keys + extra {
            if seen.contains(sample.offset) || sample.size <= 0 || sample.size > 2_000_000 { continue }
            seen.insert(sample.offset)
            let end = min(source.count, sample.offset + min(sample.size, 256_000))
            if sample.offset < 0 || sample.offset >= end { continue }
            scanSampleForHdr(source.subdata(in: sample.offset ..< end), video.family, lengthSize, &hdr)
        }
        finishHdr(&hdr)
        result.tracks[i].report.hdr = hdr
        if hdr.dolbyVision != nil && !result.tracks[i].report.codecLabel.contains("Dolby") {
            result.tracks[i].report.codecLabel += " · Dolby Vision"
        }
    }
}
