// The video timeline under the canvas: play the cut, scrub, trim clips by their edges, split at the playhead, reorder and
// delete clips, hide the picture or mute the clip's own sound, record or add voice-overs, and export a frame as a photo.
// Playback shows the cut as shot; whenever it stops, the canvas shows the edited frame at the playhead, so every photo
// tool works on the frame you're looking at (and export applies the look to every frame).
import AVFoundation
import AVKit
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Plays the cut with its sound and voice-overs.
@MainActor @Observable
final class Playback {
    let player = AVPlayer()
    var playing = false
    var playhead = 0.0  // timeline seconds
    @ObservationIgnored private var observer: Any?

    func play(_ p: Photo, from t: Double, muted: Bool = false) {
        pause()
        guard let made = try? editComposition(p) else { return }
        let item = AVPlayerItem(asset: made.0)
        item.audioMix = made.1
        player.replaceCurrentItem(with: item)
        player.isMuted = muted
        let end = made.0.duration.seconds, from = t >= end - 0.05 ? 0 : t  // from the end, play from the start
        playhead = from
        player.seek(to: cmTime(from), toleranceBefore: .zero, toleranceAfter: .zero)
        observer = player.addPeriodicTimeObserver(forInterval: cmTime(1.0 / 30), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.playing else { return }
                self.playhead = min(time.seconds, end)
                if time.seconds >= end - 0.02 { self.pause() }
            }
        }
        player.play()
        playing = true
    }

    func pause() {
        player.pause()
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
        playing = false
    }
}

/// The canvas with the timeline under it, for a video.
struct VideoWorkspace<Content: View>: View {
    let photo: Photo
    let content: Content
    @Environment(Library.self) private var library
    @State private var playback = Playback()
    @State private var duration = 0.0  // of the source clip
    @State private var thumbs: [CGImage] = []
    @State private var selection: Layer?
    @State private var draft: Timeline?  // while dragging; saved when the drag ends
    @State private var undo: [Timeline] = []
    @State private var redo: [Timeline] = []
    @State private var recorder: AVAudioRecorder?
    @State private var recordStart = 0.0
    @State private var message: String?
    @State private var drag: Drag?
    @State private var dragBase: Timeline?
    @State private var dragScale: CGFloat = 1
    @State private var shownSource: Double?  // the frame a trim lands on, shown when the drag ends

    enum Layer: Hashable { case clip(UUID), sound, voice(UUID) }
    private enum Drag { case scrub, trimStart(Int, Clip), trimEnd(Int, Clip), voice(Int, VoiceOver) }

    init(photo: Photo, @ViewBuilder content: () -> Content) {
        self.photo = photo
        self.content = content()
    }

    private var tl: Timeline { draft ?? photo.timeline ?? .whole(duration) }
    private let rulerH: CGFloat = 18, videoH: CGFloat = 46, rowH: CGFloat = 24, gap: CGFloat = 4, gutter: CGFloat = 150
    private var soundY: CGFloat { rulerH + videoH + gap }
    private func voiceY(_ k: Int) -> CGFloat { soundY + (rowH + gap) * CGFloat(k + 1) }
    private var stripHeight: CGFloat { voiceY(tl.voices.count) + 2 }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                content.opacity(playback.playing ? 0 : 1)
                if playback.playing {
                    VideoPlayer(player: playback.player).overlay { if tl.videoHidden { Color.black } }
                }
            }
            .overlay(alignment: .bottomLeading) {
                if tl.videoHidden {
                    Label("Video hidden: exports black, the sound plays on", systemImage: "eye.slash").font(.caption)
                        .padding(6).background(.black.opacity(0.6), in: .rect(cornerRadius: 6)).foregroundStyle(.white).padding(12)
                }
            }
            Divider()
            toolbar
            strip.padding(.horizontal, 12).padding(.bottom, 8)
        }
        .task(id: photo.id) {
            let u = photo.url
            let (d, th) = await Task.detached { () -> (Double, [CGImage]) in let d = videoDuration(u); return (d, videoThumbnails(u, d, 40)) }.value
            (duration, thumbs) = (d, th)
            playback.playhead = (photo.timeline ?? .whole(d)).position(ofSource: photo.time ?? 0) ?? 0
        }
        .onChange(of: playback.playing) { _, playing in if !playing { showFrame(at: playback.playhead) } }
        .onDisappear { playback.pause(); recorder?.stop() }
        .alert("FlashEdit", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {} message: { Text(message ?? "") }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 12) {
            Button { playback.playing ? playback.pause() : playback.play(photo, from: playback.playhead) } label: {
                Label(playback.playing ? "Pause" : "Play", systemImage: playback.playing ? "pause.fill" : "play.fill")
            }
            .help(playback.playing ? "Pause" : "Play the cut. The look shows when you pause, and in the export.")
            .disabled(recorder != nil)
            Text("\(timecode(playback.playhead, tenths: true)) / \(timecode(tl.duration, tenths: true))")
                .monospacedDigit().foregroundStyle(.secondary).frame(minWidth: 96, alignment: .leading)
            Divider().frame(height: 16)
            Button { split() } label: { Label("Split", systemImage: "scissors") }
                .keyboardShortcut("k").help("Split the clip at the playhead (⌘K)")
            Button { move(-1) } label: { Label("Move Earlier", systemImage: "chevron.left") }
                .disabled((selectedClip ?? 0) == 0).help("Move the selected clip earlier")
            Button { move(1) } label: { Label("Move Later", systemImage: "chevron.right") }
                .disabled(selectedClip.map { $0 + 1 >= tl.clips.count } ?? true).help("Move the selected clip later")
            Button { deleteSelected() } label: { Label("Delete", systemImage: "trash") }
                .disabled(!canDelete).help("Delete the selected clip or voice-over")
            Divider().frame(height: 16)
            Button { addAudioFile() } label: { Label("Add Audio", systemImage: "music.note") }
                .help("Add a sound or music file at the playhead")
            Button { toggleRecording() } label: {
                Label(recorder == nil ? "Record Voice" : "Stop Recording", systemImage: recorder == nil ? "mic" : "stop.circle.fill")
            }
            .foregroundStyle(recorder == nil ? Color.primary : Color.red)
            .help(recorder == nil ? "Record a voice-over from the playhead while the video plays (muted)" : "Stop recording")
            if let volume = volumeBinding {
                Image(systemName: "speaker.wave.2").foregroundStyle(.secondary)
                Slider(value: volume, in: 0...2, onEditingChanged: { if !$0, let d = draft { commit(d) } }).frame(width: 100)
                    .help("Volume of the selected sound")
            }
            Spacer()
            Button { exportFrame() } label: { Label("Export Frame…", systemImage: "photo").labelStyle(.titleAndIcon) }
                .help("Save the frame at the playhead as a photo, with the edit, at full resolution")
            Button { stepUndo() } label: { Label("Undo Timeline", systemImage: "arrow.uturn.backward") }
                .disabled(undo.isEmpty).help("Undo the last timeline change")
            Button { stepRedo() } label: { Label("Redo Timeline", systemImage: "arrow.uturn.forward") }
                .disabled(redo.isEmpty).help("Redo")
            Button { change { $0.clips = Timeline.whole(duration).clips } } label: { Label("Restore Clip", systemImage: "arrow.counterclockwise") }
                .help("Undo every cut and trim (keeps the sound settings and voice-overs)")
        }
        .labelStyle(.iconOnly).buttonStyle(.borderless)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .disabled(duration == 0)
    }

    private var selectedClip: Int? {
        if case .clip(let id) = selection { return tl.clips.firstIndex { $0.id == id } }
        return nil
    }

    private var canDelete: Bool {
        switch selection {
        case .clip: return selectedClip != nil && tl.clips.count > 1
        case .voice(let id): return tl.voices.contains { $0.id == id }
        default: return false
        }
    }

    private var volumeBinding: Binding<Double>? {
        switch selection {
        case .sound: return Binding(get: { tl.volume }, set: { v in var t = tl; t.volume = v; draft = t })
        case .voice(let id):
            guard tl.voices.contains(where: { $0.id == id }) else { return nil }
            return Binding(get: { tl.voices.first { $0.id == id }?.volume ?? 1 }, set: { v in
                var t = tl
                if let i = t.voices.firstIndex(where: { $0.id == id }) { t.voices[i].volume = v }
                draft = t
            })
        default: return nil
        }
    }

    // MARK: Edits (each one an undo step)

    private func commit(_ t: Timeline) {
        draft = nil
        let old = photo.timeline ?? .whole(duration)
        guard t != old else { return }
        undo.append(old)
        redo.removeAll()
        library.update(photo.id) { $0.timeline = t }
    }

    private func change(_ f: (inout Timeline) -> Void) { var t = tl; f(&t); commit(t) }

    private func stepUndo() {
        guard let t = undo.popLast() else { return }
        redo.append(photo.timeline ?? .whole(duration))
        library.update(photo.id) { $0.timeline = t }
        playback.playhead = min(playback.playhead, t.duration)
    }

    private func stepRedo() {
        guard let t = redo.popLast() else { return }
        undo.append(photo.timeline ?? .whole(duration))
        library.update(photo.id) { $0.timeline = t }
        playback.playhead = min(playback.playhead, t.duration)
    }

    private func split() {
        var t = tl
        if t.split(at: playback.playhead) { commit(t) }
    }

    private func move(_ d: Int) {
        guard let i = selectedClip, tl.clips.indices.contains(i + d) else { return }
        change { $0.clips.swapAt(i, i + d) }
    }

    private func deleteSelected() {
        var t = tl
        switch selection {
        case .clip(let id):
            guard t.clips.count > 1 else { return }
            t.clips.removeAll { $0.id == id }
        case .voice(let id): t.voices.removeAll { $0.id == id }
        default: return
        }
        selection = nil
        commit(t)
        playback.playhead = min(playback.playhead, t.duration)
        showFrame(at: playback.playhead)
    }

    /// Shows the edited frame under timeline second `t` on the canvas.
    private func showFrame(at t: Double) {
        guard let s = tl.locate(t)?.source, s != photo.time else { return }
        library.update(photo.id) { $0.time = s }
    }

    // MARK: Sound

    private func addAudioFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio]
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let u = panel.url else { return }
        addAudio(u, at: playback.playhead, name: u.deletingPathExtension().lastPathComponent)
    }

    private func addAudio(_ url: URL, at: Double, name: String) {
        let d = AVURLAsset(url: url).duration.seconds
        guard d.isFinite, d > 0.05 else { message = "\(url.lastPathComponent) has no sound."; return }
        let voice = VoiceOver(path: url.path, name: name, at: at, duration: d)
        change { $0.voices.append(voice) }
        selection = .voice(voice.id)
    }

    private func toggleRecording() {
        if let r = recorder {
            r.stop()
            recorder = nil
            playback.pause()
            addAudio(r.url, at: recordStart, name: "Voice \(tl.voices.count + 1)")
            return
        }
        AVCaptureDevice.requestAccess(for: .audio) { ok in
            Task { @MainActor in
                if ok { startRecording() } else {
                    message = "FlashEdit can't use the microphone. Allow it in System Settings → Privacy & Security → Microphone."
                }
            }
        }
    }

    private func startRecording() {
        let dir = appFolder.appending(path: "Voice")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        do {
            let r = try AVAudioRecorder(url: dir.appending(path: "\(UUID().uuidString).m4a"),
                                        settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1])
            guard r.record() else { message = "Recording didn't start."; return }
            playback.play(photo, from: playback.playhead, muted: true)  // narrate over the picture; muted so the mic doesn't hear it
            (recorder, recordStart) = (r, playback.playhead)
        } catch { message = error.localizedDescription }
    }

    // MARK: Export a frame

    private func exportFrame() {
        playback.pause()
        let src = tl.locate(playback.playhead)?.source ?? photo.time ?? 0, p = photo
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.jpeg, .heic, .png, .tiff]
        panel.nameFieldStringValue = p.url.deletingPathExtension().lastPathComponent + "_"
            + timecode(src, tenths: true).replacingOccurrences(of: ":", with: "-") + ".jpg"
        guard panel.runModal() == .OK, let dst = panel.url else { return }
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    let cg = try render(p.url, bg: p.params(for: .background), fg: p.params(for: .person), whole: p.params, at: src).0
                    try save(cg, to: dst)
                }.value
                NSWorkspace.shared.activateFileViewerSelecting([dst])
            } catch { message = error.localizedDescription }
        }
    }

    // MARK: The strip

    private var strip: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(spacing: gap) {
                layerRow("Video", icon: "film", height: videoH, on: !tl.videoHidden, onIcon: "eye", offIcon: "eye.slash",
                         help: tl.videoHidden ? "Show the video" : "Hide the video (black picture, the sound plays on)") { $0.videoHidden.toggle() }
                layerRow("Sound", icon: "waveform", height: rowH, select: .sound, on: !tl.soundMuted, onIcon: "speaker.wave.2",
                         offIcon: "speaker.slash", help: tl.soundMuted ? "Unmute the clip's sound" : "Mute the clip's sound") { $0.soundMuted.toggle() }
                ForEach(tl.voices) { v in
                    layerRow(v.name, icon: "mic", height: rowH, select: .voice(v.id), on: !v.muted, onIcon: "speaker.wave.2",
                             offIcon: "speaker.slash", help: v.muted ? "Unmute" : "Mute") { t in
                        if let i = t.voices.firstIndex(where: { $0.id == v.id }) { t.voices[i].muted.toggle() }
                    }
                }
            }
            .padding(.top, rulerH)
            .frame(width: gutter)
            GeometryReader { geo in
                Canvas { ctx, size in draw(&ctx, size) }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { dragChanged($0, geo.size.width) }
                        .onEnded { _ in dragEnded() })
            }
        }
        .frame(height: stripHeight)
    }

    private func layerRow(_ name: String, icon: String, height: CGFloat, select: Layer? = nil, on: Bool, onIcon: String, offIcon: String,
                          help: String, toggle: @escaping (inout Timeline) -> Void) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(.secondary).frame(width: 16)
            Text(name).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 2)
            Button { change(toggle) } label: { Image(systemName: on ? onIcon : offIcon) }
                .buttonStyle(.borderless).foregroundStyle(on ? Color.primary : Color.red).help(help)
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .frame(height: height)
        .background(select != nil && select == selection ? Color.accentColor.opacity(0.25) : Color.clear, in: .rect(cornerRadius: 4))
        .contentShape(Rectangle())
        .onTapGesture { if let select { selection = select } }
    }

    private func scale(_ width: CGFloat) -> CGFloat { drag != nil ? dragScale : width / CGFloat(max(tl.duration, 0.1)) }

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let t = tl, k = scale(size.width)
        // ruler
        let step = [0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60, 120, 300, 600].first { $0 * Double(k) >= 60 } ?? 600
        var s = 0.0
        while s <= t.duration + 1e-6 {
            let x = CGFloat(s) * k
            ctx.fill(Path(CGRect(x: x, y: rulerH - 6, width: 1, height: 6)), with: .color(.secondary))
            ctx.draw(Text(timecode(s, tenths: step < 1)).font(.system(size: 9)).foregroundStyle(.secondary), at: CGPoint(x: x + 3, y: 1),
                     anchor: .topLeading)
            s += step
        }
        // clips, with the clip's sound under them
        let tw = thumbs.first.map { videoH * CGFloat($0.width) / CGFloat(max($0.height, 1)) } ?? videoH
        var x0: CGFloat = 0
        for c in t.clips {
            let w = CGFloat(c.length) * k, r = CGRect(x: x0 + 1, y: rulerH, width: max(w - 2, 1), height: videoH)
            let shape = Path(roundedRect: r, cornerRadius: 4)
            ctx.drawLayer { l in
                l.clip(to: shape)
                l.fill(shape, with: .color(.gray.opacity(0.3)))
                if !thumbs.isEmpty, duration > 0 {
                    var tx = r.minX
                    while tx < r.maxX {
                        let src = c.start + Double((tx - r.minX + tw / 2) / max(r.width, 1)) * c.length
                        let i = min(thumbs.count - 1, max(0, Int(src / duration * Double(thumbs.count))))
                        l.draw(Image(decorative: thumbs[i], scale: 1), in: CGRect(x: tx, y: r.minY, width: tw, height: videoH))
                        tx += tw
                    }
                }
                if t.videoHidden { l.fill(shape, with: .color(.black.opacity(0.65))) }
            }
            let selected = selection == .clip(c.id)
            ctx.stroke(shape, with: .color(selected ? Color.yellow : Color.white.opacity(0.35)), lineWidth: selected ? 2 : 1)
            if selected {
                for ex in [r.minX + 3, r.maxX - 6] {
                    ctx.fill(Path(roundedRect: CGRect(x: ex, y: r.minY + 12, width: 3, height: videoH - 24), cornerRadius: 1.5), with: .color(.yellow))
                }
            }
            let sr = CGRect(x: x0 + 1, y: soundY, width: max(w - 2, 1), height: rowH)
            ctx.fill(Path(roundedRect: sr, cornerRadius: 3), with: .color(t.soundMuted ? Color.gray.opacity(0.25) : Color.green.opacity(0.45)))
            x0 += w
        }
        // voice-overs
        for (i, v) in t.voices.enumerated() {
            let r = CGRect(x: CGFloat(v.at) * k, y: voiceY(i), width: max(CGFloat(v.duration) * k, 2), height: rowH)
            let shape = Path(roundedRect: r, cornerRadius: 3)
            ctx.fill(shape, with: .color(v.muted ? Color.gray.opacity(0.25) : Color.purple.opacity(0.55)))
            if selection == .voice(v.id) { ctx.stroke(shape, with: .color(.yellow), lineWidth: 2) }
            ctx.drawLayer { l in
                l.clip(to: shape)
                l.draw(Text(v.name).font(.system(size: 10)).foregroundStyle(.white), at: CGPoint(x: r.minX + 5, y: r.midY), anchor: .leading)
            }
        }
        if recorder != nil {  // the take so far
            let r = CGRect(x: CGFloat(recordStart) * k, y: voiceY(t.voices.count) - rowH - gap, width: max(CGFloat(playback.playhead - recordStart) * k, 2), height: 4)
            ctx.fill(Path(r), with: .color(.red))
        }
        // playhead
        let px = CGFloat(playback.playhead) * k
        ctx.fill(Path(CGRect(x: px - 0.75, y: 0, width: 1.5, height: size.height)), with: .color(.red))
        var tri = Path()
        tri.move(to: CGPoint(x: px - 5, y: 0)); tri.addLine(to: CGPoint(x: px + 5, y: 0)); tri.addLine(to: CGPoint(x: px, y: 7)); tri.closeSubpath()
        ctx.fill(tri, with: .color(.red))
    }

    // MARK: Dragging: scrub, trim a clip's edge, or slide a voice-over

    private func dragChanged(_ v: DragGesture.Value, _ width: CGFloat) {
        guard duration > 0, recorder == nil else { return }
        if drag == nil { begin(v.startLocation, width) }
        guard let drag, let base = dragBase else { return }
        let dt = Double(v.translation.width / dragScale)
        var t = base
        switch drag {
        case .scrub:
            playback.playhead = min(max(Double(v.location.x / dragScale), 0), base.duration)
            return
        case .trimStart(let i, let c):
            t.clips[i].start = min(max(c.start + dt, 0), c.end - 0.1)
            shownSource = t.clips[i].start
        case .trimEnd(let i, let c):
            t.clips[i].end = max(min(c.end + dt, duration), c.start + 0.1)
            shownSource = max(c.start, t.clips[i].end - 0.04)
        case .voice(let i, let vo):
            t.voices[i].at = max(0, vo.at + dt)
        }
        draft = t
    }

    private func begin(_ p: CGPoint, _ width: CGFloat) {
        playback.pause()
        let base = tl, k = width / CGFloat(max(base.duration, 0.1))
        dragBase = base
        dragScale = k
        drag = .scrub
        if p.y >= rulerH && p.y < rulerH + videoH {
            var x0: CGFloat = 0
            for (i, c) in base.clips.enumerated() {
                let x1 = x0 + CGFloat(c.length) * k
                if p.x <= x1 && x1 - p.x < 7 { drag = .trimEnd(i, c); selection = .clip(c.id); return }
                if p.x >= x0 && p.x - x0 < 7 { drag = .trimStart(i, c); selection = .clip(c.id); return }
                if p.x > x0 && p.x < x1 { selection = .clip(c.id) }
                x0 = x1
            }
        } else if p.y >= soundY && p.y < soundY + rowH {
            selection = .sound
        } else {
            for (i, v) in base.voices.enumerated() where p.y >= voiceY(i) && p.y < voiceY(i) + rowH {
                if p.x >= CGFloat(v.at) * k && p.x <= CGFloat(v.at + v.duration) * k {
                    selection = .voice(v.id)
                    drag = .voice(i, v)
                    return
                }
            }
        }
        playback.playhead = min(max(Double(p.x / k), 0), base.duration)
    }

    private func dragEnded() {
        let ended = drag
        drag = nil
        dragBase = nil
        guard let ended else { return }
        if case .scrub = ended { showFrame(at: playback.playhead); return }
        if let d = draft { commit(d) }
        if let s = shownSource {
            library.update(photo.id) { $0.time = s }
            if let pos = tl.position(ofSource: s) { playback.playhead = pos }
        }
        shownSource = nil
    }
}
