import Foundation

public enum CinecoreOpen {
    /// Demux from any random-access source. Sample bytes stay in the source
    /// until something reads a range.
    public static func open(source: any MediaByteSource, name: String) -> LoadedMedia {
        let ext = name.split(separator: ".").last?.lowercased() ?? ""
        let head = source.readOrEmpty(at: 0, count: 16)
        var info = MediaInfo(
            name: name, container: "unknown", format: "Unknown", size: Int(min(source.length, Int64(Int.max))), duration: 0,
            brands: [], tracks: [], videoIndex: -1, audioIndex: -1, warnings: [], log: []
        )
        if head.count >= 8 && Bytes.fourcc(head, 4) == "ftyp" {
            var iso = parseIso(source)
            enrichIsoHdr(source, &iso)
            info.container = "mp4"
            info.format = iso.format
            info.brands = iso.brands
            info.duration = iso.duration
            info.warnings = iso.warnings
            info.log = iso.log
            info.tracks = iso.tracks.map(\.report)
            return pack(info, source, iso.tracks, nil, nil)
        }
        if head.count >= 4 && head[0] == 0x1a && head[1] == 0x45 && head[2] == 0xdf && head[3] == 0xa3 {
            switch parseMatroska(source, webm: ext == "webm" || ext == "weba") {
            case .failure(let error):
                info.warnings.append(error.message)
                return LoadedMedia(info: info, source: source, video: nil, audio: nil, packetSize: nil, headerSkip: nil)
            case .success(let mkv):
                info.container = (ext == "webm" || mkv.docType == "webm") ? "webm" : "mkv"
                info.format = info.container == "webm" ? "WebM" : "Matroska"
                info.duration = mkv.duration
                info.warnings = mkv.warnings
                info.log = mkv.log
                info.tracks = mkv.tracks.map(\.report)
                var media = pack(info, source, mkv.tracks, nil, nil)
                media.matroska = mkv.index
                return media
            }
        }
        if head.count >= 12 && Bytes.fourcc(head, 0) == "RIFF" && Bytes.fourcc(head, 8) == "AVI " {
            switch parseAvi(source) {
            case .failure(let error):
                info.warnings.append(error.message)
            case .success(let avi):
                info.container = "avi"
                info.format = "AVI"
                info.duration = avi.duration
                info.warnings = avi.warnings
                info.log = avi.log
                if let video = avi.video {
                    info.tracks = [video.report]
                    info.videoIndex = 0
                    return LoadedMedia(info: info, source: source, video: video, audio: nil, packetSize: nil, headerSkip: nil)
                }
            }
            return LoadedMedia(info: info, source: source, video: nil, audio: nil, packetSize: nil, headerSkip: nil)
        }
        if (head.first == 0x47) || ext == "ts" || ext == "m2ts" || ext == "mts" {
            let ts = parseTs(source)
            info.container = "ts"
            info.format = "MPEG-TS"
            info.duration = ts.duration
            info.warnings = ts.warnings
            info.log = ts.log
            var tracks: [LoadedTrack] = []
            if let video = ts.video { tracks.append(video) }
            if let audio = ts.audio { tracks.append(audio) }
            info.tracks = tracks.map(\.report)
            return pack(info, source, tracks, ts.packetSize, ts.headerSkip)
        }
        info.warnings.append("Container not recognized. This engine reads MP4, MOV, MKV, WebM, MPEG-TS, and AVI.")
        return LoadedMedia(info: info, source: source, video: nil, audio: nil, packetSize: nil, headerSkip: nil)
    }

    public static func open(data: Data, name: String) -> LoadedMedia {
        open(source: MemoryByteSource(data), name: name)
    }

    public static func open(fileURL: URL) throws -> LoadedMedia {
        let source = try FileByteSource(url: fileURL)
        return open(source: source, name: fileURL.lastPathComponent)
    }

    /// HTTP Range requests. The server must answer HEAD with a length and GET
    /// with status 206. This does not download the object first.
    public static func open(remote url: URL, name: String? = nil) throws -> LoadedMedia {
        let source = try HTTPByteSource(url: url)
        return open(source: source, name: name ?? url.lastPathComponent)
    }
}

private func pack(_ infoIn: MediaInfo, _ source: any MediaByteSource, _ tracks: [LoadedTrack], _ packetSize: Int?, _ headerSkip: Int?) -> LoadedMedia {
    var info = infoIn
    let video = tracks.first { $0.report.kind == .video && $0.video != nil }
    let playable = tracks.first { $0.report.kind == .audio && $0.playableAudio && $0.audio != nil }
    let anyAudio = tracks.first { $0.report.kind == .audio }
    info.videoIndex = video.flatMap { v in info.tracks.firstIndex { $0.id == v.report.id && $0.kind == .video } } ?? -1
    let audioTrack = playable ?? anyAudio
    info.audioIndex = audioTrack.flatMap { a in info.tracks.firstIndex { $0.id == a.report.id && $0.kind == .audio } } ?? -1
    if let label = video?.report.hdr.label, label != "SDR" { info.log.append("signal \(label)") }
    if audioTrack?.report.audio?.atmos == true, let label = audioTrack?.report.audio?.codecLabel {
        info.log.append("audio \(label)")
    }
    return LoadedMedia(info: info, source: source, video: video, audio: playable ?? anyAudio, packetSize: packetSize, headerSkip: headerSkip)
}