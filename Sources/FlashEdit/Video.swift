// Video: a clip is edited like a photo. The canvas shows one frame (you pick which), and export runs every frame of the
// cut through the same pipeline, with Vision finding the person again in each one. The timeline (VideoEditor.swift) keeps
// the cut: clips, hidden or muted layers and voice-overs, which `editComposition` turns into one AVComposition.
import AVFoundation
import CoreImage
import Foundation
import UniformTypeIdentifiers

func isVideoFile(_ url: URL) -> Bool { UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) == true }

/// One upright frame `time` seconds in. `maxSide` downsamples (for previews and thumbnails).
func videoFrame(_ url: URL, at time: Double, maxSide: Int? = nil) -> CGImage? {
    let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    gen.appliesPreferredTrackTransform = true
    (gen.requestedTimeToleranceBefore, gen.requestedTimeToleranceAfter) = (.zero, .zero)  // the exact frame you picked
    if let maxSide { gen.maximumSize = CGSize(width: maxSide, height: maxSide) }
    let t = CMTime(seconds: max(time, 0), preferredTimescale: 600)
    if let cg = try? gen.copyCGImage(at: t, actualTime: nil) { return cg }
    (gen.requestedTimeToleranceBefore, gen.requestedTimeToleranceAfter) = (.positiveInfinity, .positiveInfinity)  // e.g. the very end
    return try? gen.copyCGImage(at: t, actualTime: nil)
}

private func videoTrack(_ url: URL) -> AVAssetTrack? { AVURLAsset(url: url).tracks(withMediaType: .video).first }

/// Upright pixel size of the clip.
func videoSize(_ url: URL) -> CGSize? {
    guard let t = videoTrack(url) else { return nil }
    let r = CGRect(origin: .zero, size: t.naturalSize).applying(t.preferredTransform)
    return CGSize(width: abs(r.width), height: abs(r.height))
}

func videoDuration(_ url: URL) -> Double { let d = AVURLAsset(url: url).duration.seconds; return d.isFinite ? d : 0 }

func cmTime(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: 600) }

/// "0:12", or "0:12.4" with `tenths`.
func timecode(_ t: Double, tenths: Bool = false) -> String {
    let t = max(t, 0), s = Int(t)
    return tenths ? String(format: "%d:%02d.%d", s / 60, s % 60, Int((t - Double(s)) * 10)) : String(format: "%d:%02d", s / 60, s % 60)
}

/// `n` small frames spread evenly over the clip, for the timeline's filmstrip.
func videoThumbnails(_ url: URL, _ duration: Double, _ n: Int) -> [CGImage] {
    let gen = AVAssetImageGenerator(asset: AVURLAsset(url: url))
    gen.appliesPreferredTrackTransform = true
    gen.maximumSize = CGSize(width: 160, height: 160)
    return (0..<n).compactMap { k in try? gen.copyCGImage(at: cmTime(duration * (Double(k) + 0.5) / Double(n)), actualTime: nil) }
}

// MARK: - Timeline: cuts, layers and voice-overs

/// A kept part of the source clip, in source seconds.
struct Clip: Codable, Equatable, Identifiable {
    var id = UUID()
    var start: Double, end: Double
    var length: Double { end - start }
}

/// Recorded or imported sound laid over the video from `at` (timeline seconds).
struct VoiceOver: Codable, Equatable, Identifiable {
    var id = UUID()
    var path: String, name: String
    var at: Double, duration: Double
    var volume = 1.0
    var muted = false
}

/// How a video is cut: its clips in order, which layers are on, and the voice-overs. A photo's nil timeline is the whole
/// clip as shot.
struct Timeline: Codable, Equatable {
    var clips: [Clip]
    var videoHidden = false  // black picture; the sound plays on
    var soundMuted = false  // the clip's own sound
    var volume = 1.0  // of the clip's own sound
    var voices: [VoiceOver] = []

    static func whole(_ duration: Double) -> Timeline { Timeline(clips: [Clip(start: 0, end: max(duration, 0.01))]) }
    var duration: Double { clips.reduce(0) { $0 + $1.length } }
    func start(of i: Int) -> Double { clips[..<i].reduce(0) { $0 + $1.length } }

    /// The clip under timeline second `t` and the source second it shows there.
    func locate(_ t: Double) -> (index: Int, source: Double)? {
        var x = 0.0
        for (i, c) in clips.enumerated() {
            if t < x + c.length || i == clips.count - 1 { return (i, min(c.end, c.start + max(0, t - x))) }
            x += c.length
        }
        return nil
    }

    /// Where source second `s` first shows on the timeline (nil when it was cut out).
    func position(ofSource s: Double) -> Double? {
        var x = 0.0
        for c in clips {
            if (c.start...c.end).contains(s) { return x + s - c.start }
            x += c.length
        }
        return nil
    }

    /// Cuts the clip under `t` in two; false when `t` is within 0.05 s of a cut already.
    mutating func split(at t: Double) -> Bool {
        guard let hit = locate(t), hit.source - clips[hit.index].start > 0.05, clips[hit.index].end - hit.source > 0.05 else { return false }
        let end = clips[hit.index].end
        clips[hit.index].end = hit.source
        clips.insert(Clip(start: hit.source, end: end), at: hit.index + 1)
        return true
    }
}

/// The cut as one composition: the kept clips in order (picture and, unless muted, the clip's own sound), then each voice-over
/// that isn't muted on its own track, with their volumes in the audio mix. Playback and export both use it.
func editComposition(_ p: Photo) throws -> (AVMutableComposition, AVMutableAudioMix?) {
    let fail = { (m: String) in NSError(domain: "FlashEdit", code: 3, userInfo: [NSLocalizedDescriptionKey: m]) }
    let asset = AVURLAsset(url: p.url)
    guard let src = asset.tracks(withMediaType: .video).first else { throw fail("The file has no video track.") }
    let tl = p.timeline ?? .whole(asset.duration.seconds)
    let comp = AVMutableComposition()
    guard let v = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw fail("Can't build the video.") }
    v.preferredTransform = src.preferredTransform  // upright, like the source
    let srcSound = tl.soundMuted ? nil : asset.tracks(withMediaType: .audio).first
    let sound = srcSound == nil ? nil : comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
    var at = CMTime.zero
    for c in tl.clips where c.length > 0 {
        let range = CMTimeRange(start: cmTime(c.start), end: cmTime(c.end))
        try v.insertTimeRange(range, of: src, at: at)
        if let srcSound, let sound { try? sound.insertTimeRange(range, of: srcSound, at: at) }
        at = CMTimeAdd(at, range.duration)
    }
    var inputs: [AVMutableAudioMixInputParameters] = []
    if let sound {
        let input = AVMutableAudioMixInputParameters(track: sound)
        input.setVolume(Float(tl.volume), at: .zero)
        inputs.append(input)
    }
    for voice in tl.voices where !voice.muted && voice.at < at.seconds {
        let va = AVURLAsset(url: URL(fileURLWithPath: voice.path))
        guard let vt = va.tracks(withMediaType: .audio).first,
              let track = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
        let length = CMTimeMinimum(va.duration, CMTimeSubtract(at, cmTime(voice.at)))  // a voice-over never runs past the end
        try? track.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: vt, at: cmTime(voice.at))
        let input = AVMutableAudioMixInputParameters(track: track)
        input.setVolume(Float(voice.volume), at: .zero)
        inputs.append(input)
    }
    let mix = AVMutableAudioMix()
    mix.inputParameters = inputs
    return (comp, inputs.isEmpty ? nil : mix)
}

/// "1920 × 1080 · 30 fps · 0:12"
func videoInfo(_ url: URL) -> String {
    guard let t = videoTrack(url), let size = videoSize(url) else { return "" }
    var parts = ["\(Int(size.width)) × \(Int(size.height))"]
    if t.nominalFrameRate > 0 { parts.append("\(Int(t.nominalFrameRate.rounded())) fps") }
    parts.append(timecode(videoDuration(url)))
    return parts.joined(separator: " · ")
}

/// Renders every frame of the cut with its edit into a QuickTime movie (H.264 or HEVC) at `dst`, with the clip's sound and
/// voice-overs mixed into AAC. `longEdge` (0 = full size) shrinks frames before editing, which also makes long clips much
/// quicker. `metadata` keeps the date and location. `progress` gets 0...1.
func exportVideo(_ p: Photo, to dst: URL, longEdge: Int, hevc: Bool, metadata: Bool, progress: (Double) -> Void) throws {
    let fail = { (m: String) in NSError(domain: "FlashEdit", code: 3, userInfo: [NSLocalizedDescriptionKey: m]) }
    let source = AVURLAsset(url: p.url)
    let (asset, mix) = try editComposition(p)
    guard let track = asset.tracks(withMediaType: .video).first else { throw fail("The file has no video track.") }
    let duration = max(asset.duration.seconds, 0.001), hidden = p.timeline?.videoHidden == true
    let (bg, fg, whole) = (p.params(for: .background), p.params(for: .person), p.params)

    let reader = try AVAssetReader(asset: asset)
    let frames = AVAssetReaderVideoCompositionOutput(videoTracks: [track],
        videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    frames.videoComposition = AVMutableVideoComposition(propertiesOf: asset)  // upright, like the preview
    reader.add(frames)
    guard reader.startReading() else { throw reader.error ?? fail("Can't read the video.") }
    // the sound (the clip's own and the voice-overs, mixed) has its own reader, so the slow video frames never hold it up
    let audioTracks = asset.tracks(withMediaType: .audio)
    let sound = audioTracks.isEmpty ? nil : AVAssetReaderAudioMixOutput(audioTracks: audioTracks, audioSettings: [
        AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
    sound?.audioMix = mix
    let audioReader = try sound.map { s -> AVAssetReader in let r = try AVAssetReader(asset: asset); r.add(s); _ = r.startReading(); return r }

    let ci = CIContext()
    var black: CGImage?  // a hidden video layer: every frame is this, at the edited size
    func nextFrame() throws -> (CMTime, CGImage)? {
        while let buf = frames.copyNextSampleBuffer() {
            if let black { return (CMSampleBufferGetPresentationTimeStamp(buf), black) }
            guard let pb = CMSampleBufferGetImageBuffer(buf) else { continue }
            let img = CIImage(cvPixelBuffer: pb)
            guard let full = ci.createCGImage(img, from: img.extent) else { continue }
            let cg = resized(full, longEdge: longEdge)
            let (M, faces) = try analyze(cg)
            var out = geometry(edit(rgb(cg), M, faces, bg: bg, fg: fg), whole)
            if hidden {
                let zero = [Float](repeating: 0, count: out.n)
                out = RGB(w: out.w, h: out.h, r: zero, g: zero, b: zero)
                black = cgImage(out)
            }
            return (CMSampleBufferGetPresentationTimeStamp(buf), cgImage(out))
        }
        if reader.status == .failed { throw reader.error ?? fail("Can't read the video.") }
        return nil
    }
    guard var next = try nextFrame() else { throw fail("The video has no frames.") }

    // the first edited frame sets the size (crop and rotation change it); encoders want even sizes
    let (W, H) = (next.1.width & ~1, next.1.height & ~1)
    let rate = source.tracks(withMediaType: .video).first?.nominalFrameRate ?? 0, fps = Double(rate > 0 ? rate : 30)
    try? FileManager.default.removeItem(at: dst)
    let writer = try AVAssetWriter(outputURL: dst, fileType: .mov)
    if metadata {  // date taken and location (QuickTime keys; an MP4's iTunes tags don't carry over)
        let keep: [AVMetadataKeySpace] = [.quickTimeMetadata, .quickTimeUserData, .common]
        writer.metadata = source.metadata.filter { $0.keySpace.map(keep.contains) == true }
    }
    let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
        AVVideoCodecKey: hevc ? AVVideoCodecType.hevc : AVVideoCodecType.h264, AVVideoWidthKey: W, AVVideoHeightKey: H,
        AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: Int(Double(W * H) * fps * (hevc ? 0.12 : 0.2))],
        AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                    AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                    AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]])
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: W,
        kCVPixelBufferHeightKey as String: H])
    writer.add(video)
    var audio = sound.map { _ in
        AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000,
                                                               AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 192_000])
    }
    if let a = audio, !writer.canAdd(a) { audio = nil }  // can't hold the sound: export without it
    if let audio { writer.add(audio) }
    guard writer.startWriting() else { throw writer.error ?? fail("Can't write the video.") }
    writer.startSession(atSourceTime: .zero)

    func append(_ cg: CGImage, at t: CMTime) throws {
        var made: CVPixelBuffer?
        guard let pool = adaptor.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &made) == kCVReturnSuccess, let out = made
        else { throw writer.error ?? fail("Can't write the video.") }
        CVPixelBufferLockBaseAddress(out, [])
        let ctx = CGContext(data: CVPixelBufferGetBaseAddress(out), width: W, height: H, bitsPerComponent: 8,
                            bytesPerRow: CVPixelBufferGetBytesPerRow(out), space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        ctx?.draw(cg, in: CGRect(x: 0, y: H - cg.height, width: cg.width, height: cg.height))  // an odd last row or column is dropped
        CVPixelBufferUnlockBaseAddress(out, [])
        guard ctx != nil, adaptor.append(out, withPresentationTime: t) else { throw writer.error ?? fail("Can't write the video.") }
    }

    do {
        // one thread feeds both inputs; the sound stays at most a second ahead so the movie interleaves
        var videoDone = false, audioDone = audio == nil, shown = -1
        while !videoDone || !audioDone {
            var moved = false
            if !videoDone, video.isReadyForMoreMediaData {
                try append(next.1, at: next.0)
                let f = min(1, next.0.seconds / duration)
                if Int(f * 100) != shown { shown = Int(f * 100); progress(f) }
                if let n = try nextFrame() { next = n } else { video.markAsFinished(); videoDone = true }
                moved = true
            }
            if !audioDone, let audio, let sound {
                while audio.isReadyForMoreMediaData {
                    guard let b = sound.copyNextSampleBuffer() else { audio.markAsFinished(); audioDone = true; break }
                    guard audio.append(b) else { throw writer.error ?? fail("Can't write the sound.") }
                    moved = true
                    if !videoDone, CMSampleBufferGetPresentationTimeStamp(b).seconds > next.0.seconds + 1 { break }
                }
            }
            if !moved { Thread.sleep(forTimeInterval: 0.005) }
        }
        if audioReader?.status == .failed { throw audioReader?.error ?? fail("Can't read the sound.") }
    } catch {
        writer.cancelWriting()
        try? FileManager.default.removeItem(at: dst)
        throw error
    }
    let done = DispatchSemaphore(value: 0)
    writer.finishWriting { done.signal() }
    done.wait()
    guard writer.status == .completed else { throw writer.error ?? fail("Can't write the video.") }
    progress(1)
}
