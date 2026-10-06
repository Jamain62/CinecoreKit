import Foundation

public enum CinecoreOpen {
    /// Demux a whole file that is already in memory. Containers: MP4, MOV, Matroska,
    /// WebM, MPEG-TS, AVI. Decode of the picture is a separate step on Apple platforms.
    public static func open(data: Data, name: String) -> LoadedMedia {
        let ext = name.split(separator: ".").last?.lowercased() ?? ""
        var info = MediaInfo(
            name: name, container: "unknown", format: "Unknown", size: data.count, duration: 0,
            brands: [], tracks: [], videoIndex: -1, audioIndex: -1, warnings: [], log: []
        )
        if data.count >= 8 && Bytes.fourcc(data, 4) == "ftyp" {
            var iso = parseIso(data)
            enrichIsoHdr(data, &iso)
            info.container = "mp4"
            info.format = iso.format
            info.brands = iso.brands
            info.duration = iso.duration
            info.warnings = iso.warnings
            info.log = iso.log
            info.tracks = iso.tracks.map(\.report)
            return pack(info, data, iso.tracks, nil, nil)
        }
        if data.count >= 4 && data[0] == 0x1a && data[1] == 0x45 && data[2] == 0xdf && data[3] == 0xa3 {
            switch parseMatroska(data, webm: ext == "webm" || ext == "weba") {
            case .failure(let error):
                info.warnings.append(error.message)
                return LoadedMedia(info: info, data: data, video: nil, audio: nil, packetSize: nil, headerSkip: nil)
            case .success(let mkv):
                info.container = (ext == "webm" || mkv.docType == "webm") ? "webm" : "mkv"
                info.format = info.container == "webm" ? "WebM" : "Matroska"
                info.duration = mkv.duration
                info.warnings = mkv.warnings
                info.log = mkv.log
                info.tracks = mkv.tracks.map(\.report)
                return pack(info, data, mkv.tracks, nil, nil)
            }
        }
        if data.count >= 12 && Bytes.fourcc(data, 0) == "RIFF" && Bytes.fourcc(data, 8) == "AVI " {
            switch parseAvi(data) {
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
                    return LoadedMedia(info: info, data: data, video: video, audio: nil, packetSize: nil, headerSkip: nil)
                }
            }
            return LoadedMedia(info: info, data: data, video: nil, audio: nil, packetSize: nil, headerSkip: nil)
        }
        if (data.first == 0x47) || ext == "ts" || ext == "m2ts" || ext == "mts" {
            let ts = parseTs(data)
            info.container = "ts"
            info.format = "MPEG-TS"
            info.duration = ts.duration
            info.warnings = ts.warnings
            info.log = ts.log
            var tracks: [LoadedTrack] = []
            if let video = ts.video { tracks.append(video) }
            if let audio = ts.audio { tracks.append(audio) }
            info.tracks = tracks.map(\.report)
            return pack(info, data, tracks, ts.packetSize, ts.headerSkip)
        }
        info.warnings.append("Container not recognized. This engine reads MP4, MOV, MKV, WebM, MPEG-TS, and AVI.")
        return LoadedMedia(info: info, data: data, video: nil, audio: nil, packetSize: nil, headerSkip: nil)
    }

    public static func open(fileURL: URL) throws -> LoadedMedia {
        let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        return open(data: data, name: fileURL.lastPathComponent)
    }
}

private func pack(_ infoIn: MediaInfo, _ data: Data, _ tracks: [LoadedTrack], _ packetSize: Int?, _ headerSkip: Int?) -> LoadedMedia {
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
    return LoadedMedia(info: info, data: data, video: video, audio: playable ?? anyAudio, packetSize: packetSize, headerSkip: headerSkip)
}
