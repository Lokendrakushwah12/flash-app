// Video: a clip is edited like a photo. The canvas shows one frame (you pick which), and export runs every frame through
// the same pipeline, with Vision finding the person again in each one. The sound is copied as it is.
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

func timecode(_ t: Double) -> String { let s = Int(max(t, 0)); return String(format: "%d:%02d", s / 60, s % 60) }

/// "1920 × 1080 · 30 fps · 0:12"
func videoInfo(_ url: URL) -> String {
    guard let t = videoTrack(url), let size = videoSize(url) else { return "" }
    var parts = ["\(Int(size.width)) × \(Int(size.height))"]
    if t.nominalFrameRate > 0 { parts.append("\(Int(t.nominalFrameRate.rounded())) fps") }
    parts.append(timecode(videoDuration(url)))
    return parts.joined(separator: " · ")
}

/// Renders every frame of the clip with its edit into a QuickTime movie (H.264 or HEVC) at `dst`, with the original sound.
/// `longEdge` (0 = full size) shrinks frames before editing, which also makes long clips much quicker.
/// `metadata` keeps the date and location. `progress` gets 0...1.
func exportVideo(_ p: Photo, to dst: URL, longEdge: Int, hevc: Bool, metadata: Bool, progress: (Double) -> Void) throws {
    let fail = { (m: String) in NSError(domain: "FlashEdit", code: 3, userInfo: [NSLocalizedDescriptionKey: m]) }
    let asset = AVURLAsset(url: p.url)
    guard let track = asset.tracks(withMediaType: .video).first else { throw fail("The file has no video track.") }
    let duration = max(asset.duration.seconds, 0.001)
    let (bg, fg, whole) = (p.params(for: .background), p.params(for: .person), p.params)

    let reader = try AVAssetReader(asset: asset)
    let frames = AVAssetReaderVideoCompositionOutput(videoTracks: [track],
        videoSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    frames.videoComposition = AVMutableVideoComposition(propertiesOf: asset)  // upright, like the preview
    reader.add(frames)
    guard reader.startReading() else { throw reader.error ?? fail("Can't read the video.") }
    // the sound has its own reader, so the slow video frames never hold it up
    let audioTrack = asset.tracks(withMediaType: .audio).first
    let sound = audioTrack.map { AVAssetReaderTrackOutput(track: $0, outputSettings: nil) }
    let audioReader = try sound.map { s -> AVAssetReader in let r = try AVAssetReader(asset: asset); r.add(s); _ = r.startReading(); return r }

    let ci = CIContext()
    func nextFrame() throws -> (CMTime, CGImage)? {
        while let buf = frames.copyNextSampleBuffer() {
            guard let pb = CMSampleBufferGetImageBuffer(buf) else { continue }
            let img = CIImage(cvPixelBuffer: pb)
            guard let full = ci.createCGImage(img, from: img.extent) else { continue }
            let cg = resized(full, longEdge: longEdge)
            let (M, faces) = try analyze(cg)
            return (CMSampleBufferGetPresentationTimeStamp(buf), cgImage(geometry(edit(rgb(cg), M, faces, bg: bg, fg: fg), whole)))
        }
        if reader.status == .failed { throw reader.error ?? fail("Can't read the video.") }
        return nil
    }
    guard var next = try nextFrame() else { throw fail("The video has no frames.") }

    // the first edited frame sets the size (crop and rotation change it); encoders want even sizes
    let (W, H) = (next.1.width & ~1, next.1.height & ~1)
    let fps = Double(track.nominalFrameRate > 0 ? track.nominalFrameRate : 30)
    try? FileManager.default.removeItem(at: dst)
    let writer = try AVAssetWriter(outputURL: dst, fileType: .mov)
    if metadata {  // date taken and location (QuickTime keys; an MP4's iTunes tags don't carry over)
        let keep: [AVMetadataKeySpace] = [.quickTimeMetadata, .quickTimeUserData, .common]
        writer.metadata = asset.metadata.filter { $0.keySpace.map(keep.contains) == true }
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
    var audio = audioTrack.map { t in
        AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: t.formatDescriptions.first.map { $0 as! CMFormatDescription })
    }
    if let a = audio, !writer.canAdd(a) { audio = nil }  // a sound format QuickTime can't hold: export without it
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
