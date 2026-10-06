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

`CinecorePlayer` keeps feeding `AVSampleBufferDisplayLayer` and
`AVSampleBufferAudioRenderer` through `requestMediaDataWhenReady`. The layer
asks for more samples when its queue has room. Seeking flushes that queue and
starts again from the previous keyframe. H.264 and HEVC are decoded by
VideoToolbox. AAC is queued when a format description can be built. Dolby
Vision atoms are attached to that description. This process does not run an
RPU composer and does not render Atmos objects. The player is compiled only
for iOS, macOS, and tvOS.

`MediaByteSource` is how bytes are read. `FileByteSource` seeks in a local
file. `HTTPByteSource` sends `Range` requests and keeps a small block cache.
An MP4 index reads the movie header and skips `mdat`. A Matroska index reads
one cluster at a time and keeps only the sample table. The table is in
memory. The picture bytes are not, until a sample is enqueued.

A failed sample read does not advance the cursor. The clock pauses, `buffering`
becomes true, and the same sample is tried again with a longer wait, up to
five seconds. A seek past the last audio sample stays past the end instead of
restarting that track at zero.

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

```swift
let media = try CinecoreOpen.open(remote: url)
```

The sample index is in memory. The media payload is not loaded up front.
