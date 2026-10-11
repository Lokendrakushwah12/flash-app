// The catalog (every photo keeps its own edit and chat, saved to Application Support like a Lightroom catalog),
// the live preview, and the chat bridge to the local Claude Code CLI.
import AppKit
import Foundation
import Observation
import UniformTypeIdentifiers

struct Msg: Codable, Identifiable, Equatable { var id = UUID(); var user: Bool; var text: String }

enum Region: String, CaseIterable { case whole = "Whole", background = "Background", person = "Person" }

/// Everything that defines how a photo looks. Saved versions are snapshots of it.
struct EditState: Codable, Equatable { var preset: Int, params: Params, bg: Params?, fg: Params? }

struct Version: Codable, Identifiable, Equatable { var id = UUID(); var name: String; var date = Date(); var state: EditState }

struct UserPreset: Codable, Identifiable, Equatable { var id: Int; var name: String; var state: EditState }

/// The app's folder in Application Support (catalog and presets live here).
let appFolder: URL = {
    let dir = URL.applicationSupportDirectory.appending(path: "FlashEdit")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}()

/// Reads a JSON file; one that exists but can't be read is moved aside, never overwritten.
func loadJSON<T: Decodable>(_ type: T.Type, _ file: URL) -> T? {
    guard let data = try? Data(contentsOf: file) else { return nil }
    do { return try JSONDecoder().decode(type, from: data) } catch {
        try? FileManager.default.moveItem(at: file, to: file.deletingPathExtension()
            .appendingPathExtension("unreadable-\(Int(Date().timeIntervalSince1970)).json"))
        return nil
    }
}

/// Presets: None and 1-4 are built in; yours are saved by name and work on every photo (presets.json).
@Observable final class Presets {
    static let shared = Presets()
    private static let file = appFolder.appending(path: "presets.json")
    var user: [UserPreset] { didSet { try? JSONEncoder().encode(user).write(to: Self.file, options: .atomic) } }

    private init() { user = loadJSON([UserPreset].self, Self.file) ?? [] }

    var ids: [Int] { Array(0...4) + user.map(\.id) }
    func name(_ k: Int) -> String { k == 0 ? "None" : (1...4).contains(k) ? "Preset \(k)" : user.first { $0.id == k }?.name ?? "Deleted preset" }

    func state(_ k: Int) -> EditState {
        if let u = user.first(where: { $0.id == k }) { return u.state }
        let b = (0...4).contains(k) ? k : 0  // a deleted preset falls back to None
        return EditState(preset: b, params: .preset(b), bg: nil, fg: nil)
    }

    func params(_ k: Int, for r: Region) -> Params {
        let s = state(k)
        return r == .background ? s.bg ?? s.params : r == .person ? s.fg ?? s.params : s.params
    }

    /// Saves a look under `name` (required); a preset with the same name is replaced. Returns its id.
    func save(_ name: String, _ s: EditState) -> Int {
        var st = s
        if let i = user.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            st.preset = user[i].id
            user[i].state = st
            return user[i].id
        }
        let id = max(Int(Date().timeIntervalSince1970), (user.map(\.id).max() ?? 0) + 1)  // never reuses a deleted id
        st.preset = id
        user.append(UserPreset(id: id, name: name, state: st))
        return id
    }
}

struct Photo: Codable, Identifiable, Equatable {
    var id = UUID()
    var path: String  // the original is never modified; the edit lives here
    var preset = 0  // 0 = None, 1-4 = learned looks, larger = one of your saved presets
    var params = Params.preset(0)
    var bg: Params?  // Isolate edits; nil = the region follows the whole-photo edit
    var fg: Params?
    var chat: [Msg] = []
    var versions: [Version] = []
    var draft: EditState?  // the unsaved edit, set aside while you look at a saved version
    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.lastPathComponent }
    var presetName: String { Presets.shared.name(preset) }
    var isEdited: Bool { state != Presets.shared.state(preset) }
    var look: [Params] { [params(for: .background), params(for: .person)] }  // what the render depends on

    var state: EditState {
        get { EditState(preset: preset, params: params, bg: bg, fg: fg) }
        set { (preset, params, bg, fg) = (newValue.preset, newValue.params, newValue.bg, newValue.fg) }
    }
    var currentVersion: Version? { versions.first { $0.state == state } }

    mutating func saveVersion() {
        let n = versions.compactMap { Int($0.name.dropFirst("Version ".count)) }.max() ?? 0
        versions.append(Version(name: "Version \(n + 1)", state: state))
        draft = nil
    }

    /// Switches to a saved version (or the draft). Unsaved changes are kept as the draft, never dropped.
    mutating func open(_ s: EditState) {
        if currentVersion == nil { draft = state }
        state = s
    }

    func params(for r: Region) -> Params { r == .background ? bg ?? params : r == .person ? fg ?? params : params }

    /// Edits one region. Whole-photo changes are carried into isolated regions too, so they stay in step.
    mutating func change(_ r: Region, _ f: (inout Params) -> Void) {
        var p = params(for: r)
        f(&p)
        switch r {
        case .background: bg = p
        case .person: fg = p
        case .whole: (bg, fg) = (bg?.carrying(from: params, to: p), fg?.carrying(from: params, to: p)); params = p
        }
    }

    /// A preset on Whole starts over; on a region it gives just that region the preset's look for it.
    mutating func setPreset(_ k: Int, _ r: Region) {
        switch r {
        case .whole: state = Presets.shared.state(k)
        case .background: bg = Presets.shared.params(k, for: .background)
        case .person: fg = Presets.shared.params(k, for: .person)
        }
    }
}

extension Photo {
    // Fields added later (bg, fg, chat, versions, draft) may be missing from older catalogs.
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        path = try c.decode(String.self, forKey: .path)
        preset = try c.decode(Int.self, forKey: .preset)
        params = try c.decode(Params.self, forKey: .params)
        bg = try c.decodeIfPresent(Params.self, forKey: .bg)
        fg = try c.decodeIfPresent(Params.self, forKey: .fg)
        chat = try c.decodeIfPresent([Msg].self, forKey: .chat) ?? []
        versions = try c.decodeIfPresent([Version].self, forKey: .versions) ?? []
        draft = try c.decodeIfPresent(EditState.self, forKey: .draft)
    }
}

/// Dropped items: files from Finder keep their place on disk; photos dragged from Photos, Safari and other apps arrive
/// as file promises (HEIC, JPEG, ...) whose temporary file is copied into Application Support/FlashEdit/Imported.
func droppedFiles(_ providers: [NSItemProvider]) async -> [URL] {
    var out: [URL] = []
    for p in providers {
        if p.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            let u = await withCheckedContinuation { (c: CheckedContinuation<URL?, Never>) in
                _ = p.loadObject(ofClass: URL.self) { url, _ in c.resume(returning: url) }
            }
            if let u { out.append(u) }
        } else if let type = p.registeredContentTypes.first(where: { $0.conforms(to: .image) }) {
            let u = await withCheckedContinuation { (c: CheckedContinuation<URL?, Never>) in
                _ = p.loadFileRepresentation(for: type, openInPlace: false) { url, _, _ in
                    c.resume(returning: url.flatMap { src in
                        let dir = appFolder.appending(path: "Imported")
                        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        let ext = src.pathExtension.isEmpty ? (type.preferredFilenameExtension ?? "heic") : src.pathExtension
                        let dst = dir.appending(path: "\(src.deletingPathExtension().lastPathComponent)-\(UUID().uuidString.prefix(6)).\(ext)")
                        return (try? FileManager.default.copyItem(at: src, to: dst)) != nil ? dst : nil
                    })
                }
            }
            if let u { out.append(u) }
        }
    }
    return out
}

@MainActor @Observable
final class Library {
    var photos: [Photo] = [] { didSet { save() } }

    private static let file = appFolder.appending(path: "library.json")

    init() { photos = loadJSON([Photo].self, Self.file) ?? [] }

    // ponytail: rewrites the whole catalog on every change; a few KB per photo, move to SQLite past thousands of photos
    private func save() { try? JSONEncoder().encode(photos).write(to: Self.file, options: .atomic) }

    /// Adds image files (folders are expanded one level). Returns the ids of the new photos.
    func add(_ urls: [URL]) -> [UUID] {
        let files = urls.flatMap { (try? FileManager.default.contentsOfDirectory(at: $0, includingPropertiesForKeys: nil)) ?? [$0] }
        let known = Set(photos.map(\.path))
        let new = files.filter { !known.contains($0.path) && UTType(filenameExtension: $0.pathExtension)?.conforms(to: .image) == true }
            .sorted { $0.path < $1.path }.map { Photo(path: $0.path) }
        photos += new
        return new.map(\.id)
    }

    // Undo/redo per photo, for this session. A burst of changes less than 0.6 s apart (one slider drag) is one step.
    private(set) var undoStack: [UUID: [EditState]] = [:]
    private(set) var redoStack: [UUID: [EditState]] = [:]
    @ObservationIgnored private var lastEdit: (id: UUID, at: Date)?

    func update(_ id: UUID, _ change: (inout Photo) -> Void) {
        guard let i = photos.firstIndex(where: { $0.id == id }) else { return }
        let before = photos[i].state
        change(&photos[i])
        guard photos[i].state != before else { return }
        if lastEdit?.id != id || Date().timeIntervalSince(lastEdit!.at) > 0.6 {
            undoStack[id, default: []].append(before)
            if undoStack[id]!.count > 200 { undoStack[id]!.removeFirst() }
        }
        redoStack[id] = nil
        lastEdit = (id, Date())
    }

    func undo(_ id: UUID) { step(id, &undoStack, &redoStack) }
    func redo(_ id: UUID) { step(id, &redoStack, &undoStack) }

    private func step(_ id: UUID, _ from: inout [UUID: [EditState]], _ to: inout [UUID: [EditState]]) {
        guard let i = photos.firstIndex(where: { $0.id == id }), let s = from[id]?.popLast() else { return }
        to[id, default: []].append(photos[i].state)
        photos[i].state = s
        lastEdit = nil
    }
}

/// Before/after preview at screen size. Edits are scale-aware (s = min(H,W)/720), so the preview looks like the export.
@MainActor @Observable
final class Preview {
    var before: CGImage?
    var after: CGImage?
    var error: String?
    var busy = false

    var original = CGSize(width: 1, height: 1)  // full-resolution size of the shown photo, for the zoom %
    @ObservationIgnored var previewWidth: CGFloat = 1
    /// Set while zoomed past the preview's pixels: renders again at up to 4096 px once edits settle.
    @ObservationIgnored var wantDetail = false { didSet { if wantDetail, !oldValue, let last { show(last) } } }

    private struct Source { let image: CGImage, rgb: RGB, mask: [Float], faces: [Face], original: CGSize }
    @ObservationIgnored private var sources: [UUID: Source] = [:]
    @ObservationIgnored private var detail: (id: UUID, src: Source)?  // one photo only: ~250 MB at 4096 px
    @ObservationIgnored private var pending: Photo?
    @ObservationIgnored private var last: Photo?
    @ObservationIgnored private var running = false

    /// Latest request wins: slider drags queue at most one render behind the one in flight.
    func show(_ photo: Photo?) {
        last = photo
        guard let photo else { before = nil; after = nil; return }
        pending = photo
        guard !running else { return }
        running = true; busy = true
        Task {
            while let p = pending {
                pending = nil
                await render(p, detail: false)
                guard wantDetail, pending == nil, max(original.width, original.height) > previewWidth + 1 else { continue }
                try? await Task.sleep(for: .milliseconds(300))
                // ponytail: a detail render can't be cancelled, so an edit made during it waits ~1-2 s
                if pending == nil { await render(p, detail: true) }
            }
            running = false; busy = false
        }
    }

    private func render(_ p: Photo, detail full: Bool) async {
        let cached = full ? (detail?.id == p.id ? detail?.src : nil) : sources[p.id]
        let r = await Task.detached(priority: .userInitiated) { () -> Result<(Source, CGImage), Error> in
            Result {
                let src = try cached ?? Self.load(p, maxSide: full ? 4096 : 1400)
                return (src, cgImage(edit(src.rgb, src.mask, src.faces, bg: p.params(for: .background), fg: p.params(for: .person))))
            }
        }.value
        switch r {
        case .success(let (src, img)):
            if full { detail = (p.id, src) } else {
                if sources.count > 8 { sources.removeAll() }  // ponytail: ~30 MB per cached photo, LRU if it matters
                sources[p.id] = src
                previewWidth = CGFloat(src.image.width)
            }
            if (pending?.id ?? p.id) == p.id { before = src.image; after = img; original = src.original; error = nil }
        case .failure(let e):
            before = nil; after = nil; error = "\(p.name): \(e.localizedDescription)"
        }
    }

    nonisolated private static func load(_ p: Photo, maxSide: Int) throws -> Source {
        guard let cg = loadImage(p.url, maxSide: maxSide) else { throw CocoaError(.fileReadNoSuchFile) }
        let (mask, faces) = try analyze(cg), img = rgb(cg)
        // "before" is re-made from what the pipeline sees, so both panes are the same kind of bitmap
        return Source(image: cgImage(img), rgb: img, mask: mask, faces: faces,
                      original: imageSize(p.url) ?? CGSize(width: cg.width, height: cg.height))
    }
}

/// Chat runs your local Claude Code CLI headless (`claude -p`, same login as the desktop app). Claude never touches
/// pixels: it answers with parameter changes, and the deterministic pipeline renders them, so every edit stays tweakable.
enum Claude {
    struct Answer { var preset: Int?; var params: [String: Any]; var reply: String }

    static func ask(_ photo: Photo, _ region: Region, before: CGImage?, after: CGImage?, _ question: String) async throws -> Answer {
        let dir = FileManager.default.temporaryDirectory.appending(path: "FlashEdit-\(photo.id.uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let b = dir.appending(path: "original.jpg"), a = dir.appending(path: "current_edit.jpg")
        if let before { try save(before, to: b) }
        if let after { try save(after, to: a) }
        let history = photo.chat.suffix(12).map { ($0.user ? "User: " : "You: ") + $0.text }.joined(separator: "\n")
        let prompt = """
        You are the editing assistant inside FlashEdit, a Mac photo editor that gives photos a Meitu-style "flash" look: \
        darker ambient background, flash-lit person, neutral whites, skin tone and shading, optional fog behind the person. \
        You never edit pixels. You change the edit parameters and the app re-renders the photo deterministically.

        Parameters:
        - preset 0-4: 0 leaves the photo untouched, 1-4 are starting looks learned from reference edits: \(Params.presetInfo.enumerated().map { "\($0) \($1)" }.joined(separator: "; ")). \
        The user's own saved presets (use the number as preset): \(Presets.shared.user.isEmpty ? "none yet" : Presets.shared.user.map { "\($0.id) \"\($0.name)\"" }.joined(separator: "; ")). \
        Choosing a preset replaces all parameters.
        - ambient (background) and flash (person): 8 non-negative rises of a monotone luminance tone curve through 9 knots \
        (identity = 0.125 each, the running sum is capped at 1). Smaller total = darker. Bigger early rises lift shadows, \
        bigger late rises brighten highlights.
        - temp_ambient, tint_ambient, temp_flash, tint_flash (-0.2..0.2): white balance. temp + is warmer, tint + is greener, tint - is more magenta.
        - sat_ambient, sat_flash (0.5..1.6): saturation.
        - omega (0..0.95): dehaze strength.
        - spill (0..0.6): how much flash light reaches the scene just behind the person.
        - shine (0..0.6): extra glow on bright surfaces of the person (forehead, cap).
        - white (0..1): keeps bright flash-lit areas neutral white.
        - clarity (0..2): local contrast on the person.
        - warm_ev (-3..1): exposure in stops of dark warm tones on the person (brown hair).
        - skin_L (-10..15), skin_a, skin_b (-6..6): Lab shift of face skin. L is brightness, a + is pinker, b + is yellower.
        - body_L: Lab L shift for hands, neck and arms (null = same as skin_L). skin_contrast (0.5..1.5): face shading, 1 = unchanged.
        - strength (0..1): how much of the whole look is applied, blended with the original photo (1 = full).
        - plastic (-100..100, null/0 = off): plastic shine on the face, hands and visible body skin. Positive is waxy, \
        glossy skin; negative is matte (removes shiny spots).
        - lips (-100..100, null/0 = off): pink lips. Positive is pinker; negative is a more natural, nude lip.
        - hsl_hue, hsl_sat, hsl_lum: Color Mixer like Lightroom's HSL, each 8 values -100..100 (null = all 0) for \
        [red, orange, yellow, green, aqua, blue, purple, magenta]. Hue shifts that colour by up to 30 degrees, sat scales \
        its saturation (-100 = grey), lum changes its brightness (up to 1.2 stops). Always send all 8 values.
        - fog (0..0.9): mist behind the person. fog_start (0..1, 0 = starts at the bottom), fog_gamma (0.3..3, higher = \
        concentrated at the top), fog_color [r, g, b] in 0..1.

        Isolate: \(region == .whole ? "the whole photo." : "the user is editing only the \(region.rawValue.lowercased()). Your changes apply only to the \(region.rawValue.lowercased()); the rest of the photo keeps its own edit, so parameters for the other region have no visible effect.")
        Current preset: \(photo.preset)
        Current parameters\(region == .whole ? "" : " for the \(region.rawValue.lowercased())"): \(photo.params(for: region).json)
        Images you can Read: the original photo at \(b.path) and the current edit at \(a.path).

        Conversation so far:
        \(history.isEmpty ? "(none)" : history)

        User: \(question)

        Reply with one JSON object and nothing else:
        {"preset": <only if switching preset>, "params": {<only the keys you change>}, "reply": "<one short sentence on what you changed>"}
        """
        let text = try await Task.detached { try run(prompt, in: dir) }.value
        guard let s = text.firstIndex(of: "{"), let e = text.lastIndex(of: "}"),
              let obj = try? JSONSerialization.jsonObject(with: Data(text[s...e].utf8)) as? [String: Any] else {
            return Answer(params: [:], reply: text)  // plain answer, no change
        }
        return Answer(preset: (obj["preset"] as? Int).flatMap { Presets.shared.ids.contains($0) ? $0 : nil },
                      params: obj["params"] as? [String: Any] ?? [:], reply: obj["reply"] as? String ?? "Done.")
    }

    private static func run(_ prompt: String, in dir: URL) throws -> String {
        let fail = { (m: String) in NSError(domain: "FlashEdit", code: 2, userInfo: [NSLocalizedDescriptionKey: m]) }
        guard let exe = ["~/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .map({ NSString(string: $0).expandingTildeInPath }).first(where: FileManager.default.isExecutableFile) else {
            throw fail("Claude Code CLI not found. Install it from claude.com/claude-code, then sign in once in Terminal with `claude`.")
        }
        let p = Process(), inp = Pipe(), out = Pipe()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = ["-p", "--output-format", "json", "--allowedTools", "Read"]
        p.currentDirectoryURL = dir
        (p.standardInput, p.standardOutput, p.standardError) = (inp, out, FileHandle.nullDevice)
        try p.run()
        inp.fileHandleForWriting.write(Data(prompt.utf8))
        try inp.fileHandleForWriting.close()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let result = obj["result"] as? String else {
            throw fail("Claude returned nothing (exit \(p.terminationStatus)). Run `claude` once in Terminal to sign in.")
        }
        if obj["is_error"] as? Bool == true { throw fail(result) }
        return result
    }
}
