import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
enum Entry {
    static func main() {
        let a = CommandLine.arguments
        // FlashEdit render in.jpg out.jpg [preset 0-4] [key=value ...]: headless, like flashgrade.py (e.g. plastic=60 hsl_sat=0,0,0,0,0,-50,0,0
        // 'masks=[{"kind":"radial","shape":[0.5,0.4,0.2,0.25],"exposure":0.8}]'). Heal spots given as [x, y, r] are one brushed run: they
        // share a source, picked the way the app picks one.
        if a.count >= 4, a[1] == "render" {
            do {
                let kv = a.dropFirst(5).map { $0.split(separator: "=", maxSplits: 1).map(String.init) }.filter { $0.count == 2 }
                var over = Dictionary(kv.map { kv -> (String, Any) in  // JSON (numbers, lists, masks), comma lists, or text (blur_type=lens)
                    let v = kv[1]
                    return (kv[0], (try? JSONSerialization.jsonObject(with: Data(v.utf8), options: .fragmentsAllowed))
                        ?? (v.contains(",") ? v.split(separator: ",").compactMap { Double($0) } as Any : v))
                }, uniquingKeysWith: { $1 })
                if let spots = over["heal"] as? [[Double]], spots.contains(where: { $0.count == 3 }), let cg = loadImage(URL(fileURLWithPath: a[2])) {
                    let (dx, dy) = healOffset(rgb(cg), spots.filter { $0.count == 3 })
                    over["heal"] = spots.map { $0.count == 3 ? $0 + [$0[0] + dx, $0[1] + dy] : $0 }
                    print("heal: \(over["heal"]!)")
                }
                let p = try Params.preset(Int(a.count > 4 ? a[4] : "1") ?? 1).merged(over)
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
            var tilted = Params(); (tilted.rotate, tilted.flip, tilted.straighten, tilted.crop) = (90, 1, 7, [0.1, 0.15, 0.7, 0.8])
            let g = Geo(tilted, 300, 200)
            check([(10, 20), (150, 100), (290, 5)].allSatisfy { (x: Float, y: Float) in
                let (u, v) = g.output(x, y), (x2, y2) = g.source(u, v); return abs(x2 - x) < 1e-3 && abs(y2 - y) < 1e-3 }, "Geo.output must undo Geo.source")
            // Heal: a dark dot on a left-to-right ramp, copied from a brighter patch to its right. The dot goes and the ramp
            // carries on unbroken, because the copy is colour-matched to the spot's surroundings, not the source's.
            let (hw, hh) = (200, 200), ramp = fill(hw * hh) { Float($0 % hw) / Float(hw - 1) * 0.6 + 0.2 }
            var dotted = ramp
            for i in dotted.indices where hypot(Float(i % hw) - 100, Float(i / hw) - 100) < 5 { dotted[i] = 0.05 }
            let healed = heal(RGB(w: hw, h: hh, r: dotted, g: dotted, b: dotted), [[0.5, 0.5, 0.06, 0.65, 0.5]])
            check(zip(healed.g, ramp).allSatisfy { abs($0 - $1) < 0.01 }, "heal must remove the dot and match the ramp")
            check((0..<hw * hh).allSatisfy { hypot(Float($0 % hw) - 100, Float($0 / hw) - 100) < 13 || healed.r[$0] == dotted[$0] }, "heal must stay inside its circle")
            // automatic source: off the spot, inside the photo, and not in the busy stripes on the right
            let striped = fill(hw * hh) { i in i % hw > 125 ? Float((i % hw / 2) % 2) : (hypot(Float(i % hw) - 100, Float(i / hw) - 100) < 5 ? 0.05 : 0.5) }
            let (odx, ody) = healOffset(RGB(w: hw, h: hh, r: striped, g: striped, b: striped), [[0.5, 0.5, 0.06]])
            let (sx, sy) = (100 + odx * 200, 100 + ody * 200)
            check(hypot(odx, ody) * 200 >= 24 && sx + 12 <= 125 && sx >= 12 && sy >= 12 && sy <= 188, "auto source must avoid the spot, the edges and the stripes (got \(sx), \(sy))")
            var hp = Params(); hp.heal = [[0.3, 0.4, 0.03, 0.45, 0.4]]
            let he = edit(img, M, faces, hp), (hcx, hcy, hr) = (Float(0.3 * Double(img.w)), Float(0.4 * Double(img.h)), Float(0.03 * Double(min(img.w, img.h))))
            check((0..<img.n).allSatisfy { hypot(Float($0 % img.w) + 0.5 - hcx, Float($0 / img.w) + 0.5 - hcy) <= hr + 1 || he.g[$0] == img.g[$0] }
                  && (0..<img.n).contains { he.g[$0] != img.g[$0] }, "a heal-only edit must change only its spot")
            // Masks: radial works inside only, linear fades from full to none, a brush dab and its erase cancel out
            let flat = RGB(w: 100, h: 100, r: fill(10_000) { _ in 0.3 }, g: fill(10_000) { _ in 0.3 }, b: fill(10_000) { _ in 0.3 })
            var rm = Params(); rm.masks = [LocalMask(kind: .radial, shape: [0.5, 0.5, 0.2, 0.2], exposure: 1)]
            let lr = localMasks(flat, rm, 1)
            check(lr.g[5050] > 0.4 && lr.g[0] == 0.3, "radial mask must brighten its inside only")
            rm.masks![0].invert = true
            let li = localMasks(flat, rm, 1)
            check(li.g[5050] == 0.3 && li.g[0] > 0.4, "inverted radial mask must brighten its outside only")
            var lm = Params(); lm.masks = [LocalMask(kind: .linear, shape: [0.5, 0, 0.5, 1], exposure: 1, temp: 50)]
            let ll = localMasks(flat, lm, 1)
            check(ll.g[50] > ll.g[5050] && ll.g[5050] > ll.g[9950] && abs(ll.g[9950] - 0.3) < 1e-3 && ll.r[50] > ll.b[50], "linear mask must fade top to bottom")
            var turned = LocalMask(kind: .radial, shape: [0.5, 0.5, 0.4, 0.1, 90], exposure: 1)  // a tall ellipse once turned
            check(maskPlane(turned, 100, 100)[40 * 100 + 50] > 0.9 && maskPlane(turned, 100, 100)[50 * 100 + 20] < 0.1, "radial mask must rotate")
            (turned.blur, turned.exposure) = (80, nil)
            var soft = Params(); soft.masks = [turned]
            let stripes = RGB(w: 100, h: 100, r: fill(10_000) { Float(($0 % 100 / 4) % 2) }, g: fill(10_000) { Float(($0 % 100 / 4) % 2) },
                              b: fill(10_000) { Float(($0 % 100 / 4) % 2) })
            let bl2 = localMasks(stripes, soft, 1)
            check(abs(bl2.g[5050] - 0.5) < 0.3 && bl2.g[5000 + 2] == stripes.g[5000 + 2], "mask blur must soften inside only")
            let dab = LocalMask(kind: .brush, shape: [0.5, 0.5, 0.1]), erased = LocalMask(kind: .brush, shape: [0.5, 0.5, 0.1, 0.5, 0.5, -0.1])
            check(maskPlane(dab, 100, 100)[5050] == 1 && maskPlane(dab, 100, 100)[0] == 0 && maskPlane(erased, 100, 100).allSatisfy { $0 < 1e-6 }, "brush dab and erase")
            check((try? Params().merged(["heal": [[0.5, 0.5]]])) == nil && (try? Params().merged(["masks": [["kind": "lasso", "shape": []]]])) == nil
                  && (try? Params().merged(["masks": [["kind": "radial", "shape": [0.5, 0.5, 0.2, 0.2], "exposure": 1]], "heal": [[0.5, 0.5, 0.05, 0.6, 0.5]]])) != nil,
                  "heal and mask shapes must be checked")
            var ph4 = Photo(path: "/x.png")
            ph4.change(.background) { $0.fog = 0.2 }
            ph4.change(.whole) { $0.masks = rm.masks; $0.heal = hp.heal }
            check(ph4.bg?.masks == rm.masks && ph4.bg?.heal == hp.heal, "masks and spots must carry into isolated regions")
            ph4.change(.whole) { $0.masks = nil; $0.heal = nil }
            check(ph4.bg?.masks == nil && ph4.bg?.heal == nil && ph4.bg?.fog == 0.2, "clearing them on the whole photo must clear them in regions")
            var ph5 = Photo(path: "/x.png")
            ph5.change(.background) { $0.fog = 0.3 }
            ph5.change(.whole) { $0.crop = [0.1, 0.1, 0.8, 0.8]; $0.rotate = 90; $0.heal = hp.heal; $0.masks = rm.masks; $0.exposure = 1 }
            ph5.setPreset(3, .whole)
            check(ph5.params.crop == [0.1, 0.1, 0.8, 0.8] && ph5.params.rotate == 90 && ph5.params.heal == hp.heal && ph5.params.masks == rm.masks
                  && ph5.params.exposure == nil, "a new preset must keep crop, heal and masks and replace the look")
            ph5.change(.background) { $0.fog = 0.3 }
            ph5.setPreset(1, .background)
            check(ph5.bg?.masks == rm.masks && ph5.bg?.heal == hp.heal, "a preset on a region must keep its heal and masks")
            ph5.setPreset(3, .whole, keepLocal: false)
            check(ph5.params.crop == nil && ph5.params.heal == nil && ph5.params.masks == nil, "Reset All must clear them")
            var tl = Timeline.whole(10)
            check(tl.split(at: 4) && !tl.split(at: 4.02) && tl.clips.count == 2 && tl.clips[1].start == 4, "split must cut the clip at the playhead")
            tl.clips[0].start = 1  // trim 1 s off the front, then put the second part first
            tl.clips.swapAt(0, 1)
            check(tl.duration == 9 && tl.locate(0.5)!.source == 4.5 && tl.locate(7)!.source == 2 && tl.position(ofSource: 2) == 7
                  && tl.position(ofSource: 0.5) == nil, "timeline must map its seconds to the source")
            check(isVideoFile(URL(fileURLWithPath: "/clip.MOV")) && isVideoFile(URL(fileURLWithPath: "/clip.mp4"))
                  && !isVideoFile(URL(fileURLWithPath: "/x.heic")), "videos must be told apart from photos")
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
            .defaultSize(width: 1400, height: 880)
    }
}

struct ContentView: View {
    @Environment(Library.self) private var library
    @State private var preview = Preview()
    @State private var selection = Set<UUID>()
    @State private var importing = false
    @State private var exportSheet = false
    @State private var exporting: String?
    @State private var alert: String?
    @State private var clipboard: EditState?  // Copy / Paste Edit Settings
    @State private var keyMonitor: Any?
    @AppStorage("singleView") private var single = false
    @AppStorage("minRating") private var minRating = 0

    private var current: Photo? { library.photos.first { selection.contains($0.id) } }
    private var shown: [Photo] { library.photos.filter { ($0.rating ?? 0) >= minRating } }
    /// What the preview depends on; while the crop box is being edited, moving it doesn't need a re-render.
    private var renderKey: [Params]? { current.map { $0.look.map { var q = $0; if preview.cropMode { q.crop = nil }; return q } } }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(shown) { PhotoRow(photo: $0).tag($0.id) }
            }
            .safeAreaInset(edge: .top) {
                Picker("Show", selection: $minRating) {
                    Text("All photos").tag(0)
                    ForEach(1...5, id: \.self) { Text(String(repeating: "★", count: $0) + ($0 < 5 ? " and up" : "")).tag($0) }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .help("Filter by star rating (press 1–5 to rate, 0 to clear)")
            }
            .contextMenu(forSelectionType: UUID.self) { ids in
                Button("Create Virtual Copy") { virtualCopy(ids) }
                Button("Copy Edit Settings") { copySettings(ids) }.disabled(ids.count != 1)
                Button("Paste Edit Settings") { paste(ids) }.disabled(clipboard == nil)
                Menu("Rating") {
                    ForEach(1...5, id: \.self) { r in Button(String(repeating: "★", count: r)) { rate(ids, r) } }
                    Button("No Rating") { rate(ids, 0) }
                }
                Divider()
                Button("Remove from Library") { remove(ids) }
            }
            .onDeleteCommand { remove(selection) }
            .navigationSplitViewColumnWidth(min: 190, ideal: 240)
        } detail: {
            if let photo = current {
                HStack(spacing: 0) {
                    Group {
                        if photo.isVideo { VideoWorkspace(photo: photo) { canvas(photo) } } else { canvas(photo) }
                    }
                    .id(photo.id)  // each photo opens fitted
                    Divider()
                    Inspector(id: photo.id, preview: preview).frame(width: 350).id(photo.id)
                }
            } else {
                ContentUnavailableView("Drop photos or videos here", systemImage: "photo.on.rectangle.angled",
                                       description: Text("Drag photos, videos or a folder into this window, or click +. Every edit is saved automatically."))
            }
        }
        .onDrop(of: [.fileURL, .image, .movie], isTargeted: nil) { providers in  // Finder files, or photos and videos dragged from Photos/Safari
            Task { @MainActor in add(await droppedFiles(providers)) }
            return true
        }
        .onOpenURL { add([$0]) }  // Finder's Open With, or a photo dropped on the Dock icon
        .fileImporter(isPresented: $importing, allowedContentTypes: [.image, .heic, .heif, .movie, .folder], allowsMultipleSelection: true) {
            if case .success(let urls) = $0 { add(urls) }
        }
        .sheet(isPresented: $exportSheet) {
            ExportSheet(count: selection.count, videos: library.photos.filter { selection.contains($0.id) && $0.isVideo }.count) { export($0) }
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
                Button { single.toggle() } label: {
                    Label(single ? "Before and After" : "After Only", systemImage: single ? "rectangle.split.2x1" : "rectangle")
                }
                .keyboardShortcut("b").help(single ? "Show before and after side by side (⌘B)" : "Show only the edit, larger (⌘B)")
                Button { importing = true } label: { Label("Add Photos or Videos", systemImage: "plus") }
                Button { exportSheet = true } label: { Label("Export", systemImage: "square.and.arrow.up") }
                    .disabled(selection.isEmpty || exporting != nil)
                    .help("Export the selected photos and videos")
            }
        }
        .background {  // keyboard shortcuts for the library
            Group {
                Button("") { if let id = selection.first { copySettings([id]) } }.keyboardShortcut("c", modifiers: [.command, .shift])
                Button("") { paste(selection) }.keyboardShortcut("v", modifiers: [.command, .shift])
                Button("") { virtualCopy(selection) }.keyboardShortcut("'")
            }
            .opacity(0)
        }
        .onChange(of: current?.id, initial: true) { preview.show(current) }
        .onChange(of: renderKey) { preview.show(current) }
        .onChange(of: current?.time) { preview.show(current) }  // another frame of a video
        .onAppear {
            if selection.isEmpty, let first = library.photos.first { selection = [first.id] }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in  // 0-5 rate, like Lightroom
                guard e.modifierFlags.intersection([.command, .option, .control]).isEmpty, let ch = e.characters, let r = Int(ch), (0...5).contains(r),
                      !(NSApp.keyWindow?.firstResponder is NSText), !selection.isEmpty else { return e }
                rate(selection, r)
                return nil
            }
        }
        .onDisappear { if let keyMonitor { NSEvent.removeMonitor(keyMonitor) } }
        .alert("FlashEdit", isPresented: Binding(get: { alert != nil }, set: { if !$0 { alert = nil } })) {} message: { Text(alert ?? "") }
    }

    private func canvas(_ photo: Photo) -> some View {
        CompareView(preview: preview, single: single, params: Binding(get: { current?.params ?? Params() }, set: { v in
            library.update(photo.id) { $0.change(.whole) { $0 = v } }
        }))
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

    private func virtualCopy(_ ids: Set<UUID>) {
        let made = library.photos.filter { ids.contains($0.id) }.compactMap { library.duplicate($0.id) }
        if !made.isEmpty { selection = Set(made) }
    }

    private func copySettings(_ ids: Set<UUID>) { clipboard = library.photos.first { ids.contains($0.id) }?.state }

    private func paste(_ ids: Set<UUID>) {
        guard let clipboard else { return }
        for id in ids { library.update(id) { $0.state = clipboard } }
    }

    private func rate(_ ids: Set<UUID>, _ r: Int) {
        for id in ids { library.update(id) { $0.rating = r == 0 ? nil : r } }
    }

    private func export(_ s: ExportSettings) {
        let panel = NSOpenPanel()
        (panel.canChooseDirectories, panel.canChooseFiles, panel.prompt) = (true, false, "Export Here")
        guard panel.runModal() == .OK, let dir = panel.url else { return }
        let items = library.photos.filter { selection.contains($0.id) }
        Task {
            var failed = [String](), used = Set<String>()
            for (k, p) in items.enumerated() {
                exporting = "Exporting \(k + 1) of \(items.count)"
                let ext = p.isVideo ? "mov" : s.format != "original" ? s.format : ["heic", "heif"].contains(p.url.pathExtension.lowercased()) ? "heic" : "jpg"
                var base = p.url.deletingPathExtension().lastPathComponent + (p.label.map { "_" + $0.replacingOccurrences(of: " ", with: "").lowercased() } ?? "") + s.suffix
                while used.contains(base) { base += "_2" }  // two copies of one file never overwrite each other
                used.insert(base)
                let dst = dir.appending(path: "\(base).\(ext)")
                do {
                    if p.isVideo {  // every frame through the pipeline: minutes, not seconds, so it reports how far it is
                        let label = "Exporting \(k + 1) of \(items.count)"
                        try await Task.detached(priority: .userInitiated) {
                            try exportVideo(p, to: dst, longEdge: s.longEdge, hevc: s.videoCodec == "hevc", metadata: s.keepMetadata) { f in
                                Task { @MainActor in if exporting != nil { exporting = "\(label) · \(Int(f * 100))%" } }
                            }
                        }.value
                    } else {
                        try await Task.detached(priority: .userInitiated) {
                            let cg = try render(p.url, bg: p.params(for: .background), fg: p.params(for: .person), whole: p.params).0
                            try save(resized(cg, longEdge: s.longEdge), to: dst, quality: s.quality, metadataFrom: s.keepMetadata ? p.url : nil)
                        }.value
                    }
                } catch { failed.append("\(p.displayName): \(error.localizedDescription)") }
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
            .overlay(alignment: .bottomTrailing) {
                if photo.isVideo { Image(systemName: "video.fill").font(.system(size: 9)).foregroundStyle(.white).shadow(radius: 1).padding(3) }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(photo.displayName).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(photo.isEdited ? "\(photo.presetName), edited" : photo.presetName).foregroundStyle(.secondary)
                    if let r = photo.rating { Text(String(repeating: "★", count: r)).foregroundStyle(.yellow) }
                }
                .font(.caption)
            }
        }
        .task(id: "\(photo.path) \(photo.time ?? 0)") {
            let (u, t) = (photo.url, photo.time ?? 0)
            thumb = await Task.detached { loadImage(u, maxSide: 128, at: t) }.value
        }
    }
}
