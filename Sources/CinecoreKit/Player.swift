#if os(iOS) || os(macOS) || os(tvOS)
import AVFoundation
import CoreMedia
import Foundation
#if os(iOS) || os(tvOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif
import SwiftUI

/// Swift player. The container is read by `CinecoreOpen`. H.264 and HEVC samples
/// are handed to VideoToolbox through `AVSampleBufferDisplayLayer`. AAC goes to
/// `AVSampleBufferAudioRenderer` when the format description can be built.
/// Dolby Vision atoms are attached to the format description; the RPU itself is
/// not composited in this process.
public final class CinecorePlayer: NSObject, ObservableObject {
    @Published public private(set) var info: MediaInfo?
    @Published public private(set) var time: Double = 0
    @Published public private(set) var duration: Double = 0
    @Published public private(set) var playing = false
    @Published public private(set) var decodePath = "not open"
    @Published public private(set) var detail = "Standby"
    @Published public private(set) var lastError: String?

    public let view: CinecorePlayerView
    private let display = AVSampleBufferDisplayLayer()
    private let sync = AVSampleBufferRenderSynchronizer()
    private let audioRenderer = AVSampleBufferAudioRenderer()
    private var media: LoadedMedia?
    private var videoFormat: CMFormatDescription?
    private var audioFormat: CMAudioFormatDescription?
    private var nalLength = 4
    private var family: VideoFamily = .other
    private var audioAttached = false
    private var feeding = false
    private var feedGeneration = 0
    private var videoCursor = 0
    private var audioCursor = 0
    private let mediaQueue = DispatchQueue(label: "cinecore.samples")
    private let cursorLock = NSLock()
    private var ticker: Timer?

    public override init() {
        let view = CinecorePlayerView(display: display)
        self.view = view
        super.init()
        display.videoGravity = .resizeAspect
        display.backgroundColor = CGColor(gray: 0, alpha: 1)
        sync.addRenderer(display)
        display.controlTimebase = sync.timebase
    }

    public func open(data: Data, name: String) {
        adopt(CinecoreOpen.open(data: data, name: name))
    }

    public func open(fileURL: URL) {
        do {
            adopt(try CinecoreOpen.open(fileURL: fileURL))
        } catch {
            lastError = error.localizedDescription
            detail = lastError ?? "Unreadable file."
        }
    }

    public func open(remote url: URL) {
        do {
            adopt(try CinecoreOpen.open(remote: url))
        } catch {
            lastError = error.localizedDescription
            detail = lastError ?? "Remote open failed."
        }
    }

    private func adopt(_ opened: LoadedMedia) {
        stopFeeding()
        stopTicker()
        sync.rate = 0
        display.flush()
        audioRenderer.flush()
        cursorLock.lock()
        media = opened
        cursorLock.unlock()
        info = opened.info
        duration = opened.info.duration
        time = 0
        playing = false
        lastError = nil
        videoFormat = nil
        audioFormat = nil
        videoCursor = 0
        audioCursor = 0
        guard let video = opened.video, let setup = video.video else {
            decodePath = "metadata"
            detail = opened.info.warnings.first ?? "No picture track."
            return
        }
        family = setup.family
        switch setup.family {
        case .avc, .hevc:
            videoFormat = makeVideoFormat(setup)
            if videoFormat == nil {
                decodePath = "metadata"
                detail = "VideoToolbox rejected the \(video.report.codecLabel) parameter sets."
                lastError = detail
            } else {
                decodePath = "VideoToolbox"
                detail = video.report.codecLabel
                if video.report.hdr.dolbyVision != nil {
                    detail += " · base layer. RPU is attached for the display, not composited here."
                }
            }
        case .jpeg:
            decodePath = "ImageIO"
            detail = "Motion JPEG"
            if let first = video.samples.first {
                view.show(jpeg: sampleBytes(opened, first))
            }
        default:
            decodePath = "metadata"
            detail = "\(video.report.codecLabel) was demuxed. This engine does not include a \(setup.family.rawValue) decoder."
            lastError = detail
        }
        if let audio = opened.audio, audio.playableAudio, let setup = audio.audio, setup.codecs.first?.hasPrefix("mp4a") == true {
            audioFormat = makeAudioFormat(setup)
            if audioFormat != nil && !audioAttached {
                sync.addRenderer(audioRenderer)
                audioAttached = true
            }
        }
    }

    public func play() {
        guard let media, videoFormat != nil || family == .jpeg else {
            lastError = lastError ?? "Nothing playable is open."
            return
        }
        if family == .jpeg {
            playing = true
            startTicker()
            return
        }
        if !feeding { startFeeding(from: time) }
        sync.rate = 1
        playing = true
        startTicker()
    }

    public func pause() {
        if let timebase = sync.timebase {
            time = CMTimeGetSeconds(CMTimebaseGetTime(timebase))
        }
        sync.rate = 0
        playing = false
        stopTicker()
    }

    public func seek(to seconds: Double) {
        let target = max(0, min(seconds, duration))
        time = target
        guard videoFormat != nil else { return }
        let was = playing
        sync.rate = 0
        stopFeeding()
        display.flush()
        audioRenderer.flush()
        sync.setRate(0, time: CMTime(seconds: target, preferredTimescale: 600))
        startFeeding(from: target)
        if was {
            sync.rate = 1
            playing = true
        }
    }

    public func close() {
        pause()
        stopFeeding()
        display.flush()
        audioRenderer.flush()
        cursorLock.lock()
        media = nil
        cursorLock.unlock()
        info = nil
        videoFormat = nil
        audioFormat = nil
        decodePath = "not open"
        detail = "Standby"
        time = 0
        duration = 0
    }

    private func startFeeding(from start: Double) {
        guard let media, let track = media.video else { return }
        cursorLock.lock()
        feedGeneration += 1
        let generation = feedGeneration
        videoCursor = 0
        for (index, sample) in track.samples.enumerated() where sample.key && sample.pts <= start + 0.0008 {
            videoCursor = index
        }
        audioCursor = 0
        if let audio = media.audio {
            for (index, sample) in audio.samples.enumerated() where sample.pts + sample.duration >= start {
                audioCursor = index
                break
            }
        }
        cursorLock.unlock()
        feeding = true
        display.requestMediaDataWhenReady(on: mediaQueue) { [weak self] in
            self?.supplyVideo(generation)
        }
        if audioFormat != nil {
            audioRenderer.requestMediaDataWhenReady(on: mediaQueue) { [weak self] in
                self?.supplyAudio(generation)
            }
        }
    }

    private func stopFeeding() {
        display.stopRequestingMediaData()
        audioRenderer.stopRequestingMediaData()
        cursorLock.lock()
        feedGeneration += 1
        cursorLock.unlock()
        feeding = false
    }

    private func supplyVideo(_ generation: Int) {
        guard let format = videoFormat else {
            display.stopRequestingMediaData()
            return
        }
        if display.status == .failed { display.flush() }
        while display.isReadyForMoreMediaData {
            cursorLock.lock()
            if generation != feedGeneration {
                cursorLock.unlock()
                return
            }
            guard let media, let track = media.video else {
                cursorLock.unlock()
                display.stopRequestingMediaData()
                return
            }
            if videoCursor >= track.samples.count {
                cursorLock.unlock()
                display.stopRequestingMediaData()
                return
            }
            let sample = track.samples[videoCursor]
            videoCursor += 1
            cursorLock.unlock()
            let bytes = normalize(sampleBytes(media, sample))
            guard !bytes.isEmpty, let buffer = makeVideoBuffer(bytes, sample, format) else { continue }
            display.enqueue(buffer)
        }
    }

    private func supplyAudio(_ generation: Int) {
        guard let format = audioFormat else {
            audioRenderer.stopRequestingMediaData()
            return
        }
        while audioRenderer.isReadyForMoreMediaData {
            cursorLock.lock()
            if generation != feedGeneration {
                cursorLock.unlock()
                return
            }
            guard let media, let track = media.audio, track.playableAudio else {
                cursorLock.unlock()
                audioRenderer.stopRequestingMediaData()
                return
            }
            if audioCursor >= track.samples.count {
                cursorLock.unlock()
                audioRenderer.stopRequestingMediaData()
                return
            }
            let sample = track.samples[audioCursor]
            audioCursor += 1
            cursorLock.unlock()
            let bytes = sampleBytes(media, sample)
            guard !bytes.isEmpty, let buffer = makeAudioBuffer(bytes, sample, format) else { continue }
            audioRenderer.enqueue(buffer)
        }
    }

    private func sampleBytes(_ media: LoadedMedia, _ sample: SampleRec) -> Data {
        if let inline = sample.inline { return inline }
        if sample.offset < 0 || sample.size <= 0 { return Data() }
        if media.info.container == "ts", let packet = media.packetSize, let skip = media.headerSkip {
            return extractPes(media.source, sample.offset, sample.size, packet, skip)
        }
        return media.source.readOrEmpty(at: Int64(sample.offset), count: sample.size)
    }

    private func normalize(_ data: Data) -> Data {
        guard family == .avc || family == .hevc else { return data }
        let annex = data.count > 4 && data[0] == 0 && data[1] == 0 && (data[2] == 1 || (data[2] == 0 && data[3] == 1))
        if !annex && nalLength == 4 { return data }
        let nals = annex ? splitAnnexB(data) : lengthPrefixedNals(data, nalLength)
        var out = Data()
        for nal in nals {
            var len = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &len) { out.append(contentsOf: $0) }
            out.append(nal)
        }
        return out
    }

    private func lengthPrefixedNals(_ data: Data, _ length: Int) -> [Data] {
        var o = 0
        var nals: [Data] = []
        let ls = max(1, length)
        while o + ls <= data.count {
            var size = 0
            for _ in 0 ..< ls {
                size = (size << 8) | Int(data[o])
                o += 1
            }
            if size <= 0 || o + size > data.count { break }
            nals.append(data.subdata(in: o ..< (o + size)))
            o += size
        }
        return nals
    }

    private func makeVideoFormat(_ setup: VideoSetup) -> CMFormatDescription? {
        var atoms: [CFString: Any] = [:]
        for (key, value) in setup.atoms {
            atoms[key as CFString] = value as CFData
        }
        let extensions: CFDictionary? = atoms.isEmpty ? nil : [kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms: atoms] as CFDictionary
        if setup.family == .avc, let avcC = setup.description ?? setup.atoms["avcC"] {
            let sets = avcParameterSets(avcC)
            nalLength = 4
            return parameterFormat(sets.sps + sets.pps, hevc: false, extensions: extensions)
        }
        if setup.family == .hevc, let hvcC = setup.description ?? setup.atoms["hvcC"] {
            nalLength = hvcC.count > 21 ? (Int(hvcC[21]) & 3) + 1 : 4
            return parameterFormat(hevcParameterSets(hvcC), hevc: true, extensions: extensions)
        }
        return nil
    }

    private func parameterFormat(_ sets: [Data], hevc: Bool, extensions: CFDictionary?) -> CMFormatDescription? {
        if sets.isEmpty { return nil }
        let owned = sets.map { $0 as NSData }
        var pointers = owned.map { UnsafePointer<UInt8>($0.bytes.assumingMemoryBound(to: UInt8.self)) }
        var sizes = owned.map(\.length)
        var format: CMFormatDescription?
        let status: OSStatus
        if hevc {
            status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: pointers.count,
                parameterSetPointers: &pointers, parameterSetSizes: &sizes,
                nalUnitHeaderLength: 4, extensions: extensions, formatDescriptionOut: &format
            )
        } else {
            status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault, parameterSetCount: pointers.count,
                parameterSetPointers: &pointers, parameterSetSizes: &sizes,
                nalUnitHeaderLength: 4, extensions: extensions, formatDescriptionOut: &format
            )
        }
        return status == noErr ? format : nil
    }

    private func makeAudioFormat(_ setup: AudioSetup) -> CMAudioFormatDescription? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(setup.sampleRate), mFormatID: kAudioFormatMPEG4AAC, mFormatFlags: 0,
            mBytesPerPacket: 0, mFramesPerPacket: 1024, mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(max(1, setup.channels)), mBitsPerChannel: 0, mReserved: 0
        )
        let cookie = (setup.description ?? Data()) as NSData
        var format: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault, asbd: &asbd, layoutSize: 0, layout: nil,
            magicCookieSize: cookie.length, magicCookie: cookie.length == 0 ? nil : cookie.bytes,
            extensions: nil, formatDescriptionOut: &format
        )
        return status == noErr ? format : nil
    }

    private func makeVideoBuffer(_ data: Data, _ sample: SampleRec, _ format: CMFormatDescription) -> CMSampleBuffer? {
        makeBuffer(data, sample, format)
    }

    private func makeAudioBuffer(_ data: Data, _ sample: SampleRec, _ format: CMAudioFormatDescription) -> CMSampleBuffer? {
        makeBuffer(data, sample, format)
    }

    private func makeBuffer(_ data: Data, _ sample: SampleRec, _ format: CMFormatDescription) -> CMSampleBuffer? {
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: data.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: data.count, flags: 0, blockBufferOut: &block
        ) == kCMBlockBufferNoErr, let block else { return nil }
        let replaced = data.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: data.count)
        }
        if replaced != kCMBlockBufferNoErr { return nil }
        var timing = CMSampleTimingInfo(
            duration: CMTime(seconds: sample.duration > 0 ? sample.duration : 1.0 / 30.0, preferredTimescale: 600),
            presentationTimeStamp: CMTime(seconds: max(0, sample.pts), preferredTimescale: 600),
            decodeTimeStamp: .invalid
        )
        var size = data.count
        var buffer: CMSampleBuffer?
        let status = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault, dataBuffer: block, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: format, sampleCount: 1,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
            sampleSizeArray: &size, sampleBufferOut: &buffer
        )
        return status == noErr ? buffer : nil
    }

    private func startTicker() {
        stopTicker()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.family == .jpeg { self.advanceJpeg() ; return }
            guard let timebase = self.sync.timebase else { return }
            let now = CMTimeGetSeconds(CMTimebaseGetTime(timebase))
            if now.isFinite { self.time = now }
            if self.duration > 0 && now >= self.duration - 0.05 {
                self.pause()
            }
        }
        ticker = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func advanceJpeg() {
        guard let media, let track = media.video else { return }
        time += 0.1
        if time >= duration { pause(); return }
        if let sample = track.samples.last(where: { $0.pts <= time }) ?? track.samples.first {
            view.show(jpeg: sampleBytes(media, sample))
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }
}

#if os(iOS) || os(tvOS)
public final class CinecorePlayerView: UIView {
    private let imageView = UIImageView()
    init(display: AVSampleBufferDisplayLayer) {
        super.init(frame: .zero)
        backgroundColor = .black
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        display.frame = bounds
        layer.addSublayer(display)
    }
    public override func layoutSubviews() {
        super.layoutSubviews()
        layer.sublayers?.forEach { $0.frame = bounds }
    }
    func show(jpeg data: Data) {
        imageView.image = UIImage(data: data)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use CinecorePlayer") }
}
#elseif os(macOS)
public final class CinecorePlayerView: NSView {
    private let imageView = NSImageView()
    init(display: AVSampleBufferDisplayLayer) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: trailingAnchor),
            imageView.topAnchor.constraint(equalTo: topAnchor),
            imageView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        if let layer { layer.addSublayer(display) }
    }
    public override func layout() {
        super.layout()
        layer?.sublayers?.forEach { $0.frame = bounds }
    }
    func show(jpeg data: Data) {
        imageView.image = NSImage(data: data)
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("Use CinecorePlayer") }
}
#endif

public struct CinecoreView: View {
    @ObservedObject var player: CinecorePlayer
    public init(player: CinecorePlayer) { self.player = player }
    public var body: some View {
        CinecoreRepresentable(player: player)
    }
}

#if os(iOS) || os(tvOS)
private struct CinecoreRepresentable: UIViewRepresentable {
    let player: CinecorePlayer
    func makeUIView(context: Context) -> CinecorePlayerView { player.view }
    func updateUIView(_ uiView: CinecorePlayerView, context: Context) {}
}
#elseif os(macOS)
private struct CinecoreRepresentable: NSViewRepresentable {
    let player: CinecorePlayer
    func makeNSView(context: Context) -> CinecorePlayerView { player.view }
    func updateNSView(_ nsView: CinecorePlayerView, context: Context) {}
}
#endif
#endif
