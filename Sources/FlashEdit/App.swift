import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
enum Entry {
    static func main() {
        let a = CommandLine.arguments
        // FlashEdit render in.jpg out.jpg [preset 0-4] [key=value ...]: headless, like flashgrade.py (e.g. plastic=60 hsl_sat=0,0,0,0,0,-50,0,0)
        if a.count >= 4, a[1] == "render" {
            do {
                let kv = a.dropFirst(5).map { $0.split(separator: "=", maxSplits: 1).map(String.init) }.filter { $0.count == 2 }
                let p = try Params.preset(Int(a.count > 4 ? a[4] : "1") ?? 1)
                    .merged(Dictionary(kv.map { kv -> (String, Any) in  // numbers, comma lists, or text (blur_type=lens)
                        let v = kv[1]
                        return (kv[0], Double(v).map { $0 as Any } ?? (v.contains(",") ? v.split(separator: ",").compactMap { Double($0) } as Any : v))
                    }, uniquingKeysWith: { $1 }))
                let (cg, nf) = try render(URL(fileURLWithPath: a[2]), bg: p, fg: p, label: "claude")  // tagged like flashgrade.py's output, so parity.sh compares like for like
                try save(cg, to: URL(fileURLWithPath: a[3]))
                print("\(a[3]): \(nf) face(s)")
                exit(0)
            } catch { fputs("\(error)\n", stderr); exit(1) }
        }
        if a.count >= 3, a[1] == "selftest" {
            // release builds drop precondition messages, so failures print their own
            func check(_ ok: Bool, _ why: String) { if !ok { fputs("selftest FAILED: \(why)\n", stderr); exit(1) } }  // FlashEdit selftest photo.png: checks Isolate (region blend, carrying)
            let cg = loadImage(URL(fileURLWithPath: a[2]))!, img = rgb(cg), (M, faces) = try! analyze(cg), m = personMask(img, M)
            let mixed = edit(img, M, faces, bg: .preset(0), fg: .preset(1)), full = edit(img, M, faces, .preset(1))
            let bgPx = (0..<img.n).filter { m[$0] == 0 }, fgPx = (0..<img.n).filter { m[$0] == 1 }
            check(bgPx.count > 1000 && fgPx.count > 1000, "photo needs a person")
            check(bgPx.allSatisfy { mixed.r[$0] == img.r[$0] && mixed.b[$0] == img.b[$0] }, "background must stay untouched")
            check(fgPx.allSatisfy { mixed.r[$0] == full.r[$0] && mixed.b[$0] == full.b[$0] }, "person must get preset 1")
            check(lipMask(faces, img.w, img.h, 1).filter { $0 > 0.5 }.count > 30, "Vision lip outline missing")
            var halfP = Params.preset(1); halfP.strength = 0.5
            let half = edit(img, M, faces, halfP)
            check((0..<img.n).allSatisfy { abs(half.g[$0] - (img.g[$0] + full.g[$0]) / 2) < 1e-5 }, "strength 50% must be halfway")
            var ph = Photo(path: a[2])
            ph.change(.background) { $0.fog = 0.4 }
            ph.change(.whole) { $0.fog = 0.1; $0.temp_flash = 0.05; $0.ambient[0] = 0.2 }
            check(ph.params.fog == 0.1 && abs(ph.bg!.fog - 0.5) < 1e-9 && abs(ph.bg!.temp_flash - 0.05) < 1e-9
                         && abs(ph.bg!.ambient[0] - 0.2) < 1e-9 && ph.fg == nil, "whole edits must carry into isolated regions")
            // catalogs written before versions/strength existed must still load (optional 3rd arg: a real catalog to check)
            let oldFormat = #"[{"id":"\#(UUID())","path":"/x.png","preset":1,"params":\#(Params.preset(1).json)}]"#
            let catalog = a.count > 3 ? try! Data(contentsOf: URL(fileURLWithPath: a[3])) : Data(oldFormat.utf8)
            let loaded = try! JSONDecoder().decode([Photo].self, from: catalog)
            print("catalog ok: \(loaded.count) photo(s), \(loaded.map(\.versions.count).reduce(0, +)) version(s)")
            // saved presets (run with a throwaway CFFIXED_USER_HOME, as parity.sh does, so your presets.json is untouched)
            let ps = Presets.shared
            let pid = ps.save("Test look", EditState(preset: 1, params: .preset(1), bg: .preset(4), fg: nil))
            check(ps.save("test LOOK", EditState(preset: 2, params: .preset(2), bg: .preset(4), fg: nil)) == pid, "same name must replace")
            var ph3 = Photo(path: "/x.png")
            ph3.setPreset(pid, .whole)
            check(ph3.params == .preset(2) && ph3.bg == .preset(4) && !ph3.isEdited && ph3.presetName == "Test look", "saved preset must apply")
            ph3.setPreset(pid, .person)
            check(ph3.fg == .preset(2), "saved preset on a region")
            // Color Mixer: blue saturation -100 turns blue grey and leaves red alone
            var mp = Params(); mp.hsl_sat = [0, 0, 0, 0, 0, -100, 0, 0]
            let px = colorMixer(RGB(w: 2, h: 1, r: [0.1, 0.9], g: [0.1, 0.1], b: [0.9, 0.1]), mp)
            check(abs(px.r[0] - px.b[0]) < 1e-4 && abs(px.g[0] - px.b[0]) < 1e-4, "blue must turn grey")
            check(abs(px.r[1] - 0.9) < 1e-4 && abs(px.g[1] - 0.1) < 1e-4, "red must stay")
            // Develop: works on None without the flash look's face smoothing; exposure +1 doubles linear light
            var ev = Params(); ev.exposure = 1
            let lit = edit(img, M, faces, ev)
            let mid = (0..<img.n).first { (0.2...0.35).contains(luma(img.r[$0], img.g[$0], img.b[$0])) }!
            let y0 = luma(img.r[mid], img.g[mid], img.b[mid]), k = srgb(lin(y0) * 2) / y0
            check(abs(lit.g[mid] - clip01(img.g[mid] * k)) < 1e-4, "exposure +1 must double linear light")
            check(PointCurve([0, 0, 1, 1]) == nil && abs(PointCurve([0, 0, 0.5, 0.7, 1, 1])!(0.5) - 0.7) < 1e-3, "tone curve must pass its points")
            var bl = Params(); bl.blur = 80; bl.blur_type = "lens"
            let blurred = edit(img, M, faces, bl)
            check(fgPx.allSatisfy { blurred.r[$0] == img.r[$0] } && bgPx.contains { blurred.r[$0] != img.r[$0] }, "blur must keep the person sharp")
            var fl = Params(); fl.flip = 1
            var r90 = Params(); r90.rotate = 90
            var r270 = Params(); r270.rotate = 270
            var quarterCrop = Params(); quarterCrop.crop = [0, 0, 0.5, 0.5]
            let twice = geometry(geometry(img, fl), fl), turned = geometry(geometry(img, r90), r270), cropped = geometry(img, quarterCrop)
            check(zip(twice.r, img.r).allSatisfy { abs($0 - $1) < 1e-5 }, "flip twice must give the photo back")
            check(turned.w == img.w && zip(turned.g, img.g).allSatisfy { abs($0 - $1) < 1e-5 }, "90 then 270 must give the photo back")
            check(cropped.w == (img.w + 1) / 2 || cropped.w == img.w / 2, "crop must size the output")
            print("selftest ok"); exit(0)
        }
        NSApplication.shared.setActivationPolicy(.regular)  // also behaves as an app under `swift run`
        FlashEditApp.main()
    }
}

struct FlashEditApp: App {
    @State private var library = Library()
    var body: some Scene {
        WindowGroup("FlashEdit") { ContentView().environment(library) }
            .defaultSize(width: 1360, height: 860)
    }
}

struct ContentView: View {
    @Environment(Library.self) private var library
    @State private var preview = Preview()
    @State private var selection = Set<UUID>()
    @State private var importing = false
    @State private var exporting: String?
    @State private var alert: String?

    private var current: Photo? { library.photos.first { selection.contains($0.id) } }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(library.photos) { PhotoRow(photo: $0).tag($0.id) }
            }
            .contextMenu(forSelectionType: UUID.self) { ids in
                Button("Remove from Library") { remove(ids) }
            }
            .onDeleteCommand { remove(selection) }
            .navigationSplitViewColumnWidth(min: 180, ideal: 230)
        } detail: {
            if let photo = current {
                HStack(spacing: 0) {
                    CompareView(preview: preview).id(photo.id)  // each photo opens fitted
                    Divider()
                    Inspector(id: photo.id, preview: preview).frame(width: 340).id(photo.id)
                }
            } else {
                ContentUnavailableView("Drop photos here", systemImage: "photo.on.rectangle.angled",
                                       description: Text("Drag photos or a folder into this window, or click +. Every edit is saved automatically."))
            }
        }
        .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers in  // Finder files, or photos dragged from Photos/Safari
            Task { @MainActor in add(await droppedFiles(providers)) }
            return true
        }
        .onOpenURL { add([$0]) }  // Finder's Open With, or a photo dropped on the Dock icon
        .fileImporter(isPresented: $importing, allowedContentTypes: [.image, .heic, .heif, .folder], allowsMultipleSelection: true) {
            if case .success(let urls) = $0 { add(urls) }
        }
        .toolbar {
            ToolbarItemGroup {
                if let cur = current {
                    Button { library.undo(cur.id) } label: { Label("Undo", systemImage: "arrow.uturn.backward") }
                        .keyboardShortcut("z").disabled(library.undoStack[cur.id]?.isEmpty ?? true).help("Undo (⌘Z)")
                    Button { library.redo(cur.id) } label: { Label("Redo", systemImage: "arrow.uturn.forward") }
                        .keyboardShortcut("z", modifiers: [.command, .shift]).disabled(library.redoStack[cur.id]?.isEmpty ?? true).help("Redo (⇧⌘Z)")
                    versionMenu(cur)
                }
                if let exporting { ProgressView().controlSize(.small); Text(exporting).foregroundStyle(.secondary) }
                Button { importing = true } label: { Label("Add Photos", systemImage: "plus") }
                Menu {
                    Button("Export as JPEG…") { export(as: "jpg") }
                    Button("Export as HEIC…") { export(as: "heic") }
                } label: { Label("Export", systemImage: "square.and.arrow.up") } primaryAction: { export(as: nil) }
                    .disabled(selection.isEmpty || exporting != nil)
                    .help("Export the selected photos at full resolution (HEIC stays HEIC, others become JPEG)")
            }
        }
        .onChange(of: current?.id, initial: true) { preview.show(current) }
        .onChange(of: current?.look) { preview.show(current) }
        .onAppear { if selection.isEmpty, let first = library.photos.first { selection = [first.id] } }
        .alert("FlashEdit", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })) {} message: { Text(alert ?? "") }
    }

    /// Saved versions of the photo's edit: Save Version snapshots it, the menu switches between them.
    @ViewBuilder private func versionMenu(_ cur: Photo) -> some View {
        let selected = cur.currentVersion
        Menu {
            ForEach(cur.versions.reversed()) { v in
                Button { library.update(cur.id) { $0.open(v.state) } } label: {
                    let title = "\(v.name)  ·  \(v.date.formatted(date: .abbreviated, time: .shortened))"
                    if v.id == selected?.id { Label(title, systemImage: "checkmark") } else { Text(title) }
                }
            }
            if let d = cur.draft, selected != nil {
                Divider()
                Button("Unsaved Edit") { library.update(cur.id) { $0.open(d) } }
            }
            if cur.versions.isEmpty { Text("No saved versions yet. Click Save Version.") }
            if let v = selected {
                Divider()
                Button("Delete \(v.name)", role: .destructive) { library.update(cur.id) { $0.versions.removeAll { $0.id == v.id } } }
            }
        } label: {
            Label(selected?.name ?? (cur.versions.isEmpty ? "Versions" : "Unsaved"), systemImage: "square.stack.3d.up").labelStyle(.titleAndIcon)
        }
        .help("Switch between saved versions of this edit")
        Button { library.update(cur.id) { $0.saveVersion() } } label: { Label("Save Version", systemImage: "checkmark.circle") }
            .keyboardShortcut("s").disabled(selected != nil).help("Save the current edit as a new version (⌘S)")
    }

    private func add(_ urls: [URL]) {
        let ids = library.add(urls)
        if let first = ids.first { selection = [first] }
    }

    private func remove(_ ids: Set<UUID>) {
        library.photos.removeAll { ids.contains($0.id) }
        selection.subtract(ids)
    }

    /// `format` "jpg" or "heic"; nil keeps each photo's kind (HEIC/HEIF stays HEIC, everything else becomes JPEG).
    private func export(as format: String?) {
        let panel = NSOpenPanel()
        (panel.canChooseDirectories, panel.canChooseFiles, panel.prompt) = (true, false, "Export Here")
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        let items = library.photos.filter { selection.contains($0.id) }
        Task {
            var failed = [String]()
            for (k, p) in items.enumerated() {
                exporting = "Exporting \(k + 1) of \(items.count)"
                let ext = format ?? (["heic", "heif"].contains(p.url.pathExtension.lowercased()) ? "heic" : "jpg")
                let dst = dir.appending(path: p.url.deletingPathExtension().lastPathComponent + "_flash.\(ext)")
                do { try await Task.detached(priority: .userInitiated) { try save(render(p.url, bg: p.params(for: .background), fg: p.params(for: .person)).0, to: dst) }.value }
                catch { failed.append("\(p.name): \(error.localizedDescription)") }
            }
            exporting = nil
            if failed.isEmpty { NSWorkspace.shared.activateFileViewerSelecting([dir]) } else { alert = failed.joined(separator: "\n") }
        }
    }
}

struct PhotoRow: View {
    let photo: Photo
    @State private var thumb: CGImage?

    var body: some View {
        HStack {
            Group {
                if let thumb { Image(decorative: thumb, scale: 1).resizable().scaledToFill() } else { Color.secondary.opacity(0.2) }
            }
            .frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 5))
            VStack(alignment: .leading, spacing: 2) {
                Text(photo.name).lineLimit(1).truncationMode(.middle)
                Text(photo.isEdited ? "\(photo.presetName), edited" : photo.presetName)
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .task(id: photo.path) { let u = photo.url; thumb = await Task.detached { loadImage(u, maxSide: 128) }.value }
    }
}

/// Before and after, zoomed and panned together. Pinch or ⌘= / ⌘− to zoom, hold Space and drag to pan.
struct CompareView: View {
    let preview: Preview
    @Environment(\.displayScale) private var displayScale
    @State private var holding = false
    @State private var zoom: CGFloat = 1  // 1 = fit
    @State private var offset = CGSize.zero  // pan from centred, in points
    @State private var panStart: CGSize?
    @State private var pinchStart: (zoom: CGFloat, offset: CGSize)?
    @State private var space = false
    @State private var monitor: Any?
    @State private var paneSize = CGSize(width: 1, height: 1)

    /// Image size at zoom 1 inside one pane.
    private var fit: CGSize {
        guard let img = preview.after ?? preview.before else { return paneSize }
        let k = min(paneSize.width / CGFloat(img.width), paneSize.height / CGFloat(img.height))
        return CGSize(width: CGFloat(img.width) * k, height: CGFloat(img.height) * k)
    }
    private var oneToOne: CGFloat { preview.original.width / max(fit.width * displayScale, 1) }  // 1 photo px = 1 screen px

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 12) {
                panel("Before", preview.before)
                panel(holding ? "Without edits" : "After  ·  hold to compare", holding ? preview.before : preview.after)
                    .onLongPressGesture(minimumDuration: .infinity, perform: {}, onPressingChanged: { holding = $0 && !space })
            }
            .highPriorityGesture(pan, including: space ? .all : .subviews)
            .simultaneousGesture(pinch)
            .onChange(of: geo.size, initial: true) { paneSize = CGSize(width: max(1, (geo.size.width - 12) / 2), height: max(1, geo.size.height)) }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black.opacity(0.85))
        .overlay(alignment: .bottom) { zoomBar }
        .overlay(alignment: .topTrailing) { if preview.busy { ProgressView().controlSize(.small).padding(10) } }
        .overlay { if let e = preview.error { Text(e).foregroundStyle(.white).padding().background(.red.opacity(0.8), in: .rect(cornerRadius: 8)) } }
        .onChange(of: zoom * fit.width * displayScale > preview.previewWidth * 1.1, initial: true) { _, v in preview.wantDetail = v }
        .onChange(of: space) { _, down in down ? NSCursor.openHand.push() : NSCursor.pop() }
        .onAppear {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { e in
                guard e.keyCode == 49 else { return e }  // space
                if e.type == .keyUp { guard space else { return e }; space = false; return nil }
                if NSApp.keyWindow?.firstResponder is NSText { return e }  // typing in the chat box
                if !e.isARepeat { space = true }
                return nil
            }
        }
        .onDisappear { if let monitor { NSEvent.removeMonitor(monitor) }; if space { NSCursor.pop() } }
    }

    private func panel(_ title: String, _ img: CGImage?) -> some View {
        ZStack {
            if let img {
                Image(decorative: img, scale: 1).resizable().interpolation(.high)
                    .frame(width: fit.width * zoom, height: fit.height * zoom).offset(offset)
            }
        }
        .frame(width: paneSize.width, height: paneSize.height)
        .clipped()
        .contentShape(Rectangle())
        .overlay(alignment: .topLeading) {
            Text(title).font(.caption).foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 3).background(.black.opacity(0.55), in: Capsule()).padding(8)
        }
    }

    private var zoomBar: some View {
        HStack(spacing: 6) {
            Button { setZoom(zoom / 1.5) } label: { Image(systemName: "minus.magnifyingglass") }
                .keyboardShortcut("-").help("Zoom out (⌘−)")
            Text("\(Int((zoom / oneToOne * 100).rounded()))%").monospacedDigit().frame(minWidth: 46)
            Button { setZoom(zoom * 1.5) } label: { Image(systemName: "plus.magnifyingglass") }
                .keyboardShortcut("=").help("Zoom in (⌘=)")
            Divider().frame(height: 14)
            Button("Fit") { setZoom(1) }.keyboardShortcut("0").help("Fit to screen (⌘0)")
            Button("100%") { setZoom(oneToOne) }.keyboardShortcut("1").help("Actual pixels (⌘1)")
        }
        .buttonStyle(.borderless).foregroundStyle(.white)
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.black.opacity(0.65), in: Capsule())
        .help("Pinch to zoom, hold Space and drag to pan")
        .padding(.bottom, 24)
    }

    private var pan: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { v in
                let s = panStart ?? offset
                if panStart == nil { panStart = s; NSCursor.closedHand.push() }
                offset = clamped(CGSize(width: s.width + v.translation.width, height: s.height + v.translation.height), zoom)
            }
            .onEnded { _ in panStart = nil; NSCursor.pop() }
    }

    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { v in
                let s = pinchStart ?? (zoom, offset)
                if pinchStart == nil { pinchStart = s }
                // zoom around the point under the fingers, measured from the centre of whichever pane it is in
                let right = v.startLocation.x > paneSize.width + 6
                let p = CGPoint(x: v.startLocation.x - paneSize.width / 2 - (right ? paneSize.width + 12 : 0), y: v.startLocation.y - paneSize.height / 2)
                setZoom(s.zoom * v.magnification, about: p, from: s)
            }
            .onEnded { _ in pinchStart = nil }
    }

    /// Keeps the image point under `p` (relative to the pane centre) fixed while zooming.
    private func setZoom(_ z: CGFloat, about p: CGPoint = .zero, from s: (zoom: CGFloat, offset: CGSize)? = nil) {
        let (z0, o0) = s ?? (zoom, offset), z1 = min(max(z, 1), max(4, oneToOne * 8))
        offset = clamped(CGSize(width: p.x - (p.x - o0.width) * z1 / z0, height: p.y - (p.y - o0.height) * z1 / z0), z1)
        zoom = z1
    }

    /// No panning past the image edges.
    private func clamped(_ o: CGSize, _ z: CGFloat) -> CGSize {
        let mx = max(0, (fit.width * z - paneSize.width) / 2), my = max(0, (fit.height * z - paneSize.height) / 2)
        return CGSize(width: min(max(o.width, -mx), mx), height: min(max(o.height, -my), my))
    }
}

/// Preset, sliders and chat for one photo. Everything writes straight into the library, so it is saved as you go.
struct Inspector: View {
    let id: UUID
    let preview: Preview
    @Environment(Library.self) private var library
    @State private var region = Region.whole

    var body: some View {
        VSplitView {
            Adjustments(photo: binding, region: $region).frame(minHeight: 200)
            ChatPanel(id: id, region: region, preview: preview).frame(minHeight: 180, idealHeight: 320)
        }
    }

    private var binding: Binding<Photo> {
        Binding(get: { library.photos.first { $0.id == id } ?? Photo(path: "") }, set: { p in library.update(id) { $0 = p } })
    }
}

struct Adjustments: View {
    @Binding var photo: Photo
    @Binding var region: Region
    @State private var naming = false
    @State private var query = ""
    @State private var channel = 0  // Color Mixer: 0 hue, 1 saturation, 2 luminance
    @FocusState private var searchFocused: Bool
    private let presets = Presets.shared

    private struct Row: Identifiable { let id: String, section: String, search: String, view: AnyView }
    private static let sections = ["Preset", "Exposure", "Color", "Color Mixer", "Skin", "Fog"]
    private static let bands = ["Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Purple", "Magenta"]
    private static let channels: [(name: String, keys: String, kp: WritableKeyPath<Params, [Double]?>)] = [
        ("Hue", "hue shift", \.hsl_hue), ("Saturation", "saturation sat vibrance", \.hsl_sat), ("Luminance", "luminance lightness brightness", \.hsl_lum)]

    /// Every slider, with words to search by. Search shows the rows containing all typed words.
    private var rows: [Row] {
        var out: [Row] = []
        func add(_ sec: String, _ title: String, _ keys: String, _ v: Binding<Double>, _ range: ClosedRange<Double>,
                 _ only: Region? = nil, digits: Int = 2, swatch: Color? = nil) {
            out.append(Row(id: "\(sec)/\(title)", section: sec, search: "\(sec) \(title) \(keys)".lowercased(),
                           view: AnyView(knob(title, v, range, only, digits: digits, swatch: swatch))))
        }
        if !query.isEmpty {  // Strength sits with the presets, which are hidden while searching
            add("Preset", "Strength", "amount opacity intensity look",
                Binding(get: { p.strength ?? 1 }, set: { v in photo.change(region) { $0.strength = v } }), 0...1)
        }
        add("Exposure", "Background", "ambient brightness curve", curveTotal(\.ambient), 0.2...1.3, .background)
        add("Exposure", "Person (flash)", "subject brightness curve", curveTotal(\.flash), 0.2...1.3, .person)
        add("Exposure", "Dehaze", "haze clear", value(\.omega), 0...0.95)
        add("Exposure", "Flash spill", "glow light", value(\.spill), 0...0.6, .background)
        add("Exposure", "Shine", "glow highlights", value(\.shine), 0...0.6, .person)
        add("Exposure", "Neutral whites", "white balance", value(\.white), 0...1, .person)
        add("Exposure", "Clarity", "detail sharpness texture contrast", value(\.clarity), 0...2, .person)
        add("Exposure", "Hair (warm darks)", "brown dark", value(\.warm_ev), -3...1, .person)
        add("Color", "Background temp", "temperature warmth white balance colour", value(\.temp_ambient), -0.2...0.2, .background)
        add("Color", "Background tint", "green magenta white balance colour", value(\.tint_ambient), -0.2...0.2, .background)
        add("Color", "Background sat", "saturation vibrance colour", value(\.sat_ambient), 0.5...1.6, .background)
        add("Color", "Person temp", "temperature warmth white balance colour", value(\.temp_flash), -0.2...0.2, .person)
        add("Color", "Person tint", "green magenta white balance colour", value(\.tint_flash), -0.2...0.2, .person)
        add("Color", "Person sat", "saturation vibrance colour", value(\.sat_flash), 0.5...1.6, .person)
        if query.isEmpty {
            out.append(Row(id: "mixer/channel", section: "Color Mixer", search: "", view: AnyView(
                Picker("Adjust", selection: $channel) { ForEach(0..<3, id: \.self) { Text(Self.channels[$0].name).tag($0) } }
                    .pickerStyle(.segmented))))
        }
        for (c, name) in Self.bands.enumerated() {
            for (k, ch) in Self.channels.enumerated() where !query.isEmpty || k == channel {
                add("Color Mixer", query.isEmpty ? name : "\(name) \(ch.name.lowercased())", "\(ch.keys) hsl colour", mixer(ch.kp, c),
                    -100...100, digits: 0, swatch: Color(hue: Double(mixerHues[c]) / 360, saturation: 0.75, brightness: 0.95))
            }
        }
        if query.isEmpty {
            out.append(Row(id: "mixer/reset", section: "Color Mixer", search: "", view: AnyView(
                Button("Reset Color Mixer") { photo.change(region) { ($0.hsl_hue, $0.hsl_sat, $0.hsl_lum) = (nil, nil, nil) } }
                    .disabled(p.look.hsl_hue == nil && p.look.hsl_sat == nil && p.look.hsl_lum == nil))))
        }
        add("Skin", "Face brightness", "lightness", value(\.skin_L), -10...15, .person)
        add("Skin", "Face pink", "redness", value(\.skin_a), -6...6, .person)
        add("Skin", "Face yellow", "warmth", value(\.skin_b), -6...6, .person)
        add("Skin", "Body brightness", "hands arms neck lightness",
            Binding(get: { p.body_L ?? p.skin_L }, set: { v in photo.change(region) { $0.body_L = v } }), -10...15, .person)
        add("Skin", "Face contrast", "shading shadows", value(\.skin_contrast), 0.5...1.5, .person)
        add("Skin", "Plastic shine", "gloss glossy matte smooth waxy", signed(\.plastic), -100...100, .person, digits: 0)
        add("Skin", "Pink lips", "lip mouth nude", signed(\.lips), -100...100, .person, digits: 0)
        add("Fog", "Amount", "mist haze", value(\.fog), 0...0.9, .background)
        add("Fog", "Start height", "mist", value(\.fog_start), 0...1, .background)
        add("Fog", "Falloff", "mist gamma", value(\.fog_gamma), 0.3...3, .background)
        out.append(Row(id: "Fog/Color", section: "Fog", search: "fog mist color colour", view: AnyView(
            ColorPicker("Color", selection: fogColor, supportsOpacity: false).disabled(region == .person))))
        let words = query.lowercased().split(separator: " ")
        return out.filter { r in words.allSatisfy { r.search.contains($0) } }
    }

    /// One Color Mixer slider: band `i` of hue, saturation or luminance. All zeros are stored as nil (off).
    private func mixer(_ kp: WritableKeyPath<Params, [Double]?>, _ i: Int) -> Binding<Double> {
        Binding(get: { p[keyPath: kp]?[i] ?? 0 }, set: { v in
            photo.change(region) {
                var a = $0[keyPath: kp] ?? [Double](repeating: 0, count: 8)
                a[i] = abs(v) < 2 ? 0 : v.rounded()
                $0[keyPath: kp] = a.allSatisfy { $0 == 0 } ? nil : a
            }
        })
    }

    private var p: Params { photo.params(for: region) }
    /// The saved preset this photo (or the isolated region) is on, if any.
    private var myPreset: Int? {
        region == .whole ? (presets.user.contains { $0.id == photo.preset } ? photo.preset : nil)
            : presets.user.first { presets.params($0.id, for: region).look == p.look }?.id
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            adjustments
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search adjustments  ⌘F", text: $query).textFieldStyle(.plain).focused($searchFocused).onExitCommand { query = "" }
            if !query.isEmpty {
                Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
        .padding(.horizontal, 14).padding(.top, 12)
        .background(Button("") { searchFocused = true }.keyboardShortcut("f").opacity(0))
    }

    private var adjustments: some View {
        Form {
            Section {
                Picker("Isolate", selection: $region) { ForEach(Region.allCases, id: \.self) { Text($0.rawValue) } }
                    .pickerStyle(.segmented)
                if region != .whole {
                    Text("Changes affect only the \(region.rawValue.lowercased()).").font(.caption).foregroundStyle(.secondary)
                }
                if query.isEmpty {  // while searching, only the Isolate switch stays above the results
                    Picker("Preset", selection: Binding(get: { region == .whole ? photo.preset : (0...4).first { Params.preset($0) == p.look } ?? -1 },
                                                        set: { photo.setPreset($0, region) })) {
                        ForEach(0...4, id: \.self) { Text($0 == 0 ? "None" : "\($0)").tag($0) }
                    }
                    .pickerStyle(.segmented)
                    HStack {
                        Menu {
                            if presets.user.isEmpty { Text("No saved presets yet") }
                            ForEach(presets.user) { u in
                                Button { photo.setPreset(u.id, region) } label: {
                                    if u.id == myPreset { Label(u.name, systemImage: "checkmark") } else { Text(u.name) }
                                }
                            }
                            if !presets.user.isEmpty {
                                Divider()
                                Menu("Delete Preset") {
                                    ForEach(presets.user) { u in Button(u.name, role: .destructive) { presets.user.removeAll { $0.id == u.id } } }
                                }
                            }
                        } label: { Text(myPreset.map(presets.name) ?? "My Presets") }
                        .help("Your saved presets, usable on any photo")
                        Button("Save as Preset…") { naming = true }
                            .help("Save this photo's current look as a named preset")
                    }
                    if p.look != Params() {  // something to fade: a preset or any slider change
                        LabeledContent("Strength") {
                            HStack {
                                Slider(value: Binding(get: { p.strength ?? 1 }, set: { v in photo.change(region) { $0.strength = v } }), in: 0...1)
                                Text("\(Int(((p.strength ?? 1) * 100).rounded()))%").monospacedDigit()
                                    .foregroundStyle(.secondary).frame(width: 38, alignment: .trailing)
                            }
                        }
                    }
                    if region == .whole {
                        Text((0...4).contains(photo.preset) ? Params.presetInfo[photo.preset].capitalizedFirst : "Your preset “\(photo.presetName)”")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if region == .whole {
                        Button("Reset All to \(photo.presetName)") { photo.setPreset(photo.preset, .whole) }.disabled(!photo.isEdited)
                    } else {
                        Button("Match Whole Photo") { if region == .background { photo.bg = nil } else { photo.fg = nil } }
                            .disabled((region == .background ? photo.bg : photo.fg) == nil)
                    }
                }
            }
            let rows = self.rows
            if rows.isEmpty { Text("No adjustments match “\(query)”").foregroundStyle(.secondary) }
            ForEach(Self.sections, id: \.self) { sec in
                let rs = rows.filter { $0.section == sec }
                if !rs.isEmpty { Section(sec) { ForEach(rs) { $0.view } } }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $naming) {
            SavePresetSheet(existing: presets.user.map(\.name)) { name in
                let s = photo.state  // the whole look, Isolate edits included
                photo.preset = presets.save(name, s)  // the photo is now on its new preset
            }
        }
    }

    /// `only`: the region a slider acts on, so it greys out while the other region is isolated.
    private func knob(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, _ only: Region? = nil,
                      digits: Int = 2, swatch: Color? = nil) -> some View {
        LabeledContent {
            HStack {
                Slider(value: value, in: range)
                Text(value.wrappedValue, format: .number.precision(.fractionLength(digits))).monospacedDigit()
                    .foregroundStyle(.secondary).frame(width: 38, alignment: .trailing)
            }
        } label: {
            HStack(spacing: 6) {
                if let swatch { Circle().fill(swatch).frame(width: 9, height: 9) }
                Text(title)
            }
        }
        .disabled(only != nil && region != .whole && region != only)
    }

    /// −100…100 knobs stored as optionals: 0 (it snaps within ±2) means off.
    private func signed(_ kp: WritableKeyPath<Params, Double?>) -> Binding<Double> {
        Binding(get: { p[keyPath: kp] ?? 0 }, set: { v in photo.change(region) { $0[keyPath: kp] = abs(v) < 2 ? nil : v.rounded() } })
    }

    private func value(_ kp: WritableKeyPath<Params, Double>) -> Binding<Double> {
        Binding(get: { p[keyPath: kp] }, set: { v in photo.change(region) { $0[keyPath: kp] = v } })
    }

    /// Overall brightness of a tone curve = the sum of its 8 rises; dragging scales them and keeps the curve's shape.
    private func curveTotal(_ kp: WritableKeyPath<Params, [Double]>) -> Binding<Double> {
        Binding(get: { p[keyPath: kp].map { max($0, 0) }.reduce(0, +) }, set: { t in
            photo.change(region) {
                let steps = $0[keyPath: kp].map { max($0, 0) }, old = steps.reduce(0, +)
                $0[keyPath: kp] = old > 1e-6 ? steps.map { $0 * t / old } : [Double](repeating: t / 8, count: 8)
            }
        })
    }

    private var fogColor: Binding<CGColor> {
        Binding(get: { let c = p.fog_color; return CGColor(srgbRed: c[0], green: c[1], blue: c[2], alpha: 1) }, set: {
            if let c = $0.converted(to: CGColorSpace(name: CGColorSpace.sRGB)!, intent: .defaultIntent, options: nil)?.components, c.count >= 3 {
                let rgb = c[0..<3].map { min(max(Double($0), 0), 1) }
                photo.change(region) { $0.fog_color = rgb }
            }
        })
    }
}

struct ChatPanel: View {
    let id: UUID
    let region: Region
    let preview: Preview
    @Environment(Library.self) private var library
    @State private var text = ""
    @State private var thinking = false

    private var chat: [Msg] { library.photos.first { $0.id == id }?.chat ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if chat.isEmpty {
                            Text("Ask Claude to edit this photo, e.g. “darker background, more fog”, “warmer skin”, “try preset 4 but less misty”. You can fine-tune with the sliders afterwards.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        ForEach(chat) { m in
                            Text(m.text)
                                .textSelection(.enabled)
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(m.user ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12), in: .rect(cornerRadius: 10))
                                .frame(maxWidth: .infinity, alignment: m.user ? .trailing : .leading)
                                .id(m.id)
                        }
                        if thinking { ProgressView("Claude is editing…").controlSize(.small).id("thinking") }
                    }
                    .padding(12)
                }
                .onChange(of: chat.count) { withAnimation { proxy.scrollTo(chat.last?.id, anchor: .bottom) } }
            }
            Divider()
            HStack(alignment: .bottom) {
                TextField("Ask Claude to edit…", text: $text, axis: .vertical)
                    .textFieldStyle(.plain).lineLimit(1...5).onSubmit(send).disabled(thinking)
                Button(action: send) { Image(systemName: "arrow.up.circle.fill").font(.title2) }
                    .buttonStyle(.plain).disabled(thinking || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(10)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func send() {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !thinking, let photo = library.photos.first(where: { $0.id == id }) else { return }
        text = ""; thinking = true
        let region = region
        library.update(id) { $0.chat.append(Msg(user: true, text: region == .whole ? q : "(\(region.rawValue.lowercased())) \(q)")) }
        let (before, after) = (preview.before, preview.after)
        Task {
            do {
                let ans = try await Claude.ask(photo, region, model: UserDefaults.standard.string(forKey: "chatModel") ?? "", before: before, after: after, q)
                var ph = library.photos.first { $0.id == id } ?? photo
                if let k = ans.preset { ph.setPreset(k, region) }
                let params = try ph.params(for: region).merged(ans.params)
                ph.change(region) { $0 = params }
                ph.chat.append(Msg(user: false, text: ans.reply))
                library.update(id) { $0 = ph }
            } catch {
                library.update(id) { $0.chat.append(Msg(user: false, text: "⚠️ \(error.localizedDescription)")) }
            }
            thinking = false
        }
    }
}

/// Name is required; an existing name is replaced (that's how you update a preset).
struct SavePresetSheet: View {
    let existing: [String]
    let onSave: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var replaces: Bool { existing.contains { $0.caseInsensitiveCompare(trimmed) == .orderedSame } }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Save Preset").font(.headline)
            Text("Saves this photo's current look, Isolate edits included, so you can apply it to any photo.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("Preset name (required)", text: $name).onSubmit(save)
            if replaces { Text("“\(trimmed)” already exists and will be replaced.").font(.caption).foregroundStyle(.orange) }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(replaces ? "Replace" : "Save", action: save).keyboardShortcut(.defaultAction).disabled(trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func save() {
        guard !trimmed.isEmpty else { return }
        onSave(trimmed)
        dismiss()
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
