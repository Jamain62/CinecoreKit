import Foundation

private let transferNames: [Int: String] = [
    1: "BT.709", 6: "SMPTE 170M", 13: "sRGB", 14: "BT.2020 10-bit", 15: "BT.2020 12-bit", 16: "PQ", 18: "HLG",
]
private let primaryNames: [Int: String] = [
    1: "BT.709", 5: "BT.601 PAL", 6: "BT.601 NTSC", 9: "BT.2020", 11: "DCI-P3", 12: "P3-D65",
]
private let matrixNames: [Int: String] = [
    1: "BT.709", 5: "BT.601", 6: "BT.601", 9: "BT.2020 NC", 10: "BT.2020 C",
]
private let dvCompat = ["None", "HDR10", "SDR", "Reserved", "HLG"]
private let aacRates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]

func transferName(_ id: Int?) -> String {
    guard let id else { return "Unspecified" }
    return transferNames[id] ?? "TC \(id)"
}
func primariesName(_ id: Int?) -> String {
    guard let id else { return "Unspecified" }
    return primaryNames[id] ?? "P \(id)"
}
func matrixName(_ id: Int?) -> String {
    guard let id else { return "Unspecified" }
    return matrixNames[id] ?? "M \(id)"
}

func parseDvcc(_ payload: Data) -> DolbyVisionInfo? {
    if payload.count < 5 { return nil }
    var bits = BitReader(payload)
    let major = bits.read(8)
    let minor = bits.read(8)
    let profile = bits.read(7)
    let level = bits.read(6)
    let rpu = bits.read(1) == 1
    let el = bits.read(1) == 1
    let bl = bits.read(1) == 1
    let compatId = bits.read(4)
    let compatibility = compatId < dvCompat.count ? dvCompat[compatId] : "ID \(compatId)"
    let summary: String
    switch profile {
    case 5: summary = "Profile 5 · IPT, no cross-compatible base"
    case 7: summary = "Profile 7 · dual layer, HDR10 base"
    case 8: summary = "Profile 8.1-class · single layer, \(compatibility) base"
    case 9: summary = "Profile 9 · AVC base"
    case 10: summary = "Profile 10 · AV1 base"
    case 20: summary = "Profile 20"
    default: summary = "Profile \(profile)"
    }
    return DolbyVisionInfo(
        profile: profile, level: level, rpu: rpu, el: el, bl: bl,
        compatibility: compatibility, version: "\(major).\(minor)", summary: summary
    )
}

struct CodecRecord {
    var codec: String
    var lengthSize: Int
    var profile: String
    var level: String
    var bitDepth: Int
    var chroma: String
}

func avcRecord(_ avcC: Data) -> CodecRecord {
    let profileIdc = Bytes.u8(avcC, 1)
    let compat = Bytes.u8(avcC, 2)
    let levelIdc = Bytes.u8(avcC, 3)
    let lengthSize = (Bytes.u8(avcC, 4) & 3) + 1
    let names = [66: "Baseline", 77: "Main", 88: "Extended", 100: "High", 110: "High 10", 122: "High 4:2:2", 144: "High 4:4:4"]
    func hex(_ n: Int) -> String { String(format: "%02x", n) }
    return CodecRecord(
        codec: "avc1.\(hex(profileIdc))\(hex(compat))\(hex(levelIdc))",
        lengthSize: lengthSize,
        profile: names[profileIdc] ?? "Profile \(profileIdc)",
        level: String(format: "%.1f", Double(levelIdc) / 10),
        bitDepth: profileIdc == 110 || profileIdc == 122 || profileIdc == 144 ? 10 : 8,
        chroma: "4:2:0"
    )
}

func hevcRecord(_ hvcC: Data, brand: String) -> CodecRecord {
    let fallback = CodecRecord(
        codec: brand == "hev1" ? "hev1.1.6.L120.B0" : "hvc1.1.6.L120.B0",
        lengthSize: 4, profile: "Main", level: "0", bitDepth: 8, chroma: "4:2:0"
    )
    if hvcC.count < 23 { return fallback }
    let b1 = Bytes.u8(hvcC, 1)
    let space = (b1 >> 6) & 3
    let tier = (b1 >> 5) & 1
    let profileIdc = b1 & 31
    let compat = Bytes.u32(hvcC, 2)
    var reversed = 0
    var v = compat
    for _ in 0 ..< 32 {
        reversed = ((reversed << 1) | (v & 1))
        v >>= 1
    }
    let levelIdc = Bytes.u8(hvcC, 12)
    var constraints: [Int] = (0 ..< 6).map { Bytes.u8(hvcC, 6 + $0) }
    while constraints.last == 0 { constraints.removeLast() }
    let spaceC = ["", "A", "B", "C"][space]
    let four = brand == "hev1" ? "hev1" : "hvc1"
    var codec = "\(four).\(spaceC)\(profileIdc).\(String(reversed, radix: 16)).\(tier == 1 ? "H" : "L")\(levelIdc)"
    if !constraints.isEmpty {
        codec += "." + constraints.map { String(format: "%02X", $0) }.joined(separator: ".")
    }
    let chromaId = Bytes.u8(hvcC, 16) & 3
    let bitDepth = (Bytes.u8(hvcC, 17) & 7) + 8
    let lengthSize = (Bytes.u8(hvcC, 21) & 3) + 1
    let profiles = [1: "Main", 2: "Main 10", 3: "Main Still"]
    let chroma = ["4:0:0", "4:2:0", "4:2:2", "4:4:4"][chromaId]
    return CodecRecord(
        codec: codec, lengthSize: lengthSize, profile: profiles[profileIdc] ?? "Profile \(profileIdc)",
        level: String(format: "%.1f", Double(levelIdc) / 30), bitDepth: bitDepth, chroma: chroma
    )
}

func parseColr(_ payload: Data, _ hdr: inout HdrReport) {
    if payload.count < 11 { return }
    let kind = Bytes.fourcc(payload, 0)
    if kind != "nclx" { return }
    let primaries = Bytes.u16(payload, 4)
    let transfer = Bytes.u16(payload, 6)
    let matrix = Bytes.u16(payload, 8)
    hdr.primaries = primariesName(primaries)
    if transfer != 2 { hdr.transfer = transferName(transfer) }
    hdr.matrix = matrixName(matrix)
    hdr.fullRange = (Bytes.u8(payload, 10) & 0x80) != 0
}

func parseMdcv(_ payload: Data, _ hdr: inout HdrReport) {
    if payload.count < 24 { return }
    func chroma(_ o: Int) -> Double { Double(Bytes.u16(payload, o)) / 50000 }
    let g = String(format: "%.4f, %.4f", chroma(0), chroma(2))
    let b = String(format: "%.4f, %.4f", chroma(4), chroma(6))
    let r = String(format: "%.4f, %.4f", chroma(8), chroma(10))
    let w = String(format: "%.4f, %.4f", chroma(12), chroma(14))
    let max = Double(Bytes.u32(payload, 16)) / 10000
    let min = Double(Bytes.u32(payload, 20)) / 10000
    hdr.mastering = "R \(r) · G \(g) · B \(b) · W \(w) · \(String(format: "%.0f", max)) / \(String(format: "%.4f", min)) cd/m²"
}

func parseClli(_ payload: Data, _ hdr: inout HdrReport) {
    if payload.count < 4 { return }
    hdr.maxCll = Bytes.u16(payload, 0)
    hdr.maxFall = Bytes.u16(payload, 2)
}

func finishHdr(_ hdr: inout HdrReport) {
    hdr.notes.removeAll {
        $0.hasPrefix("Profile 5 is IPT") || $0.hasPrefix("RPU is present") || $0.hasPrefix("HDR10+ SEI")
    }
    let pq = hdr.transfer == "PQ"
    let hlg = hdr.transfer == "HLG"
    if let vision = hdr.dolbyVision {
        hdr.label = "Dolby Vision"
        if vision.profile == 5 {
            hdr.notes.append("Profile 5 is IPT. This decoder shows the base layer without a Dolby display map, so the picture will not match a Vision panel.")
        } else if vision.rpu {
            hdr.notes.append("RPU is present. Picture decode is the base layer. A Dolby Vision panel is only driven if the system display accepts the RPU.")
        }
    } else if hdr.hdr10Plus && (pq || hdr.maxCll != nil) {
        hdr.label = "HDR10+"
    } else if pq && (hdr.maxCll != nil || hdr.mastering != nil) {
        hdr.label = "HDR10"
    } else if pq {
        hdr.label = "PQ"
    } else if hlg {
        hdr.label = "HLG"
    } else {
        hdr.label = "SDR"
    }
    if hdr.hdr10Plus && hdr.dolbyVision != nil {
        hdr.notes.append("HDR10+ SEI is also present on the base layer.")
    }
}

private func seiMessages(_ rbsp: Data, _ visit: (Int, Data) -> Void) {
    var p = 0
    while p + 2 < rbsp.count {
        var type = 0
        while p < rbsp.count && rbsp[p] == 0xff { type += 255; p += 1 }
        if p >= rbsp.count { break }
        type += Int(rbsp[p]); p += 1
        var size = 0
        while p < rbsp.count && rbsp[p] == 0xff { size += 255; p += 1 }
        if p >= rbsp.count { break }
        size += Int(rbsp[p]); p += 1
        if size <= 0 || p + size > rbsp.count { break }
        visit(type, rbsp.subdata(in: p ..< (p + size)))
        p += size
        if p < rbsp.count && rbsp[p] == 0x80 { break }
    }
}

private func scanNal(_ nal: Data, _ hevc: Bool, _ hdr: inout HdrReport) {
    if nal.count < 2 { return }
    let nalType = hevc ? (Int(nal[0]) >> 1) & 0x3f : Int(nal[0]) & 0x1f
    let sei = hevc ? (nalType == 39 || nalType == 40) : nalType == 6
    if !sei { return }
    let header = hevc ? 2 : 1
    if header >= nal.count { return }
    let rbsp = ebspToRbsp(nal.subdata(in: header ..< nal.count))
    seiMessages(rbsp) { type, payload in
        if type == 4, payload.count >= 7,
           payload[0] == 0xb5, payload[1] == 0x00, payload[2] == 0x3c,
           payload[3] == 0x00, payload[4] == 0x01, payload[5] == 4 {
            hdr.hdr10Plus = true
        }
        if type == 137, hdr.mastering == nil { parseMdcv(payload, &hdr) }
        if type == 144, hdr.maxCll == nil, payload.count >= 4 {
            hdr.maxCll = Bytes.u16(payload, 0)
            hdr.maxFall = Bytes.u16(payload, 2)
        }
    }
}

private func findStart(_ sample: Data, _ nalStart: Int) -> Int {
    if nalStart >= 4 && sample[nalStart - 4] == 0 && sample[nalStart - 3] == 0 { return nalStart - 4 }
    if nalStart >= 3 { return nalStart - 3 }
    return nalStart
}

func scanSampleForHdr(_ sample: Data, _ family: VideoFamily, _ lengthSize: Int, _ hdr: inout HdrReport) {
    let hevc = family == .hevc
    let annex = sample.count > 4 && sample[0] == 0 && sample[1] == 0 && (sample[2] == 1 || (sample[2] == 0 && sample[3] == 1))
    if annex {
        var starts: [Int] = []
        var i = 0
        while i + 3 < sample.count {
            if sample[i] == 0 && sample[i + 1] == 0 && sample[i + 2] == 1 {
                starts.append(i + 3); i += 3; continue
            }
            if i + 4 < sample.count && sample[i] == 0 && sample[i + 1] == 0 && sample[i + 2] == 0 && sample[i + 3] == 1 {
                starts.append(i + 4); i += 4; continue
            }
            i += 1
        }
        for n in 0 ..< starts.count {
            let a = starts[n]
            let end = n + 1 < starts.count ? findStart(sample, starts[n + 1]) : sample.count
            if end > a { scanNal(sample.subdata(in: a ..< end), hevc, &hdr) }
        }
        return
    }
    var o = 0
    let ls = lengthSize == 0 ? 4 : lengthSize
    while o + ls < sample.count {
        var len = 0
        for _ in 0 ..< ls {
            len = (len << 8) | Int(sample[o])
            o += 1
        }
        if len <= 0 || o + len > sample.count { break }
        scanNal(sample.subdata(in: o ..< (o + len)), hevc, &hdr)
        o += len
    }
}

struct Dec3 {
    var bitrate: Int
    var sampleRate: Int
    var channels: Int
    var layout: String
    var atmos: Bool
    var bsid: Int
}

func acmodLayout(_ acmod: Int, _ lfe: Bool) -> (Int, String) {
    let table: [(Int, String)] = [
        (2, "dual mono"), (1, "mono"), (2, "stereo"), (3, "3/0"), (3, "2/1"), (4, "3/1"), (4, "2/2"), (5, "3/2"),
    ]
    let row = acmod >= 0 && acmod < table.count ? table[acmod] : (0, "acmod \(acmod)")
    return (row.0 + (lfe ? 1 : 0), lfe ? "\(row.1) + LFE" : row.1)
}

func parseDec3(_ payload: Data) -> Dec3? {
    if payload.count < 5 { return nil }
    var bits = BitReader(payload)
    let bitrate = bits.read(13)
    let numInd = bits.read(3)
    var channels = 0
    var layout = ""
    var sampleRate = 48000
    var bsid = 0
    let subs = numInd + 1
    for i in 0 ..< subs {
        if bits.remaining < 16 { break }
        let fscod = bits.read(2)
        bsid = bits.read(5)
        _ = bits.read(1); _ = bits.read(1); _ = bits.read(3)
        let acmod = bits.read(3)
        let lfe = bits.read(1) == 1
        _ = bits.read(3)
        let dep = bits.read(4)
        if dep > 0 {
            if bits.remaining < 9 { break }
            _ = bits.read(9)
        } else if bits.remaining >= 1 {
            _ = bits.read(1)
        }
        let rate = [48000, 44100, 32000, 0][fscod]
        if i == 0 {
            sampleRate = rate == 0 ? 48000 : rate
            let lay = acmodLayout(acmod, lfe)
            channels = lay.0
            layout = lay.1
        }
    }
    var atmos = false
    if bits.remaining >= 8 {
        _ = bits.read(7)
        atmos = bits.read(1) == 1
    }
    return Dec3(bitrate: bitrate, sampleRate: sampleRate, channels: channels, layout: layout, atmos: atmos, bsid: bsid)
}

func parseDac3(_ payload: Data) -> Dec3? {
    if payload.count < 3 { return nil }
    var bits = BitReader(payload)
    let fscod = bits.read(2)
    let bsid = bits.read(5)
    _ = bits.read(3)
    let acmod = bits.read(3)
    let lfe = bits.read(1) == 1
    let lay = acmodLayout(acmod, lfe)
    return Dec3(bitrate: 0, sampleRate: [48000, 44100, 32000, 48000][fscod], channels: lay.0, layout: lay.1, atmos: false, bsid: bsid)
}

struct Asc { var objectType: Int; var sampleRate: Int; var channels: Int }

func parseAsc(_ asc: Data) -> Asc? {
    if asc.count < 2 { return nil }
    var bits = BitReader(asc)
    var objectType = bits.read(5)
    if objectType == 31 { objectType = bits.read(6) + 32 }
    let fi = bits.read(4)
    let sampleRate = fi == 15 ? bits.read(24) : (fi < aacRates.count ? aacRates[fi] : 48000)
    var channels = bits.read(4)
    if channels == 0 { channels = 2 }
    return Asc(objectType: objectType, sampleRate: sampleRate, channels: channels)
}

private struct Descriptor { var tag: Int; var start: Int; var end: Int }

private func readDescriptor(_ data: Data, _ o0: Int) -> Descriptor? {
    var o = o0
    if o >= data.count { return nil }
    let tag = Int(data[o]); o += 1
    var size = 0
    var guardN = 0
    while o < data.count && guardN < 4 {
        let b = Int(data[o]); o += 1
        size = (size << 7) | (b & 0x7f)
        guardN += 1
        if (b & 0x80) == 0 { break }
    }
    return Descriptor(tag: tag, start: o, end: min(data.count, o + size))
}

func audioSpecificFromEsds(_ payload: Data) -> Data? {
    var o = 4
    guard let top = readDescriptor(payload, o) else { return nil }
    o = top.tag == 0x03 ? top.start + 3 : top.start
    if top.tag == 0x03 && top.start + 3 <= top.end {
        let flags = Int(payload[top.start + 2])
        var child = top.start + 3
        if (flags & 0x80) != 0 { child += 2 }
        if (flags & 0x40) != 0 && child < payload.count {
            let len = Int(payload[child])
            child += 1 + len
        }
        if (flags & 0x20) != 0 { child += 2 }
        o = child
    }
    while o + 2 < top.end {
        guard let d = readDescriptor(payload, o) else { break }
        if d.tag == 0x04 {
            var c = d.start + 13
            while c + 2 < d.end {
                guard let inner = readDescriptor(payload, c) else { break }
                if inner.tag == 0x05 { return payload.subdata(in: inner.start ..< inner.end) }
                c = inner.end
            }
        }
        if d.tag == 0x05 { return payload.subdata(in: d.start ..< d.end) }
        o = d.end
    }
    return nil
}

func vp9Codec(_ priv: Data) -> String {
    if priv.count >= 3 {
        let profile = Int(priv[0])
        let level = Int(priv[1])
        let bitDepth = (Int(priv[2]) >> 4) & 0xf
        return String(format: "vp09.%02d.%02d.%02d", profile, level, bitDepth == 0 ? 8 : bitDepth)
    }
    return "vp09.00.10.08"
}

func splitAnnexB(_ data: Data) -> [Data] {
    var starts: [Int] = []
    var i = 0
    while i + 3 < data.count {
        if data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 1 {
            starts.append(i + 3); i += 3
        } else if data[i] == 0 && data[i + 1] == 0 && data[i + 2] == 0 && data[i + 3] == 1 {
            starts.append(i + 4); i += 4
        } else { i += 1 }
    }
    var nals: [Data] = []
    for n in 0 ..< starts.count {
        let a = starts[n]
        let end = n + 1 < starts.count ? findStart(data, starts[n + 1]) : data.count
        if end > a { nals.append(data.subdata(in: a ..< end)) }
    }
    return nals
}

func buildAvcC(_ spsList: [Data], _ ppsList: [Data]) -> Data? {
    guard let sps = spsList.first, !ppsList.isEmpty, sps.count >= 4 else { return nil }
    var out = Data([1, sps[1], sps[2], sps[3], 0xff, UInt8(0xe0 | (spsList.count & 31))])
    for s in spsList {
        out.append(UInt8((s.count >> 8) & 0xff))
        out.append(UInt8(s.count & 0xff))
        out.append(s)
    }
    out.append(UInt8(ppsList.count & 0xff))
    for p in ppsList {
        out.append(UInt8((p.count >> 8) & 0xff))
        out.append(UInt8(p.count & 0xff))
        out.append(p)
    }
    return out
}

func avcPictureSize(_ nal: Data) -> (Int, Int)? {
    if nal.count < 4 { return nil }
    var bits = BitReader(ebspToRbsp(nal.subdata(in: 1 ..< nal.count)))
    let profile = bits.read(8)
    _ = bits.read(8); _ = bits.read(8)
    _ = bits.ue()
    var chromaFormat = 1
    let high: Set<Int> = [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135]
    if high.contains(profile) {
        chromaFormat = bits.ue()
        if chromaFormat == 3 { _ = bits.read(1) }
        _ = bits.ue(); _ = bits.ue(); _ = bits.read(1)
        if bits.read(1) == 1 {
            let count = chromaFormat == 3 ? 12 : 8
            for i in 0 ..< count where bits.read(1) == 1 {
                skipScalingList(&bits, i < 6 ? 16 : 64)
            }
        }
    }
    _ = bits.ue()
    let poc = bits.ue()
    if poc == 0 { _ = bits.ue() }
    else if poc == 1 {
        _ = bits.read(1); _ = bits.se(); _ = bits.se()
        let cycles = bits.ue()
        for _ in 0 ..< cycles { _ = bits.se() }
    }
    _ = bits.ue(); _ = bits.read(1)
    let widthInMbs = bits.ue() + 1
    let heightInMaps = bits.ue() + 1
    let frameOnly = bits.read(1) == 1
    if !frameOnly { _ = bits.read(1) }
    _ = bits.read(1)
    var cropL = 0, cropR = 0, cropT = 0, cropB = 0
    if bits.read(1) == 1 {
        cropL = bits.ue(); cropR = bits.ue(); cropT = bits.ue(); cropB = bits.ue()
    }
    let cropX = chromaFormat == 0 ? 1 : 2
    let cropY = (chromaFormat == 0 ? 1 : 2) * (frameOnly ? 1 : 2)
    let width = widthInMbs * 16 - (cropL + cropR) * cropX
    let height = heightInMaps * 16 * (frameOnly ? 1 : 2) - (cropT + cropB) * cropY
    if width < 16 || height < 16 || width > 8192 || height > 8192 { return nil }
    return (width, height)
}

private func skipScalingList(_ bits: inout BitReader, _ size: Int) {
    var last = 8
    var next = 8
    for _ in 0 ..< size {
        if next != 0 { next = (last + bits.se() + 256) % 256 }
        last = next == 0 ? last : next
    }
}

func hevcParameterSets(_ hvcC: Data) -> [Data] {
    if hvcC.count < 23 { return [] }
    let num = Bytes.u8(hvcC, 22)
    var o = 23
    var nals: [Data] = []
    for _ in 0 ..< num {
        if o + 3 > hvcC.count { break }
        o += 1
        let count = Bytes.u16(hvcC, o); o += 2
        for _ in 0 ..< count {
            if o + 2 > hvcC.count { return nals }
            let len = Bytes.u16(hvcC, o); o += 2
            if o + len > hvcC.count { return nals }
            nals.append(hvcC.subdata(in: o ..< (o + len)))
            o += len
        }
    }
    return nals
}

func avcParameterSets(_ avcC: Data) -> (sps: [Data], pps: [Data]) {
    if avcC.count < 7 { return ([], []) }
    var o = 5
    let spsCount = Bytes.u8(avcC, o) & 31
    o += 1
    var sps: [Data] = []
    for _ in 0 ..< spsCount {
        if o + 2 > avcC.count { break }
        let len = Bytes.u16(avcC, o); o += 2
        if o + len > avcC.count { break }
        sps.append(avcC.subdata(in: o ..< (o + len)))
        o += len
    }
    if o >= avcC.count { return (sps, []) }
    let ppsCount = Bytes.u8(avcC, o); o += 1
    var pps: [Data] = []
    for _ in 0 ..< ppsCount {
        if o + 2 > avcC.count { break }
        let len = Bytes.u16(avcC, o); o += 2
        if o + len > avcC.count { break }
        pps.append(avcC.subdata(in: o ..< (o + len)))
        o += len
    }
    return (sps, pps)
}
