// The right-hand panel: histogram, then Edit (presets and every adjustment), Crop, Heal, Masks and Chat.
import AppKit
import SwiftUI

enum InspectorTab: String, CaseIterable { case edit = "Edit", crop = "Crop", heal = "Heal", masks = "Masks", chat = "Chat" }

/// Everything here writes straight into the library, so it is saved as you go.
struct Inspector: View {
    let id: UUID
    let preview: Preview
    @Environment(Library.self) private var library
    @State private var region = Region.whole
    @AppStorage("inspectorTab") private var tab = InspectorTab.edit

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                HistogramView(bins: preview.histogram)
                Text(preview.info.isEmpty ? " " : preview.info).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                Picker("Panel", selection: $tab) { ForEach(InspectorTab.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden()
            }
            .padding(.horizontal, 14).padding(.top, 12).padding(.bottom, 4)
            switch tab {
            case .edit: Adjustments(photo: binding, region: $region, preview: preview)
            case .crop: CropPanel(photo: binding, preview: preview) { tab = .edit }
            case .heal: HealPanel(photo: binding, preview: preview)
            case .masks: MasksPanel(photo: binding, preview: preview)
            case .chat: ChatPanel(id: id, region: region, preview: preview)
            }
        }
        .onChange(of: tab, initial: true) { preview.cropMode = tab == .crop; preview.tool = tab }
        .onAppear { (preview.selectedSpot, preview.selectedMask) = (nil, nil) }  // a new photo: its own spots and masks
        .onDisappear { preview.cropMode = false }
    }

    private var binding: Binding<Photo> {
        Binding(get: { library.photos.first { $0.id == id } ?? Photo(path: "") }, set: { p in library.update(id) { $0 = p } })
    }
}

// MARK: - Edit

struct Adjustments: View {
    @Binding var photo: Photo
    @Binding var region: Region
    let preview: Preview
    @State private var naming = false
    @State private var query = ""
    @State private var channel = 0  // Color Mixer: 0 hue, 1 saturation, 2 luminance
    @State private var curveChannel = 0  // 0 RGB, 1 red, 2 green, 3 blue
    @AppStorage("expandedSections") private var expanded = "Flash Look,Light"
    @AppStorage("inspectorTab") private var tab = InspectorTab.edit
    @FocusState private var searchFocused: Bool
    private let presets = Presets.shared

    private struct Row: Identifiable { let id: String, section: String, search: String, view: AnyView }
    private static let sections = ["Preset", "Flash Look", "Light", "Presence", "White Balance", "Tone Curve", "Color Mixer",
                                   "Color Grading", "Skin", "Blur", "Detail", "Effects", "Local Edits"]
    private static let bands = ["Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Purple", "Magenta"]
    private static let channels: [(name: String, keys: String, kp: WritableKeyPath<Params, [Double]?>)] = [
        ("Hue", "hue shift", \.hsl_hue), ("Saturation", "saturation sat vibrance", \.hsl_sat), ("Luminance", "luminance lightness brightness", \.hsl_lum)]
    private static let curves: [(name: String, color: Color, kp: WritableKeyPath<Params, [Double]?>)] = [
        ("RGB", .white, \.curve), ("Red", .red, \.curve_r), ("Green", .green, \.curve_g), ("Blue", .blue, \.curve_b)]
    private static let blurKinds: [(BlurKind, String)] = [(.lens, "Lens (bokeh)"), (.gaussian, "Gaussian"), (.motion, "Motion"),
                                                          (.zoom, "Zoom"), (.tiltshift, "Tilt-shift")]

    private var p: Params { photo.params(for: region) }
    /// The saved preset this photo (or the isolated region) is on, if any.
    private var myPreset: Int? {
        region == .whole ? (presets.user.contains { $0.id == photo.preset } ? photo.preset : nil)
            : presets.user.first { presets.params($0.id, for: region).look == p.look }?.id
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Form {
                lookSection
                let rows = self.rows
                if rows.isEmpty { Text("No adjustments match “\(query)”").foregroundStyle(.secondary) }
                ForEach(Self.sections, id: \.self) { sec in
                    let rs = rows.filter { $0.section == sec }
                    if !rs.isEmpty {
                        let open = !query.isEmpty || isOpen(sec)
                        Section {  // one box per panel; its title row folds it, like Lightroom's panels
                            Button { toggle(sec) } label: {
                                HStack(spacing: 6) {
                                    Text(sec).font(.headline)
                                    if edited(sec) { Circle().fill(Color.accentColor).frame(width: 6, height: 6).help("Has edits") }
                                    Spacer()
                                    Image(systemName: open ? "chevron.down" : "chevron.right").font(.caption).foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            if open { ForEach(rs) { $0.view } }
                        }
                    }
                }
            }
            .formStyle(.grouped)
        }
        .sheet(isPresented: $naming) {
            SavePresetSheet(existing: presets.user.map(\.name)) { name in
                let s = photo.state  // the whole look, Isolate edits included
                photo.preset = presets.save(name, s)  // the photo is now on its new preset
            }
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
        .padding(.horizontal, 14).padding(.top, 8)
        .background(Button("") { searchFocused = true }.keyboardShortcut("f").opacity(0))
    }

    /// Isolate, presets, strength: always on top (only Isolate while searching).
    private var lookSection: some View {
        Section {
            Picker("Isolate", selection: $region) { ForEach(Region.allCases, id: \.self) { Text($0.rawValue) } }
                .pickerStyle(.segmented)
            if region != .whole {
                Text("Changes affect only the \(region.rawValue.lowercased()).").font(.caption).foregroundStyle(.secondary)
            }
            if query.isEmpty {
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
                    Button("Save as Preset…") { naming = true }.help("Save this photo's current look as a named preset")
                }
                if p.look != Params() {
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
                    Button("Reset All to \(photo.presetName)") { photo.setPreset(photo.preset, .whole) }.disabled(!photo.isEdited)
                } else {
                    Button("Match Whole Photo") { if region == .background { photo.bg = nil } else { photo.fg = nil } }
                        .disabled((region == .background ? photo.bg : photo.fg) == nil)
                }
            }
        }
    }

    // MARK: rows

    /// Every adjustment, with words to search by. Search shows the rows containing all typed words.
    private var rows: [Row] {
        var out: [Row] = []
        func add(_ sec: String, _ title: String, _ keys: String, _ v: Binding<Double>, _ range: ClosedRange<Double>,
                 _ only: Region? = nil, digits: Int = 2, swatch: Color? = nil) {
            out.append(Row(id: "\(sec)/\(title)", section: sec, search: "\(sec) \(title) \(keys)".lowercased(),
                           view: AnyView(knob(title, v, range, only, digits: digits, swatch: swatch))))
        }
        func custom(_ sec: String, _ id: String, _ keys: String, _ view: some View) {
            out.append(Row(id: "\(sec)/\(id)", section: sec, search: "\(sec) \(keys)".lowercased(), view: AnyView(view)))
        }
        let browsing = query.isEmpty

        if !browsing {  // Strength sits with the presets, which are hidden while searching
            add("Preset", "Strength", "amount opacity intensity look",
                Binding(get: { p.strength ?? 1 }, set: { v in photo.change(region) { $0.strength = v } }), 0...1)
        }
        // Flash Look: the app's own look
        add("Flash Look", "Background", "ambient brightness exposure curve", curveTotal(\.ambient), 0.2...1.3, .background)
        add("Flash Look", "Person (flash)", "subject brightness exposure curve", curveTotal(\.flash), 0.2...1.3, .person)
        add("Flash Look", "Flash spill", "glow light", value(\.spill), 0...0.6, .background)
        add("Flash Look", "Shine", "glow highlights", value(\.shine), 0...0.6, .person)
        add("Flash Look", "Neutral whites", "white balance", value(\.white), 0...1, .person)
        add("Flash Look", "Person clarity", "detail sharpness texture contrast", value(\.clarity), 0...2, .person)
        add("Flash Look", "Hair (warm darks)", "brown dark", value(\.warm_ev), -3...1, .person)
        // Light
        custom("Light", "auto", "auto tone exposure", HStack {
            Button("Auto") { autoLight() }.help("Balance exposure and tonal range automatically")
            Spacer()
            Button("Reset Light") { photo.change(region) { ($0.exposure, $0.contrast, $0.highlights, $0.shadows, $0.whites, $0.blacks) = (nil, nil, nil, nil, nil, nil) } }
                .disabled(!edited("Light"))
        })
        add("Light", "Exposure", "brightness stops ev", opt(\.exposure, snap: 0.03, step: 0.01), -5...5)
        add("Light", "Contrast", "", opt(\.contrast), -100...100, digits: 0)
        add("Light", "Highlights", "bright recover", opt(\.highlights), -100...100, digits: 0)
        add("Light", "Shadows", "dark lift", opt(\.shadows), -100...100, digits: 0)
        add("Light", "Whites", "white point", opt(\.whites), -100...100, digits: 0)
        add("Light", "Blacks", "black point", opt(\.blacks), -100...100, digits: 0)
        // Presence
        add("Presence", "Texture", "detail fine skin", opt(\.texture), -100...100, digits: 0)
        add("Presence", "Clarity", "midtone contrast punch", opt(\.clarity_all), -100...100, digits: 0)
        add("Presence", "Dehaze", "haze clear", value(\.omega), 0...0.95)
        add("Presence", "Vibrance", "colour color muted", opt(\.vibrance), -100...100, digits: 0)
        add("Presence", "Saturation", "colour color sat", opt(\.saturation), -100...100, digits: 0)
        // White balance, per side of the flash
        add("White Balance", "Background temp", "temperature warmth colour color", value(\.temp_ambient), -0.2...0.2, .background)
        add("White Balance", "Background tint", "green magenta colour color", value(\.tint_ambient), -0.2...0.2, .background)
        add("White Balance", "Background sat", "saturation colour color", value(\.sat_ambient), 0.5...1.6, .background)
        add("White Balance", "Person temp", "temperature warmth colour color", value(\.temp_flash), -0.2...0.2, .person)
        add("White Balance", "Person tint", "green magenta colour color", value(\.tint_flash), -0.2...0.2, .person)
        add("White Balance", "Person sat", "saturation colour color", value(\.sat_flash), 0.5...1.6, .person)
        // Tone curve
        let curve = Self.curves[curveChannel]
        custom("Tone Curve", "editor", "curve rgb red green blue points s-curve contrast graph", VStack(alignment: .leading, spacing: 8) {
            Picker("Channel", selection: $curveChannel) { ForEach(0..<4, id: \.self) { Text(Self.curves[$0].name).tag($0) } }
                .pickerStyle(.segmented).labelsHidden()
            CurveEditor(points: Binding(get: { p[keyPath: curve.kp] }, set: { v in photo.change(region) { $0[keyPath: curve.kp] = v } }),
                        color: curve.color, histogram: preview.histogram.count == 4 ? preview.histogram[curveChannel == 0 ? 3 : curveChannel - 1] : [])
                .frame(height: 230)
            HStack {
                Text("Click to add a point, drag to move, double-click to remove.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Reset") { photo.change(region) { ($0.curve, $0.curve_r, $0.curve_g, $0.curve_b) = (nil, nil, nil, nil) } }
                    .disabled(!edited("Tone Curve"))
            }
        })
        // Color mixer
        if browsing {
            custom("Color Mixer", "channel", "", Picker("Adjust", selection: $channel) {
                ForEach(0..<3, id: \.self) { Text(Self.channels[$0].name).tag($0) }
            }.pickerStyle(.segmented))
        }
        for (c, name) in Self.bands.enumerated() {
            for (k, ch) in Self.channels.enumerated() where !browsing || k == channel {
                add("Color Mixer", browsing ? name : "\(name) \(ch.name.lowercased())", "\(ch.keys) hsl colour color", mixer(ch.kp, c),
                    -100...100, digits: 0, swatch: Color(hue: Double(mixerHues[c]) / 360, saturation: 0.75, brightness: 0.95))
            }
        }
        if browsing {
            custom("Color Mixer", "reset", "", Button("Reset Color Mixer") { photo.change(region) { ($0.hsl_hue, $0.hsl_sat, $0.hsl_lum) = (nil, nil, nil) } }
                .disabled(!edited("Color Mixer")))
        }
        // Color grading
        custom("Color Grading", "wheels", "grading split toning shadows midtones highlights wheel hue tint teal orange", HStack(alignment: .top) {
            ColorWheel(title: "Shadows", value: grade(\.grade_shadows))
            ColorWheel(title: "Midtones", value: grade(\.grade_midtones))
            ColorWheel(title: "Highlights", value: grade(\.grade_highlights))
        })
        add("Color Grading", "Balance", "split shadows highlights", opt(\.grade_balance), -100...100, digits: 0)
        // Skin
        add("Skin", "Face brightness", "lightness", value(\.skin_L), -10...15, .person)
        add("Skin", "Face pink", "redness", value(\.skin_a), -6...6, .person)
        add("Skin", "Face yellow", "warmth", value(\.skin_b), -6...6, .person)
        add("Skin", "Body brightness", "hands arms neck lightness",
            Binding(get: { p.body_L ?? p.skin_L }, set: { v in photo.change(region) { $0.body_L = v } }), -10...15, .person)
        add("Skin", "Face contrast", "shading shadows", value(\.skin_contrast), 0.5...1.5, .person)
        add("Skin", "Plastic shine", "gloss glossy matte smooth waxy", opt(\.plastic), -100...100, .person, digits: 0)
        add("Skin", "Pink lips", "lip mouth nude", opt(\.lips), -100...100, .person, digits: 0)
        // Blur
        let kind = BlurKind(rawValue: p.blur_type ?? "lens") ?? .lens
        custom("Blur", "type", "blur type lens bokeh gaussian motion zoom tilt shift portrait background depth",
               Picker("Type", selection: Binding(get: { kind }, set: { k in photo.change(region) { $0.blur_type = k.rawValue } })) {
                   ForEach(Self.blurKinds, id: \.0) { Text($0.1).tag($0.0) }
               }.disabled(region == .person))
        add("Blur", "Amount", "background portrait depth", opt(\.blur), 0...100, .background, digits: 0)
        switch kind {
        case .lens: add("Blur", "Bokeh", "highlights discs lights", opt(\.blur_bokeh, off: 30), 0...100, .background, digits: 0)
        case .motion: add("Blur", "Angle", "direction streak", opt(\.blur_angle, snap: 0.5), -90...90, .background, digits: 0)
        case .tiltshift: add("Blur", "Focus height", "band sharp", Binding(get: { p.blur_focus ?? 0.5 },
                                                                         set: { v in photo.change(region) { $0.blur_focus = v } }), 0...1, .background)
        default: break
        }
        // Detail
        add("Detail", "Sharpening", "sharpen sharp crisp", opt(\.sharpen), 0...150, digits: 0)
        add("Detail", "Radius", "sharpen", opt(\.sharpen_radius, off: 1, snap: 0.02, step: 0.1), 0.5...3, digits: 1)
        add("Detail", "Masking", "sharpen edges", opt(\.sharpen_masking), 0...100, digits: 0)
        add("Detail", "Noise reduction", "denoise grain luminance smooth", opt(\.denoise), 0...100, digits: 0)
        add("Detail", "Color noise", "denoise chroma colour", opt(\.denoise_color), 0...100, digits: 0)
        // Effects
        add("Effects", "Vignette", "corners dark edges", opt(\.vignette), -100...100, digits: 0)
        add("Effects", "Midpoint", "vignette size", opt(\.vignette_midpoint, off: 50), 0...100, digits: 0)
        add("Effects", "Feather", "vignette soft", opt(\.vignette_feather, off: 50), 0...100, digits: 0)
        add("Effects", "Roundness", "vignette shape", opt(\.vignette_roundness), -100...100, digits: 0)
        add("Effects", "Grain", "film noise", opt(\.grain), 0...100, digits: 0)
        add("Effects", "Grain size", "film", opt(\.grain_size, off: 25), 0...100, digits: 0)
        add("Effects", "Fog", "mist haze amount", value(\.fog), 0...0.9, .background)
        add("Effects", "Fog start", "mist height", value(\.fog_start), 0...1, .background)
        add("Effects", "Fog falloff", "mist gamma", value(\.fog_gamma), 0.3...3, .background)
        custom("Effects", "fogcolor", "fog mist color colour", ColorPicker("Fog color", selection: fogColor, supportsOpacity: false).disabled(region == .person))
        // Local edits live in their own tabs, since they're drawn on the photo
        let spots = photo.params.heal?.count ?? 0, masks = photo.params.masks?.count ?? 0
        custom("Local Edits", "heal", "heal healing spot removal blemish clone remove retouch", LabeledContent("Heal") {
            Button(spots == 0 ? "Remove Spots…" : "\(spots) spot\(spots == 1 ? "" : "s")…") { tab = .heal }
        })
        custom("Local Edits", "masks", "masks mask local brush gradient linear radial graduated filter adjustment", LabeledContent("Masks") {
            Button(masks == 0 ? "Add a Mask…" : "\(masks) mask\(masks == 1 ? "" : "s")…") { tab = .masks }
        })

        let words = query.lowercased().split(separator: " ")
        return out.filter { r in words.allSatisfy { r.search.contains($0) } }
    }

    // MARK: sections

    private func isOpen(_ sec: String) -> Bool { sec == "Preset" || expanded.split(separator: ",").contains { $0 == sec } }

    private func toggle(_ sec: String) {
        var s = Set(expanded.split(separator: ",").map(String.init))
        if s.contains(sec) { s.remove(sec) } else { s.insert(sec) }
        expanded = s.sorted().joined(separator: ",")
    }

    /// A dot on a section's header when it holds edits (handy when it's folded).
    private func edited(_ sec: String) -> Bool {
        let q = p.look, z = Params()
        switch sec {
        case "Flash Look": return q.ambient != z.ambient || q.flash != z.flash || q.spill != 0 || q.shine != 0 || q.white != 0 || q.clarity != 0 || q.warm_ev != 0
        case "Light": return [q.exposure, q.contrast, q.highlights, q.shadows, q.whites, q.blacks].contains { $0 != nil }
        case "Presence": return [q.texture, q.clarity_all, q.vibrance, q.saturation].contains { $0 != nil } || q.omega != 0
        case "White Balance": return q.temp_ambient != 0 || q.tint_ambient != 0 || q.sat_ambient != 1 || q.temp_flash != 0 || q.tint_flash != 0 || q.sat_flash != 1
        case "Tone Curve": return [q.curve, q.curve_r, q.curve_g, q.curve_b].contains { $0 != nil }
        case "Color Mixer": return q.hsl_hue != nil || q.hsl_sat != nil || q.hsl_lum != nil
        case "Color Grading": return q.grade_shadows != nil || q.grade_midtones != nil || q.grade_highlights != nil
        case "Skin": return q.skin_L != 0 || q.skin_a != 0 || q.skin_b != 0 || q.body_L != nil || q.skin_contrast != 1 || q.plastic != nil || q.lips != nil
        case "Blur": return q.blur != nil
        case "Detail": return q.sharpen != nil || q.denoise != nil || q.denoise_color != nil
        case "Effects": return q.vignette != nil || q.grain != nil || q.fog != 0
        case "Local Edits": return q.heal != nil || q.masks != nil
        default: return false
        }
    }

    // MARK: controls

    /// `only`: the region a slider acts on, so it greys out while the other region is isolated.
    private func knob(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, _ only: Region? = nil,
                      digits: Int = 2, swatch: Color? = nil) -> some View {
        ValueSlider(title: title, value: value, range: range, digits: digits, swatch: swatch)
            .disabled(only != nil && region != .whole && region != only)
    }

    /// Optional knobs: values within `snap` of `off` are stored as nil (off); others are rounded to `step`.
    private func opt(_ kp: WritableKeyPath<Params, Double?>, off: Double = 0, snap: Double = 2, step: Double = 1) -> Binding<Double> {
        Binding(get: { p[keyPath: kp] ?? off }, set: { v in
            photo.change(region) { $0[keyPath: kp] = abs(v - off) < snap ? nil : (v / step).rounded() * step }
        })
    }

    private func value(_ kp: WritableKeyPath<Params, Double>) -> Binding<Double> {
        Binding(get: { p[keyPath: kp] }, set: { v in photo.change(region) { $0[keyPath: kp] = v } })
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

    /// A grading wheel's [hue, saturation, luminance]; no colour and no brightness change is stored as nil.
    private func grade(_ kp: WritableKeyPath<Params, [Double]?>) -> Binding<[Double]?> {
        Binding(get: { p[keyPath: kp] }, set: { v in
            photo.change(region) { $0[keyPath: kp] = v.flatMap { $0[1] < 1 && abs($0[2]) < 2 ? nil : $0 } }
        })
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

    /// Lightroom's Auto: measured on the current result, added to the current Light settings.
    private func autoLight() {
        guard let x = preview.afterRGB else { return }
        let a = autoTone(x)
        func add(_ v: Double?, _ d: Double, _ lo: Double, _ hi: Double, step: Double = 1) -> Double? {
            let n = (((v ?? 0) + d) / step).rounded() * step
            return abs(n) < step ? nil : n.clamped(lo, hi)
        }
        photo.change(region) {
            $0.exposure = add($0.exposure, a.exposure, -5, 5, step: 0.01)
            $0.contrast = add($0.contrast, a.contrast, -100, 100)
            $0.highlights = add($0.highlights, a.highlights, -100, 100)
            $0.shadows = add($0.shadows, a.shadows, -100, 100)
            $0.whites = add($0.whites, a.whites, -100, 100)
            $0.blacks = add($0.blacks, a.blacks, -100, 100)
        }
    }
}

/// A labelled slider with its value, as every adjustment shows it.
struct ValueSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var digits = 2
    var swatch: Color?

    var body: some View {
        LabeledContent {
            HStack {
                Slider(value: $value, in: range)
                Text(value, format: .number.precision(.fractionLength(digits))).monospacedDigit()
                    .foregroundStyle(.secondary).frame(width: 38, alignment: .trailing)
            }
        } label: {
            HStack(spacing: 6) {
                if let swatch { Circle().fill(swatch).frame(width: 9, height: 9) }
                Text(title)
            }
        }
    }
}

/// A point curve over the histogram. Click adds a point on the curve, drag moves it, double-click removes it.
struct CurveEditor: View {
    @Binding var points: [Double]?  // x0, y0, x1, y1, ... in 0...1
    let color: Color
    let histogram: [Float]
    @State private var dragging: Int?

    private var pts: [CGPoint] {
        let f = points ?? [0, 0, 1, 1]
        return stride(from: 0, to: f.count - 1, by: 2).map { CGPoint(x: f[$0], y: f[$0 + 1]) }
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            Canvas { ctx, s in
                if histogram.count == 256 {
                    var h = Path()
                    h.move(to: CGPoint(x: 0, y: s.height))
                    for i in 0..<256 { h.addLine(to: CGPoint(x: s.width * CGFloat(i) / 255, y: s.height * (1 - CGFloat(histogram[i]) * 0.9))) }
                    h.addLine(to: CGPoint(x: s.width, y: s.height))
                    ctx.fill(h, with: .color(.secondary.opacity(0.2)))
                }
                var grid = Path()
                for k in 1..<4 {
                    let t = CGFloat(k) / 4
                    grid.move(to: CGPoint(x: t * s.width, y: 0)); grid.addLine(to: CGPoint(x: t * s.width, y: s.height))
                    grid.move(to: CGPoint(x: 0, y: t * s.height)); grid.addLine(to: CGPoint(x: s.width, y: t * s.height))
                }
                grid.move(to: CGPoint(x: 0, y: s.height)); grid.addLine(to: CGPoint(x: s.width, y: 0))
                ctx.stroke(grid, with: .color(.secondary.opacity(0.3)), lineWidth: 0.5)
                let lut = PointCurve(points)
                var c = Path()
                for i in 0...120 {
                    let x = Double(i) / 120, y = lut.map { Double($0(Float(x))) } ?? x
                    let pt = CGPoint(x: x * s.width, y: (1 - y) * s.height)
                    i == 0 ? c.move(to: pt) : c.addLine(to: pt)
                }
                ctx.stroke(c, with: .color(color), lineWidth: 2)
                for p in pts {
                    let r = CGRect(x: p.x * s.width - 5, y: (1 - p.y) * s.height - 5, width: 10, height: 10)
                    ctx.fill(Path(ellipseIn: r), with: .color(.white))
                    ctx.stroke(Path(ellipseIn: r), with: .color(color), lineWidth: 1.5)
                }
            }
            .background(Color.black.opacity(0.25), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in
                    var p = pts
                    if dragging == nil {
                        if let hit = nearest(p, v.startLocation, size) { dragging = hit } else {
                            // a new point, placed on the curve so a plain click doesn't change it
                            let x = Double(min(max(v.startLocation.x / size.width, 0), 1))
                            let y = PointCurve(points).map { Double($0(Float(x))) } ?? x
                            p.append(CGPoint(x: x, y: y)); p.sort { $0.x < $1.x }
                            dragging = p.firstIndex { $0.x == x }
                            points = flat(p)
                        }
                    }
                    guard let k = dragging, hypot(v.translation.width, v.translation.height) > 2 else { return }
                    let lo = k > 0 ? p[k - 1].x + 0.01 : 0, hi = k < p.count - 1 ? p[k + 1].x - 0.01 : 1
                    p[k] = CGPoint(x: min(max(v.location.x / size.width, lo), hi), y: min(max(1 - v.location.y / size.height, 0), 1))
                    points = flat(p)
                }
                .onEnded { _ in dragging = nil })
            .simultaneousGesture(SpatialTapGesture(count: 2).onEnded { v in
                var p = pts
                if let hit = nearest(p, v.location, size), hit != 0, hit != p.count - 1 { p.remove(at: hit); points = flat(p) }
            })
        }
    }

    private func nearest(_ p: [CGPoint], _ at: CGPoint, _ size: CGSize) -> Int? {
        p.indices.filter { hypot(p[$0].x * size.width - at.x, (1 - p[$0].y) * size.height - at.y) < 12 }
            .min { hypot(p[$0].x * size.width - at.x, (1 - p[$0].y) * size.height - at.y) < hypot(p[$1].x * size.width - at.x, (1 - p[$1].y) * size.height - at.y) }
    }

    private func flat(_ p: [CGPoint]) -> [Double]? {
        let f = p.flatMap { [Double($0.x), Double($0.y)] }
        return f == [0, 0, 1, 1] ? nil : f
    }
}

/// A colour wheel: angle is hue, distance from the centre is saturation; the slider below is luminance.
/// Double-click the wheel to clear it.
struct ColorWheel: View {
    let title: String
    @Binding var value: [Double]?  // [hue 0...360, saturation 0...100, luminance -100...100]

    var body: some View {
        let v = value ?? [0, 0, 0]
        VStack(spacing: 6) {
            GeometryReader { geo in
                let d = min(geo.size.width, geo.size.height), r = d / 2, c = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
                let a = v[0] * .pi / 180, k = v[1] / 100 * Double(r - 6)
                ZStack {
                    Circle().fill(AngularGradient(colors: (0...12).map { Color(hue: Double($0) / 12, saturation: 0.9, brightness: 1) }, center: .center))
                    Circle().fill(RadialGradient(colors: [.white, .white.opacity(0)], center: .center, startRadius: 0, endRadius: r))
                    Circle().stroke(Color.black.opacity(0.35), lineWidth: 1)
                    Circle().fill(Color(hue: v[0] / 360, saturation: v[1] / 100, brightness: 1)).frame(width: 12, height: 12)
                        .overlay(Circle().stroke(Color.black.opacity(0.6), lineWidth: 1.5))
                        .position(x: r + CGFloat(cos(a) * k), y: r + CGFloat(sin(a) * k))
                }
                .frame(width: d, height: d)
                .position(c)
                .contentShape(Circle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                    let dx = Double(g.location.x - c.x), dy = Double(g.location.y - c.y)
                    let hue = (atan2(dy, dx) * 180 / Double.pi + 360).truncatingRemainder(dividingBy: 360)
                    value = [hue.rounded(), (min(1, hypot(dx, dy) / Double(r - 6)) * 100).rounded(), v[2]]
                })
                .simultaneousGesture(TapGesture(count: 2).onEnded { value = nil })
            }
            .frame(height: 78)
            Text(title).font(.caption)
            Slider(value: Binding(get: { v[2] }, set: { value = [v[0], v[1], abs($0) < 2 ? 0 : $0.rounded()] }), in: -100...100)
                .controlSize(.mini)
                .help("\(title) luminance")
        }
        .help("Drag to tint the \(title.lowercased()); double-click to clear")
    }
}

// MARK: - Crop

struct CropPanel: View {
    @Binding var photo: Photo
    let preview: Preview
    let done: () -> Void
    @State private var aspectName = "Free"
    private static let aspects: [(name: String, ratio: Double?)] = [("Free", nil), ("Original", 0), ("1 : 1", 1), ("4 : 5", 0.8), ("5 : 4", 1.25),
                                                                     ("3 : 2", 1.5), ("2 : 3", 2.0 / 3), ("16 : 9", 16.0 / 9), ("9 : 16", 9.0 / 16)]

    private var frameAspect: Double {  // width / height of the frame after quarter turns
        let w = Double(preview.original.width), h = Double(preview.original.height)
        return Int(((photo.params.rotate ?? 0) / 90).rounded()) % 2 == 0 ? w / max(h, 1) : h / max(w, 1)
    }

    var body: some View {
        Form {
            Section("Aspect ratio") {
                Picker("Aspect", selection: $aspectName) { ForEach(Self.aspects, id: \.name) { Text($0.name).tag($0.name) } }
                Text("Drag the box on the photo to move it; drag a corner to resize.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Straighten") {
                LabeledContent("Angle") {
                    HStack {
                        Slider(value: Binding(get: { photo.params.straighten ?? 0 },
                                              set: { v in photo.change(.whole) { $0.straighten = abs(v) < 0.1 ? nil : (v * 10).rounded() / 10 } }), in: -45...45)
                        Text(String(format: "%.1f°", photo.params.straighten ?? 0)).monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
                    }
                }
            }
            Section("Rotate and flip") {
                HStack {
                    Button { turn(-90) } label: { Label("Left", systemImage: "rotate.left") }
                    Button { turn(90) } label: { Label("Right", systemImage: "rotate.right") }
                    Button { photo.change(.whole) { $0.flip = ($0.flip ?? 0) != 0 ? nil : 1 } } label: {
                        Label("Flip", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                    }
                }
            }
            Section {
                HStack {
                    Button("Reset") { aspectName = "Free"; photo.change(.whole) { ($0.crop, $0.straighten, $0.rotate, $0.flip) = (nil, nil, nil, nil) } }
                        .disabled(!photo.params.hasGeometry)
                    Spacer()
                    Button("Done", action: done).keyboardShortcut(.defaultAction)
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: aspectName) { applyAspect() }
    }

    private func turn(_ deg: Double) {
        photo.change(.whole) {
            let r = (($0.rotate ?? 0) + deg + 360).truncatingRemainder(dividingBy: 360)
            $0.rotate = r == 0 ? nil : r
            $0.crop = nil  // the old box doesn't fit the turned frame
        }
        applyAspect()
    }

    /// Locks the box to the ratio and sets it to the largest centred box of that shape.
    private func applyAspect() {
        guard let entry = Self.aspects.first(where: { $0.name == aspectName }), let ratio = entry.ratio else { preview.cropAspect = nil; return }
        let target = ratio == 0 ? frameAspect : ratio, rel = target / frameAspect
        let (w, h) = rel >= 1 ? (1.0, 1 / rel) : (rel, 1.0)
        preview.cropAspect = target
        photo.change(.whole) { $0.crop = w > 0.999 && h > 0.999 ? nil : [(1 - w) / 2, (1 - h) / 2, w, h] }
    }
}

// MARK: - Heal

/// Spot removal. The spots are drawn and edited on the photo (HealOverlay); this panel sets the size and clears them.
/// Spots are whole-photo edits, like the crop, and apply to both Isolate regions.
struct HealPanel: View {
    @Binding var photo: Photo
    @Bindable var preview: Preview

    private var spots: [[Double]] { photo.params.heal ?? [] }
    private var selected: Int? { preview.selectedSpot.flatMap { spots.indices.contains($0) ? $0 : nil } }

    var body: some View {
        Form {
            Section {
                Text("Click a blemish to heal it, or drag over a longer one. Each spot copies a nearby patch and matches it to its surroundings. Drag a circle to move it, or its dashed source to copy from somewhere else. Hold Space to pan.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                ValueSlider(title: selected == nil ? "Brush size" : "Spot size", value: Binding(get: { (selected.map { spots[$0][2] } ?? preview.brushSize) * 100 }, set: { v in
                    preview.brushSize = (v * 10).rounded() / 1000
                    if let i = selected { photo.change(.whole) { $0.heal?[i][2] = preview.brushSize } }
                }), range: 0.5...15, digits: 1)
            }
            Section {
                LabeledContent("Spots", value: "\(spots.count)")
                HStack {
                    Button("Delete Spot") {
                        if let i = selected { photo.change(.whole) { $0.heal?.remove(at: i); if $0.heal?.isEmpty == true { $0.heal = nil } } }
                        preview.selectedSpot = nil
                    }
                    .disabled(selected == nil)
                    Spacer()
                    Button("Clear All") { photo.change(.whole) { $0.heal = nil }; preview.selectedSpot = nil }.disabled(spots.isEmpty)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Masks

/// Local adjustments. Shapes are drawn on the photo (MaskOverlay); each mask has its own light and colour settings.
/// Masks are whole-photo edits, like the crop, and apply to both Isolate regions.
struct MasksPanel: View {
    @Binding var photo: Photo
    @Bindable var preview: Preview

    private static let settings: [(name: String, kp: WritableKeyPath<LocalMask, Double?>, range: ClosedRange<Double>)] = [
        ("Exposure", \.exposure, -4...4), ("Contrast", \.contrast, -100...100), ("Highlights", \.highlights, -100...100),
        ("Shadows", \.shadows, -100...100), ("Temp", \.temp, -100...100), ("Tint", \.tint, -100...100),
        ("Saturation", \.saturation, -100...100), ("Clarity", \.clarity, -100...100), ("Sharpness", \.sharpness, -100...100)]
    private static let icons: [MaskKind: String] = [.brush: "paintbrush.pointed", .linear: "square.tophalf.filled", .radial: "circle.dashed"]

    private var masks: [LocalMask] { photo.params.masks ?? [] }
    private var selected: Int? { preview.selectedMask.flatMap { masks.indices.contains($0) ? $0 : nil } }

    var body: some View {
        Form {
            Section {
                HStack {
                    ForEach(MaskKind.allCases, id: \.self) { k in
                        Button { add(k) } label: { Label(k.rawValue.capitalized, systemImage: Self.icons[k]!) }
                    }
                }
                if masks.isEmpty {
                    Text("Add a mask, then shape it on the photo: paint with Brush, drag Linear's lines, or Radial's edge. Each mask has its own light and colour settings.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(masks.indices, id: \.self) { i in
                    HStack {
                        Image(systemName: Self.icons[masks[i].kind]!).frame(width: 18)
                        Text(name(i))
                        if masks[i].invert == true { Text("inverted").font(.caption).foregroundStyle(.secondary) }
                        Spacer()
                        Button { delete(i) } label: { Image(systemName: "trash") }.buttonStyle(.borderless).help("Delete \(name(i))")
                    }
                    .padding(.vertical, 3).padding(.horizontal, 6)
                    .background(selected == i ? Color.accentColor.opacity(0.2) : .clear, in: RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
                    .onTapGesture { preview.selectedMask = i }
                }
            } header: { Text("Masks") }
            if let i = selected {
                let m = masks[i]
                Section {
                    if m.kind == .brush {
                        Picker("Brush", selection: $preview.erasing) { Text("Paint").tag(false); Text("Erase").tag(true) }.pickerStyle(.segmented)
                        ValueSlider(title: "Size", value: Binding(get: { preview.brushSize * 100 }, set: { preview.brushSize = ($0 * 10).rounded() / 1000 }),
                                    range: 0.5...15, digits: 1)
                        Toggle("Show painted area", isOn: $preview.maskOverlay)
                    }
                    if m.kind != .linear {
                        ValueSlider(title: "Feather", value: Binding(get: { m.feather ?? 50 }, set: { v in edit(i) { $0.feather = abs(v - 50) < 1 ? nil : v.rounded() } }),
                                    range: 0...100, digits: 0)
                    }
                    Toggle("Invert", isOn: Binding(get: { m.invert == true }, set: { v in edit(i) { $0.invert = v ? true : nil } }))
                } header: { Text(name(i)) }
                Section {
                    ForEach(Self.settings, id: \.name) { st in
                        let exposure = st.name == "Exposure"
                        ValueSlider(title: st.name, value: Binding(get: { m[keyPath: st.kp] ?? 0 }, set: { v in
                            let step = exposure ? 0.01 : 1
                            edit(i) { $0[keyPath: st.kp] = abs(v) < (exposure ? 0.03 : 2) ? nil : (v / step).rounded() * step }
                        }), range: st.range, digits: exposure ? 2 : 0)
                    }
                    HStack {
                        Button("Reset Settings") { edit(i) { $0 = LocalMask(kind: $0.kind, shape: $0.shape, feather: $0.feather, invert: $0.invert) } }
                        Spacer()
                        Button("Delete Mask", role: .destructive) { delete(i) }
                    }
                } header: { Text("Adjust") }
            }
        }
        .formStyle(.grouped)
    }

    private func name(_ i: Int) -> String { "\(masks[i].kind.rawValue.capitalized) \(masks[...i].filter { $0.kind == masks[i].kind }.count)" }

    /// New masks start where they usually go: a linear one darkens a sky from the top, a radial one sits in the middle.
    private func add(_ k: MaskKind) {
        let shape: [Double] = k == .linear ? [0.5, 0.05, 0.5, 0.45] : k == .radial ? [0.5, 0.5, 0.25, 0.3] : []
        photo.change(.whole) { $0.masks = ($0.masks ?? []) + [LocalMask(kind: k, shape: shape)] }
        preview.selectedMask = masks.count - 1
        preview.erasing = false
    }

    private func edit(_ i: Int, _ f: (inout LocalMask) -> Void) {
        photo.change(.whole) { p in
            guard var ms = p.masks, ms.indices.contains(i) else { return }
            f(&ms[i]); p.masks = ms
        }
    }

    private func delete(_ i: Int) {
        photo.change(.whole) { $0.masks?.remove(at: i); if $0.masks?.isEmpty == true { $0.masks = nil } }
        preview.selectedMask = nil
    }
}

// MARK: - Chat

struct ChatPanel: View {
    let id: UUID
    let region: Region
    let preview: Preview
    @Environment(Library.self) private var library
    @AppStorage("chatModel") private var model = ""
    @State private var text = ""
    @State private var thinking = false

    private var chat: [Msg] { library.photos.first { $0.id == id }?.chat ?? [] }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Model").foregroundStyle(.secondary)
                Picker("Model", selection: $model) { ForEach(chatModels, id: \.id) { Text($0.name).tag($0.id) } }
                    .labelsHidden().fixedSize()
                    .help("Which Claude model edits for you. Runs through your local Claude Code.")
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 8)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        if chat.isEmpty {
                            Text("Ask Claude to edit this photo, e.g. “darker background, more fog”, “teal and orange grade”, “blur the background like a portrait lens”. You can fine-tune with the sliders afterwards.")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                        ForEach(chat) { m in
                            VStack(alignment: m.user ? .trailing : .leading, spacing: 2) {
                                Text(m.text)
                                    .textSelection(.enabled)
                                    .padding(.horizontal, 10).padding(.vertical, 6)
                                    .background(m.user ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.12), in: .rect(cornerRadius: 10))
                                if let used = m.model { Text(modelName(used)).font(.caption2).foregroundStyle(.tertiary) }
                            }
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
        let (region, model) = (region, model)
        library.update(id) { $0.chat.append(Msg(user: true, text: region == .whole ? q : "(\(region.rawValue.lowercased())) \(q)")) }
        let (before, after) = (preview.before, preview.after)
        Task {
            do {
                let ans = try await Claude.ask(photo, region, model: model, before: before, after: after, q)
                var ph = library.photos.first { $0.id == id } ?? photo
                if let k = ans.preset { ph.setPreset(k, region) }
                let params = try ph.params(for: region).merged(ans.params)
                ph.change(region) { $0 = params }
                ph.chat.append(Msg(user: false, text: ans.reply, model: ans.model))
                library.update(id) { $0 = ph }
            } catch {
                library.update(id) { $0.chat.append(Msg(user: false, text: "⚠️ \(error.localizedDescription)")) }
            }
            thinking = false
        }
    }
}

// MARK: - Sheets

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

struct ExportSettings { var format: String, quality: Double, longEdge: Int, keepMetadata: Bool, suffix: String, videoCodec: String }

/// Format, quality, size and metadata, remembered between exports.
struct ExportSheet: View {
    let count: Int
    var videos = 0  // how many of them are videos
    let onExport: (ExportSettings) -> Void
    @Environment(\.dismiss) private var dismiss
    @AppStorage("exportFormat") private var format = "original"
    @AppStorage("exportQuality") private var quality = 0.92
    @AppStorage("exportLongEdge") private var longEdge = 0
    @AppStorage("exportMetadata") private var keepMetadata = true
    @AppStorage("exportSuffix") private var suffix = "_flash"
    @AppStorage("exportVideoCodec") private var videoCodec = "h264"

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(videos == 0 ? "Export \(count) photo\(count == 1 ? "" : "s")" : "Export \(count) item\(count == 1 ? "" : "s"), \(videos) video\(videos == 1 ? "" : "s")")
                .font(.headline)
            Form {
                Picker("Format", selection: $format) {
                    Text("Same as original (HEIC stays HEIC, others JPEG)").tag("original")
                    Text("JPEG").tag("jpg"); Text("HEIC").tag("heic"); Text("PNG").tag("png"); Text("TIFF").tag("tiff")
                }
                if ["original", "jpg", "heic"].contains(format) {
                    LabeledContent("Quality") {
                        HStack { Slider(value: $quality, in: 0.5...1); Text("\(Int((quality * 100).rounded()))").monospacedDigit().frame(width: 30) }
                    }
                }
                Picker("Size", selection: $longEdge) {
                    Text("Full resolution").tag(0); Text("Long edge 4096 px").tag(4096); Text("Long edge 2048 px").tag(2048); Text("Long edge 1080 px").tag(1080)
                }
                if videos > 0 {
                    Picker("Video", selection: $videoCodec) {
                        Text("H.264 (plays everywhere)").tag("h264"); Text("HEVC (smaller)").tag("hevc")
                    }
                    Text("Videos are saved as QuickTime movies with their sound. Every frame is edited, so a long clip at full resolution takes a while; a smaller size is much quicker.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Keep camera info, date and location", isOn: $keepMetadata)
                TextField("Add to file names", text: $suffix)
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Choose Folder…") {
                    let s = ExportSettings(format: format, quality: quality, longEdge: longEdge, keepMetadata: keepMetadata, suffix: suffix,
                                           videoCodec: videoCodec)
                    dismiss()
                    DispatchQueue.main.async { onExport(s) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
