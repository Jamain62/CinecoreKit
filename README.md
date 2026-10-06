# CinecoreKit

Swift demuxer and player. There is no JavaScript and no `WKWebView`.

`CinecoreOpen` reads the container itself:

- MP4 / MOV, including fragmented movie boxes
- Matroska and WebM
- MPEG-TS
- AVI

It reports H.264, HEVC, VP9, AV1, Motion JPEG, AAC, Opus, AC-3, E-AC-3, the
Atmos JOC flag, Dolby Vision configuration, HDR10+ SEI, and HDR10 content-light
metadata.

`CinecorePlayer` is compiled only for iOS, macOS, and tvOS. H.264 and HEVC are
decoded by VideoToolbox through `AVSampleBufferDisplayLayer`. AAC is queued on
`AVSampleBufferAudioRenderer` when the audio-specific config builds a format
description. Dolby Vision `dvcC` / `dvvC` atoms are attached to that format
description so a capable display can see them. This process does not run a
Dolby RPU composer and does not render Atmos objects.

VP9, AV1, Opus, AC-3, E-AC-3, TrueHD, and DTS are identified. They are not
decoded. Saying otherwise would be a lie: Apple does not ship those decoders
to third-party apps, and this package does not vendor one.

## Use

```swift
import SwiftUI
import CinecoreKit

struct PlayerScreen: View {
    @StateObject private var player = CinecorePlayer()

    var body: some View {
        VStack {
            CinecoreView(player: player)
            Text(player.detail)
            Text(player.decodePath)
            if let vision = player.info?.tracks.first?.hdr.dolbyVision {
                Text("Dolby Vision profile \(vision.profile)")
            }
            Button("Play") { player.play() }
        }
        .task {
            player.open(fileURL: url)
        }
    }
}
```

Demux without a view:

```swift
let media = CinecoreOpen.open(data: data, name: "movie.mkv")
media.info.tracks
media.video?.samples
```

The whole file is loaded into memory.
