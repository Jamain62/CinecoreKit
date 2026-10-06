import Foundation

struct AviResult {
    var duration: Double
    var video: LoadedTrack?
    var warnings: [String]
    var log: [String]
}

func parseAvi(_ source: Data) -> Result<AviResult, CinecoreError> {
    var warnings: [String] = []
    var log: [String] = []
    if source.count < 12 || Bytes.fourcc(source, 0) != "RIFF" || Bytes.fourcc(source, 8) != "AVI " {
        return .failure(CinecoreError("Not an AVI file."))
    }
    var offset = 12
    var moviAt = -1
    var scale = 1
    var rate = 24
    var width = 0
    var height = 0
    var handler = ""
    var samples: [SampleRec] = []
    while offset + 8 <= source.count {
        let id = Bytes.fourcc(source, offset)
        let size = Bytes.le32(source, offset + 4)
        let payload = offset + 8
        if id == "LIST" && payload + 4 <= source.count {
            let kind = Bytes.fourcc(source, payload)
            if kind == "movi" {
                moviAt = payload
            } else if kind == "hdrl" {
                let hdrl = Bytes.slice(source, payload + 4, payload + min(size, 200_000))
                let info = readHdrl(hdrl)
                scale = info.scale == 0 ? scale : info.scale
                rate = info.rate == 0 ? rate : info.rate
                width = info.width == 0 ? width : info.width
                height = info.height == 0 ? height : info.height
                handler = info.handler.isEmpty ? handler : info.handler
            }
        } else if id == "idx1" && size > 0 && size < 40_000_000 {
            let idx = Bytes.slice(source, payload, payload + size)
            let base = moviAt >= 0 ? moviAt : 0
            let entries = idx.count / 16
            let fps = Double(rate) / Double(scale == 0 ? 1 : scale)
            for i in 0 ..< entries {
                let o = i * 16
                let ckid = Bytes.fourcc(idx, o)
                let flags = Bytes.le32(idx, o + 4)
                let rel = Bytes.le32(idx, o + 8)
                let len = Bytes.le32(idx, o + 12)
                if !ckid.hasSuffix("dc") && !ckid.hasSuffix("db") { continue }
                samples.append(SampleRec(
                    pts: Double(samples.count) / (fps == 0 ? 24 : fps),
                    duration: 1 / (fps == 0 ? 24 : fps),
                    key: (flags & 0x10) != 0 || handler.lowercased() == "mjpg",
                    offset: base + rel + 8, size: len, inline: nil
                ))
            }
        }
        let step = 8 + size + (size & 1)
        if step < 8 { break }
        offset += step
        if offset > source.count { break }
    }
    if samples.isEmpty && moviAt >= 0 {
        warnings.append("No idx1 index. Scanning the movie list.")
        scanMovi(source, moviAt, &samples, Double(rate) / Double(scale == 0 ? 1 : scale))
    }
    let mjpg = handler.uppercased() == "MJPG" || handler.uppercased() == "JPEG"
    let h264 = ["H264", "X264", "AVC1"].contains(handler.uppercased())
    let fps = Double(rate) / Double(scale == 0 ? 1 : scale)
    let duration = Double(samples.count) / (fps == 0 ? 24 : fps)
    log.append("AVI \(handler.isEmpty ? "unknown" : handler) · \(width)×\(height) · \(samples.count) frames")
    if !mjpg && !h264 {
        warnings.append("\(handler.isEmpty ? "This codec" : handler) is identified. Playback is implemented for Motion JPEG and H.264.")
    }
    let report = TrackReport(
        id: 0, kind: .video, codec: handler.isEmpty ? "avi" : handler,
        codecLabel: mjpg ? "Motion JPEG" : h264 ? "H.264" : (handler.isEmpty ? "AVI video" : handler),
        language: nil, width: width == 0 ? nil : width, height: height == 0 ? nil : height, fps: fps,
        profile: nil, level: nil, hdr: HdrReport.sdr(), audio: nil, duration: duration, bitrate: nil
    )
    let setup: VideoSetup? = mjpg
        ? VideoSetup(family: .jpeg, codecs: ["mjpeg"], description: nil, codedWidth: width == 0 ? 16 : width, codedHeight: height == 0 ? 16 : height, bitstream: .raw, atoms: [:])
        : h264
            ? VideoSetup(family: .avc, codecs: ["avc1.42E01E"], description: nil, codedWidth: width == 0 ? 16 : width, codedHeight: height == 0 ? 16 : height, bitstream: .annexb, atoms: [:])
            : nil
    let track = samples.isEmpty ? nil : LoadedTrack(report: report, samples: samples, video: setup, audio: nil, playableAudio: false, timescale: rate)
    return .success(AviResult(duration: duration, video: track, warnings: warnings, log: log))
}

private struct HdrlInfo { var scale = 1; var rate = 0; var width = 0; var height = 0; var handler = "" }

private func readHdrl(_ data: Data) -> HdrlInfo {
    var info = HdrlInfo()
    var o = 0
    while o + 8 <= data.count {
        let id = Bytes.fourcc(data, o)
        let size = Bytes.le32(data, o + 4)
        let p = o + 8
        if id == "avih" && p + 40 <= data.count {
            info.width = Bytes.le32(data, p + 32)
            info.height = Bytes.le32(data, p + 36)
        } else if id == "strh" && p + 28 <= data.count {
            let kind = Bytes.fourcc(data, p)
            if kind == "vids" || info.handler.isEmpty {
                info.handler = Bytes.ascii(data, p + 4, 4).trimmingCharacters(in: .whitespaces)
                info.scale = Bytes.le32(data, p + 20)
                if info.scale == 0 { info.scale = 1 }
                info.rate = Bytes.le32(data, p + 24)
            }
        } else if id == "LIST" && p + 4 <= data.count && Bytes.fourcc(data, p) == "strl" {
            let nested = readHdrl(Bytes.slice(data, p + 4, min(data.count, p + size)))
            if nested.scale != 0 { info.scale = nested.scale }
            if nested.rate != 0 { info.rate = nested.rate }
            if nested.width != 0 { info.width = nested.width }
            if nested.height != 0 { info.height = nested.height }
            if !nested.handler.isEmpty { info.handler = nested.handler }
        }
        let step = 8 + size + (size & 1)
        if step < 8 { break }
        o += step
    }
    if info.rate == 0 { info.rate = 24 }
    return info
}

private func scanMovi(_ source: Data, _ moviPayload: Int, _ samples: inout [SampleRec], _ fps: Double) {
    var o = moviPayload + 4
    var guardN = 0
    while o + 8 <= source.count && guardN < 200_000 {
        guardN += 1
        let id = Bytes.fourcc(source, o)
        let size = Bytes.le32(source, o + 4)
        if id == "idx1" || id == "JUNK" || id == "LIST" { break }
        if id.hasSuffix("dc") || id.hasSuffix("db") {
            samples.append(SampleRec(pts: Double(samples.count) / (fps == 0 ? 24 : fps), duration: 1 / (fps == 0 ? 24 : fps), key: true, offset: o + 8, size: size, inline: nil))
        }
        let step = 8 + size + (size & 1)
        if step < 8 { break }
        o += step
    }
}
