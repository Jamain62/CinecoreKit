import Foundation

public enum TrackKind: String, Equatable {
    case video, audio, other
}

public struct DolbyVisionInfo: Equatable {
    public var profile: Int
    public var level: Int
    public var rpu: Bool
    public var el: Bool
    public var bl: Bool
    public var compatibility: String
    public var version: String
    public var summary: String
}

public struct HdrReport: Equatable {
    public var label: String
    public var transfer: String
    public var primaries: String
    public var matrix: String
    public var fullRange: Bool
    public var bitDepth: Int?
    public var chroma: String?
    public var maxCll: Int?
    public var maxFall: Int?
    public var mastering: String?
    public var dolbyVision: DolbyVisionInfo?
    public var hdr10Plus: Bool
    public var notes: [String]

    public static func sdr() -> HdrReport {
        HdrReport(
            label: "SDR", transfer: "Unspecified", primaries: "Unspecified", matrix: "Unspecified",
            fullRange: false, bitDepth: nil, chroma: nil, maxCll: nil, maxFall: nil, mastering: nil,
            dolbyVision: nil, hdr10Plus: false, notes: []
        )
    }
}

public struct AudioReport: Equatable {
    public var codecLabel: String
    public var channels: Int?
    public var layout: String?
    public var sampleRate: Int?
    public var atmos: Bool
    public var detail: String?
}

public struct TrackReport: Equatable {
    public var id: Int
    public var kind: TrackKind
    public var codec: String
    public var codecLabel: String
    public var language: String?
    public var width: Int?
    public var height: Int?
    public var fps: Double?
    public var profile: String?
    public var level: String?
    public var hdr: HdrReport
    public var audio: AudioReport?
    public var duration: Double
    public var bitrate: Double?
}

public struct MediaInfo: Equatable {
    public var name: String
    public var container: String
    public var format: String
    public var size: Int
    public var duration: Double
    public var brands: [String]
    public var tracks: [TrackReport]
    public var videoIndex: Int
    public var audioIndex: Int
    public var warnings: [String]
    public var log: [String]
}

public enum Bitstream: String, Equatable { case avcc, annexb, raw }
public enum VideoFamily: String, Equatable { case avc, hevc, av1, vp8, vp9, jpeg, other }

public struct VideoSetup: Equatable {
    public var family: VideoFamily
    public var codecs: [String]
    public var description: Data?
    public var codedWidth: Int
    public var codedHeight: Int
    public var bitstream: Bitstream
    /// Raw sample-entry atoms such as `dvcC`, `colr`, `mdcv`, `clli`.
    public var atoms: [String: Data]
}

public struct AudioSetup: Equatable {
    public var codecs: [String]
    public var description: Data?
    public var sampleRate: Int
    public var channels: Int
}

public struct SampleRec: Equatable {
    public var pts: Double
    public var duration: Double
    public var key: Bool
    public var offset: Int
    public var size: Int
    public var inline: Data?
}

public struct LoadedTrack {
    public var report: TrackReport
    public var samples: [SampleRec]
    public var video: VideoSetup?
    public var audio: AudioSetup?
    public var playableAudio: Bool
    public var timescale: Int
}

public struct LoadedMedia {
    public var info: MediaInfo
    /// Backing bytes. Sample payloads stay here until the player asks for one.
    public var source: any MediaByteSource
    public var video: LoadedTrack?
    public var audio: LoadedTrack?
    /// MPEG-TS packet size, when the container is a transport stream.
    public var packetSize: Int?
    public var headerSkip: Int?
    /// Set for Matroska opened from HTTP. Samples grow as clusters are indexed.
    public var matroska: MatroskaIndex?
}

public struct CinecoreError: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }
    public init(_ message: String) { self.message = message }
}
